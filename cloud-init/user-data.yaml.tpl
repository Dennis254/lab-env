#cloud-config
# ---------------------------------------------------------------------------
# Cloud-init user-data — gemensam mall för labbets Linux-VMer.
# Variabler fylls i av Terraform (templatefile): hostname, ssh_key.
# ---------------------------------------------------------------------------

hostname: ${hostname}
manage_etc_hosts: true

# Administrativ användare. Endast nyckelbaserad inloggning — inget lösenord.
users:
  - name: dennis
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
  - systemctl enable --now qemu-guest-agent
