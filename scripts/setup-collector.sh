#!/usr/bin/env bash
#
# setup-collector.sh - configure collector-hosted security services
#
# Usage:
#   ./scripts/setup-collector.sh --yes
#   ./scripts/setup-collector.sh --skip-splunk
#   ./scripts/setup-collector.sh --skip-velociraptor
#   ./scripts/setup-collector.sh --targets linux
#   ./scripts/setup-collector.sh --verify-only

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
DRY_RUN=false
RUN_SPLUNK=true
RUN_VELOCIRAPTOR=true
RUN_SPLUNK_TEST=false
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-splunk|--no-splunk)
            RUN_SPLUNK=false
            shift
            ;;
        --skip-velociraptor|--no-velociraptor)
            RUN_VELOCIRAPTOR=false
            shift
            ;;
        --with-splunk-test)
            RUN_SPLUNK_TEST=true
            shift
            ;;
        --no-splunk-test)
            RUN_SPLUNK_TEST=false
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
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

run_or_record() {
    local label="$1"
    shift

    info "$label"
    if "$@"; then
        ok "$label klart"
        return 0
    fi

    warn "$label misslyckades - fortsätter"
    FAILURES+=("$label")
    return 0
}

splunk_args=(--yes --targets "$TARGETS")
velociraptor_args=(--yes --targets "$TARGETS")

$DRY_RUN && splunk_args+=(--dry-run) && velociraptor_args+=(--dry-run)
$VERIFY_ONLY && splunk_args+=(--verify-only) && velociraptor_args+=(--verify-only)
$RUN_SPLUNK_TEST || splunk_args+=(--no-test)

if $RUN_SPLUNK; then
    run_or_record "Splunk på collector" "$SCRIPT_DIR/setup-splunk.sh" "${splunk_args[@]}"
else
    info "Hoppar över Splunk (--skip-splunk)"
fi

if $RUN_VELOCIRAPTOR; then
    run_or_record "Velociraptor på collector" "$SCRIPT_DIR/setup-velociraptor.sh" "${velociraptor_args[@]}"
else
    info "Hoppar över Velociraptor (--skip-velociraptor)"
fi

if ((${#FAILURES[@]} > 0)); then
    warn "Collector setup klar med fel: ${FAILURES[*]}"
    exit 1
fi

ok "Collector setup klar"
