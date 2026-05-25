#!/usr/bin/env bash
#
# configure-inetsim.sh - install and configure INetSim on the inetsim VM
#
# Usage:
#   ./scripts/configure-inetsim.sh
#
# Defaults:
#   SSH target:      dennis@10.20.0.13
#   INetSim bind IP: 10.30.0.13

set -euo pipefail

SSH_TARGET="${INETSIM_SSH_TARGET:-dennis@10.20.0.13}"
INETSIM_BIND_IP="${INETSIM_BIND_IP:-10.30.0.13}"
SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
)

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

command -v ssh >/dev/null 2>&1 || die "ssh saknas."

info "Konfigurerar INetSim på $SSH_TARGET (bind: $INETSIM_BIND_IP)"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo INETSIM_BIND_IP='$INETSIM_BIND_IP' bash -s" <<'REMOTE'
set -euo pipefail

CONF="/etc/inetsim/inetsim.conf"
BIND_IP="${INETSIM_BIND_IP:?}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y inetsim dnsutils curl netcat-openbsd

if [[ ! -f "$CONF.aegis-orig" ]]; then
    cp "$CONF" "$CONF.aegis-orig"
fi

set_or_append() {
    local key="$1" value="$2" file="$3"
    if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$file"
    fi
}

set_or_append "service_bind_address" "$BIND_IP" "$CONF"
set_or_append "dns_default_ip" "$BIND_IP" "$CONF"
set_or_append "dns_default_hostname" "www" "$CONF"
set_or_append "dns_default_domainname" "detonation.lab" "$CONF"
set_or_append "create_reports" "yes" "$CONF"
set_or_append "report_language" "en" "$CONF"

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

grep -E "^(service_bind_address|dns_default_ip|dns_default_hostname|dns_default_domainname|create_reports|report_language) " "$CONF"
ss -lntup | grep -E "(${BIND_IP}:53|${BIND_IP}:80|${BIND_IP}:443|${BIND_IP}:25|${BIND_IP}:21)" || true
dig @"$BIND_IP" example.com +short
curl -fsS --connect-timeout 3 "http://${BIND_IP}/" >/dev/null
REMOTE

ok "INetSim är installerat och lyssnar på $INETSIM_BIND_IP"
