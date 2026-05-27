#!/usr/bin/env bash
#
# build-image.sh — wrapper för Packer-baserade Windows-image-byggen
# ---------------------------------------------------------------------------
# Validerar prereqs, kör `packer init` + `packer build` med rätt arbets-
# katalog och konsekventa variabler. Outputten landar i $LAB_ROOT/images/
# som backing-disk för Terraform.
#
# Användning:
#   ./scripts/build-image.sh win-ep1
#   ./scripts/build-image.sh win-ep1 --debug   # kör med PACKER_LOG=1 + GUI
#   ./scripts/build-image.sh win-ep1 --force   # bygg om även om manifest matchar
#   ./scripts/build-image.sh --list            # listar tillgängliga templates
#
# Förutsättningar:
#   - bootstrap.sh har körts (tools/packer finns, virtio-win.iso finns)
#   - Windows install-ISO ligger manuellt i iso/ enligt template-default
#   - wimlib-imagex/7z/xorriso finns för Windows-ISO-prep
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKER_BIN="$LAB_ROOT/tools/packer"
PACKER_DIR="$LAB_ROOT/packer"
BUILD_ADMIN_PASSWORD_FILE="$PACKER_DIR/.build-admin-password"

# --- Logging-helpers (matchar bootstrap.sh) -------------------------------
c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n'  "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n'  "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n'  "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n'  "$c_red"    "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

random_build_password() {
    local rand
    if command -v openssl >/dev/null 2>&1; then
        rand="$(openssl rand -hex 12)"
    else
        rand="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
    fi
    printf 'Pkr%sAa1!\n' "$rand"
}

get_build_admin_password() {
    if [[ -n "${PACKER_BUILD_ADMIN_PASSWORD:-}" ]]; then
        printf '%s\n' "$PACKER_BUILD_ADMIN_PASSWORD"
        return
    fi

    if [[ -f "$BUILD_ADMIN_PASSWORD_FILE" ]]; then
        tr -d '\r\n' < "$BUILD_ADMIN_PASSWORD_FILE"
        return
    fi

    mkdir -p "$PACKER_DIR"
    random_build_password > "$BUILD_ADMIN_PASSWORD_FILE"
    chmod 600 "$BUILD_ADMIN_PASSWORD_FILE"
    tr -d '\r\n' < "$BUILD_ADMIN_PASSWORD_FILE"
}

render_autounattend() {
    local template_file="$1" output_file="$2" password="$3"

    [[ -f "$template_file" ]] || die "Saknar Packer-autounattend: $template_file"
    grep -q "__BUILD_ADMIN_PASSWORD__" "$template_file" || \
        die "Autounattend saknar __BUILD_ADMIN_PASSWORD__: $template_file"

    mkdir -p "$(dirname "$output_file")"
    sed "s|__BUILD_ADMIN_PASSWORD__|${password}|g" "$template_file" > "$output_file"
    chmod 600 "$output_file"
}

# --- Argument --------------------------------------------------------------
DEBUG=false
FORCE=false
TEMPLATE=""
LIST_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --debug)   DEBUG=true ;;
        --force)   FORCE=true ;;
        --list)    LIST_ONLY=true ;;
        -h|--help)
            awk 'BEGIN { n = 0 } /^# / && $0 !~ /^# ---/ { sub(/^# ?/, ""); print; n++; if (n >= 18) exit }' "$0"
            exit 0
            ;;
        -*) die "Okänt argument: $arg" ;;
        *)  TEMPLATE="$arg" ;;
    esac
done

# --- Lista templates ------------------------------------------------------
if $LIST_ONLY; then
    info "Tillgängliga Packer-templates i $PACKER_DIR:"
    for f in "$PACKER_DIR"/*.pkr.hcl; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .pkr.hcl)"
        printf '       - %s\n' "$name"
    done
    exit 0
fi

[[ -n "$TEMPLATE" ]] || die "Ange template-namn (eller --list). Ex: $0 win-ep1"
TEMPLATE_FILE="$PACKER_DIR/${TEMPLATE}.pkr.hcl"
[[ -f "$TEMPLATE_FILE" ]] || die "Hittar inte $TEMPLATE_FILE"

# --- Prereq-checkar -------------------------------------------------------
info "Kontrollerar prereqs"

[[ -x "$PACKER_BIN" ]] || die "Packer saknas — kör ./bootstrap.sh först (eller scripts/fetch-packer.sh)."
PACKER_VERSION_OUT="$("$PACKER_BIN" version 2>/dev/null || true)"
PACKER_VERSION_LINE="${PACKER_VERSION_OUT%%$'\n'*}"
ok "Packer: ${PACKER_VERSION_LINE:-okänd version}"

[[ -f "$LAB_ROOT/iso/virtio-win.iso" ]] || die "iso/virtio-win.iso saknas — kör ./bootstrap.sh."
ok "virtio-win.iso finns"

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

image_manifest() {
    local src_iso="${1:-}" prep_unattend="${2:-}"

    printf 'template=%s\n' "$TEMPLATE"
    local packer_version_out packer_version_line
    packer_version_out="$("$PACKER_BIN" version 2>/dev/null || true)"
    packer_version_line="${packer_version_out%%$'\n'*}"
    printf 'packer_version=%s\n' "$packer_version_line"
    printf 'template_sha256=%s\n' "$(file_sha256 "$TEMPLATE_FILE")"
    printf 'build_image_sha256=%s\n' "$(file_sha256 "$0")"
    printf 'virtio_iso_sha256=%s\n' "$(file_sha256 "$LAB_ROOT/iso/virtio-win.iso")"

    if [[ -n "$src_iso" && -f "$src_iso" ]]; then
        printf 'source_iso=%s\n' "$(basename "$src_iso")"
        printf 'source_iso_sha256=%s\n' "$(file_sha256 "$src_iso")"
    fi

    if [[ -n "$prep_unattend" && -f "$prep_unattend" ]]; then
        printf 'prep_unattend_sha256=%s\n' "$(file_sha256 "$prep_unattend")"
    fi

    if [[ -f "$LAB_ROOT/scripts/prep-windows-iso.sh" ]]; then
        printf 'prep_script_sha256=%s\n' "$(file_sha256 "$LAB_ROOT/scripts/prep-windows-iso.sh")"
    fi

    while IFS= read -r f; do
        printf 'packer_support_sha256[%s]=%s\n' \
            "${f#$PACKER_DIR/}" \
            "$(file_sha256 "$f")"
    done < <(find "$PACKER_DIR/http" "$PACKER_DIR/scripts" -type f | sort)
}

# Per-template källa-ISO + Windows-version för driver-extraktion.
# Hardkodat här (inte i templaten) eftersom Packer-templaten inte
# behöver känna till källan. win-ep1 använder en preppad Windows-ISO och en
# separat PROVISION-CD från Packer-templaten.
PREP_ISO_NAME=""
PREP_UNATTEND_TEMPLATE=""
PREP_PATCH_BOOT_WIM=false
case "$TEMPLATE" in
    win-ep1)
        SRC_ISO_NAME="windows-11-enterprise.iso"
        WIN_VER="w11"
        PREP_ISO_NAME="windows-11-enterprise-packer.iso"
        PREP_UNATTEND_TEMPLATE="$PACKER_DIR/http/Autounattend.xml"
        PREP_PATCH_BOOT_WIM=true
        ;;
    win-srv)
        SRC_ISO_NAME="windows-server-2025.iso"
        WIN_VER="2k25"
        PREP_ISO_NAME="windows-server-2025-packer.iso"
        PREP_UNATTEND_TEMPLATE="$PACKER_DIR/http/Autounattend-win-srv.xml"
        PREP_PATCH_BOOT_WIM=true
        ;;
    *)
        SRC_ISO_NAME=""
        WIN_VER=""
        ;;
esac

if [[ -n "$SRC_ISO_NAME" ]]; then
    SRC_ISO="$LAB_ROOT/iso/$SRC_ISO_NAME"
    if [[ -e "$SRC_ISO" ]]; then
        if [[ -L "$SRC_ISO" ]]; then
            real="$(readlink -f "$SRC_ISO")"
            ok "Källa-ISO: $SRC_ISO_NAME → $(basename "$real")"
        else
            ok "Källa-ISO: $SRC_ISO_NAME"
        fi
        warn "Hash-verifiering av Windows-ISO är ditt ansvar — Microsoft Eval"
        warn "Center publicerar inga stabila sha256:or. Vill du verifiera:"
        warn "  sha256sum '$SRC_ISO'"
    else
        err "Saknar $SRC_ISO"
        err ""
        err "Konvention: skapa en symlink i iso/ med stabilt namn som pekar på"
        err "Microsofts ISO med build-nummer i filnamnet:"
        err ""
        err "  ln -sf <microsoft-iso>.iso iso/$SRC_ISO_NAME"
        err ""
        err "Win 11 Enterprise eval: https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise"
        die "Kan inte fortsätta utan Windows-ISO."
    fi
fi

BUILD_ADMIN_PASSWORD="$(get_build_admin_password)"
RENDERED_UNATTEND=""
if [[ -n "$PREP_UNATTEND_TEMPLATE" ]]; then
    RENDERED_UNATTEND="$PACKER_DIR/rendered/${TEMPLATE}-Autounattend.xml"
    render_autounattend "$PREP_UNATTEND_TEMPLATE" "$RENDERED_UNATTEND" "$BUILD_ADMIN_PASSWORD"
    ok "Renderad Autounattend.xml för $TEMPLATE"
fi

PACKER_OUTPUT_DIR="$PACKER_DIR/output-${TEMPLATE}"
SRC_QCOW="$PACKER_OUTPUT_DIR/${TEMPLATE}-base.qcow2"
DST_QCOW="$LAB_ROOT/images/${TEMPLATE}-base.qcow2"
DST_MANIFEST="$DST_QCOW.manifest"

CURRENT_MANIFEST="$(mktemp)"
trap 'rm -f "$CURRENT_MANIFEST"' EXIT
image_manifest "${SRC_ISO:-}" "$RENDERED_UNATTEND" > "$CURRENT_MANIFEST"

if [[ -f "$DST_QCOW" && -f "$DST_MANIFEST" ]] && cmp -s "$CURRENT_MANIFEST" "$DST_MANIFEST" && ! $FORCE; then
    ok "Golden image är up-to-date: $DST_QCOW"
    exit 0
elif [[ -f "$DST_QCOW" && ! -f "$DST_MANIFEST" && ! $FORCE ]]; then
    warn "Golden image finns men saknar manifest — bygger om för spårbarhet"
elif [[ -f "$DST_QCOW" && ! $FORCE ]]; then
    warn "Golden image finns men inputs har ändrats — bygger om"
elif $FORCE; then
    warn "Force-läge: bygger om även om manifest matchar"
fi

# --- Pre-step: extrahera virtio-artefakter från virtio-win.iso -----------
# Används inte för WinPE i win-ep1-bygget längre: installationen kör IDE-disk
# och e1000-NIC så Windows Setup klarar sig med inbyggda drivers.
# virtio-win-guest-tools.exe läggs på Packer PROVISION-CD och installeras
# post-WinRM före cleanup + sysprep, så WinRM slipper skicka stora filer.

CDSTAGING="$PACKER_DIR/cdstaging"

if [[ -n "$WIN_VER" ]]; then
    required_files=(
        viostor.inf viostor.sys viostor.cat
        vioscsi.inf vioscsi.sys vioscsi.cat
        netkvm.inf netkvm.sys netkvm.cat
        virtio-win-guest-tools.exe
        qemu-ga-x86_64.msi
    )
    missing=false
    for f in "${required_files[@]}"; do
        [[ -f "$CDSTAGING/$f" ]] || missing=true
    done

    if $missing; then
        info "Extraherar virtio-artefakter ($WIN_VER) ur virtio-win.iso → packer/cdstaging/"
        mkdir -p "$CDSTAGING"
        xorriso -osirrox on -indev "$LAB_ROOT/iso/virtio-win.iso" \
            -cpx "/amd64/${WIN_VER}/viostor.inf" \
                 "/amd64/${WIN_VER}/viostor.sys" \
                 "/amd64/${WIN_VER}/viostor.cat" \
                 "/amd64/${WIN_VER}/vioscsi.inf" \
                 "/amd64/${WIN_VER}/vioscsi.sys" \
                 "/amd64/${WIN_VER}/vioscsi.cat" \
                 "/NetKVM/${WIN_VER}/amd64/netkvm.inf" \
                 "/NetKVM/${WIN_VER}/amd64/netkvm.sys" \
                 "/NetKVM/${WIN_VER}/amd64/netkvm.cat" \
                 "/virtio-win-guest-tools.exe" \
                 "/guest-agent/qemu-ga-x86_64.msi" \
                 "$CDSTAGING/" 2>&1 | tail -n 1
        for f in "${required_files[@]}"; do
            [[ -f "$CDSTAGING/$f" ]] || die "Extraktion lyckades inte: $f saknas i $CDSTAGING/"
        done
        ok "virtio-artefakter extraherade ($(du -sh "$CDSTAGING" | cut -f1))"
    else
        ok "virtio-artefakter i cdstaging/ (cachat)"
    fi
fi

# --- Pre-step: bygg Packer-specifik Windows install-ISO -------------------
# Valfri strategi för templates som behöver en preppad install-ISO.
# win-ep1 använder detta för att bädda in Autounattend.xml och patcha boot.wim.
PACKER_WIN_ISO_NAME=""
if [[ -n "$PREP_ISO_NAME" ]]; then
    [[ -n "$RENDERED_UNATTEND" && -f "$RENDERED_UNATTEND" ]] || die "Saknar renderad Packer-autounattend: $RENDERED_UNATTEND"
    PREP_ISO="$LAB_ROOT/iso/$PREP_ISO_NAME"
    info "Förbereder Packer-install-ISO → iso/$PREP_ISO_NAME"
    prep_args=( "$SRC_ISO" "$PREP_ISO" "$RENDERED_UNATTEND" )
    if $PREP_PATCH_BOOT_WIM; then
        prep_args+=( --patch-boot-wim )
    fi
    "$LAB_ROOT/scripts/prep-windows-iso.sh" "${prep_args[@]}"
    ok "Packer-install-ISO klar ($(du -h "$PREP_ISO" | cut -f1))"
    PACKER_WIN_ISO_NAME="$PREP_ISO_NAME"
fi

# --- packer init + build --------------------------------------------------
info "Initierar Packer-pluginer för $TEMPLATE"
( cd "$PACKER_DIR" && "$PACKER_BIN" init "${TEMPLATE_FILE}" )
ok "Plugins initierade"

# Avbrutna Packer-körningar lämnar ofta en tom/halvbyggd output-katalog.
# Lyckade byggen flyttas till images/ längre ner, så output-* är transient.
if [[ -d "$PACKER_OUTPUT_DIR" ]]; then
    warn "Rensar gammal transient Packer-output: $PACKER_OUTPUT_DIR"
    rm -rf "$PACKER_OUTPUT_DIR"
fi

# Variabler skickas via -var. lab_root är OBLIGATORISK (templaten saknar default).
PACKER_VARS=(
    -var "lab_root=$LAB_ROOT"
    -var "build_admin_password=$BUILD_ADMIN_PASSWORD"
)
if [[ -n "$PACKER_WIN_ISO_NAME" ]]; then
    PACKER_VARS+=( -var "win_iso_filename=$PACKER_WIN_ISO_NAME" )
fi
if [[ -n "$RENDERED_UNATTEND" ]]; then
    PACKER_VARS+=( -var "autounattend_file=$RENDERED_UNATTEND" )
fi

if $DEBUG; then
    info "Debug-läge: PACKER_LOG=1, headless=false"
    export PACKER_LOG=1
    export PACKER_LOG_PATH="$LAB_ROOT/packer/build-${TEMPLATE}-$(date +%s).log"
    PACKER_VARS+=( -var "headless=false" )
    warn "Logg: $PACKER_LOG_PATH"
fi

info "Startar bygget: $TEMPLATE"
warn "Detta tar 30-60 min. VM:n bootar Windows-installation från ISO."
echo

( cd "$PACKER_DIR" && "$PACKER_BIN" build "${PACKER_VARS[@]}" "${TEMPLATE_FILE}" )

# Flytta golden-image från transient packer-output till images/.
# Då innehåller images/ bara loadbearing backing-disks och Packer-
# output kan alltid rensas av lab-cleanup utan risk.
if [[ -f "$SRC_QCOW" ]]; then
    info "Flyttar golden-image till images/"
    mv -f "$SRC_QCOW" "$DST_QCOW"
    cp "$CURRENT_MANIFEST" "$DST_MANIFEST"
    rmdir "$PACKER_DIR/output-${TEMPLATE}" 2>/dev/null || true
    ok "Golden image: $DST_QCOW ($(du -h "$DST_QCOW" | cut -f1))"
else
    die "Packer rapporterade lyckat bygge men förväntad output saknas: $SRC_QCOW"
fi
