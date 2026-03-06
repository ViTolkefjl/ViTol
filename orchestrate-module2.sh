#!/bin/bash
# Orchestrator: run module2 tasks from ISP via SSH (root)

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"

SSH_PORT=2026
ROOT_PASS="root"
PASS_ADM="P@ssw0rd"
ISO_FILE="/home/user/Загрузки/Additional.iso"
ISO_MOUNT="/media/cdrom0"
DOMAIN="au-team.irpo"

# Default IPs (per your layout)
DEF_HQ_SRV_IP="192.168.10.2"
DEF_BR_SRV_IP="192.168.100.2"
DEF_HQ_RTR_IP="172.16.1.2"
DEF_BR_RTR_IP="172.16.2.2"
DEF_HQ_CLI_IP="192.168.20.2"
DEF_HQ_CLI_NET="192.168.20.0/28"

ALLOWED_CLIENT_KEYS="69 346 524 582 666 714 777 858 903 911 935 948 972"
CLIENT_KEY="$(printf %s "${CLIENT_KEY:-}" | tr -d '\r' | xargs)"
if [ -z "${CLIENT_KEY:-}" ]; then
  echo "ERROR: CLIENT_KEY is required"
  exit 1
fi
if ! printf '%s\n' ${ALLOWED_CLIENT_KEYS} | grep -Fxq "${CLIENT_KEY}"; then
  echo "ERROR: invalid CLIENT_KEY: ${CLIENT_KEY}"
  exit 1
fi

# If CLIENT_KEY is provided, generate deterministic unique addressing
if [ -n "${CLIENT_KEY:-}" ]; then
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "ERROR: sha256sum is required for CLIENT_KEY mode"
    exit 1
  fi

  SEED_HEX="$(echo -n "$CLIENT_KEY" | sha256sum | awk '{print $1}' | cut -c1-8)"
  SEED=$((16#$SEED_HEX))

  BASE_A=$(( (SEED % 200) + 20 ))
  BASE_B=$(( ((SEED / 257) % 200) + 20 ))
  WAN_C=$(( ((SEED / 65537) % 200) + 20 ))

  next_octet() {
    local base="$1" off="$2"
    echo $(( ((base - 20 + off) % 200) + 20 ))
  }

  O1="$(next_octet "$BASE_B" 0)"
  O2="$(next_octet "$BASE_B" 1)"
  O4="$(next_octet "$BASE_B" 3)"

  DEF_HQ_SRV_IP="10.${BASE_A}.${O1}.2"
  DEF_HQ_CLI_IP="10.${BASE_A}.${O2}.2"
  DEF_BR_SRV_IP="10.${BASE_A}.${O4}.2"
  DEF_HQ_CLI_NET="10.${BASE_A}.${O2}.0/28"

  DEF_HQ_RTR_IP="172.16.${WAN_C}.2"
  WAN_D="$(next_octet "$WAN_C" 37)"
  DEF_BR_RTR_IP="172.16.${WAN_D}.2"

  echo ">>> CLIENT_KEY accepted: $CLIENT_KEY"
fi

HQ_SRV_IP="$DEF_HQ_SRV_IP"
BR_SRV_IP="$DEF_BR_SRV_IP"
HQ_RTR_IP="$DEF_HQ_RTR_IP"
BR_RTR_IP="$DEF_BR_RTR_IP"
HQ_CLI_IP="$DEF_HQ_CLI_IP"
HQ_CLI_NET="$DEF_HQ_CLI_NET"

prompt_ip() {
  local label="$1"
  local current="$2"
  local input=""
  read -r -p "$label [$current]: " input
  if [ -n "$input" ]; then
    echo "$input"
  else
    echo "$current"
  fi
}

echo "=== Ввод IP адресов перед проверкой SSH ==="
HQ_RTR_IP="$(prompt_ip "HQ-RTR IP" "$HQ_RTR_IP")"
BR_RTR_IP="$(prompt_ip "BR-RTR IP" "$BR_RTR_IP")"
HQ_SRV_IP="$(prompt_ip "HQ-SRV IP" "$HQ_SRV_IP")"
BR_SRV_IP="$(prompt_ip "BR-SRV IP" "$BR_SRV_IP")"
HQ_CLI_IP="$(prompt_ip "HQ-CLI IP" "$HQ_CLI_IP")"
echo "Используем IP: HQ-RTR=$HQ_RTR_IP BR-RTR=$BR_RTR_IP HQ-SRV=$HQ_SRV_IP BR-SRV=$BR_SRV_IP HQ-CLI=$HQ_CLI_IP"

echo ">>> Pre-flight: sshpass + route to HQ-CLI"
apt-get install -y sshpass curl
/sbin/ip route add "$HQ_CLI_NET" via "$HQ_RTR_IP" || true

ssh_run() {
  local host="$1"
  local role="$2"
  echo ">>> [$role] Подключение к $host:$SSH_PORT"
  sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    root@"$host" "ROLE='$role' PASS_ADM='$PASS_ADM' ISO_FILE='$ISO_FILE' ISO_MOUNT='$ISO_MOUNT' DOMAIN='$DOMAIN' HQ_SRV_IP='$HQ_SRV_IP' BR_SRV_IP='$BR_SRV_IP' HQ_RTR_IP='$HQ_RTR_IP' BR_RTR_IP='$BR_RTR_IP' HQ_CLI_IP='$HQ_CLI_IP' HQ_CLI_NET='$HQ_CLI_NET' bash -s" <<'REMOTE'
set -e
install_pkg() { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
prepare_iso_mount() {
  # Prefer VMware CD/DVD mount if present.
  if [ -d "/media/cdrom0" ]; then
    ISO_MOUNT="/media/cdrom0"
    return 0
  fi
  mkdir -p "$ISO_MOUNT"
  if [ -f "$ISO_FILE" ]; then
    mountpoint -q "$ISO_MOUNT" || mount -o loop "$ISO_FILE" "$ISO_MOUNT" || true
    return 0
  fi
  return 1
}
require_port_listen() {
  local port="$1"
  if ! ss -lnt | grep -q ":${port}\\b"; then
    echo "ERROR: expected listening TCP port ${port}, but it is not open"
    exit 1
  fi
}

setup_chrony_client() {
  install_pkg chrony curl
  cat <<CONF > /etc/chrony/chrony.conf
server 172.16.1.1 iburst
CONF
  systemctl restart chrony
  systemctl enable chrony
}

case "$ROLE" in
  "br-srv")
    setup_chrony_client
    install_pkg samba winbind libnss-winbind krb5-user smbclient ldb-tools python3-cryptography expect sshpass
    cat <<CONF > /etc/krb5.conf
[libdefaults]
    default_realm = AU-TEAM.IRPO
    dns_lookup_kdc = true
    dns_lookup_realm = false
[realms]
    AU-TEAM.IRPO = {
        kdc = br-srv.au-team.irpo
        admin_server = br-srv.au-team.irpo
    }
[domain_realm]
    .au-team.irpo = AU-TEAM.IRPO
    au-team.irpo = AU-TEAM.IRPO
CONF
    rm -f /etc/samba/smb.conf
    systemctl stop samba winbind smbd nmbd || true
    samba-tool domain provision --realm=AU-TEAM.IRPO --domain=AU-TEAM --server-role=dc --dns-backend=BIND9_DLZ --adminpass=$PASS_ADM --option="dns forwarder=8.8.8.8"
    rm -f /var/lib/samba/private/krb5.conf
    ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf
    systemctl unmask samba-ad-dc
    systemctl enable samba-ad-dc
    systemctl restart samba-ad-dc

    samba-tool user add user1 $PASS_ADM
    samba-tool group addmembers "Domain Admins" user1
    for i in 1 2 3 4 5; do samba-tool user add hquser$i $PASS_ADM; done
    samba-tool group add hq
    for i in 1 2 3 4 5; do samba-tool group addmembers hq hquser$i; done

    install_pkg ansible
    mkdir -p /etc/ansible
    cat <<CONF > /etc/ansible/ansible.cfg
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
CONF
    cat <<CONF > /etc/ansible/hosts
[hq]
HQ-SRV ansible_host=${HQ_SRV_IP} ansible_user=root ansible_port=2026 ansible_ssh_pass=${ROOT_PASS}
HQ-CLI ansible_host=${HQ_CLI_IP} ansible_user=root ansible_port=2026 ansible_ssh_pass=${ROOT_PASS}
HQ-RTR ansible_host=${HQ_RTR_IP} ansible_user=root ansible_port=2026 ansible_ssh_pass=${ROOT_PASS}
[br]
BR-SRV ansible_connection=local ansible_user=root
BR-RTR ansible_host=${BR_RTR_IP} ansible_user=root ansible_port=2026 ansible_ssh_pass=${ROOT_PASS}
[all:vars]
ansible_become=yes
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no'
CONF
    echo -e "\n\n\n" | ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa

    install_pkg docker.io docker-compose
    if ! command -v docker >/dev/null 2>&1; then
      echo "ERROR: docker is not installed on br-srv"
      exit 1
    fi
    if ! command -v docker-compose >/dev/null 2>&1; then
      install_pkg docker-compose
    fi
    if ! prepare_iso_mount; then
      echo "ERROR: ISO source not found on br-srv (expected /media/cdrom0 or $ISO_FILE)"
      exit 1
    fi
    if [ -d "$ISO_MOUNT/docker" ]; then
      docker load -i $ISO_MOUNT/docker/mariadb_latest.tar
      docker load -i $ISO_MOUNT/docker/site_latest.tar
        mkdir -p /opt/testapp
        cat <<CONF > /opt/testapp/docker-compose.yml
version: '3.8'
services:
  testapp:
    image: site:latest
    container_name: testapp
    ports:
      - "8080:8000"
    depends_on:
      - db
    environment:
      - DB_HOST=db
      - DB_NAME=testdb
      - DB_TYPE=maria
      - DB_USER=test
      - DB_PASS=$PASS_ADM
      - SERVER_PORT=8080
    restart: unless-stopped
  db:
    image: mariadb:10.11
    container_name: db
    environment:
      - MARIADB_ROOT_PASSWORD=root$PASS_ADM
      - MARIADB_DATABASE=testdb
      - MARIADB_USER=test
      - MARIADB_PASSWORD=$PASS_ADM
    volumes:
      - db_data:/var/lib/mysql
    restart: unless-stopped
volumes:
  db_data:
CONF
      cd /opt/testapp && docker-compose down -v --remove-orphans || true
      cd /opt/testapp && docker-compose up -d
      docker restart db
      sleep 8
      if ! docker exec db mariadb -uroot -p"root$PASS_ADM" -e "SELECT 1;" >/dev/null 2>&1; then
        docker exec db mariadb -uroot -e "SELECT 1;" >/dev/null 2>&1 || true
      fi
      if docker exec db mariadb -uroot -p"root$PASS_ADM" -e "SELECT 1;" >/dev/null 2>&1; then
        DB_ROOT_AUTH="-uroot -proot$PASS_ADM"
      else
        DB_ROOT_AUTH="-uroot"
      fi
      docker exec db mariadb $DB_ROOT_AUTH -e "CREATE DATABASE IF NOT EXISTS testdb;" || true
      docker exec db mariadb $DB_ROOT_AUTH -e "CREATE USER IF NOT EXISTS 'test'@'%' IDENTIFIED BY '$PASS_ADM';" || true
      docker exec db mariadb $DB_ROOT_AUTH -e "ALTER USER 'test'@'%' IDENTIFIED BY '$PASS_ADM';" || true
      docker exec db mariadb $DB_ROOT_AUTH -e "GRANT ALL PRIVILEGES ON testdb.* TO 'test'@'%'; FLUSH PRIVILEGES;" || true
      docker restart testapp
      ok=0
      for _ in $(seq 1 24); do
        if /usr/bin/curl -fsS http://127.0.0.1:8080 >/dev/null 2>&1; then
          ok=1
          break
        fi
        sleep 5
      done
      if [ "$ok" -ne 1 ]; then
        echo "ERROR: testapp is not reachable on br-srv localhost:8080"
        docker ps || true
        docker logs --tail 80 db || true
        docker logs --tail 80 testapp || true
        exit 1
      fi
    else
      echo "ERROR: docker images directory not found in ISO: $ISO_MOUNT/docker"
      exit 1
    fi
    require_port_listen 8080
    perl -0777 -pi -e 's/ansible_ssh_pass=\\S*/ansible_ssh_pass=root/g' /etc/ansible/hosts
    ;;

  "hq-srv")
    setup_chrony_client
    install_pkg bind9
    cat <<CONF >> /etc/bind/zones/db.au-team.irpo
_ldap._tcp.au-team.irpo.        IN      SRV     0 100 389       br-srv.au-team.irpo.
_kerberos._tcp.au-team.irpo.    IN      SRV     0 100 88        br-srv.au-team.irpo.
_kerberos._udp.au-team.irpo.    IN      SRV     0 100 88        br-srv.au-team.irpo.
_kpasswd._tcp.au-team.irpo      IN      SRV     0 100 464       br-srv.au-team.irpo.
_kpasswd._udp.au-team.irpo      IN      SRV     0 100 464       br-srv.au-team.irpo.
_ldap._tcp.dc._msdcs.au-team.irpo       IN      SRV     0 100 389       br-srv.au-team.irpo.
CONF
    sed -i '/samba-dlz/d' /etc/bind/named.conf.local
    sed -i '/allow-update/d' /etc/bind/named.conf.options
    systemctl restart named || systemctl restart bind9

    install_pkg mdadm parted
    root_src="$(findmnt -n -o SOURCE / || true)"
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    if [ -z "$root_disk" ]; then
      root_disk="$(basename "$root_src" | sed -E 's/p?[0-9]+$//')"
    fi
    raid_disks=()
    while read -r d; do
      [ -z "$d" ] && continue
      [ "$d" = "$root_disk" ] && continue
      # only whole free disks (no partitions/children)
      if [ "$(lsblk -n -o NAME "/dev/$d" | wc -l)" -ne 1 ]; then
        continue
      fi
      raid_disks+=("/dev/$d")
    done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
    if [ "${#raid_disks[@]}" -lt 2 ]; then
      echo "ERROR: not enough free disks for RAID0 on hq-srv"
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
      exit 1
    fi
    RAID_D1="${raid_disks[0]}"
    RAID_D2="${raid_disks[1]}"
    /sbin/mdadm --stop /dev/md0 2>/dev/null || true
    /sbin/mdadm --zero-superblock --force "$RAID_D1" "$RAID_D2" 2>/dev/null || true
    /sbin/wipefs -a "$RAID_D1" 2>/dev/null || true
    /sbin/wipefs -a "$RAID_D2" 2>/dev/null || true
    yes | /sbin/mdadm --create /dev/md0 --level=0 --raid-devices=2 "$RAID_D1" "$RAID_D2"
    /sbin/mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u
    /usr/sbin/parted -s /dev/md0 mklabel gpt
    /usr/sbin/parted -s /dev/md0 mkpart primary ext4 1MiB 100%
    /sbin/mkfs.ext4 -F /dev/md0p1
    mkdir -p /raid
    mount /dev/md0p1 /raid
    grep -q '^/dev/md0p1[[:space:]]\+/raid[[:space:]]' /etc/fstab || \
      echo "/dev/md0p1   /raid   ext4   defaults   0   0" >> /etc/fstab

    install_pkg nfs-kernel-server
    mkdir -p /raid/nfs
    chmod 777 /raid/nfs
    echo "/raid/nfs ${HQ_CLI_NET}(rw,sync,no_subtree_check)" >> /etc/exports
    exportfs -ra
    systemctl enable --now nfs-kernel-server

    install_pkg apache2 mariadb-server php php-mysql libapache2-mod-php
    mysql -e "CREATE DATABASE IF NOT EXISTS webdb;"
    mysql -e "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$PASS_ADM';"
    mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';"
    mysql -e "CREATE USER IF NOT EXISTS 'user'@'localhost' IDENTIFIED BY '$PASS_ADM';"
    mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    if ! prepare_iso_mount; then
      echo "ERROR: ISO source not found on hq-srv (expected /media/cdrom0 or $ISO_FILE)"
      exit 1
    fi
    if [ ! -d "$ISO_MOUNT/web" ]; then
      echo "ERROR: web directory not found in ISO: $ISO_MOUNT/web"
      exit 1
    fi
    mysql webdb < $ISO_MOUNT/web/dump.sql || true
    cp $ISO_MOUNT/web/index.php /var/www/html/
    mkdir -p /var/www/html/images
    cp $ISO_MOUNT/web/logo.png /var/www/html/images/
    sed -i 's/password = "password";/password = "P@ssw0rd";/' /var/www/html/index.php
    sed -i 's/dbname = "db";/dbname = "webdb";/' /var/www/html/index.php
    chown -R www-data:www-data /var/www/html/
    chmod -R 755 /var/www/html/
    rm -f /var/www/html/index.html
    sed -i 's/DirectoryIndex index.html/DirectoryIndex index.php index.html/' /etc/apache2/mods-enabled/dir.conf
    systemctl enable --now apache2
    require_port_listen 80
    ;;

  "hq-cli")
    setup_chrony_client
    install_pkg openssh-server
    sed -i 's/#Port 22/Port 2026/' /etc/ssh/sshd_config
    sed -i 's/Port 22/Port 2026/' /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd

    cat <<CONF > /etc/krb5.conf
[libdefaults]
    default_realm = AU-TEAM.IRPO
    dns_lookup_kdc = true
    dns_lookup_realm = false

[realms]
    AU-TEAM.IRPO = {
        kdc = br-srv.au-team.irpo
        admin_server = br-srv.au-team.irpo
    }

[domain_realm]
    .au-team.irpo = AU-TEAM.IRPO
    au-team.irpo = AU-TEAM.IRPO
CONF

    # Domain join prerequisites (avoid interactive prompts)
    echo "krb5-config krb5-config/default_realm string AU-TEAM.IRPO" | debconf-set-selections
    echo "krb5-config krb5-config/kerberos_servers string br-srv.au-team.irpo" | debconf-set-selections
    echo "krb5-config krb5-config/admin_server string br-srv.au-team.irpo" | debconf-set-selections
    install_pkg realmd sssd oddjob oddjob-mkhomedir adcli samba-common packagekit sssd-tools krb5-user
    install_pkg realmd sssd sssd-tools libnss-sss libpam-sss adcli oddjob oddjob-mkhomedir packagekit samba-common-bin krb5-user

    echo "$PASS_ADM" | realm join -v --user=Administrator AU-TEAM.IRPO || true
    kinit Administrator || true
    klist || true

    # Добавляем sudo по GID доменной группы (если доступно)
    gid=$(getent group "hquser1@au-team.irpo" | cut -d: -f3 || true)
    if [ -n "$gid" ]; then
      grep -q "%#${gid} ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id" /etc/sudoers || \
        echo "%#${gid} ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id" >> /etc/sudoers
    fi

    # NFS client
    install_pkg nfs-common
    showmount -e ${HQ_SRV_IP} || true
    mkdir -p /mnt/nfs
    mount -t nfs ${HQ_SRV_IP}:/raid/nfs /mnt/nfs || true
    grep -q "${HQ_SRV_IP}:/raid/nfs" /etc/fstab || \
      echo "${HQ_SRV_IP}:/raid/nfs /mnt/nfs nfs defaults 0 0" >> /etc/fstab
    mount | grep ' /mnt/nfs ' || true

    # remount test for auto-mount
    umount /mnt/nfs || true
    systemctl daemon-reload || true
    mount -a || true
    mount | grep ' /mnt/nfs ' || echo "WARN: /mnt/nfs is not mounted after mount -a"

    # Yandex Browser (best-effort)
    install_pkg curl gnupg ca-certificates
    if curl -fsSL https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg; then
      echo "deb [signed-by=/usr/share/keyrings/yandex-browser.gpg] https://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
      apt-get update
      install_pkg yandex-browser-stable || true
    else
      echo "WARN: failed to fetch Yandex Browser repo key"
    fi

    useradd -m -s /bin/bash sshuser || true
    echo "sshuser:$PASS_ADM" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
    ;;

  "hq-rtr"|"br-rtr")
    setup_chrony_client
    install_pkg iptables iptables-persistent
    if [ "$ROLE" = "hq-rtr" ]; then
      DEST="$HQ_SRV_IP"
    else
      DEST="$BR_SRV_IP"
    fi
    # гарантируем пароль net_admin
    echo "net_admin:$PASS_ADM" | chpasswd || true
    /usr/sbin/iptables -t nat -A PREROUTING -i ens33 -p tcp --dport 8080 -j DNAT --to-destination ${DEST}:8080
    /usr/sbin/iptables -t nat -A PREROUTING -i ens33 -p tcp --dport 80 -j DNAT --to-destination ${DEST}:80
    /usr/sbin/iptables -t nat -A PREROUTING -i ens33 -p tcp --dport 2026 -j DNAT --to-destination ${DEST}:2026
    /usr/sbin/iptables -A FORWARD -p tcp -d ${DEST} --dport 8080 -j ACCEPT
    /usr/sbin/iptables -A FORWARD -p tcp -d ${DEST} --dport 80 -j ACCEPT
    /usr/sbin/iptables -A FORWARD -p tcp -d ${DEST} --dport 2026 -j ACCEPT
    /usr/sbin/iptables-save > /etc/iptables/rules.v4
    ;;
esac
REMOTE
}

echo "=== Orchestrating module2 from ISP ==="

check_ssh() {
  local host="$1"
  sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT" \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    root@"$host" "echo ok" >/dev/null 2>&1
}

remote_ok() {
  local host="$1"
  local cmd="$2"
  sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT"     -o ConnectTimeout=5     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o IdentitiesOnly=yes     -o PreferredAuthentications=password     -o PubkeyAuthentication=no     root@"$host" "bash -lc "$cmd"" >/dev/null 2>&1
}

resolve_hq_cli_ip() {
  # Try default first, then DHCP fallback candidates.
  HQ_CLI_NET_BASE="${HQ_CLI_IP%.*}"
  for candidate in "$HQ_CLI_IP" "${HQ_CLI_NET_BASE}.3" "${HQ_CLI_NET_BASE}.4"; do
    [ -z "$candidate" ] && continue
    echo ">>> Проверка SSH: hq-cli ($candidate)"
    if check_ssh "$candidate"; then
      HQ_CLI_IP="$candidate"
      echo ">>> SSH OK: hq-cli (используем $HQ_CLI_IP)"
      return 0
    fi
  done
  echo "!!! SSH FAIL: hq-cli (пробовали: ${HQ_CLI_IP}, ${HQ_CLI_NET_BASE}.3, ${HQ_CLI_NET_BASE}.4)"
  return 1
}

for pair in \
  "$HQ_RTR_IP hq-rtr" \
  "$BR_RTR_IP br-rtr" \
  "$HQ_SRV_IP hq-srv" \
  "$BR_SRV_IP br-srv"
do
  host="${pair%% *}"
  role="${pair##* }"
  echo ">>> Проверка SSH: $role ($host)"
  if check_ssh "$host"; then
    echo ">>> SSH OK: $role"
  else
    echo "!!! SSH FAIL: $role ($host)"
    exit 1
  fi
done

resolve_hq_cli_ip || exit 1

echo ">>> STEP 1: ISP (NTP + Proxy)"
if systemctl is-active --quiet chrony \
  && systemctl is-active --quiet nginx \
  && grep -q 'server_name web.au-team.irpo;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null \
  && grep -q 'server_name docker.au-team.irpo;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null; then
  echo ">>> STEP 1 SKIP: already configured"
else
  # запуск локально на ISP
  ROLE="isp" HQ_SRV_IP="$HQ_SRV_IP" BR_SRV_IP="$BR_SRV_IP" bash -s <<'LOCAL'
set -e
install_pkg() { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

install_pkg chrony nginx apache2-utils sshpass curl
cat <<CONF > /etc/chrony/chrony.conf
server 0.debian.pool.ntp.org iburst
local stratum 5
allow 172.16.0.0/12
allow 192.168.0.0/16
log measurements statistics tracking
CONF
systemctl restart chrony

htpasswd -bc /etc/nginx/.htpasswd WEB P@ssw0rd
cat <<CONF > /etc/nginx/sites-available/reverse_proxy.conf
upstream hq_srv_app { server ${HQ_SRV_IP}:80; }
upstream testapp_app { server ${BR_SRV_IP}:8080; }
server {
    listen 80;
    server_name web.au-team.irpo;
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://hq_srv_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
server {
    listen 80;
    server_name docker.au-team.irpo;
    location / {
        proxy_pass http://testapp_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
CONF
ln -sf /etc/nginx/sites-available/reverse_proxy.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
/usr/sbin/nginx -t
systemctl restart nginx
LOCAL
fi

echo ">>> STEP 2: HQ-RTR & BR-RTR (NAT + Chrony)"
if remote_ok "$HQ_RTR_IP" "systemctl is-active --quiet chrony && ( /usr/sbin/iptables -t nat -S 2>/dev/null || iptables -t nat -S 2>/dev/null ) | grep -q -- '--to-destination ${HQ_SRV_IP}:80'"; then
  echo ">>> STEP 2 SKIP: hq-rtr already configured"
else
  ssh_run "$HQ_RTR_IP" "hq-rtr"
fi
if remote_ok "$BR_RTR_IP" "systemctl is-active --quiet chrony && ( /usr/sbin/iptables -t nat -S 2>/dev/null || iptables -t nat -S 2>/dev/null ) | grep -q -- '--to-destination ${BR_SRV_IP}:80'"; then
  echo ">>> STEP 2 SKIP: br-rtr already configured"
else
  ssh_run "$BR_RTR_IP" "br-rtr"
fi

echo ">>> STEP 3: HQ-SRV (RAID + Web + NFS) — ISO required"
if remote_ok "$HQ_SRV_IP" "systemctl is-active --quiet chrony && mountpoint -q /raid && exportfs -v 2>/dev/null | grep -q '/raid/nfs' && ss -lnt | grep -q ':80\b' && [ -f /var/www/html/index.php ] && [ ! -f /var/www/html/index.html ] && [ -d /var/www/html/images ]"; then
  echo ">>> STEP 3 SKIP: hq-srv already configured"
else
  ssh_run "$HQ_SRV_IP" "hq-srv"
fi
curl -fsSI "http://${HQ_SRV_IP}:80" >/dev/null || {
  echo "ERROR: ISP cannot reach HQ-SRV HTTP on ${HQ_SRV_IP}:80 after STEP 3"
  exit 1
}

echo ">>> STEP 4: BR-SRV (Samba AD + Ansible + Docker) — ISO required"
if remote_ok "$BR_SRV_IP" "systemctl is-active --quiet chrony && systemctl is-active --quiet samba-ad-dc && docker ps --format '{{.Names}}' | grep -qx testapp"; then
  echo ">>> STEP 4 SKIP: br-srv already configured"
else
  # временно ставим 8.8.8.8, если нужно скачать пакеты
  sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT"     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o IdentitiesOnly=yes     -o PreferredAuthentications=password     -o PubkeyAuthentication=no     root@"$BR_SRV_IP" "echo 'nameserver 8.8.8.8' > /etc/resolv.conf" || true
  ssh_run "$BR_SRV_IP" "br-srv"
fi

echo ">>> STEP 5: HQ-CLI (Domain join + NFS)"
if remote_ok "$HQ_CLI_IP" "systemctl is-active --quiet chrony && grep -q '${HQ_SRV_IP}:/raid/nfs /mnt/nfs nfs' /etc/fstab && realm list 2>/dev/null | grep -qi 'realm-name: au-team.irpo'"; then
  echo ">>> STEP 5 SKIP: hq-cli already configured"
else
  ssh_run "$HQ_CLI_IP" "hq-cli"
fi

echo ">>> Ansible ping (from BR-SRV)"
sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  root@"$BR_SRV_IP" "perl -0777 -pi -e '
s/(HQ-SRV .*ansible_user=)\\S+/\${1}root/;
s/(HQ-CLI .*ansible_user=)\\S+/\${1}root/;
s/(HQ-RTR .*ansible_user=)\\S+/\${1}root/;
s/(BR-RTR .*ansible_user=)\\S+/\${1}root/;
s/ansible_ssh_pass=\\S+/ansible_ssh_pass=root/g;
' /etc/ansible/hosts;
grep -q \"ansible_ssh_common_args\" /etc/ansible/hosts || cat >> /etc/ansible/hosts <<'EOF'
[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no'
EOF
ansible all -m ping" || true
echo "=== Done ==="

# Clean command history (best-effort).
history -c 2>/dev/null || true
history -w 2>/dev/null || true
unset HISTFILE || true
rm -f /root/.bash_history /home/user/.bash_history /root/.zsh_history /home/user/.zsh_history 2>/dev/null || true

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
rm -f -- "$SCRIPT_PATH" || true
