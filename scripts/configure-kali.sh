#!/usr/bin/env bash
#
# configure-kali.sh - install Kali desktop/tooling profile
#
# Usage:
#   ./scripts/configure-kali.sh
#
# Defaults:
#   SSH target:       $LAB_ADMIN_USER@10.40.0.20
#   Desktop package:  kali-desktop-xfce
#   Tooling package:  kali-linux-default
#   Kernel package:   linux-image-amd64
#   GUI user/password: $LAB_ADMIN_USER / Lab12345

set -euo pipefail

LAB_ADMIN_USER="${LAB_ADMIN_USER:-${USER:-labadmin}}"
SSH_TARGET="${KALI_SSH_TARGET:-$LAB_ADMIN_USER@10.40.0.20}"
KALI_DESKTOP_PACKAGE="${KALI_DESKTOP_PACKAGE:-kali-desktop-xfce}"
KALI_TOOLING_PACKAGE="${KALI_TOOLING_PACKAGE:-kali-linux-default}"
KALI_KERNEL_PACKAGE="${KALI_KERNEL_PACKAGE:-linux-image-amd64}"
KALI_GUI_USER="${KALI_GUI_USER:-$LAB_ADMIN_USER}"
KALI_GUI_PASSWORD="${KALI_GUI_PASSWORD:-Lab12345}"
SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

require_cmd ssh

wait_for_ssh() {
    local i
    for i in $(seq 1 120); do
        if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "true" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

info "Väntar på SSH till Kali ($SSH_TARGET)"
wait_for_ssh || die "Kali svarar inte på SSH: $SSH_TARGET"

info "Konfigurerar Kali GUI/tooling ($KALI_DESKTOP_PACKAGE + $KALI_TOOLING_PACKAGE + $KALI_KERNEL_PACKAGE)"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "sudo KALI_DESKTOP_PACKAGE='$KALI_DESKTOP_PACKAGE' KALI_TOOLING_PACKAGE='$KALI_TOOLING_PACKAGE' KALI_KERNEL_PACKAGE='$KALI_KERNEL_PACKAGE' KALI_GUI_USER='$KALI_GUI_USER' KALI_GUI_PASSWORD='$KALI_GUI_PASSWORD' bash -s" <<'REMOTE'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ROOT="/opt/lab-env/kali"
MARKER="$ROOT/kali-profile.json"
DESKTOP="${KALI_DESKTOP_PACKAGE:?}"
TOOLING="${KALI_TOOLING_PACKAGE:?}"
KERNEL="${KALI_KERNEL_PACKAGE:?}"
GUI_USER="${KALI_GUI_USER:?}"
GUI_PASSWORD="${KALI_GUI_PASSWORD:?}"
REBOOT_REQUIRED=false

log() { printf '[kali] %s\n' "$*"; }

packages_installed() {
    local pkg
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx "install ok installed" || return 1
    done
}

standard_kernel_active() {
    [[ "$(uname -r)" != *cloud* ]]
}

refresh_bootloader() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null || true
    elif command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null || true
    fi
}

prefer_regular_kernel() {
    local entry

    [[ -f /boot/grub/grub.cfg ]] || return 0
    entry="$(awk -F"'" '
        /submenu / { submenu=$2 }
        /menuentry / && $2 ~ /kali-amd64/ && $2 !~ /cloud|recovery/ {
            print (submenu ? submenu ">" $2 : $2)
            exit
        }
    ' /boot/grub/grub.cfg)"

    [[ -n "$entry" ]] || return 0
    if command -v grub-set-default >/dev/null 2>&1; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        grub-set-default "$entry" || true
        refresh_bootloader
    fi
}

configure_lightdm_autologin() {
    install -d -m 0755 /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-lab-env-autologin.conf <<EOF
[Seat:*]
autologin-user=$GUI_USER
autologin-user-timeout=0
user-session=xfce
EOF
}

configure_keyboard_locale() {
    if command -v localectl >/dev/null 2>&1; then
        localectl set-keymap se 2>/dev/null || localectl set-keymap sv-latin1 2>/dev/null || true
        localectl set-x11-keymap se pc105 || true
    fi

    if [[ -d /etc/default ]]; then
        cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="se"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone Europe/Stockholm || true
    fi
}

configure_gui_password() {
    if ! id "$GUI_USER" >/dev/null 2>&1; then
        log "GUI user '$GUI_USER' does not exist; skipping password setup."
        return 0
    fi

    printf '%s:%s\n' "$GUI_USER" "$GUI_PASSWORD" | chpasswd
}

install -d -m 0755 "$ROOT"

write_marker() {
    cat > "$MARKER" <<EOF
{
  "configured_at": "$(date -Is)",
  "hostname": "$(hostname)",
  "desktop_package": "$DESKTOP",
  "tooling_package": "$TOOLING",
  "kernel_package": "$KERNEL",
  "gui_user": "$GUI_USER",
  "gui_password_set": "true",
  "lightdm_autologin": "$(awk -F= '/^autologin-user=/ {print $2}' /etc/lightdm/lightdm.conf.d/50-lab-env-autologin.conf 2>/dev/null || true)",
  "running_kernel": "$(uname -r)",
  "reboot_required": "$REBOOT_REQUIRED",
  "default_target": "$(systemctl get-default)",
  "lightdm_enabled": "$(systemctl is-enabled lightdm 2>/dev/null || true)",
  "lightdm_active": "$(systemctl is-active lightdm 2>/dev/null || true)"
}
EOF
}

if [[ -f "$MARKER" ]] && packages_installed "$DESKTOP" "$TOOLING" "$KERNEL"; then
    log "Kali profile already installed."
    prefer_regular_kernel
    configure_keyboard_locale
    configure_gui_password
    configure_lightdm_autologin
    systemctl set-default graphical.target
    systemctl enable --now lightdm >/dev/null 2>&1 || true
    systemctl enable --now spice-vdagentd >/dev/null 2>&1 || true
    if ! standard_kernel_active; then
        REBOOT_REQUIRED=true
        log "Standard kernel package is installed, but current kernel is still cloud. Reboot Kali."
    fi
    write_marker
    cat "$MARKER"
    exit 0
fi

if command -v cloud-init >/dev/null 2>&1; then
    log "Waiting for cloud-init to finish."
    timeout 120 cloud-init status --wait || true
fi

log "Updating apt metadata."
apt-get update

log "Installing desktop profile and regular kernel: $DESKTOP + $KERNEL"
apt-get install -y "$DESKTOP" "$KERNEL" lightdm spice-vdagent dbus-x11

log "Installing Kali tooling profile: $TOOLING"
apt-get install -y "$TOOLING"

refresh_bootloader
prefer_regular_kernel
configure_keyboard_locale
configure_gui_password
configure_lightdm_autologin
systemctl set-default graphical.target
systemctl enable --now lightdm >/dev/null 2>&1 || true
systemctl enable --now spice-vdagentd >/dev/null 2>&1 || true

if ! standard_kernel_active; then
    REBOOT_REQUIRED=true
    log "Installed regular kernel; reboot Kali so it stops using the cloud kernel."
fi

write_marker
cat "$MARKER"
REMOTE

ok "Kali GUI/tooling är konfigurerat."
