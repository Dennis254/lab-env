#!/usr/bin/env bash
#
# configure-keyboard.sh - apply Swedish keyboard defaults to lab VMs
#
# Usage:
#   ./scripts/configure-keyboard.sh
#   ./scripts/configure-keyboard.sh --targets linux
#   ./scripts/configure-keyboard.sh --targets win-ep1,kali
#   ./scripts/configure-keyboard.sh --dry-run

set -euo pipefail

LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"
TARGETS="all"
DRY_RUN=false

SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

linux_targets=(
    "linux-srv:10.20.0.11"
    "linux-dev:10.20.0.12"
    "inetsim:10.20.0.13"
    "collector:10.20.0.30"
    "kali:10.40.0.20"
)

windows_targets=(
    "win-srv"
    "win-ep1"
)

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)
            TARGETS="${2:?--targets kräver ett värde}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Okänt argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Saknar kommando: %s\n' "$1" >&2
        exit 1
    }
}

target_matches() {
    local selector="$1" os="$2" name="$3" item
    case "$selector" in
        all) return 0 ;;
        linux) [[ "$os" == "linux" ]] ;;
        windows) [[ "$os" == "windows" ]] ;;
        *)
            IFS=',' read -ra names <<< "$selector"
            for item in "${names[@]}"; do
                [[ "$item" == "$name" ]] && return 0
            done
            return 1
            ;;
    esac
}

qga() {
    local domain="$1" payload="$2"
    virsh --connect "$LIBVIRT_URI" qemu-agent-command "$domain" --timeout "$QGA_TIMEOUT" "$payload"
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
    local domain="$1" ps="$2" encoded payload response pid status exited exitcode out err

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
    [[ -n "$pid" && "$pid" != "null" ]] || {
        printf 'Kunde inte starta PowerShell i %s: %s\n' "$domain" "$response" >&2
        return 1
    }

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

configure_linux() {
    local name="$1" ip="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[keyboard] DRY-RUN linux %s (%s)\n' "$name" "$ip"
        return 0
    fi

    printf '[keyboard] linux %s\n' "$name"
    if ! ssh "${SSH_OPTS[@]}" "dennis@$ip" 'sudo bash -s' <<'REMOTE'
set -euo pipefail

if command -v localectl >/dev/null 2>&1; then
    localectl set-keymap se 2>/dev/null || localectl set-keymap sv-latin1 2>/dev/null || true
    localectl set-x11-keymap se pc105 || true
fi

if [[ -d /etc/default ]]; then
    cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="se"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
fi

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Europe/Stockholm || true
fi

install -d -m 0755 /opt/lab-env
cat > /opt/lab-env/keyboard.json <<EOF
{
  "configured_at": "$(date -Is)",
  "keyboard_layout": "se",
  "x11_layout": "$(localectl status 2>/dev/null | awk -F: '/X11 Layout/ {gsub(/^[ \t]+/, "", $2); print $2}' || true)",
  "vc_keymap": "$(localectl status 2>/dev/null | awk -F: '/VC Keymap/ {gsub(/^[ \t]+/, "", $2); print $2}' || true)",
  "timezone": "$(timedatectl show -p Timezone --value 2>/dev/null || true)"
}
EOF
REMOTE
    then
        printf '[keyboard] %s svarar inte via SSH - hoppar över\n' "$name" >&2
        return 0
    fi
}

configure_windows() {
    local domain="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[keyboard] DRY-RUN windows %s\n' "$domain"
        return 0
    fi

    if [[ "$(virsh --connect "$LIBVIRT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        printf '[keyboard] %s är inte igång - hoppar över\n' "$domain"
        return 0
    fi

    printf '[keyboard] windows %s\n' "$domain"
    wait_for_agent "$domain" || {
        printf '[keyboard] %s QGA svarar inte - hoppar över\n' "$domain" >&2
        return 1
    }

    guest_exec_encoded_powershell "$domain" '
$ErrorActionPreference = "Stop"
$logDir = "C:\ProgramData\LabEnv"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$languageList = New-WinUserLanguageList -Language "sv-SE"
$languageList.Add("en-US")
Set-WinUserLanguageList -LanguageList $languageList -Force
Set-WinDefaultInputMethodOverride -InputTip "041D:0000041D"
Set-Culture -CultureInfo "sv-SE"
Set-WinHomeLocation -GeoId 221
Set-WinSystemLocale -SystemLocale "en-US"

New-Item -Path "Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload" -Force | Out-Null
Set-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload" -Name "1" -Value "0000041d"

if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
}

[pscustomobject]@{
    configured_at = (Get-Date).ToString("o")
    input_method = "041D:0000041D"
    user_language = "sv-SE"
    culture = (Get-Culture).Name
} | ConvertTo-Json | Set-Content -Path (Join-Path $logDir "keyboard.json") -Encoding UTF8
'
}

require_cmd ssh
require_cmd virsh
require_cmd jq
require_cmd iconv
require_cmd base64

matched=0
for entry in "${linux_targets[@]}"; do
    IFS=: read -r name ip <<< "$entry"
    if target_matches "$TARGETS" linux "$name"; then
        matched=$((matched + 1))
        configure_linux "$name" "$ip"
    fi
done

for name in "${windows_targets[@]}"; do
    if target_matches "$TARGETS" windows "$name"; then
        matched=$((matched + 1))
        configure_windows "$name"
    fi
done

[[ "$matched" -gt 0 ]] || {
    printf 'Inga targets matchade: %s\n' "$TARGETS" >&2
    exit 1
}

printf '[keyboard] klart\n'
