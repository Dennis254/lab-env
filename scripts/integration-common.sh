#!/usr/bin/env bash
#
# Shared helpers for profile-based SIEM/agent integrations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INTEGRATIONS_DIR="$LAB_ROOT/integrations"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

normalize_profile() {
    local profile="$1"
    profile="${profile#-}"
    profile="${profile#-}"
    printf '%s' "$profile" | tr '[:upper:]' '[:lower:]'
}

profile_dir() {
    local profile="$1"
    printf '%s/%s' "$INTEGRATIONS_DIR" "$profile"
}

require_profile() {
    local profile="$1" dir
    [[ "$profile" =~ ^[a-z0-9_-]+$ ]] || die "Ogiltigt profilnamn: $profile"
    dir="$(profile_dir "$profile")"
    [[ -d "$dir" ]] || die "Profilen saknas: $profile ($dir)"
}

default_config_file() {
    local profile="$1"
    printf '%s/config.env' "$(profile_dir "$profile")"
}

linux_targets=(
    "linux-srv:10.20.0.11"
    "linux-dev:10.20.0.12"
    "kali:10.40.0.20"
)

windows_targets=(
    "win-srv:"
    "win-ep1:"
)

target_matches() {
    local selector="$1" os="$2" name="$3"
    case "$selector" in
        all) return 0 ;;
        linux) [[ "$os" == "linux" ]] ;;
        windows) [[ "$os" == "windows" ]] ;;
        *)
            IFS=',' read -ra names <<< "$selector"
            local item
            for item in "${names[@]}"; do
                [[ "$item" == "$name" ]] && return 0
            done
            return 1
            ;;
    esac
}

run_for_targets() {
    local profile="$1" action="$2" selector="$3" config_file="$4" dry_run="$5"
    local agent_hook entry name ip matched
    agent_hook="$(profile_dir "$profile")/agent.sh"
    [[ -x "$agent_hook" ]] || die "Profilen saknar körbar agent hook: $agent_hook"
    matched=0

    for entry in "${linux_targets[@]}"; do
        IFS=: read -r name ip <<< "$entry"
        if target_matches "$selector" "linux" "$name"; then
            matched=$((matched + 1))
            info "$profile $action agent på $name"
            INTEGRATION_CONFIG="$config_file" DRY_RUN="$dry_run" "$agent_hook" "$action" linux "$name" "$ip"
        fi
    done

    for entry in "${windows_targets[@]}"; do
        IFS=: read -r name ip <<< "$entry"
        if target_matches "$selector" "windows" "$name"; then
            matched=$((matched + 1))
            info "$profile $action agent på $name"
            INTEGRATION_CONFIG="$config_file" DRY_RUN="$dry_run" "$agent_hook" "$action" windows "$name" "$ip"
        fi
    done

    [[ "$matched" -gt 0 ]] || die "Inga targets matchade: $selector"
}
