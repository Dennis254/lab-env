#!/usr/bin/env bash
#
# windows-activate-eval.sh - activate Windows Evaluation guests via QGA
#
# Usage:
#   ./scripts/windows-activate-eval.sh
#   ./scripts/windows-activate-eval.sh --targets win-ep1
#   ./scripts/windows-activate-eval.sh --targets win-srv,win-ep1
#   ./scripts/windows-activate-eval.sh --dry-run

set -euo pipefail

LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
QGA_TIMEOUT="${LAB_ENV_QGA_TIMEOUT:-60}"
TARGETS="all"
DRY_RUN=false

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
            TARGETS="${2:?--targets requires a value}"
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
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing command: %s\n' "$1" >&2
        exit 1
    }
}

target_matches() {
    local selector="$1" name="$2" item
    case "$selector" in
        all|windows) return 0 ;;
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
        printf '[windows-activation] Could not start PowerShell in %s: %s\n' "$domain" "$response" >&2
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

activate_windows() {
    local domain="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[windows-activation] DRY-RUN %s\n' "$domain"
        return 0
    fi

    if [[ "$(virsh --connect "$LIBVIRT_URI" domstate "$domain" 2>/dev/null | tr -d '\r')" != "running" ]]; then
        printf '[windows-activation] %s is not running - skipping\n' "$domain"
        return 0
    fi

    printf '[windows-activation] %s\n' "$domain"
    wait_for_agent "$domain" || {
        printf '[windows-activation] %s QGA is not responding - skipping\n' "$domain" >&2
        return 1
    }

    guest_exec_encoded_powershell "$domain" '
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$logDir = "C:\ProgramData\LabEnv"
$logPath = Join-Path $logDir "windows-activation.json"
$slmgr = Join-Path $env:SystemRoot "System32\slmgr.vbs"
$lines = New-Object System.Collections.Generic.List[string]

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Add-ActivationOutput {
    param(
        [string]$Prefix,
        [object[]]$Output
    )
    foreach ($line in $Output) {
        $text = "${Prefix}: $line"
        Write-Output "[windows-activation] $text"
        $lines.Add($text) | Out-Null
    }
}

$before = & cscript.exe //Nologo $slmgr /xpr 2>&1
Add-ActivationOutput -Prefix "before" -Output $before

$activation = & cscript.exe //Nologo $slmgr /ato 2>&1
$activationExitCode = $LASTEXITCODE
Add-ActivationOutput -Prefix "activation" -Output $activation
if ($activationExitCode -ne 0) {
    Write-Warning "[windows-activation] slmgr /ato returned exit code $activationExitCode"
}

$after = & cscript.exe //Nologo $slmgr /xpr 2>&1
Add-ActivationOutput -Prefix "after" -Output $after

[pscustomobject]@{
    configured_at = (Get-Date).ToString("o")
    activation_exit_code = $activationExitCode
    status = $lines.ToArray()
} | ConvertTo-Json -Depth 4 | Set-Content -Path $logPath -Encoding UTF8
'
}

require_cmd virsh
require_cmd jq
require_cmd iconv
require_cmd base64

matched=0
failed=0
for name in "${windows_targets[@]}"; do
    if target_matches "$TARGETS" "$name"; then
        matched=$((matched + 1))
        activate_windows "$name" || failed=$((failed + 1))
    fi
done

[[ "$matched" -gt 0 ]] || {
    printf 'No targets matched: %s\n' "$TARGETS" >&2
    exit 1
}

if [[ "$failed" -gt 0 ]]; then
    printf '[windows-activation] completed with %s failed target(s)\n' "$failed" >&2
    exit 1
fi

printf '[windows-activation] done\n'
