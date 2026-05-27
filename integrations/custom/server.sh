#!/usr/bin/env bash
#
# Host-side custom SIEM hook.

set -euo pipefail

ACTION="${1:-install}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${INTEGRATION_CONFIG:-$PROFILE_DIR/config.env}"

c_reset=$'\e[0m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"
export CUSTOM_SIEM_URL="${CUSTOM_SIEM_URL:-}"
export CUSTOM_SIEM_TENANT="${CUSTOM_SIEM_TENANT:-}"
export CUSTOM_AGENT_MODE="${CUSTOM_AGENT_MODE:-observe}"

run_command() {
    local label="$1" command_text="$2"
    if [[ -z "$command_text" ]]; then
        warn "$label saknar kommando i config - inget att göra"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle köra $label"
        return 0
    fi
    bash -lc "$command_text"
}

case "$ACTION" in
    install)
        run_command "custom SIEM server install" "${CUSTOM_SIEM_SERVER_INSTALL_COMMAND:-}"
        ;;
    verify)
        run_command "custom SIEM server verify" "${CUSTOM_SIEM_SERVER_VERIFY_COMMAND:-}"
        ;;
    *)
        die "Okänd server-action: $ACTION"
        ;;
esac

ok "custom server action klar: $ACTION"
