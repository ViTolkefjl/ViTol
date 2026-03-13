#!/bin/bash
# Module 3 local runner (run on each target VM)

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"

ROLE="${1:-}"
PASS_ADM="P@ssw0rd"
ROOT_PASS="root"

DEF_HQ_SRV_IP="192.168.10.2"
DEF_BR_SRV_IP="192.168.100.2"
DEF_HQ_CLI_IP="192.168.20.2"

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
DEF_HQ_RTR_IP="172.16.1.2"
DEF_BR_RTR_IP="172.16.2.2"

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

  DEF_HQ_RTR_IP="172.16.${WAN_C}.2"
  WAN_D="$(next_octet "$WAN_C" 37)"
  DEF_BR_RTR_IP="172.16.${WAN_D}.2"

  echo ">>> CLIENT_KEY accepted: $CLIENT_KEY"
fi

HQ_SRV_IP="$DEF_HQ_SRV_IP"
BR_SRV_IP="$DEF_BR_SRV_IP"
HQ_CLI_IP="$DEF_HQ_CLI_IP"
HQ_RTR_IP="$DEF_HQ_RTR_IP"
BR_RTR_IP="$DEF_BR_RTR_IP"
SSH_PORT="2026"

if [ -z "$ROLE" ]; then
  echo "Usage: $0 {br-srv|hq-cli|hq-rtr|br-rtr|hq-srv}"
  exit 1
fi

install_pkg() {
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

run_if_needed() {
  local title="$1"
  local check_cmd="$2"
  local action_cmd="$3"
  if eval "$check_cmd"; then
    echo ">>> SKIP: $title (already done)"
  else
    echo ">>> RUN: $title"
    eval "$action_cmd"
  fi
}

setup_import_users_br_srv() {
  mkdir -p /mnt/additional
  mount -o loop "/home/user/Загрузки/Additional.iso" /mnt/additional 2>/dev/null || true
  mount -o loop "/home/br-srv/Загрузки/Additional.iso" /mnt/additional 2>/dev/null || true

  local csv_src="/media/cdrom0/Users.csv"
  [ -f /mnt/additional/Users.csv ] && csv_src="/mnt/additional/Users.csv"

  cat > /opt/import_users.sh <<'EOF'
#!/bin/bash
set -euo pipefail
CSV_FILE="${1:-/media/cdrom0/Users.csv}"
[ -f "$CSV_FILE" ] || { echo "Ошибка: Файл $CSV_FILE не найден!"; exit 1; }
tail -n +2 "$CSV_FILE" | while IFS=';' read -r first_name last_name role phone ou street zip city country password
do
  username=$(echo "${first_name:0:1}$last_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || true)
  username=$(echo "$username" | tr -d '[:punct:]')
  password=$(echo "${password:-}" | tr -d ' ')
  first_name=$(echo "${first_name:-}" | tr -d ' ')
  last_name=$(echo "${last_name:-}" | tr -d ' ')
  city=$(echo "${city:-}" | tr -d ' ')
  [ -z "$username" ] && continue
  [ -z "$password" ] && continue
  samba-tool user show "$username" >/dev/null 2>&1 && { echo "[SKIP] $username"; continue; }
  samba-tool user create "$username" "$password" \
    --given-name="$first_name" \
    --surname="$last_name" \
    --description="$role" \
    --company="$city" || true
done
echo "Импорт завершен."
EOF
  chmod +x /opt/import_users.sh
  /opt/import_users.sh "$csv_src" || true
}

setup_hq_cli_pam() {
  grep -q "pam_mkhomedir.so" /etc/pam.d/common-session || \
    echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" >> /etc/pam.d/common-session
}

setup_ipsec() {
  local left_ip="$1"
  local left_id="$2"
  local right_ip="$3"
  local right_id="$4"

  install_pkg strongswan strongswan-starter strongswan-swanctl

  cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
    uniqueids=no

conn %default
    keyexchange=ikev2
    ike=aes256-sha2_256-modp2048!
    esp=aes256-sha2_256!
    leftauth=psk
    rightauth=psk
    auto=start
    dpdaction=restart
    closeaction=restart

conn gre-encrypt
    left=$left_ip
    leftid=@$left_id
    right=$right_ip
    rightid=@$right_id
    type=transport
    authby=psk
    leftprotoport=47/%any
    rightprotoport=47/%any
EOF

  cat > /etc/ipsec.secrets <<EOF
@$left_id @$right_id : PSK "$PASS_ADM"
EOF

  systemctl enable strongswan-starter >/dev/null 2>&1 || true
  rm -f /var/run/charon.pid /var/run/starter.charon.pid || true
  systemctl restart strongswan-starter || true
}

setup_firewall_router() {
  local dest="$1"
  local wan_if="${2:-ens33}"
  install_pkg iptables iptables-persistent
  nft flush ruleset 2>/dev/null || true
  systemctl disable --now nftables 2>/dev/null || true

  cat > /etc/start_iptables.sh <<EOF
#!/bin/bash
set -e
WAN_IF="$wan_if"
DEST="$dest"
IPT="\$(command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
"\$IPT" -F
"\$IPT" -t nat -F
"\$IPT" -t mangle -F
"\$IPT" -t raw -F
"\$IPT" -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A INPUT -p icmp -j ACCEPT
"\$IPT" -A FORWARD -p icmp -j ACCEPT
"\$IPT" -A OUTPUT -p icmp -j ACCEPT
"\$IPT" -A INPUT -p ospf -j ACCEPT
"\$IPT" -A FORWARD -p ospf -j ACCEPT
"\$IPT" -A OUTPUT -p ospf -j ACCEPT
"\$IPT" -A INPUT -p gre -j ACCEPT
"\$IPT" -A FORWARD -p gre -j ACCEPT
"\$IPT" -A OUTPUT -p gre -j ACCEPT
"\$IPT" -A INPUT -p 50 -j ACCEPT
"\$IPT" -A OUTPUT -p 50 -j ACCEPT
"\$IPT" -A FORWARD -p 50 -j ACCEPT
"\$IPT" -A INPUT -p 51 -j ACCEPT
"\$IPT" -A OUTPUT -p 51 -j ACCEPT
"\$IPT" -A FORWARD -p 51 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 500 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 500 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 4500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 4500 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 4500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 53 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp --dport 53 -j ACCEPT
"\$IPT" -A INPUT -p udp --sport 53 -j ACCEPT
"\$IPT" -A INPUT -p tcp --sport 53 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 2049 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 2049 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 111 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 111 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 20048 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 20048 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 88,135,139,389,445,464,636,3268,3269 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 88,137,138,389,464 -j ACCEPT
"\$IPT" -A INPUT -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -P INPUT DROP
"\$IPT" -P FORWARD DROP
"\$IPT" -P OUTPUT DROP
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination \${DEST}:8080
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 80 -j DNAT --to-destination \${DEST}:80
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination \${DEST}:2026
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 8080 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 80 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 2026 -j ACCEPT
EOF
  chmod +x /etc/start_iptables.sh
  /etc/start_iptables.sh
  mkdir -p /etc/iptables
  $(command -v iptables-save 2>/dev/null || echo /usr/sbin/iptables-save) > /etc/iptables/rules.v4
}

setup_rsyslog_server_br_srv() {
  install_pkg rsyslog
  mkdir -p /opt
  cat > /etc/rsyslog.d/10-remote-server.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
$template RemoteLogs,"/opt/%HOSTNAME%/%$YEAR%-%$MONTH%-%$DAY%.log"
if $fromhost-ip != '127.0.0.1' and $fromhost-ip != '__BR_SRV_IP__' then {
    if $syslogseverity <= 4 then {
        ?RemoteLogs
        stop
    }
}
EOF
  sed -i "s/__BR_SRV_IP__/${BR_SRV_IP}/g" /etc/rsyslog.d/10-remote-server.conf
  systemctl restart rsyslog
  systemctl enable rsyslog
}

setup_rsyslog_client() {
  install_pkg rsyslog
  cat > /etc/rsyslog.d/90-remote-forward.conf <<EOF
*.* @${BR_SRV_IP}:514
EOF
  systemctl restart rsyslog
  systemctl enable rsyslog
}

setup_ansible_task8_br_srv() {
  install_pkg ansible sshpass
  mkdir -p /etc/ansible/PC-INFO /etc/ansible/playbook /etc/ansible/router-backups
  cat > /etc/ansible/hosts <<EOF
[hq]
hq-srv ansible_host=${HQ_SRV_IP} ansible_user=root ansible_port=${SSH_PORT} ansible_ssh_pass=${ROOT_PASS}
hq-cli ansible_host=${HQ_CLI_IP} ansible_user=root ansible_port=${SSH_PORT} ansible_ssh_pass=${ROOT_PASS}

[routers]
hq-rtr ansible_host=${HQ_RTR_IP} ansible_user=root ansible_port=${SSH_PORT} ansible_ssh_pass=${ROOT_PASS}
br-rtr ansible_host=${BR_RTR_IP} ansible_user=root ansible_port=${SSH_PORT} ansible_ssh_pass=${ROOT_PASS}

[br]
br-srv ansible_connection=local ansible_user=root
br-rtr ansible_host=${BR_RTR_IP} ansible_user=root ansible_port=${SSH_PORT} ansible_ssh_pass=${ROOT_PASS}

[all:vars]
ansible_become=yes
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no'
EOF
  cat > /etc/ansible/playbook/get_hostname_address.yml <<'EOF'
- name: получение данных с хоста
  hosts: hq
  gather_facts: yes
  tasks:
    - name: создание отчета на BR-SRV
      copy:
        dest: /etc/ansible/PC-INFO/{{ ansible_hostname }}.yml
        content: |
          computer_name: {{ ansible_hostname }}
          ip_address: {{ ansible_default_ipv4.address | default('N/A') }}
      delegate_to: localhost
      run_once: false
EOF

  cat > /etc/ansible/playbook/backup_router_configs.yml <<'EOF'
- name: backup router running-config
  hosts: routers
  gather_facts: no
  tasks:
    - name: collect running-config
      shell: vtysh -c 'show running-config'
      register: running_cfg
      changed_when: false

    - name: save running-config to file on BR-SRV
      copy:
        dest: /etc/ansible/router-backups/{{ inventory_hostname }}-running.cfg
        content: "{{ running_cfg.stdout }}
"
      delegate_to: localhost
EOF
}


setup_cups_hq_srv() {
  install_pkg cups cups-pdf printer-driver-cups-pdf cups-client
  /usr/sbin/usermod -aG lpadmin sshuser || true
  /usr/sbin/cupsctl --remote-admin --remote-any --share-printers
  systemctl enable cups
  systemctl restart cups
}

setup_cups_hq_cli() {
  install_pkg cups-client
  lpadmin -x Virtual_PDF_Printer 2>/dev/null || true
  lpadmin -p Virtual_PDF_Printer -E -v ipp://hq-srv.au-team.irpo/printers/CUPS-PDF -m everywhere
}


setup_restic_hq_cli() {
  install_pkg restic openssh-server
  /usr/sbin/useradd -m -s /bin/bash backupuser 2>/dev/null || true
  echo "backupuser:$PASS_ADM" | /usr/sbin/chpasswd || true

  mkdir -p /home/backupuser/.ssh /backup/etc /backup/webdb
  chown -R backupuser:backupuser /home/backupuser/.ssh /backup
  chmod 700 /home/backupuser/.ssh
  chmod 750 /backup /backup/etc /backup/webdb

  if [ -f /etc/ssh/sshd_config ]; then
    grep -q '^Port 2026$' /etc/ssh/sshd_config || echo 'Port 2026' >> /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    if grep -q '^AllowUsers' /etc/ssh/sshd_config; then
      grep -q '^AllowUsers .*backupuser' /etc/ssh/sshd_config || sed -i 's/^AllowUsers .*/& backupuser/' /etc/ssh/sshd_config
    else
      echo 'AllowUsers root sshuser backupuser' >> /etc/ssh/sshd_config
    fi
  fi
  systemctl restart ssh || systemctl restart sshd || true
}

setup_restic_hq_srv() {
  install_pkg restic sshpass mariadb-client
  /usr/sbin/useradd -m -s /bin/bash irpoadmin 2>/dev/null || true
  echo "irpoadmin:$PASS_ADM" | /usr/sbin/chpasswd || true
  /usr/sbin/usermod -aG sudo irpoadmin || true
  grep -q '^irpoadmin ALL=(ALL:ALL) NOPASSWD: ALL$' /etc/sudoers ||     echo 'irpoadmin ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

  sudo -u irpoadmin mkdir -p /home/irpoadmin/.ssh
  [ -f /home/irpoadmin/.ssh/id_rsa ] ||     sudo -u irpoadmin ssh-keygen -t rsa -b 4096 -f /home/irpoadmin/.ssh/id_rsa -N ""

  cat > /home/irpoadmin/.ssh/config <<'EOF'
Host hq-cli.au-team.irpo
    HostName hq-cli.au-team.irpo
    Port 2026
    User backupuser
    IdentitiesOnly yes
    IdentityFile /home/irpoadmin/.ssh/id_rsa
    PreferredAuthentications publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
  chown -R irpoadmin:irpoadmin /home/irpoadmin/.ssh
  chmod 700 /home/irpoadmin/.ssh
  chmod 600 /home/irpoadmin/.ssh/config /home/irpoadmin/.ssh/id_rsa
  chmod 644 /home/irpoadmin/.ssh/id_rsa.pub

  sudo -u irpoadmin sshpass -p "$PASS_ADM" ssh-copy-id \
    -f \
    -F /dev/null \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PasswordAuthentication=yes \
    -o PubkeyAuthentication=no \
    backupuser@hq-cli.au-team.irpo

  sudo -u irpoadmin ssh \
    -F /dev/null \
    -p "$SSH_PORT" \
    -i /home/irpoadmin/.ssh/id_rsa \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    backupuser@hq-cli.au-team.irpo 'echo RESTIC_SSH_OK' >/dev/null

  sudo -u irpoadmin RESTIC_PASSWORD="$PASS_ADM" restic snapshots --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/etc" >/dev/null 2>&1 || \
    sudo -u irpoadmin RESTIC_PASSWORD="$PASS_ADM" restic init --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/etc"

  sudo -u irpoadmin RESTIC_PASSWORD="$PASS_ADM" restic snapshots --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/webdb" >/dev/null 2>&1 || \
    sudo -u irpoadmin RESTIC_PASSWORD="$PASS_ADM" restic init --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/webdb"

  install_pkg libcap2-bin || true
  setcap 'cap_dac_read_search+ep' "$(command -v restic)" || true
}

setup_restic_scripts_hq_srv() {
  cat > /home/irpoadmin/backup_etc.sh <<'EOF'
#!/bin/bash
export RESTIC_PASSWORD="P@ssw0rd"
restic backup --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/etc" /etc
EOF

  cat > /home/irpoadmin/backup_webdb.sh <<'EOF'
#!/bin/bash
DUMP_FILE="/tmp/webdb_$(date +%Y%m%d_%H%M%S).sql"
mysqldump -u web -pP@ssw0rd webdb > "$DUMP_FILE"
export RESTIC_PASSWORD="P@ssw0rd"
restic backup --repo "sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/webdb" "$DUMP_FILE"
rm -f "$DUMP_FILE"
EOF

  chown irpoadmin:irpoadmin /home/irpoadmin/backup_etc.sh /home/irpoadmin/backup_webdb.sh
  chmod +x /home/irpoadmin/backup_etc.sh /home/irpoadmin/backup_webdb.sh
}

run_restic_backups_hq_srv() {
  sudo -u irpoadmin /home/irpoadmin/backup_etc.sh
  sudo -u irpoadmin /home/irpoadmin/backup_webdb.sh
}

setup_fail2ban_hq_srv() {
  install_pkg fail2ban
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 60
findtime = 600
maxretry = 3
backend = systemd
banaction = iptables-multiport
action = %(action_)s
[sshd]
enabled = true
port = 2026
filter = sshd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
maxretry = 3
bantime = 60
findtime = 600
[sshd-ddos]
enabled = false
EOF
  systemctl restart fail2ban
  systemctl enable fail2ban
}

case "$ROLE" in
  br-srv)
    run_if_needed "BR-SRV user import" "[ -x /opt/import_users.sh ]" "setup_import_users_br_srv"
    run_if_needed "BR-SRV rsyslog server" "systemctl is-active --quiet rsyslog && [ -f /etc/rsyslog.d/10-remote-server.conf ]" "setup_rsyslog_server_br_srv"
    run_if_needed "BR-SRV ansible task8" "[ -f /etc/ansible/playbook/get_hostname_address.yml ] && [ -f /etc/ansible/hosts ]" "setup_ansible_task8_br_srv"
    ;;
  hq-cli)
    run_if_needed "HQ-CLI PAM mkhomedir" "grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session" "setup_hq_cli_pam"
    run_if_needed "HQ-CLI CUPS printer" "lpstat -v 2>/dev/null | grep -q 'Virtual_PDF_Printer'" "setup_cups_hq_cli"
    run_if_needed "HQ-CLI Restic storage" "id backupuser >/dev/null 2>&1 && [ -d /backup/etc ] && [ -d /backup/webdb ] && grep -q '^Port 2026$' /etc/ssh/sshd_config && grep -q '^PasswordAuthentication yes$' /etc/ssh/sshd_config && grep -q '^PubkeyAuthentication yes$' /etc/ssh/sshd_config && ( ! grep -q '^AllowUsers' /etc/ssh/sshd_config || grep -q '^AllowUsers .*backupuser' /etc/ssh/sshd_config )" "setup_restic_hq_cli"
    ;;
  hq-rtr)
    run_if_needed "HQ-RTR IPsec" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null && systemctl is-active --quiet strongswan-starter" "setup_ipsec '$HQ_RTR_IP' 'hq-rtr.au-team.irpo' '$BR_RTR_IP' 'br-rtr.au-team.irpo'"
    run_if_needed "HQ-RTR firewall" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST="${HQ_SRV_IP}"' /etc/start_iptables.sh" "setup_firewall_router '$HQ_SRV_IP' 'ens33'"
    run_if_needed "HQ-RTR rsyslog client" "systemctl is-active --quiet rsyslog && grep -q '^\*\.\* @${BR_SRV_IP}:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" "setup_rsyslog_client"
    ;;
  br-rtr)
    run_if_needed "BR-RTR IPsec" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null && systemctl is-active --quiet strongswan-starter" "setup_ipsec '$BR_RTR_IP' 'br-rtr.au-team.irpo' '$HQ_RTR_IP' 'hq-rtr.au-team.irpo'"
    run_if_needed "BR-RTR firewall" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST="${BR_SRV_IP}"' /etc/start_iptables.sh" "setup_firewall_router '$BR_SRV_IP' 'ens33'"
    run_if_needed "BR-RTR rsyslog client" "systemctl is-active --quiet rsyslog && grep -q '^\*\.\* @${BR_SRV_IP}:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" "setup_rsyslog_client"
    ;;
  hq-srv)
    run_if_needed "HQ-SRV CUPS server" "systemctl is-active --quiet cups && lpstat -v 2>/dev/null | grep -q 'CUPS-PDF'" "setup_cups_hq_srv"
    run_if_needed "HQ-SRV Restic base" "id irpoadmin >/dev/null 2>&1 && [ -f /home/irpoadmin/.ssh/config ] && sudo -u irpoadmin ssh -F /dev/null -p 2026 -i /home/irpoadmin/.ssh/id_rsa -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null backupuser@hq-cli.au-team.irpo true >/dev/null 2>&1" "setup_restic_hq_srv"
    run_if_needed "HQ-SRV Restic scripts" "[ -x /home/irpoadmin/backup_etc.sh ] && [ -x /home/irpoadmin/backup_webdb.sh ]" "setup_restic_scripts_hq_srv"
    run_if_needed "HQ-SRV Restic snapshots" "sudo -u irpoadmin RESTIC_PASSWORD='P@ssw0rd' restic snapshots --repo 'sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/etc' >/dev/null 2>&1 && sudo -u irpoadmin RESTIC_PASSWORD='P@ssw0rd' restic snapshots --repo 'sftp:backupuser@hq-cli.au-team.irpo:2026:/backup/webdb' >/dev/null 2>&1" "setup_restic_hq_srv; setup_restic_scripts_hq_srv; run_restic_backups_hq_srv"
    run_if_needed "HQ-SRV rsyslog client" "systemctl is-active --quiet rsyslog && grep -q '^\*\.\* @${BR_SRV_IP}:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" "setup_rsyslog_client"
    run_if_needed "HQ-SRV fail2ban" "systemctl is-active --quiet fail2ban && [ -f /etc/fail2ban/jail.local ] && grep -q '^port = 2026' /etc/fail2ban/jail.local" "setup_fail2ban_hq_srv"
    ;;
  *)
    echo "Unknown role: $ROLE"
    exit 1
    ;;
esac

echo "=== module3 done for role: $ROLE ==="
if [ "$ROLE" = "hq-srv" ]; then
  echo "CUPS admin: https://hq-srv.au-team.irpo:631/admin"
  echo "Login: sshuser"
  echo "Password: P@ssw0rd"
fi

# Clean command history (best-effort).
history -c 2>/dev/null || true
history -w 2>/dev/null || true
unset HISTFILE || true
rm -f /root/.bash_history /home/user/.bash_history /root/.zsh_history /home/user/.zsh_history 2>/dev/null || true

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
rm -f -- "$SCRIPT_PATH" || true
