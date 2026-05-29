#!/usr/bin/env bash
#
# configure-vm-console.sh - improve existing VM console pointer handling
# ---------------------------------------------------------------------------
# Adds a USB tablet input device to lab VMs and fixes Kali's video model for a
# usable graphical console. This is intentionally done through virsh instead of
# Terraform because changing graphics/input/video in Terraform forces
# libvirt_domain replacement with the current provider.
#
# Usage:
#   ./scripts/configure-vm-console.sh
#   ./scripts/configure-vm-console.sh --targets kali,win-ep1
# ---------------------------------------------------------------------------

set -euo pipefail

LIBVIRT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
TARGETS="all"
VIDEO_TARGETS="${LAB_VIDEO_TARGETS:-kali}"
VIDEO_MODEL="${LAB_VIDEO_MODEL:-virtio}"
DRY_RUN=false
REBOOT_NEEDED=()

LAB_DOMAINS=(
    linux-srv
    linux-dev
    inetsim
    kali
    collector
    win-srv
    win-ep1
)

usage() {
    cat <<'EOF'
Usage: configure-vm-console.sh [--targets all|vm1,vm2] [--video-targets kali|none|vm1,vm2] [--dry-run]

Adds USB tablet input to existing libvirt domains for better mouse handling in
virt-manager/virt-viewer. Kali also gets virtio video by default, because the
libvirt default cirrus adapter often leaves modern Kali cloud images at a text
console even when lightdm is running.

Tablet input is applied live when possible and to persistent config. Video
model changes are persistent-only and require a VM reboot.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)
            TARGETS="${2:?--targets kräver ett värde}"
            shift 2
            ;;
        --video-targets)
            VIDEO_TARGETS="${2:?--video-targets kräver ett värde}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Okänt argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Saknar kommando: %s\n' "$1" >&2
        exit 1
    }
}

virsh_cmd() {
    virsh --connect "$LIBVIRT_URI" "$@"
}

domain_selected() {
    local domain="$1"
    local selector="${2:-$TARGETS}"
    local item

    [[ "$selector" == "none" ]] && return 1
    [[ "$selector" == "all" ]] && return 0
    IFS=',' read -ra selected <<< "$selector"
    for item in "${selected[@]}"; do
        [[ "$item" == "$domain" ]] && return 0
    done
    return 1
}

domain_exists() {
    virsh_cmd dominfo "$1" >/dev/null 2>&1
}

domain_running() {
    [[ "$(virsh_cmd domstate "$1" 2>/dev/null | tr -d '\r')" == "running" ]]
}

has_tablet() {
    virsh_cmd dumpxml "$1" 2>/dev/null | grep -q "<input type=['\"]tablet['\"]"
}

attach_tablet() {
    local domain="$1"
    local device_xml="$2"

    if has_tablet "$domain"; then
        printf '[console] %s har redan tablet-input\n' "$domain"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        if domain_running "$domain"; then
            printf 'DRY-RUN virsh --connect %q attach-device %q %q --live\n' "$LIBVIRT_URI" "$domain" "$device_xml"
        fi
        printf 'DRY-RUN virsh --connect %q attach-device %q %q --config\n' "$LIBVIRT_URI" "$domain" "$device_xml"
        return 0
    fi

    if domain_running "$domain"; then
        virsh_cmd attach-device "$domain" "$device_xml" --live >/dev/null
    fi
    virsh_cmd attach-device "$domain" "$device_xml" --config >/dev/null
    printf '[console] %s tablet-input aktiverad\n' "$domain"
}

current_video_model() {
    virsh_cmd dumpxml "$1" 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
model = root.find("./devices/video/model")
print(model.get("type", "") if model is not None else "")
'
}

ensure_video_model() {
    local domain="$1"
    local current
    local xml_file

    current="$(current_video_model "$domain")"
    if [[ "$current" == "$VIDEO_MODEL" ]]; then
        printf '[console] %s har redan video=%s\n' "$domain" "$VIDEO_MODEL"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        printf 'DRY-RUN virsh --connect %q dumpxml --inactive %q > /tmp/%q.xml\n' "$LIBVIRT_URI" "$domain" "$domain"
        printf 'DRY-RUN patch first <video><model> from %s to %s and virsh define it\n' "${current:-unknown}" "$VIDEO_MODEL"
        return 0
    fi

    xml_file="$(mktemp)"
    virsh_cmd dumpxml --inactive "$domain" > "$xml_file"
    python3 - "$xml_file" "$VIDEO_MODEL" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, model = sys.argv[1], sys.argv[2]
tree = ET.parse(path)
root = tree.getroot()
video_model = root.find("./devices/video/model")
if video_model is None:
    raise SystemExit("domain XML has no ./devices/video/model")

video_model.set("type", model)
if model == "virtio":
    video_model.attrib.pop("vram", None)
tree.write(path, encoding="unicode", xml_declaration=False)
PY
    virsh_cmd define "$xml_file" >/dev/null
    rm -f "$xml_file"
    printf '[console] %s video ändrad: %s -> %s (reboot krävs)\n' "$domain" "${current:-unknown}" "$VIDEO_MODEL"
    REBOOT_NEEDED+=("$domain")
}

require_cmd virsh
require_cmd grep
require_cmd mktemp
require_cmd python3

DEVICE_XML="$(mktemp)"
trap 'rm -f "$DEVICE_XML"' EXIT
cat > "$DEVICE_XML" <<'EOF'
<input type='tablet' bus='usb'/>
EOF

for domain in "${LAB_DOMAINS[@]}"; do
    domain_selected "$domain" || continue
    if ! domain_exists "$domain"; then
        printf '[console] %s finns inte - hoppar över\n' "$domain"
        continue
    fi
    attach_tablet "$domain" "$DEVICE_XML"
    if domain_selected "$domain" "$VIDEO_TARGETS"; then
        ensure_video_model "$domain"
    fi
done

if ((${#REBOOT_NEEDED[@]} > 0)); then
    printf '[console] Reboota för att aktivera videoändringen: %s\n' "${REBOOT_NEEDED[*]}"
fi
