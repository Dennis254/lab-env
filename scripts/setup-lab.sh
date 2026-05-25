#!/usr/bin/env bash
#
# setup-lab.sh — one-shot setup for a freshly cloned lab-env repo
# ---------------------------------------------------------------------------
# Intended public entrypoint:
#
#   ./scripts/setup-lab.sh --yes
#
# The script is deliberately thin. It orchestrates the existing, auditable
# steps instead of duplicating logic:
#   1. bootstrap.sh installs host tools and downloads Linux cloud-images
#   2. Windows golden images are built with scripts/build-image.sh
#   3. OpenTofu initializes and applies terraform/
#   4. INetSim is configured on the inetsim VM
#   5. Local endpoint logging is configured
#
# Windows install media must be supplied manually under iso/ because Microsoft
# requires an interactive download flow.
#
# Extra flags:
#   --plan-only       Run bootstrap/image checks and tofu plan, but do not apply
#   --no-windows      Fresh Linux-only bring-up; refuses to destroy Windows state
#   --force-windows   Rebuild Windows golden images even when manifests match
#   --no-inetsim      Skip in-guest INetSim installation/configuration
#   --no-logging      Skip local Windows/Linux logging configuration
# ---------------------------------------------------------------------------

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
APPLY=true
BUILD_WINDOWS=true
DEBUG_WINDOWS=false
FORCE_WINDOWS=false
CONFIGURE_INETSIM=true
CONFIGURE_LOGGING=true
ALLOW_WINDOWS_DESTROY=false
TOFU_VAR_ARGS=()

for arg in "$@"; do
    case "$arg" in
        -y|--yes)        ASSUME_YES=true ;;
        --plan-only)     APPLY=false ;;
        --no-windows)    BUILD_WINDOWS=false ;;
        --debug-windows) DEBUG_WINDOWS=true ;;
        --force-windows) FORCE_WINDOWS=true ;;
        --no-inetsim)    CONFIGURE_INETSIM=false ;;
        --no-logging)    CONFIGURE_LOGGING=false ;;
        --allow-windows-destroy) ALLOW_WINDOWS_DESTROY=true ;;
        -h|--help)
            grep '^# ' "$0" | sed 's/^# \{0,1\}//' | head -n 30
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

require_iso() {
    local filename="$1" purpose="$2"
    if [[ -e "$LAB_ROOT/iso/$filename" ]]; then
        ok "$purpose: iso/$filename finns"
        return 0
    fi

    err "$purpose saknas: iso/$filename"
    err "Skapa en stabil symlink efter manuell Microsoft-download, t.ex.:"
    err "  ln -sf <microsoft-original>.iso iso/$filename"
    return 1
}

info "Steg 1/6: Bootstrap"
bootstrap_args=()
$ASSUME_YES && bootstrap_args+=(--yes)
"$LAB_ROOT/bootstrap.sh" "${bootstrap_args[@]}"

info "Steg 2/6: Windows-media och golden images"
if $BUILD_WINDOWS; then
    require_iso "windows-11-enterprise.iso" "Windows 11 Enterprise" || die "Kan inte bygga win-ep1 utan Windows 11 ISO."
    require_iso "windows-server-2025.iso" "Windows Server 2025" || die "Kan inte bygga win-srv utan Windows Server 2025 ISO."

    windows_templates=(win-srv win-ep1)
    for template in "${windows_templates[@]}"; do
        build_args=("$template")
        $DEBUG_WINDOWS && build_args+=(--debug)
        $FORCE_WINDOWS && build_args+=(--force)
        "$LAB_ROOT/scripts/build-image.sh" "${build_args[@]}"
    done
    ok "Windows golden images verifierade"
else
    info "Hoppar över Windows image-bygge (--no-windows)"
    TOFU_VAR_ARGS+=(-var 'windows_vms={}')
fi

TOFU_BIN="$(find_tofu)" || die "OpenTofu/Terraform saknas efter bootstrap."
TOFU_VERSION_OUT="$("$TOFU_BIN" version 2>/dev/null || true)"
TOFU_VERSION_LINE="${TOFU_VERSION_OUT%%$'\n'*}"
ok "IaC-verktyg: ${TOFU_VERSION_LINE:-$TOFU_BIN}"

info "Steg 3/6: Initierar Terraform/OpenTofu"
( cd "$TERRAFORM_DIR" && "$TOFU_BIN" init )

if ! $BUILD_WINDOWS && $APPLY && ! $ALLOW_WINDOWS_DESTROY; then
    state_out="$(cd "$TERRAFORM_DIR" && "$TOFU_BIN" state list 2>/dev/null || true)"
    if grep -Eq '^(libvirt_domain|libvirt_volume|null_resource)\.windows|^libvirt_volume\.virtio_win_iso' <<< "$state_out"; then
        die "--no-windows skulle ta bort befintliga Windows-resurser i Terraform-state. Kör --plan-only först, eller lägg till --allow-windows-destroy om det är avsiktligt."
    fi
fi

info "Steg 4/6: Plan/apply"
if $APPLY; then
    apply_args=(apply)
    $ASSUME_YES && apply_args+=(-auto-approve)
    ( cd "$TERRAFORM_DIR" && "$TOFU_BIN" "${apply_args[@]}" "${TOFU_VAR_ARGS[@]}" )
else
    ( cd "$TERRAFORM_DIR" && "$TOFU_BIN" plan "${TOFU_VAR_ARGS[@]}" )
fi

info "Steg 5/6: INetSim"
if $APPLY && $CONFIGURE_INETSIM; then
    "$LAB_ROOT/scripts/configure-inetsim.sh"
elif ! $APPLY; then
    info "Hoppar över INetSim-konfiguration i --plan-only"
else
    info "Hoppar över INetSim-konfiguration (--no-inetsim)"
fi

info "Steg 6/6: Local logging"
if $APPLY && $CONFIGURE_LOGGING; then
    "$LAB_ROOT/scripts/configure-logging.sh"
elif ! $APPLY; then
    info "Hoppar över local logging i --plan-only"
else
    info "Hoppar över local logging (--no-logging)"
fi

ok "Setup klart."
