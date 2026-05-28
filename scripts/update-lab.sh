#!/usr/bin/env bash
#
# update-lab.sh - apply repo updates to an existing lab without Packer rebuilds
#
# Usage:
#   ./scripts/update-lab.sh --yes
#   ./scripts/update-lab.sh --dry-run
#   ./scripts/update-lab.sh --with-tofu-plan
#   ./scripts/update-lab.sh --with-splunk-test
#   ./scripts/update-lab.sh --skip-splunk
#   ./scripts/update-lab.sh --strict
#
# This script is for an already-created lab. It intentionally does not build
# Windows golden images and does not run tofu apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$LAB_ROOT/terraform"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

ASSUME_YES=false
DRY_RUN=false
WITH_TOFU_PLAN=false
CONFIGURE_CONSOLE=true
CONFIGURE_KEYBOARD=true
CONFIGURE_KALI=true
CONFIGURE_INETSIM=true
CONFIGURE_LOGGING=true
CONFIGURE_SPLUNK=true
RUN_SPLUNK_TEST=false
STRICT=false
FAILURES=()

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        --with-tofu-plan) WITH_TOFU_PLAN=true ;;
        --with-splunk-test) RUN_SPLUNK_TEST=true ;;
        --skip-console) CONFIGURE_CONSOLE=false ;;
        --skip-keyboard) CONFIGURE_KEYBOARD=false ;;
        --skip-kali) CONFIGURE_KALI=false ;;
        --skip-inetsim) CONFIGURE_INETSIM=false ;;
        --skip-logging) CONFIGURE_LOGGING=false ;;
        --skip-splunk) CONFIGURE_SPLUNK=false ;;
        --strict) STRICT=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

find_tofu() {
    if command -v tofu >/dev/null 2>&1; then
        printf 'tofu'
    elif command -v terraform >/dev/null 2>&1; then
        printf 'terraform'
    else
        return 1
    fi
}

run_step() {
    local label="$1"
    shift

    info "$label"
    if $DRY_RUN; then
        printf 'DRY-RUN'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    if "$@"; then
        ok "$label klart"
        return 0
    fi

    FAILURES+=("$label")
    if $STRICT; then
        die "$label misslyckades"
    fi
    warn "$label misslyckades - fortsätter med nästa steg"
    return 0
}

if ! $ASSUME_YES && ! $DRY_RUN; then
    warn "Detta uppdaterar befintliga VMer in-place men bygger inte om Packer-images och kör inte tofu apply."
    read -r -p "Fortsätt? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Avbrutet"
fi

if $WITH_TOFU_PLAN; then
    TOFU_BIN="$(find_tofu)" || die "OpenTofu/Terraform saknas"
    run_step "Terraform/OpenTofu plan (ingen apply)" \
        bash -c "cd '$TERRAFORM_DIR' && '$TOFU_BIN' plan"
else
    info "Hoppar över Terraform/OpenTofu plan. Använd --with-tofu-plan om du vill granska IaC-drift."
fi

if $CONFIGURE_CONSOLE; then
    run_step "VM console/mus/video" "$LAB_ROOT/scripts/configure-vm-console.sh"
fi

if $CONFIGURE_KEYBOARD; then
    run_step "Svensk tangentbordslayout" "$LAB_ROOT/scripts/configure-keyboard.sh"
fi

if $CONFIGURE_KALI; then
    run_step "Kali GUI/tooling" "$LAB_ROOT/scripts/configure-kali.sh"
fi

if $CONFIGURE_INETSIM; then
    run_step "INetSim" "$LAB_ROOT/scripts/configure-inetsim.sh"
fi

if $CONFIGURE_LOGGING; then
    run_step "Local endpoint logging" "$LAB_ROOT/scripts/configure-logging.sh"
fi

if $CONFIGURE_SPLUNK; then
    splunk_args=(--yes)
    if ! $RUN_SPLUNK_TEST; then
        splunk_args+=(--no-test)
    fi
    $DRY_RUN && splunk_args+=(--dry-run)
    run_step "Splunk profile" "$LAB_ROOT/scripts/setup-splunk.sh" "${splunk_args[@]}"
fi

if ((${#FAILURES[@]} > 0)); then
    warn "Lab update klar med fel i följande steg:"
    for failure in "${FAILURES[@]}"; do
        warn " - $failure"
    done
    warn "Kör om scriptet när saknade/stoppade VMer är igång."
    exit 1
fi

ok "Lab update klart."
