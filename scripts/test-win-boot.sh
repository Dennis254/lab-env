#!/usr/bin/env bash
#
# test-win-boot.sh — interaktiv qemu-boot för Windows-ISO-felsökning
# ---------------------------------------------------------------------------
# Replikerar Packer's qemu-setup (samma machine, samma OVMF, samma disk-
# interface, samma två CDROMs) men UTAN Packer i mitten. Du kör qemu med
# GTK-GUI och kan trycka tangenter, navigera boot-meny, observera fel.
#
# Förändringar mot Packers automatik:
#   - GTK display (Packer kör headless+VNC)
#   - Per-VM OVMF NVRAM (Packer återanvänder samma i flera försök)
#   - Boot-meny synlig som default ('boot menu=on')
#   - Ingen automation: du trycker själv
#
# Tillstånd lagras i /tmp/lab-manual-boot/. Radera den för att starta om
# från noll.
#
# Användning:
#   ./scripts/test-win-boot.sh                # default: win-ep1 + båda CDs + UEFI
#   ./scripts/test-win-boot.sh win-srv        # Server 2025-ISOn istället
#   ./scripts/test-win-boot.sh --no-prov      # boota utan provision-CD
#   ./scripts/test-win-boot.sh --prov-first   # provision-CD som första IDE-drive
#   ./scripts/test-win-boot.sh --ahci         # CDROMs på AHCI istället för IDE
#   ./scripts/test-win-boot.sh --with-floppy  # autounattend.xml + viostor på A:
#                                               (samma som Packers floppy_files)
#   ./scripts/test-win-boot.sh --bios         # SeaBIOS istället för OVMF/UEFI
#                                               kombinera med --with-floppy
#                                               för fullt Packer-equivalent test
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="/tmp/lab-manual-boot"

TEMPLATE="win-ep1"
WITH_PROV=true
PROV_FIRST=false
USE_AHCI=false
WITH_FLOPPY=false
USE_BIOS=false
for arg in "$@"; do
    case "$arg" in
        win-ep1|win-srv) TEMPLATE="$arg" ;;
        --no-prov)       WITH_PROV=false ;;
        --prov-first)    PROV_FIRST=true ;;
        --ahci)          USE_AHCI=true ;;
        --with-floppy)   WITH_FLOPPY=true; WITH_PROV=false ;;
        --bios)          USE_BIOS=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 35
            exit 0
            ;;
        *) echo "Okänt argument: $arg" >&2; exit 1 ;;
    esac
done

case "$TEMPLATE" in
    win-ep1) SRC_ISO_NAME="windows-11-enterprise.iso" ;;
    win-srv) SRC_ISO_NAME="windows-server-2025.iso"  ;;
esac
SRC_ISO="$LAB_ROOT/iso/$SRC_ISO_NAME"
[[ -e "$SRC_ISO" ]] || { echo "Saknar $SRC_ISO" >&2; exit 1; }

mkdir -p "$WORK"

# OVMF NVRAM (per-VM, så vi inte rör default-vars som andra VMer delar)
if [[ ! -f "$WORK/vars.fd" ]]; then
    echo "==> Kopierar OVMF NVRAM → $WORK/vars.fd"
    cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$WORK/vars.fd"
    chmod u+w "$WORK/vars.fd"
fi

# Tom 60G boot-disk (sparse qcow2)
if [[ ! -f "$WORK/disk.qcow2" ]]; then
    echo "==> Skapar tom 60G qcow2-disk → $WORK/disk.qcow2"
    qemu-img create -f qcow2 "$WORK/disk.qcow2" 60G >/dev/null
fi

# Provision-ISO: speglar vad Packer bygger från cd_files
PROVISION_ISO="$WORK/provision.iso"
if $WITH_PROV; then
    # Rebuild om någon källa är nyare än output
    SOURCES=(
        "$LAB_ROOT/packer/http/Autounattend.xml"
        "$LAB_ROOT/packer/http/sysprep-unattend.xml"
        "$LAB_ROOT/packer/scripts/setup-winrm.ps1"
    )
    need_rebuild=false
    [[ -f "$PROVISION_ISO" ]] || need_rebuild=true
    for s in "${SOURCES[@]}"; do
        [[ -f "$s" ]] || { echo "Saknar källa: $s" >&2; exit 1; }
        [[ "$s" -nt "$PROVISION_ISO" ]] && need_rebuild=true
    done

    if $need_rebuild; then
        echo "==> Bygger provision-ISO → $PROVISION_ISO"
        PROV_WORK="$(mktemp -d --tmpdir="$WORK" --suffix=-prov)"
        for s in "${SOURCES[@]}"; do cp "$s" "$PROV_WORK/"; done
        if [[ -d "$LAB_ROOT/packer/cdstaging" ]]; then
            cp "$LAB_ROOT/packer/cdstaging/"* "$PROV_WORK/" 2>/dev/null || true
        fi
        xorriso -as mkisofs -V PROVISION -J -R -o "$PROVISION_ISO" "$PROV_WORK" \
            2>&1 | grep -E '^xorriso : (FAILURE|SORRY|WARNING)' || true
        rm -rf "$PROV_WORK"
    else
        echo "==> Provision-ISO är up-to-date"
    fi
fi

# Floppy med autounattend + scripts + viostor (matchar Packer's floppy_files)
FLOPPY_IMG="$WORK/floppy.img"
if $WITH_FLOPPY; then
    if [[ ! -f "$FLOPPY_IMG" ]] || \
       [[ "$LAB_ROOT/packer/http/Autounattend.xml" -nt "$FLOPPY_IMG" ]]; then
        echo "==> Bygger floppy-image → $FLOPPY_IMG"
        FLOPPY_TMP="$(mktemp -d --tmpdir="$WORK" --suffix=-floppy)"
        cp "$LAB_ROOT/packer/http/Autounattend.xml" "$FLOPPY_TMP/"
        cp "$LAB_ROOT/packer/http/sysprep-unattend.xml" "$FLOPPY_TMP/"
        cp "$LAB_ROOT/packer/scripts/setup-winrm.ps1" "$FLOPPY_TMP/"
        for f in viostor.inf viostor.sys viostor.cat; do
            [[ -f "$LAB_ROOT/packer/cdstaging/$f" ]] && \
                cp "$LAB_ROOT/packer/cdstaging/$f" "$FLOPPY_TMP/"
        done
        # mformat + mcopy producerar samma FAT12-floppy som Packer
        dd if=/dev/zero of="$FLOPPY_IMG" bs=1024 count=1440 status=none
        mformat -i "$FLOPPY_IMG" -f 1440 ::
        for f in "$FLOPPY_TMP"/*; do
            mcopy -i "$FLOPPY_IMG" "$f" ::"$(basename "$f")"
        done
        rm -rf "$FLOPPY_TMP"
    else
        echo "==> Floppy-image är up-to-date"
    fi
fi

echo
echo "==> Startar qemu (GTK GUI). Konfiguration:"
echo "    machine:     q35 + OVMF (samma som Packer)"
echo "    disk:        $WORK/disk.qcow2 (virtio-blk, 60G tom)"
if $WITH_PROV && $PROV_FIRST; then
    echo "    CD #1:       provision.iso (autounattend + scripts)  <-- första"
    echo "    CD #2:       $SRC_ISO_NAME (huvud install-ISO)"
else
    echo "    CD #1:       $SRC_ISO_NAME (huvud install-ISO)"
    $WITH_PROV && echo "    CD #2:       provision.iso (autounattend + scripts)"
    $WITH_PROV || echo "    CD #2:       <ingen — kört med --no-prov>"
fi
echo "    NVRAM:       $WORK/vars.fd (per-VM)"
echo "    boot-meny:   synlig (tryck ESC eller välj från BDS-menyn)"
echo
echo "    Stäng VMen genom att stänga fönstret eller File → Quit."
echo "    Radera $WORK/ för att starta om helt från noll (tom disk)."
echo

if $USE_AHCI; then
    # AHCI/SATA via q35:s ich9-ahci (6 oberoende portar) — varje CD får
    # sin egen port, ingen master/slave-konflikt. bootindex=1 tvingar
    # UEFI BDS att försöka Windows-CDn först.
    CDROMS=(
        -device "ich9-ahci,id=ahci"
        -drive  "id=cd0,if=none,format=raw,readonly=on,media=cdrom,file=$SRC_ISO"
        -device "ide-cd,bus=ahci.0,drive=cd0,bootindex=1"
    )
    if $WITH_PROV; then
        CDROMS+=(
            -drive  "id=cd1,if=none,format=raw,readonly=on,media=cdrom,file=$PROVISION_ISO"
            -device "ide-cd,bus=ahci.1,drive=cd1,bootindex=2"
        )
    fi
elif $WITH_PROV && $PROV_FIRST; then
    # piix3-IDE med provision-CD först (testar drive-ordning på samma bus)
    CDROMS=(
        -drive "file=$PROVISION_ISO,if=ide,media=cdrom,readonly=on"
        -drive "file=$SRC_ISO,if=ide,media=cdrom,readonly=on"
    )
else
    # piix3-IDE default — Windows först, provision på master/slave
    CDROMS=( -drive "file=$SRC_ISO,if=ide,media=cdrom,readonly=on" )
    $WITH_PROV && CDROMS+=( -drive "file=$PROVISION_ISO,if=ide,media=cdrom,readonly=on" )
fi

if $USE_BIOS; then
    # SeaBIOS-mode (qemu default firmware). Ingen pflash/OVMF.
    # Win 11 25H2 ISO bootar i BIOS-mode och Setup går i MBR-läge.
    # LabConfig-bypass i Autounattend kringgår TPM/SecureBoot-kraven.
    FIRMWARE_ARGS=()
    echo "    firmware:    SeaBIOS (BIOS-mode, ej UEFI)"
else
    # OVMF/UEFI (default i lab-env)
    FIRMWARE_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd"
        -drive "if=pflash,format=raw,file=$WORK/vars.fd"
    )
    echo "    firmware:    OVMF (UEFI)"
fi

QEMU_ARGS=(
    -name "${TEMPLATE}-manual"
    -machine q35,accel=kvm
    -cpu host
    -smp 2 -m 4096
    "${FIRMWARE_ARGS[@]}"
    -drive "file=$WORK/disk.qcow2,if=virtio,format=qcow2"
    "${CDROMS[@]}"
    -netdev user,id=net0
    -device virtio-net-pci,netdev=net0
    -display gtk -vga std
    -boot menu=on,splash-time=0
)
$WITH_FLOPPY && QEMU_ARGS+=( -fda "$FLOPPY_IMG" )

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
