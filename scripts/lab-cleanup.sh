#!/usr/bin/env bash
#
# lab-cleanup.sh — rensa bygg-artefakter, ej runtime-state
# ---------------------------------------------------------------------------
# Tar bort filer och kataloger som bootstrap.sh / build-image.sh skapat.
# Rör INTE backing-disks, libvirt-volymer, Terraform-state eller cloud-
# init-ISOs — sådant är runtime-loadbearing för existerande VMer.
#
# Tre kategorier:
#
#   1) ALLTID (no prompt, alltid säkert):
#      - tools/                         (packer-binär, fetch-packer återskapar)
#      - packer/.packer.d/              (plugin-cache, packer init återskapar)
#      - packer/.packer_cache/
#      - packer/cdstaging/              (extraherade virtio-drivers)
#      - packer/output-*/               (transient Packer-output)
#      - packer/build-*.log             (debug-loggar)
#      - terraform/build/               (renderade autounattend + per-VM-ISOs)
#
#   2) MED PROMPT (du laddade ner dem manuellt):
#      - iso/windows-11-enterprise.iso  (symlink + ev. original)
#      - iso/windows-server-2025.iso
#      - iso/*.iso utom virtio-win.iso  (allt övrigt manuellt placerat)
#
#   3) ALDRIG (loadbearing eller utanför scope):
#      - images/*.qcow2                 (backing-disks för running VMer)
#      - iso/virtio-win.iso             (mountad i Windows-VMer som CDROM)
#      - cloud-init/*.iso               (cidata mountad i Linux-VMer)
#      - terraform/*.tfstate*           (rör aldrig)
#      - libvirt-volymer i default-pool (tofu destroy hanterar)
#
# Användning:
#   ./scripts/lab-cleanup.sh             # interaktiv: visa, prompta, rensa
#   ./scripts/lab-cleanup.sh --dry-run   # visa bara, ta inte bort något
#   ./scripts/lab-cleanup.sh --yes       # rensa kategori 1 utan att fråga
#                                          (Windows-ISOs lämnas orörda)
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Logging-helpers (matchar bootstrap.sh) -------------------------------
c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n'  "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n'  "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n'  "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n'  "$c_red"    "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

# --- Argument --------------------------------------------------------------
DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        --yes|-y)     ASSUME_YES=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 40
            exit 0
            ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

# --- VM-kontroll ----------------------------------------------------------
# Kategori 1 är alltid säkert oavsett VM-state, så vi blockerar inte —
# men vi visar en varning så användaren vet att det finns running VMer.

if command -v virsh &>/dev/null; then
    running="$(virsh list --name --state-running 2>/dev/null | grep -v '^$' || true)"
    if [[ -n "$running" ]]; then
        warn "Följande VMer kör fortfarande (de påverkas INTE av cleanup):"
        printf '       %s\n' $running
        echo
    fi
fi

# --- Kategori 1: alltid säkra targets -------------------------------------

# Bygg listan dynamiskt — bara peka på saker som faktiskt finns.
declare -a CAT1_PATHS=()

[[ -d "$LAB_ROOT/tools" ]]              && CAT1_PATHS+=("$LAB_ROOT/tools")
[[ -d "$LAB_ROOT/packer/.packer.d" ]]   && CAT1_PATHS+=("$LAB_ROOT/packer/.packer.d")
[[ -d "$LAB_ROOT/packer/.packer_cache" ]] && CAT1_PATHS+=("$LAB_ROOT/packer/.packer_cache")
[[ -d "$LAB_ROOT/packer/cdstaging" ]]   && CAT1_PATHS+=("$LAB_ROOT/packer/cdstaging")
[[ -d "$LAB_ROOT/terraform/build" ]]    && CAT1_PATHS+=("$LAB_ROOT/terraform/build")

# Glob-träffar — använd nullglob-trick (skapa subshell med shopt) så icke-
# matchande globs inte expanderar till bokstavliga strängar.
while IFS= read -r -d '' p; do CAT1_PATHS+=("$p"); done < <(
    find "$LAB_ROOT/packer" -maxdepth 1 -type d -name 'output-*' -print0 2>/dev/null
)
while IFS= read -r -d '' p; do CAT1_PATHS+=("$p"); done < <(
    find "$LAB_ROOT/packer" -maxdepth 1 -type f -name 'build-*.log' -print0 2>/dev/null
)

# --- Kategori 2: Windows-ISOs (prompt) ------------------------------------

declare -a CAT2_PATHS=()
while IFS= read -r -d '' p; do
    # Inkludera bara om det INTE är virtio-win.iso (eller symlink dit).
    base="$(basename "$p")"
    if [[ "$base" == "virtio-win.iso" ]]; then continue; fi
    # Följ symlinks: lägg till både länken och dess target om båda finns.
    CAT2_PATHS+=("$p")
done < <(find "$LAB_ROOT/iso" -maxdepth 1 \( -type f -o -type l \) -name '*.iso' -print0 2>/dev/null)

# --- Visa plan ------------------------------------------------------------

echo
info "Cleanup-plan för $LAB_ROOT"
echo

if [[ ${#CAT1_PATHS[@]} -eq 0 ]]; then
    ok "Kategori 1 (bygg-artefakter): inget att rensa."
else
    info "Kategori 1 — bygg-artefakter (rensas alltid, kan återskapas):"
    total_cat1=0
    for p in "${CAT1_PATHS[@]}"; do
        size_h="$(du -sh "$p" 2>/dev/null | cut -f1)"
        size_b="$(du -sb "$p" 2>/dev/null | cut -f1)"
        printf '       %-60s %s\n' "${p#$LAB_ROOT/}" "$size_h"
        total_cat1=$((total_cat1 + ${size_b:-0}))
    done
    printf '       %-60s %s\n' "TOTALT:" "$(numfmt --to=iec "$total_cat1" 2>/dev/null || echo "$total_cat1 B")"
fi

echo
if [[ ${#CAT2_PATHS[@]} -eq 0 ]]; then
    ok "Kategori 2 (manuella nedladdningar): inga ISOs hittade."
else
    info "Kategori 2 — Windows-ISOs (du laddade ner dem; promptas separat):"
    for p in "${CAT2_PATHS[@]}"; do
        if [[ -L "$p" ]]; then
            printf '       %-60s -> %s\n' "${p#$LAB_ROOT/}" "$(readlink "$p")"
        else
            size_h="$(du -sh "$p" 2>/dev/null | cut -f1)"
            printf '       %-60s %s\n' "${p#$LAB_ROOT/}" "$size_h"
        fi
    done
fi
echo

if $DRY_RUN; then
    info "Dry-run — inget tas bort."
    exit 0
fi

# --- Bekräfta kategori 1 --------------------------------------------------

if [[ ${#CAT1_PATHS[@]} -gt 0 ]]; then
    if ! $ASSUME_YES; then
        read -r -p "Rensa kategori 1? [Y/n] " reply
        reply="${reply:-y}"
        case "$reply" in
            [Yy]*) ;;
            *) info "Hoppar över kategori 1"; CAT1_PATHS=() ;;
        esac
    fi
    for p in "${CAT1_PATHS[@]}"; do
        rm -rf -- "$p" && ok "Tog bort ${p#$LAB_ROOT/}"
    done
fi

# --- Prompt för kategori 2 ------------------------------------------------

if [[ ${#CAT2_PATHS[@]} -gt 0 ]]; then
    echo
    if $ASSUME_YES; then
        info "Windows-ISOs lämnas orörda (kräver explicit prompt — använd inte --yes för dessa)."
    else
        warn "Kategori 2: dessa filer är ~7GB och du laddade ner dem manuellt."
        read -r -p "Ta också bort Windows-ISOs och dess symlinks? [y/N] " reply
        reply="${reply:-n}"
        case "$reply" in
            [Yy]*)
                for p in "${CAT2_PATHS[@]}"; do
                    rm -f -- "$p" && ok "Tog bort ${p#$LAB_ROOT/}"
                done
                ;;
            *) info "Windows-ISOs sparas" ;;
        esac
    fi
fi

echo
ok "Cleanup klar."
