#!/usr/bin/env bash
#
# configure-agents.sh - install SIEM/EDR agents through integration profiles
#
# Usage:
#   ./scripts/configure-agents.sh --profile custom --targets all
#   ./scripts/configure-agents.sh -Custom
#   ./scripts/configure-agents.sh -Wazuh --targets windows
#   ./scripts/configure-agents.sh -Splunk --targets linux --dry-run
#   ./scripts/configure-agents.sh -Velociraptor --targets all
#
# Targets:
#   all, linux, windows, or comma-separated VM names

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/integration-common.sh
source "$SCRIPT_DIR/integration-common.sh"

PROFILE=""
TARGETS="all"
CONFIG_FILE=""
DRY_RUN=false
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$(normalize_profile "${2:-}")"
            shift 2
            ;;
        --targets)
            TARGETS="${2:-}"
            shift 2
            ;;
        --config)
            CONFIG_FILE="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --action)
            ACTION="${2:-}"
            shift 2
            ;;
        -Custom|-custom|--custom|-Wazuh|-wazuh|--wazuh|-Splunk|-splunk|--splunk|-Velociraptor|-velociraptor|--velociraptor)
            PROFILE="$(normalize_profile "$1")"
            shift
            ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Okänt argument: $1"
            ;;
    esac
done

[[ -n "$PROFILE" ]] || die "Ange profil, t.ex. --profile custom eller -Custom"
[[ "$ACTION" =~ ^(install|verify|remove)$ ]] || die "Ogiltig action: $ACTION"
require_profile "$PROFILE"

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$(default_config_file "$PROFILE")"
fi

run_for_targets "$PROFILE" "$ACTION" "$TARGETS" "$CONFIG_FILE" "$DRY_RUN"
ok "Agent action klar: $PROFILE/$ACTION ($TARGETS)"
