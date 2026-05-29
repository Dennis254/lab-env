#!/usr/bin/env bash
#
# lab-dns.sh - switch endpoint DNS between dev and detonation modes
#
# Usage:
#   ./scripts/lab-dns.sh dev
#   ./scripts/lab-dns.sh detonation
#
# Linux endpoints are configured over SSH on lab-mgmt. Windows endpoints are
# configured via QEMU Guest Agent so the command also works after networking
# inside the guest has changed.

set -euo pipefail

MODE="${1:-}"
[[ "$MODE" == "dev" || "$MODE" == "detonation" ]] || {
    printf 'Usage: %s <dev|detonation>\n' "$0" >&2
    exit 1
}

CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"
INETSIM_DNS="${INETSIM_DNS:-10.30.0.13}"
DEV_DNS="${DEV_DNS:-10.20.0.1}"
DC_DNS="${DC_DNS:-10.20.0.10}"

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
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

require_cmd ssh
require_cmd virsh
require_cmd jq
require_cmd iconv
require_cmd base64

LINUX_VICTIMS=(
    "linux-srv:10.20.0.11"
    "linux-dev:10.20.0.12"
)

WINDOWS_VICTIMS=(
    "win-ep1:52:54:00:6c:20:21:52:54:00:6c:30:21:$DC_DNS"
)

linux_dns_payload='
set -euo pipefail
mode="${1:?}"
dev_dns="${2:?}"
inetsim_dns="${3:?}"

if [[ "$mode" == "detonation" ]]; then
    target_dns="$inetsim_dns"
else
    target_dns="$dev_dns"
fi

if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    install -d -m 0755 /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-lab-env-lab.conf <<EOF
[Resolve]
DNS=$target_dns
Domains=~.
EOF
    systemctl restart systemd-resolved
    resolvectl flush-caches 2>/dev/null || true
elif command -v nmcli >/dev/null 2>&1; then
    nm_conn() {
        local dev="$1" conn=""
        conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$dev" '\''$2 == dev { print $1; exit }'\'')"
        if [[ -z "$conn" ]]; then
            conn="$(nmcli -t -f NAME connection show 2>/dev/null | awk -F: -v name="System $dev" '\''$1 == name { print $1; exit }'\'')"
        fi
        printf "%s" "$conn"
    }

    mgmt_conn="$(nm_conn mgmt)"
    deto_conn="$(nm_conn deto)"

    if [[ "$mode" == "detonation" ]]; then
        [[ -n "$deto_conn" ]] && nmcli connection modify "$deto_conn" ipv4.dns "$target_dns" ipv4.ignore-auto-dns yes ipv4.dns-priority -50 2>/dev/null || true
        [[ -n "$mgmt_conn" ]] && nmcli connection modify "$mgmt_conn" ipv4.dns "" ipv4.ignore-auto-dns yes ipv4.dns-priority 100 2>/dev/null || true
        [[ -n "$deto_conn" ]] && nmcli connection up "$deto_conn" >/dev/null 2>&1 || true
    else
        [[ -n "$mgmt_conn" ]] && nmcli connection modify "$mgmt_conn" ipv4.dns "$target_dns" ipv4.ignore-auto-dns yes ipv4.dns-priority -50 2>/dev/null || true
        [[ -n "$deto_conn" ]] && nmcli connection modify "$deto_conn" ipv4.dns "" ipv4.ignore-auto-dns yes ipv4.dns-priority 100 2>/dev/null || true
        [[ -n "$mgmt_conn" ]] && nmcli connection up "$mgmt_conn" >/dev/null 2>&1 || true
    fi

    cat > /etc/resolv.conf <<EOF
# Managed by lab-env lab-dns.sh
nameserver $target_dns
EOF
elif command -v resolvconf >/dev/null 2>&1; then
    install -d -m 0755 /etc/resolvconf/resolv.conf.d
    cat > /etc/resolvconf/resolv.conf.d/head <<EOF
# Managed by lab-env lab-dns.sh
nameserver $target_dns
EOF
    resolvconf -u
else
    cat > /etc/resolv.conf <<EOF
# Managed by lab-env lab-dns.sh
nameserver $target_dns
EOF
fi

printf "dns=%s\n" "$target_dns"
'

configure_linux() {
    local name="$1" ip="$2" target_dns
    if [[ "$MODE" == "detonation" ]]; then
        target_dns="$INETSIM_DNS"
    else
        target_dns="$DEV_DNS"
    fi

    info "$name Linux DNS -> $target_dns"
    ssh "${SSH_OPTS[@]}" "dennis@$ip" \
        "sudo bash -s -- '$MODE' '$DEV_DNS' '$INETSIM_DNS'" <<< "$linux_dns_payload"
}

qga() {
    local domain="$1" payload="$2"
    virsh --connect "$CONNECT_URI" qemu-agent-command "$domain" --timeout "$QGA_TIMEOUT" "$payload"
}

wait_for_agent() {
    local domain="$1" i
    for i in $(seq 1 60); do
        if qga "$domain" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

guest_exec_encoded_powershell() {
    local domain="$1" ps="$2"
    local encoded payload response pid status exited exitcode out err

    encoded="$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
    payload="$(
        jq -nc --arg encoded "$encoded" '{
          "execute": "guest-exec",
          "arguments": {
            "path": "powershell.exe",
            "arg": [
              "-NoProfile",
              "-NonInteractive",
              "-ExecutionPolicy",
              "Bypass",
              "-EncodedCommand",
              $encoded
            ],
            "capture-output": true
          }
        }'
    )"

    response="$(qga "$domain" "$payload")"
    pid="$(jq -r '.return.pid' <<<"$response")"
    [[ -n "$pid" && "$pid" != "null" ]] || die "Kunde inte starta PowerShell i $domain: $response"

    while true; do
        status="$(qga "$domain" "$(jq -nc --argjson pid "$pid" '{"execute":"guest-exec-status","arguments":{"pid":$pid}}')")"
        exited="$(jq -r '.return.exited // false' <<<"$status")"
        [[ "$exited" == "true" ]] && break
        sleep 1
    done

    exitcode="$(jq -r '.return.exitcode // 0' <<<"$status")"
    out="$(jq -r '.return."out-data" // empty' <<<"$status")"
    err="$(jq -r '.return."err-data" // empty' <<<"$status")"

    [[ -n "$out" ]] && printf '%s' "$out" | base64 -d 2>/dev/null || true
    [[ -n "$err" ]] && printf '%s' "$err" | base64 -d >&2 2>/dev/null || true
    [[ "$exitcode" == "0" ]] || return "$exitcode"
}

windows_dns_payload() {
    local mode="$1" mgmt_mac="$2" deto_mac="$3" dev_dns="$4"
    local mode_b64 mgmt_b64 deto_b64 dev_b64 inetsim_b64
    mode_b64="$(printf '%s' "$mode" | base64 -w0)"
    mgmt_b64="$(printf '%s' "$mgmt_mac" | base64 -w0)"
    deto_b64="$(printf '%s' "$deto_mac" | base64 -w0)"
    dev_b64="$(printf '%s' "$dev_dns" | base64 -w0)"
    inetsim_b64="$(printf '%s' "$INETSIM_DNS" | base64 -w0)"

cat <<EOF
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$mode = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$mode_b64"))
\$mgmtMac = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$mgmt_b64")).Replace(":","-").ToUpperInvariant()
\$detoMac = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$deto_b64")).Replace(":","-").ToUpperInvariant()
\$devDns = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$dev_b64"))
\$inetsimDns = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$inetsim_b64"))

\$mgmt = Get-NetAdapter | Where-Object { \$_.MacAddress -eq \$mgmtMac } | Select-Object -First 1
\$deto = Get-NetAdapter | Where-Object { \$_.MacAddress -eq \$detoMac } | Select-Object -First 1
if (-not \$mgmt) { throw "mgmt adapter not found: \$mgmtMac" }
if (-not \$deto) { throw "deto adapter not found: \$detoMac" }

if (\$mode -eq "detonation") {
    Set-DnsClientServerAddress -InterfaceIndex \$deto.InterfaceIndex -ServerAddresses \$inetsimDns
    Set-DnsClientServerAddress -InterfaceIndex \$mgmt.InterfaceIndex -ServerAddresses \$devDns
    Write-Output "deto_dns=\$inetsimDns"
} else {
    Set-DnsClientServerAddress -InterfaceIndex \$mgmt.InterfaceIndex -ServerAddresses \$devDns
    Set-DnsClientServerAddress -InterfaceIndex \$deto.InterfaceIndex -ResetServerAddresses
    Write-Output "mgmt_dns=\$devDns"
}
EOF
}

configure_windows() {
    local domain="$1" mgmt_mac="$2" deto_mac="$3" dev_dns="$4" target_dns
    if [[ "$MODE" == "detonation" ]]; then
        target_dns="$INETSIM_DNS"
    else
        target_dns="$dev_dns"
    fi

    info "$domain Windows DNS -> $target_dns"
    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$domain är inte igång - hoppar över DNS-växling"
        return 0
    fi
    if ! wait_for_agent "$domain"; then
        warn "$domain QGA svarar inte - hoppar över DNS-växling"
        return 0
    fi
    guest_exec_encoded_powershell "$domain" "$(windows_dns_payload "$MODE" "$mgmt_mac" "$deto_mac" "$dev_dns")"
}

info "Sätter DNS-läge: $MODE"

for entry in "${LINUX_VICTIMS[@]}"; do
    IFS=: read -r name ip <<< "$entry"
    configure_linux "$name" "$ip"
done

for entry in "${WINDOWS_VICTIMS[@]}"; do
    IFS=: read -r domain m1 m2 m3 m4 m5 m6 d1 d2 d3 d4 d5 d6 dev_dns <<< "$entry"
    configure_windows "$domain" "$m1:$m2:$m3:$m4:$m5:$m6" "$d1:$d2:$d3:$d4:$d5:$d6" "$dev_dns"
done

ok "DNS-läge satt: $MODE"
