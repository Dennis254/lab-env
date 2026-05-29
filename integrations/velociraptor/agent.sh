#!/usr/bin/env bash
#
# Velociraptor client profile for lab endpoints.

set -euo pipefail

ACTION="${1:?action saknas}"
TARGET_OS="${2:?target os saknas}"
TARGET_NAME="${3:?target name saknas}"
TARGET_ADDR="${4:-}"

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${INTEGRATION_CONFIG:-$PROFILE_DIR/config.env}"
CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"

SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

c_reset=$'\e[0m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

if [[ ! -f "$CONFIG_FILE" && -f "$PROFILE_DIR/config.env.example" ]]; then
    warn "Config saknas, använder example defaults"
    CONFIG_FILE="$PROFILE_DIR/config.env.example"
fi

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

VELOCIRAPTOR_FRONTEND_HOST="${VELOCIRAPTOR_FRONTEND_HOST:-10.30.0.30}"
VELOCIRAPTOR_INSTALLER_HTTP_PORT="${VELOCIRAPTOR_INSTALLER_HTTP_PORT:-8082}"
VELOCIRAPTOR_INSTALLER_BASE_URL="${VELOCIRAPTOR_INSTALLER_BASE_URL:-http://${VELOCIRAPTOR_FRONTEND_HOST}:${VELOCIRAPTOR_INSTALLER_HTTP_PORT}}"
VELOCIRAPTOR_CLIENT_INSTALL_DIR_LINUX="${VELOCIRAPTOR_CLIENT_INSTALL_DIR_LINUX:-/opt/velociraptor}"
VELOCIRAPTOR_CLIENT_CONFIG_LINUX="${VELOCIRAPTOR_CLIENT_CONFIG_LINUX:-/etc/velociraptor/client.config.yaml}"
VELOCIRAPTOR_CLIENT_INSTALL_DIR_WINDOWS="${VELOCIRAPTOR_CLIENT_INSTALL_DIR_WINDOWS:-C:\\Program Files\\Velociraptor}"
VELOCIRAPTOR_CLIENT_SERVICE_NAME="${VELOCIRAPTOR_CLIENT_SERVICE_NAME:-Velociraptor}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

shell_quote() {
    printf '%q' "$1"
}

json_config() {
    jq -nc \
      --arg base_url "$VELOCIRAPTOR_INSTALLER_BASE_URL" \
      --arg install_dir "$VELOCIRAPTOR_CLIENT_INSTALL_DIR_WINDOWS" \
      --arg service_name "$VELOCIRAPTOR_CLIENT_SERVICE_NAME" \
      '{
        base_url: $base_url,
        install_dir: $install_dir,
        service_name: $service_name
      }'
}

run_linux_install() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle installera Velociraptor på $TARGET_NAME från $VELOCIRAPTOR_INSTALLER_BASE_URL"
        return 0
    fi

    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" 'sudo bash -s' <<EOF
set -euo pipefail
BASE_URL=$(shell_quote "$VELOCIRAPTOR_INSTALLER_BASE_URL")
INSTALL_DIR=$(shell_quote "$VELOCIRAPTOR_CLIENT_INSTALL_DIR_LINUX")
CONFIG_PATH=$(shell_quote "$VELOCIRAPTOR_CLIENT_CONFIG_LINUX")

if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ca-certificates curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl
    else
        echo "Hittar ingen känd pakethanterare för curl" >&2
        exit 1
    fi
fi

install -d -m 0755 "\$INSTALL_DIR"
install -d -m 0755 "\$(dirname "\$CONFIG_PATH")"
curl -fL --retry 3 -o "\$INSTALL_DIR/velociraptor.tmp" "\$BASE_URL/velociraptor-linux-amd64"
mv "\$INSTALL_DIR/velociraptor.tmp" "\$INSTALL_DIR/velociraptor"
chmod 0755 "\$INSTALL_DIR/velociraptor"
curl -fL --retry 3 -o "\$CONFIG_PATH.tmp" "\$BASE_URL/client.config.yaml"
mv "\$CONFIG_PATH.tmp" "\$CONFIG_PATH"
chmod 0644 "\$CONFIG_PATH"

cat > /etc/systemd/system/velociraptor-client.service <<UNIT
[Unit]
Description=Velociraptor client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=\$INSTALL_DIR/velociraptor --config \$CONFIG_PATH client
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now velociraptor-client.service
systemctl restart velociraptor-client.service
EOF
}

run_linux_verify() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle verifiera Velociraptor på $TARGET_NAME"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" "sudo test -x '$VELOCIRAPTOR_CLIENT_INSTALL_DIR_LINUX/velociraptor' && sudo test -s '$VELOCIRAPTOR_CLIENT_CONFIG_LINUX' && sudo systemctl is-active --quiet velociraptor-client.service"
}

run_linux_remove() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle stoppa Velociraptor på $TARGET_NAME"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" "sudo systemctl disable --now velociraptor-client.service 2>/dev/null || true"
}

qga() {
    local domain="$1" payload="$2"
    virsh --connect "$CONNECT_URI" qemu-agent-command "$domain" --timeout "$QGA_TIMEOUT" "$payload"
}

wait_for_agent() {
    local domain="$1" i
    for i in $(seq 1 90); do
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
        sleep 2
    done

    exitcode="$(jq -r '.return.exitcode // 0' <<<"$status")"
    out="$(jq -r '.return."out-data" // empty' <<<"$status")"
    err="$(jq -r '.return."err-data" // empty' <<<"$status")"

    [[ -n "$out" ]] && printf '%s' "$out" | base64 -d 2>/dev/null || true
    [[ -n "$err" ]] && printf '%s' "$err" | base64 -d >&2 2>/dev/null || true
    [[ "$exitcode" == "0" ]] || return "$exitcode"
}

run_windows_script() {
    local mode="$1"
    require_cmd virsh
    require_cmd jq
    require_cmd iconv
    require_cmd base64
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle köra Velociraptor $mode på $TARGET_NAME"
        return 0
    fi
    if [[ "$(virsh --connect "$CONNECT_URI" domstate "$TARGET_NAME" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        warn "$TARGET_NAME är inte igång - hoppar över"
        return 0
    fi
    wait_for_agent "$TARGET_NAME" || die "$TARGET_NAME QGA svarar inte"

    local config_b64
    config_b64="$(json_config | base64 -w0)"

    guest_exec_encoded_powershell "$TARGET_NAME" "\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$mode = '$mode'
\$cfg = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$config_b64')) | ConvertFrom-Json
\$installDir = \$cfg.install_dir
\$serviceName = \$cfg.service_name
\$exe = Join-Path \$installDir 'velociraptor.exe'
\$config = Join-Path \$installDir 'client.config.yaml'

if (\$mode -eq 'install') {
    New-Item -ItemType Directory -Path \$installDir -Force | Out-Null

    \$svc = Get-Service -Name \$serviceName -ErrorAction SilentlyContinue
    if (\$svc) {
        Stop-Service -Name \$serviceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if ((Test-Path \$exe) -and (Test-Path \$config)) {
            & \$exe --config \$config service remove | Out-Null
        }
        Start-Sleep -Seconds 2
    }
    Get-Process -Name 'velociraptor' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    \$tmpExe = \$exe + '.download'
    \$tmpConfig = \$config + '.download'
    Invoke-WebRequest -UseBasicParsing -Uri (\$cfg.base_url + '/velociraptor-windows-amd64.exe') -OutFile \$tmpExe
    Invoke-WebRequest -UseBasicParsing -Uri (\$cfg.base_url + '/client.config.yaml') -OutFile \$tmpConfig
    Move-Item -Path \$tmpExe -Destination \$exe -Force
    Move-Item -Path \$tmpConfig -Destination \$config -Force

    & \$exe --config \$config service install | Out-Null
    Start-Service -Name \$serviceName
}
elseif (\$mode -eq 'verify') {
    if (-not (Test-Path \$exe)) { throw 'Velociraptor executable missing' }
    if (-not (Test-Path \$config)) { throw 'Velociraptor client config missing' }
    \$svc = Get-Service -Name \$serviceName -ErrorAction SilentlyContinue
    if (-not \$svc) { throw 'Velociraptor service missing' }
    if (\$svc.Status -ne 'Running') { Start-Service -Name \$serviceName }
    Get-Service -Name \$serviceName | Select-Object Name,Status | ConvertTo-Json -Compress
}
elseif (\$mode -eq 'remove') {
    \$svc = Get-Service -Name \$serviceName -ErrorAction SilentlyContinue
    if (\$svc) {
        Stop-Service -Name \$serviceName -Force -ErrorAction SilentlyContinue
        if (Test-Path \$exe) { & \$exe --config \$config service remove | Out-Null }
    }
}
else {
    throw \"Unknown mode: \$mode\"
}"
}

case "$TARGET_OS:$ACTION" in
    linux:install)   run_linux_install ;;
    linux:verify)    run_linux_verify ;;
    linux:remove)    run_linux_remove ;;
    windows:install) run_windows_script install ;;
    windows:verify)  run_windows_script verify ;;
    windows:remove)  run_windows_script remove ;;
    *) die "Okänd kombination: $TARGET_OS:$ACTION" ;;
esac

ok "$TARGET_NAME Velociraptor agent action klar: $ACTION"
