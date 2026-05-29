#!/usr/bin/env bash
#
# Splunk Universal Forwarder profile for lab endpoints.

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

if [[ "${DRY_RUN:-false}" == "true" && ! -f "$CONFIG_FILE" ]]; then
    warn "Dry-run: config saknas, använder example defaults"
    CONFIG_FILE="$PROFILE_DIR/config.env.example"
fi

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SPLUNK_SERVER_HOST="${SPLUNK_SERVER_HOST:-10.20.0.30}"
SPLUNK_INDEXER_HOST="${SPLUNK_INDEXER_HOST:-10.30.0.30}"
SPLUNK_RECEIVER_PORT="${SPLUNK_RECEIVER_PORT:-9997}"
SPLUNK_DEPLOYMENT_SERVER="${SPLUNK_DEPLOYMENT_SERVER:-}"
SPLUNK_UF_HOME="${SPLUNK_UF_HOME:-/opt/splunkforwarder}"
SPLUNK_UF_LINUX_PACKAGE="${SPLUNK_UF_LINUX_PACKAGE:-}"
SPLUNK_UF_ADMIN_USER="${SPLUNK_UF_ADMIN_USER:-admin}"
SPLUNK_UF_PASSWORD="${SPLUNK_UF_PASSWORD:-}"
SPLUNK_UF_WINDOWS_PACKAGE="${SPLUNK_UF_WINDOWS_PACKAGE:-}"
SPLUNK_INSTALLER_HTTP_PORT="${SPLUNK_INSTALLER_HTTP_PORT:-8081}"
SPLUNK_UF_WINDOWS_URL="${SPLUNK_UF_WINDOWS_URL:-}"
SPLUNK_UF_WINDOWS_HOME="${SPLUNK_UF_WINDOWS_HOME:-C:\\Program Files\\SplunkUniversalForwarder}"

if [[ -z "$SPLUNK_UF_WINDOWS_URL" && -n "$SPLUNK_UF_WINDOWS_PACKAGE" ]]; then
    SPLUNK_UF_WINDOWS_URL="http://${SPLUNK_SERVER_HOST}:${SPLUNK_INSTALLER_HTTP_PORT}/$(basename "$SPLUNK_UF_WINDOWS_PACKAGE")"
fi

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

shell_quote() {
    printf '%q' "$1"
}

json_config() {
    jq -nc \
      --arg indexer "$SPLUNK_INDEXER_HOST" \
      --arg receiver_port "$SPLUNK_RECEIVER_PORT" \
      --arg deployment_server "$SPLUNK_DEPLOYMENT_SERVER" \
      --arg uf_home "$SPLUNK_UF_WINDOWS_HOME" \
      --arg uf_url "$SPLUNK_UF_WINDOWS_URL" \
      --arg uf_admin_user "$SPLUNK_UF_ADMIN_USER" \
      --arg uf_password "$SPLUNK_UF_PASSWORD" \
      '{
        indexer: $indexer,
        receiver_port: $receiver_port,
        deployment_server: $deployment_server,
        uf_home: $uf_home,
        uf_url: $uf_url,
        uf_admin_user: $uf_admin_user,
        uf_password: $uf_password
      }'
}

run_linux_install() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle installera Splunk UF på $TARGET_NAME från $SPLUNK_UF_LINUX_PACKAGE"
        return 0
    fi

    [[ -n "$SPLUNK_UF_PASSWORD" ]] || die "SPLUNK_UF_PASSWORD måste sättas i config.env"
    [[ -n "$SPLUNK_UF_LINUX_PACKAGE" ]] || die "SPLUNK_UF_LINUX_PACKAGE måste peka på en lokal Universal Forwarder .tgz"
    [[ -f "$SPLUNK_UF_LINUX_PACKAGE" ]] || die "SPLUNK_UF_LINUX_PACKAGE finns inte: $SPLUNK_UF_LINUX_PACKAGE"

    local remote_pkg="/tmp/splunkforwarder.tgz"
    scp "${SSH_OPTS[@]}" "$SPLUNK_UF_LINUX_PACKAGE" "dennis@$TARGET_ADDR:$remote_pkg"

    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" 'sudo bash -s' <<EOF
set -euo pipefail
UF_HOME=$(shell_quote "$SPLUNK_UF_HOME")
UF_PASSWORD=$(shell_quote "$SPLUNK_UF_PASSWORD")
INDEXER=$(shell_quote "$SPLUNK_INDEXER_HOST")
RECEIVER_PORT=$(shell_quote "$SPLUNK_RECEIVER_PORT")
DEPLOYMENT_SERVER=$(shell_quote "$SPLUNK_DEPLOYMENT_SERVER")
REMOTE_PKG=$(shell_quote "$remote_pkg")

if [[ ! -x "\$UF_HOME/bin/splunk" ]]; then
    mkdir -p "\$(dirname "\$UF_HOME")"
    tar -xzf "\$REMOTE_PKG" -C "\$(dirname "\$UF_HOME")"
fi

mkdir -p "\$UF_HOME/etc/apps/lab_env_forwarding/local"
cat > "\$UF_HOME/etc/apps/lab_env_forwarding/local/outputs.conf" <<CONF
[tcpout]
defaultGroup = lab_env_indexers

[tcpout:lab_env_indexers]
server = \$INDEXER:\$RECEIVER_PORT
CONF

cat > "\$UF_HOME/etc/apps/lab_env_forwarding/local/inputs.conf" <<CONF
[monitor:///var/log/audit/audit.log]
disabled = 0
index = linux
sourcetype = linux:audit

[monitor:///var/log/auth.log]
disabled = 0
index = linux
sourcetype = linux:auth

[monitor:///var/log/secure]
disabled = 0
index = linux
sourcetype = linux:secure

[monitor:///var/log/syslog]
disabled = 0
index = linux
sourcetype = linux:syslog

[monitor:///var/log/messages]
disabled = 0
index = linux
sourcetype = linux:messages
CONF

if [[ -n "\$DEPLOYMENT_SERVER" ]]; then
    cat > "\$UF_HOME/etc/system/local/deploymentclient.conf" <<CONF
[target-broker:deploymentServer]
targetUri = \$DEPLOYMENT_SERVER
CONF
fi

if pgrep -f "\$UF_HOME/bin/splunkd" >/dev/null 2>&1; then
    timeout 120 "\$UF_HOME/bin/splunk" restart --accept-license --answer-yes --no-prompt || true
else
    timeout 120 "\$UF_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt --seed-passwd "\$UF_PASSWORD" --run-as-root || true
fi

timeout 120 "\$UF_HOME/bin/splunk" enable boot-start -user root --accept-license --answer-yes --no-prompt >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart SplunkForwarder >/dev/null 2>&1 || timeout 120 "\$UF_HOME/bin/splunk" restart --accept-license --answer-yes --no-prompt || true
EOF
}

run_linux_verify() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle verifiera Splunk UF på $TARGET_NAME"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" "sudo test -x '$SPLUNK_UF_HOME/bin/splunk' && sudo '$SPLUNK_UF_HOME/bin/splunk' status && sudo test -f '$SPLUNK_UF_HOME/etc/apps/lab_env_forwarding/local/outputs.conf'"
}

run_linux_remove() {
    [[ -n "$TARGET_ADDR" ]] || die "$TARGET_NAME saknar IP-adress"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle stoppa Splunk UF på $TARGET_NAME"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "dennis@$TARGET_ADDR" "if sudo test -x '$SPLUNK_UF_HOME/bin/splunk'; then sudo '$SPLUNK_UF_HOME/bin/splunk' stop || true; fi"
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
        warn "Dry-run: skulle köra Splunk UF $mode på $TARGET_NAME"
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
\$ufHome = \$cfg.uf_home
\$splunkExe = Join-Path \$ufHome 'bin\splunk.exe'
\$serviceName = 'SplunkForwarder'

if (\$mode -eq 'install') {
    if (-not (Test-Path \$splunkExe)) {
        if (-not \$cfg.uf_url) { throw 'SPLUNK_UF_WINDOWS_URL måste sättas till en MSI-URL som Windows-VMn når.' }
        \$installer = Join-Path \$env:TEMP 'splunkforwarder.msi'
        Invoke-WebRequest -UseBasicParsing -Uri \$cfg.uf_url -OutFile \$installer
        \$args = @('/i', \$installer, 'AGREETOLICENSE=Yes', '/quiet')
        if (\$cfg.uf_password) {
            \$args += ('SPLUNKUSERNAME=' + \$cfg.uf_admin_user)
            \$args += ('SPLUNKPASSWORD=' + \$cfg.uf_password)
        }
        \$proc = Start-Process msiexec.exe -ArgumentList \$args -Wait -PassThru
        if (\$proc.ExitCode -ne 0) { throw \"msiexec failed with exit code \$(\$proc.ExitCode)\" }
    }

    \$appDir = Join-Path \$ufHome 'etc\apps\lab_env_forwarding\local'
    New-Item -ItemType Directory -Path \$appDir -Force | Out-Null

    @\"
[tcpout]
defaultGroup = lab_env_indexers

[tcpout:lab_env_indexers]
server = \$(\$cfg.indexer):\$(\$cfg.receiver_port)
\"@ | Set-Content -Path (Join-Path \$appDir 'outputs.conf') -Encoding ASCII

    @\"
[WinEventLog://Security]
disabled = 0
index = wineventlog
sourcetype = XmlWinEventLog:Security
renderXml = true

[WinEventLog://System]
disabled = 0
index = wineventlog
sourcetype = XmlWinEventLog:System
renderXml = true

[WinEventLog://Application]
disabled = 0
index = wineventlog
sourcetype = XmlWinEventLog:Application
renderXml = true

[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = 0
index = sysmon
sourcetype = XmlWinEventLog:Microsoft-Windows-Sysmon/Operational
renderXml = true

[WinEventLog://Microsoft-Windows-PowerShell/Operational]
disabled = 0
index = wineventlog
sourcetype = XmlWinEventLog:Microsoft-Windows-PowerShell/Operational
renderXml = true

[WinEventLog://Windows PowerShell]
disabled = 0
index = wineventlog
sourcetype = XmlWinEventLog:Windows PowerShell
renderXml = true
\"@ | Set-Content -Path (Join-Path \$appDir 'inputs.conf') -Encoding ASCII

    if (\$cfg.deployment_server) {
        \$sysLocal = Join-Path \$ufHome 'etc\system\local'
        New-Item -ItemType Directory -Path \$sysLocal -Force | Out-Null
        @\"
[target-broker:deploymentServer]
targetUri = \$(\$cfg.deployment_server)
\"@ | Set-Content -Path (Join-Path \$sysLocal 'deploymentclient.conf') -Encoding ASCII
    }

    Restart-Service -Name \$serviceName -ErrorAction SilentlyContinue
    Start-Service -Name \$serviceName
}
elseif (\$mode -eq 'verify') {
    if (-not (Get-Service -Name \$serviceName -ErrorAction SilentlyContinue)) { throw 'SplunkForwarder service missing' }
    if (-not (Test-Path (Join-Path \$ufHome 'etc\apps\lab_env_forwarding\local\outputs.conf'))) { throw 'outputs.conf missing' }
    Get-Service -Name \$serviceName | Select-Object Name,Status | ConvertTo-Json -Compress
}
elseif (\$mode -eq 'remove') {
    Stop-Service -Name \$serviceName -ErrorAction SilentlyContinue
    Set-Service -Name \$serviceName -StartupType Disabled -ErrorAction SilentlyContinue
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

ok "$TARGET_NAME Splunk agent action klar: $ACTION"
