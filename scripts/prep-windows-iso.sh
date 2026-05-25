#!/usr/bin/env bash
#
# prep-windows-iso.sh — bygga om en Windows-install-ISO för obevakad installation
# ---------------------------------------------------------------------------
# Tre modifikationer görs på ISOn:
#
#   1. UEFI-boot-prompten tas bort: cdboot.efi och efisys.bin byts mot sina
#      _noprompt-versioner. BIOS/SeaBIOS-prompten behålls, eftersom den
#      hindrar installations-CDn från att boota igen efter första rebooten.
#
#   2. autounattend.xml läggs i ISO-rot. Vissa Windows-versioner plockar
#      upp den automatiskt därifrån (klassiskt beteende).
#
#   3. Valfritt: \Windows\System32\startnet.cmd inuti boot.wim image 2
#      (Microsoft Windows Setup) kan bytas mot en version som kör setup.exe
#      med /unattend explicit. Aktiveras med --patch-boot-wim för flöden där
#      root-autounattend inte räcker.
#
# Implementation: extraherar ISOn med 7z (xorriso 1.5.8 kan inte läsa
# UDF-tree som Windows-ISOs använder), modifierar filerna + boot.wim,
# repackar med xorriso -as mkisofs och Windows-standard boot-args.
#
# Beroenden (installeras av bootstrap.sh):
#   7z, xorriso, isoinfo, wimlib-imagex (paket: p7zip, xorriso, wimlib-utils)
#
# Användning:
#   prep-windows-iso.sh <input.iso> <output.iso> <autounattend.xml> [--patch-boot-wim]
# ---------------------------------------------------------------------------

set -euo pipefail

PATCH_BOOT_WIM=false
if [[ $# -eq 4 && "$4" == "--patch-boot-wim" ]]; then
    PATCH_BOOT_WIM=true
elif [[ $# -ne 3 ]]; then
    echo "usage: $0 <input.iso> <output.iso> <autounattend.xml> [--patch-boot-wim]" >&2
    exit 1
fi

INPUT="$1"
OUTPUT="$2"
AUTOUNATTEND="$3"

[[ -f "$INPUT"        ]] || { echo "input-ISO saknas: $INPUT" >&2; exit 1; }
[[ -f "$AUTOUNATTEND" ]] || { echo "autounattend saknas: $AUTOUNATTEND" >&2; exit 1; }
command -v 7z             >/dev/null || { echo "7z saknas (paket: p7zip-plugins/p7zip-full)" >&2; exit 1; }
command -v xorriso        >/dev/null || { echo "xorriso saknas" >&2; exit 1; }
command -v wimlib-imagex  >/dev/null || { echo "wimlib-imagex saknas (paket: wimlib-utils)" >&2; exit 1; }

# Idempotens: hoppa över om output finns och är nyare än input + autounattend +
# scriptet självt.
SCRIPT="${BASH_SOURCE[0]}"
if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" && "$OUTPUT" -nt "$AUTOUNATTEND" && "$OUTPUT" -nt "$SCRIPT" ]]; then
    echo "  ✓ $(basename "$OUTPUT") är redan up-to-date — hoppar över"
    exit 0
fi

# Tempkatalog under samma filsystem som output (snabb atomic move).
OUTPUT_DIR="$(dirname "$OUTPUT")"
WORK="$(mktemp -d --tmpdir="$OUTPUT_DIR" --suffix=-iso-prep)"
trap 'rm -rf "$WORK"' EXIT

echo "  → Extraherar $(basename "$INPUT") (~$(du -hL "$INPUT" | awk '{print $1}'), ~10-20s) ..."
7z x -o"$WORK" "$INPUT" >/dev/null

# (1) Byt UEFI-prompt-versioner mot noprompt. Behåll BIOS bootfix.bin så
# Windows Setup kan reboota till hårddisken utan att CDn autobootar igen.
echo "  → Tar bort UEFI-boot-prompt (behåller BIOS-prompt) ..."
[[ -f "$WORK/efi/microsoft/boot/cdboot_noprompt.efi" ]] \
    || { echo "cdboot_noprompt.efi saknas i ISOn" >&2; exit 1; }
[[ -f "$WORK/efi/microsoft/boot/efisys_noprompt.bin" ]] \
    || { echo "efisys_noprompt.bin saknas i ISOn" >&2; exit 1; }
cp "$WORK/efi/microsoft/boot/cdboot_noprompt.efi" "$WORK/efi/microsoft/boot/cdboot.efi"
cp "$WORK/efi/microsoft/boot/efisys_noprompt.bin" "$WORK/efi/microsoft/boot/efisys.bin"

# (2) autounattend.xml i ISO-rot. För 24H2 räcker inte detta ensamt
# (Setup-UI:n ignorerar det) — vi använder boot.wim-modifikationen nedan
# som primär mekanism, men har autounattend kvar i rot för (a) äldre
# Windows-versioner och (b) Setup-fasen efter WinPE.
echo "  → Lägger in autounattend.xml i ISO-rot ..."
cp "$AUTOUNATTEND" "$WORK/autounattend.xml"

# (3) Valfri boot.wim-modifikation: skriv en custom startnet.cmd som kör
# Setup unattended. Sätt på image 2 (Microsoft Windows Setup) — det är den
# image WinPE bootar till för Setup-fasen.
if $PATCH_BOOT_WIM; then
    echo "  → Skapar custom startnet.cmd för WinPE ..."
    cat > "$WORK/startnet.cmd" <<'STARTNET_EOF'
@echo off
rem startnet.cmd — körs av WinPE som första shell-script.
rem Vi byter ut default-versionens enbart-wpeinit mot:
rem   1. wpeinit (default init)
rem   2. setup.exe med explicit /unattend
rem
rem Packer-bygget använder IDE-disk under installationen, så WinPE ska kunna
rem se Disk 0 utan VirtIO-storage-drivers. VirtIO installeras senare inne i
rem Windows innan sysprep.

wpeinit

rem Hitta install-mediet (CD/DVD) genom att leta efter \sources\setup.exe
rem på alla drive-letters. Kör setup.exe med /unattend pekande på
rem autounattend.xml på samma media (lagt där av prep-windows-iso.sh).
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\sources\setup.exe (
        if exist %%d:\autounattend.xml (
            echo Starting Windows Setup unattended from %%d:
            start /wait "" %%d:\sources\setup.exe /unattend:%%d:\autounattend.xml
            exit /b
        )
    )
)

rem Fallback: kör Setup interaktivt om autounattend inte hittas.
echo WARNING: autounattend.xml not found on any drive. Falling back.
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%d:\sources\setup.exe start /wait "" %%d:\sources\setup.exe
)
STARTNET_EOF

    echo "  → Modifierar boot.wim image 2 med custom startnet.cmd ..."
    # wimlib-imagex update kan ändra en WIM utan att fullt extrahera + repacka.
    # 'add' med destination-path som redan existerar skriver över filen.
    wimlib-imagex update "$WORK/sources/boot.wim" 2 \
        --command="add '$WORK/startnet.cmd' '/Windows/System32/startnet.cmd'" \
        2>&1 | grep -vE '^$' | tail -5

    # Också inkludera autounattend.xml i boot.wim:s rot — Setup söker även där.
    wimlib-imagex update "$WORK/sources/boot.wim" 2 \
        --command="add '$AUTOUNATTEND' '/autounattend.xml'" \
        2>&1 | grep -vE '^$' | tail -5

else
    echo "  → Lämnar boot.wim orörd (standard Windows Setup-start)"
fi

# Behåll original-volym-label så Windows Setup känner igen ISOn.
LABEL="$(isoinfo -d -i "$INPUT" 2>/dev/null | awk -F': ' '/Volume id/ {print $2}' | tr -d '\r' | head -1)"
LABEL="${LABEL:-WIN_INSTALL}"

echo "  → Repackar UEFI+BIOS-bootable ISO (label: $LABEL) ..."
# Ta bort vår temporära startnet.cmd så den inte hamnar i ISO-rot.
rm -f "$WORK/startnet.cmd"
rm -f "$OUTPUT"
xorriso -as mkisofs \
    -iso-level 4 \
    -d \
    -V "$LABEL" \
    -no-emul-boot \
    -b boot/etfsboot.com \
    -boot-load-size 8 \
    -eltorito-alt-boot \
    -no-emul-boot \
    -e efi/microsoft/boot/efisys.bin \
    -o "$OUTPUT" \
    "$WORK" 2>&1 | grep -E '^xorriso : (FAILURE|SORRY|WARNING)' || true

[[ -s "$OUTPUT" ]] || { echo "Output-ISO blev tom eller skapades inte" >&2; exit 1; }
echo "  ✓ Klar: $(basename "$OUTPUT") ($(du -h "$OUTPUT" | awk '{print $1}'))"
