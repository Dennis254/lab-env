#!/usr/bin/env bash
#
# setup-velociraptor.sh - idempotent orchestration for the Velociraptor profile
#
# Usage:
#   ./scripts/setup-velociraptor.sh --yes
#   ./scripts/setup-velociraptor.sh --targets linux
#   ./scripts/setup-velociraptor.sh --skip-server
#   ./scripts/setup-velociraptor.sh --skip-agents
#   ./scripts/setup-velociraptor.sh --verify-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

TARGETS="all"
CONFIG_FILE=""
DRY_RUN=false
RUN_SERVER=true
RUN_AGENTS=true
RUN_VERIFY=true
VERIFY_ONLY=false
FAILURES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            shift
            ;;
        --targets)
            TARGETS="${2:-}"
            [[ -n "$TARGETS" ]] || die "--targets kräver ett värde"
            shift 2
            ;;
        --config)
            CONFIG_FILE="${2:-}"
            [[ -n "$CONFIG_FILE" ]] || die "--config kräver en sökväg"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-server|--no-server)
            RUN_SERVER=false
            shift
            ;;
        --skip-agents|--no-agents)
            RUN_AGENTS=false
            shift
            ;;
        --no-verify)
            RUN_VERIFY=false
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
            RUN_SERVER=false
            RUN_AGENTS=false
            RUN_VERIFY=true
            shift
            ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Okänt argument: $1"
            ;;
    esac
done

profile_args=(--profile velociraptor)
agent_args=(--profile velociraptor --targets "$TARGETS")

if [[ -n "$CONFIG_FILE" ]]; then
    profile_args+=(--config "$CONFIG_FILE")
    agent_args+=(--config "$CONFIG_FILE")
fi

if $DRY_RUN; then
    profile_args+=(--dry-run)
    agent_args+=(--dry-run)
fi

run_server_install() {
    info "Velociraptor server install/uppdatering"
    "$SCRIPT_DIR/install-siem.sh" "${profile_args[@]}"
}

run_server_verify() {
    info "Velociraptor server verifiering"
    "$SCRIPT_DIR/install-siem.sh" "${profile_args[@]}" --action verify
}

run_agents_install() {
    info "Velociraptor klienter install/uppdatering ($TARGETS)"
    "$SCRIPT_DIR/configure-agents.sh" "${agent_args[@]}"
}

run_agents_verify() {
    info "Velociraptor klienter verifiering ($TARGETS)"
    "$SCRIPT_DIR/verify-agents.sh" "${agent_args[@]}"
}

run_or_record() {
    local label="$1"
    shift

    if "$@"; then
        return 0
    fi

    warn "$label misslyckades - fortsätter"
    FAILURES+=("$label")
    return 0
}

if $VERIFY_ONLY; then
    run_or_record "Velociraptor server verifiering" run_server_verify
    run_or_record "Velociraptor klienter verifiering" run_agents_verify
    if ((${#FAILURES[@]} > 0)); then
        warn "Velociraptor verifiering klar med fel: ${FAILURES[*]}"
        exit 1
    fi
    ok "Velociraptor verifiering klar"
    exit 0
fi

if $RUN_SERVER; then
    run_or_record "Velociraptor server install/uppdatering" run_server_install
else
    info "Hoppar över Velociraptor server (--skip-server)"
fi

if $RUN_AGENTS; then
    run_or_record "Velociraptor klienter install/uppdatering" run_agents_install
else
    info "Hoppar över Velociraptor klienter (--skip-agents)"
fi

if $RUN_VERIFY; then
    if $RUN_SERVER; then
        run_or_record "Velociraptor server verifiering" run_server_verify
    fi
    if $RUN_AGENTS; then
        run_or_record "Velociraptor klienter verifiering" run_agents_verify
    fi
else
    info "Hoppar över Velociraptor verifiering (--no-verify)"
fi

if ((${#FAILURES[@]} > 0)); then
    warn "Velociraptor setup klar med fel: ${FAILURES[*]}"
    exit 1
fi
ok "Velociraptor setup klar"
