#!/usr/bin/env bash
#
# configure-inetsim.sh - install and configure INetSim on the inetsim VM
#
# Usage:
#   ./scripts/configure-inetsim.sh
#
# Defaults:
#   SSH target:      $LAB_ADMIN_USER@10.20.0.13
#   INetSim bind IP: 10.30.0.13

set -euo pipefail

LAB_ADMIN_USER="${LAB_ADMIN_USER:-${USER:-labadmin}}"
SSH_TARGET="${INETSIM_SSH_TARGET:-$LAB_ADMIN_USER@10.20.0.13}"
INETSIM_BIND_IP="${INETSIM_BIND_IP:-10.30.0.13}"
SSH_WAIT_TIMEOUT="${INETSIM_SSH_WAIT_TIMEOUT:-300}"
REMOTE_TIMEOUT="${INETSIM_REMOTE_TIMEOUT:-1200}"
SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
)

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

command -v ssh >/dev/null 2>&1 || die "ssh saknas."
command -v timeout >/dev/null 2>&1 || die "timeout saknas."

wait_for_ssh() {
    local start now
    start="$(date +%s)"
    while true; do
        if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo -n true' >/dev/null 2>&1; then
            return 0
        fi

        now="$(date +%s)"
        if ((now - start >= SSH_WAIT_TIMEOUT)); then
            err "Kan inte nå $SSH_TARGET med SSH + passwordless sudo inom ${SSH_WAIT_TIMEOUT}s."
            err "Kontrollera att VM:n 'inetsim' är igång, att lab-mgmt är uppe och att cloud-init har lagt in rätt SSH-nyckel."
            err "Snabbtest:"
            err "  virsh --connect qemu:///system domstate inetsim"
            err "  ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_TARGET 'cloud-init status --long; ip addr show mgmt'"
            return 1
        fi
        sleep 5
    done
}

info "Konfigurerar INetSim på $SSH_TARGET (bind: $INETSIM_BIND_IP)"

info "Väntar på SSH och passwordless sudo på $SSH_TARGET"
wait_for_ssh

timeout "$REMOTE_TIMEOUT" ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo -n INETSIM_BIND_IP='$INETSIM_BIND_IP' bash -s" <<'REMOTE'
set -euo pipefail

CONF="/etc/inetsim/inetsim.conf"
BIND_IP="${INETSIM_BIND_IP:?}"

export DEBIAN_FRONTEND=noninteractive

echo "[inetsim] Host: $(hostname)"
echo "[inetsim] Bind IP: $BIND_IP"
echo "[inetsim] Väntar på cloud-init/apt-lås om första boot fortfarande pågår..."
cloud-init status --wait >/dev/null 2>&1 || true

echo "[inetsim] Installerar paket..."
apt-get -o Dpkg::Lock::Timeout=600 update
apt-get -o Dpkg::Lock::Timeout=600 install -y inetsim dnsutils curl netcat-openbsd iproute2

if [[ ! -f "$CONF.lab-env-orig" ]]; then
    cp "$CONF" "$CONF.lab-env-orig"
fi

set_or_append() {
    local key="$1" value="$2" file="$3"
    if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$file"
    fi
}

echo "[inetsim] Skriver $CONF..."
set_or_append "service_bind_address" "$BIND_IP" "$CONF"
set_or_append "dns_default_ip" "$BIND_IP" "$CONF"
set_or_append "dns_default_hostname" "www" "$CONF"
set_or_append "dns_default_domainname" "detonation.lab" "$CONF"
set_or_append "create_reports" "yes" "$CONF"
set_or_append "report_language" "en" "$CONF"

echo "[inetsim] Startar om tjänsten..."
systemctl enable inetsim >/dev/null
systemctl restart inetsim

for i in $(seq 1 20); do
    if ss -lntup | grep -q "${BIND_IP}:80"; then
        break
    fi
    sleep 1
done

systemctl --no-pager --full status inetsim >/tmp/inetsim-status.txt || {
    cat /tmp/inetsim-status.txt
    exit 1
}

echo "[inetsim] Verifierar konfiguration och listeners..."
grep -E "^(service_bind_address|dns_default_ip|dns_default_hostname|dns_default_domainname|create_reports|report_language) " "$CONF"
ss -lntup | grep -E "(${BIND_IP}:53|${BIND_IP}:80|${BIND_IP}:443|${BIND_IP}:25|${BIND_IP}:21)" || true
dig @"$BIND_IP" example.com +short
curl -fsS --connect-timeout 3 "http://${BIND_IP}/" >/dev/null
REMOTE

ok "INetSim är installerat och lyssnar på $INETSIM_BIND_IP"
