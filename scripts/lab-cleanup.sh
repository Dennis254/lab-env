#!/usr/bin/env bash
#
# lab-cleanup.sh — rensa labbresurser och bygg-artefakter
# ---------------------------------------------------------------------------
# Kan riva Terraform/OpenTofu-hanterade labbresurser efter tydlig bekräftelse
# och tar därefter bort filer och kataloger som bootstrap.sh / build-image.sh
# skapat.
#
# Fyra kategorier:
#
#   0) DESTRUKTIVT (prompt, eller --destroy --yes):
#      - Terraform/OpenTofu destroy i terraform/
#      - libvirt-domäner, nätverk och volymer som ligger i Terraform-state
#
#   1) BYGGARTEFAKTER (prompt, eller --yes):
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
#   3) ALDRIG via fil-rensning:
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
#                                          (destroy + Windows-ISOs lämnas orörda)
#   ./scripts/lab-cleanup.sh --destroy --yes
#                                        # tofu destroy -auto-approve + kategori 1
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

find_tofu() {
    if command -v tofu >/dev/null 2>&1; then
        printf 'tofu'
    elif command -v terraform >/dev/null 2>&1; then
        printf 'terraform'
    else
        return 1
    fi
}

# --- Argument --------------------------------------------------------------
DRY_RUN=false
ASSUME_YES=false
DESTROY_REQUESTED=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        --yes|-y)     ASSUME_YES=true ;;
        --destroy)    DESTROY_REQUESTED=true ;;
        -h|--help)
            awk '
                NR == 1 { next }
                /^# --- Logging-helpers/ { exit }
                /^#/ { sub(/^# ?/, ""); print }
            ' "$0"
            exit 0
            ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

TOFU_BIN=""
if TOFU_BIN="$(find_tofu 2>/dev/null)"; then
    :
else
    TOFU_BIN=""
fi

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

if [[ -n "$TOFU_BIN" && -f "$LAB_ROOT/terraform/main.tf" ]]; then
    state_count="$(
        cd "$LAB_ROOT/terraform" &&
        "$TOFU_BIN" state list 2>/dev/null | wc -l
    )"
    if [[ "$state_count" -gt 0 ]]; then
        warn "Kategori 0 — Terraform/OpenTofu destroy kan ta bort $state_count state-resurser."
        warn "Detta tar bort labb-VMer, nätverk och libvirt-volymer som Terraform hanterar."
        if $ASSUME_YES && ! $DESTROY_REQUESTED; then
            info "Destroy hoppas över i --yes-läge om inte --destroy också anges."
        fi
    else
        ok "Kategori 0 (Terraform/OpenTofu): inga resurser i state."
    fi
elif [[ -f "$LAB_ROOT/terraform/main.tf" ]]; then
    warn "Kategori 0 — OpenTofu/Terraform saknas, kan inte köra destroy."
fi

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

# --- Bekräfta kategori 0 --------------------------------------------------

if [[ -n "$TOFU_BIN" && -f "$LAB_ROOT/terraform/main.tf" ]]; then
    state_count="$(
        cd "$LAB_ROOT/terraform" &&
        "$TOFU_BIN" state list 2>/dev/null | wc -l
    )"
    if [[ "$state_count" -gt 0 ]]; then
        run_destroy=false
        if $DESTROY_REQUESTED && $ASSUME_YES; then
            run_destroy=true
        elif ! $ASSUME_YES; then
            echo
            warn "Destruktivt steg: tofu/terraform destroy tar bort labbets runtime-resurser."
            read -r -p "Köra $TOFU_BIN destroy i terraform/? [y/N] " reply
            reply="${reply:-n}"
            case "$reply" in
                [Yy]*) run_destroy=true ;;
                *) info "Hoppar över Terraform/OpenTofu destroy" ;;
            esac
        else
            info "Hoppar över Terraform/OpenTofu destroy"
        fi

        if $run_destroy; then
            destroy_args=(destroy)
            $ASSUME_YES && destroy_args+=(-auto-approve)
            ( cd "$LAB_ROOT/terraform" && "$TOFU_BIN" "${destroy_args[@]}" )
            ok "Terraform/OpenTofu destroy klar"
        fi
    fi
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
