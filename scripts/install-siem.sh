#!/usr/bin/env bash
#
# install-siem.sh - install or verify a SIEM/server integration profile
#
# Usage:
#   ./scripts/install-siem.sh --profile custom
#   ./scripts/install-siem.sh -Wazuh --dry-run
#   ./scripts/install-siem.sh -Velociraptor --action verify
#   ./scripts/install-siem.sh -Splunk --action verify

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/integration-common.sh
source "$SCRIPT_DIR/integration-common.sh"

PROFILE=""
CONFIG_FILE=""
DRY_RUN=false
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$(normalize_profile "${2:-}")"
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
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Okänt argument: $1"
            ;;
    esac
done

[[ -n "$PROFILE" ]] || die "Ange profil, t.ex. --profile custom eller -Custom"
[[ "$ACTION" =~ ^(install|verify)$ ]] || die "Ogiltig action: $ACTION"
require_profile "$PROFILE"

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$(default_config_file "$PROFILE")"
fi

server_hook="$(profile_dir "$PROFILE")/server.sh"
[[ -x "$server_hook" ]] || die "Profilen saknar körbar server hook: $server_hook"

info "$PROFILE server action: $ACTION"
INTEGRATION_CONFIG="$CONFIG_FILE" DRY_RUN="$DRY_RUN" "$server_hook" "$ACTION"
ok "Server action klar: $PROFILE/$ACTION"
