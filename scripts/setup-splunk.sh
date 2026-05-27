#!/usr/bin/env bash
#
# setup-splunk.sh - idempotent orchestration for the Splunk lab profile
#
# Usage:
#   ./scripts/setup-splunk.sh --yes
#   ./scripts/setup-splunk.sh --targets linux
#   ./scripts/setup-splunk.sh --skip-server
#   ./scripts/setup-splunk.sh --skip-agents
#   ./scripts/setup-splunk.sh --no-test
#   ./scripts/setup-splunk.sh --verify-only

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
RUN_TEST=true
VERIFY_ONLY=false
FORCE_TEST=false

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
        --no-test)
            RUN_TEST=false
            shift
            ;;
        --force-test)
            FORCE_TEST=true
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
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Okänt argument: $1"
            ;;
    esac
done

profile_args=(--profile splunk)
agent_args=(--profile splunk --targets "$TARGETS")

if [[ -n "$CONFIG_FILE" ]]; then
    profile_args+=(--config "$CONFIG_FILE")
    agent_args+=(--config "$CONFIG_FILE")
fi

if $DRY_RUN; then
    profile_args+=(--dry-run)
    agent_args+=(--dry-run)
fi

run_server_install() {
    info "Splunk server install/uppdatering"
    "$SCRIPT_DIR/install-siem.sh" "${profile_args[@]}"
}

run_server_verify() {
    info "Splunk server verifiering"
    "$SCRIPT_DIR/install-siem.sh" "${profile_args[@]}" --action verify
}

run_agents_install() {
    info "Splunk forwarders install/uppdatering ($TARGETS)"
    "$SCRIPT_DIR/configure-agents.sh" "${agent_args[@]}"
}

run_agents_verify() {
    info "Splunk forwarders verifiering ($TARGETS)"
    "$SCRIPT_DIR/verify-agents.sh" "${agent_args[@]}"
}

run_flow_test() {
    if $DRY_RUN; then
        warn "Hoppar över Splunk end-to-end-test i --dry-run"
        return 0
    fi
    if [[ "$TARGETS" != "all" && "$FORCE_TEST" != "true" ]]; then
        warn "Hoppar över Splunk end-to-end-test för partiella targets ($TARGETS). Använd --force-test om du vill köra det ändå."
        return 0
    fi
    if ! $RUN_AGENTS && ! $VERIFY_ONLY; then
        warn "Hoppar över Splunk end-to-end-test eftersom agentsteget hoppades över"
        return 0
    fi

    info "Splunk end-to-end-test"
    "$SCRIPT_DIR/splunk/test-flow.sh"
}

if $VERIFY_ONLY; then
    run_server_verify
    run_agents_verify
    $RUN_TEST && run_flow_test
    ok "Splunk verifiering klar"
    exit 0
fi

if $RUN_SERVER; then
    run_server_install
else
    info "Hoppar över Splunk server (--skip-server)"
fi

if $RUN_AGENTS; then
    run_agents_install
else
    info "Hoppar över Splunk forwarders (--skip-agents)"
fi

if $RUN_VERIFY; then
    if $RUN_SERVER; then
        run_server_verify
    fi
    if $RUN_AGENTS; then
        run_agents_verify
    fi
else
    info "Hoppar över Splunk verifiering (--no-verify)"
fi

if $RUN_TEST; then
    run_flow_test
else
    info "Hoppar över Splunk end-to-end-test (--no-test)"
fi
ok "Splunk setup klar"
