#cloud-config
# ---------------------------------------------------------------------------
# Cloud-init user-data — gemensam mall för labbets Linux-VMer.
# Variabler fylls i av Terraform (templatefile): hostname, ssh_key.
# ---------------------------------------------------------------------------

hostname: ${hostname}
manage_etc_hosts: true
# Keep cloud-init's locale module conservative across Ubuntu, Debian, Rocky and
# Kali. Keyboard layout is normalized by scripts/configure-keyboard.sh.
locale: C.UTF-8
timezone: Europe/Stockholm

# Administrativ användare. Endast nyckelbaserad inloggning — inget lösenord.
users:
  - name: ${linux_admin_user}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_key}

# Ingen lösenordsbaserad SSH — bara publik nyckel.
ssh_pwauth: false

# Uppdatera paketindex och installera qemu-guest-agent (krävs av mgmt-NIC
# vid första boot — sker via lab-mgmt-nätet).
package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - localectl set-keymap se 2>/dev/null || localectl set-keymap sv-latin1 2>/dev/null || true
  - localectl set-x11-keymap se pc105 || true
  - systemctl enable --now qemu-guest-agent
