# vms-linux.tf — Linux-VMer
# ---------------------------------------------------------------------------
# Bygger labbets fyra Linux-VMer (linux-srv, linux-dev, inetsim, kali) via
# for_each över var.linux_vms. Varje VM får:
#   - en copy-on-write-disk klonad från sin base-volym
#   - en cloud-init-disk (user-data + network-config)
#   - en domän med två NICs: admin/default-route-nät och lab-detonation
#
# Windows-VMerna byggs separat (annan process — ingen cloud-init).
# ---------------------------------------------------------------------------

locals {
  # Dennis publika SSH-nyckel — läses från värdens ~/.ssh.
  # Saknas nyckeln: skapa med 'ssh-keygen -t ed25519'.
  ssh_public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))

  # Diskstorlek för alla Linux-VMer (40 GiB i bytes).
  # Kalis base-image är 25 GiB virtual size — qcow2-CoW kräver att 'size'
  # är minst lika stor som backing-store, så 40 GiB ger marginal för alla.
  # qcow2 är thin-provisionerat, så VMer som inte använder utrymmet förbrukar
  # det inte på disk.
  vm_disk_bytes = 42949672960
}

# --- VM-diskar — copy-on-write-kloner av base-volymerna --------------------
# base_volume_id pekar på rätt base-volym via VM:ns os-nyckel. Disken tar
# nästan ingen plats förrän VM:n skriver data.
resource "libvirt_volume" "vm" {
  for_each = var.linux_vms

  name           = "${each.key}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base[each.value.os].id
  format         = "qcow2"
  size           = local.vm_disk_bytes
}

# --- Cloud-init-diskar -----------------------------------------------------
# En ISO per VM med user-data (användare, paket) och network-config
# (statiska IPs). Attachas som CDROM av providern.
resource "libvirt_cloudinit_disk" "linux" {
  for_each = var.linux_vms

  name = "${each.key}-cloudinit.iso"
  pool = "default"

  user_data = templatefile("${local.lab_root}/cloud-init/user-data.yaml.tpl", {
    hostname = each.key
    ssh_key  = local.ssh_public_key
  })

  meta_data = "instance-id: ${each.key}\nlocal-hostname: ${each.key}"

  network_config = templatefile("${local.lab_root}/cloud-init/network-config.yaml.tpl", {
    mgmt_ip      = each.value.mgmt_ip
    mgmt_mac     = each.value.mgmt_mac
    mgmt_gateway = each.value.mgmt_gateway
    mgmt_dns     = each.value.mgmt_dns
    deto_ip      = each.value.deto_ip
    deto_mac     = each.value.deto_mac
  })
}

# --- Domäner ---------------------------------------------------------------
resource "libvirt_domain" "linux" {
  for_each = var.linux_vms

  name   = each.key
  vcpu   = each.value.vcpu
  memory = each.value.memory

  cloudinit = libvirt_cloudinit_disk.linux[each.key].id

  # host-passthrough ger VM:n värdens CPU-funktioner — bra prestanda och
  # stöd för nested virt om det skulle behövas.
  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.vm[each.key].id
  }

  # NIC 1 — admin/default-route. För de flesta VMer lab-mgmt, för Kali lab-wan.
  network_interface {
    network_id = libvirt_network.lab[each.value.mgmt_network].id
    mac        = each.value.mgmt_mac
  }

  # NIC 2 — lab-detonation (isolerat).
  network_interface {
    network_id = libvirt_network.lab["lab-detonation"].id
    mac        = each.value.deto_mac
  }

  # Seriekonsoll — åtkomst via 'virsh console <vm>'.
  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  # Grafisk konsoll via VNC.
  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  # qemu-guest-agent-kanal — låter libvirt fråga VM:n om t.ex. IP.
  qemu_agent = true
}

output "linux_vms" {
  description = "Linux-VMer: namn -> OS och IP-adresser"
  value = {
    for k, v in var.linux_vms : k => {
      os      = v.os
      network = v.mgmt_network
      mgmt_ip = v.mgmt_ip
      deto_ip = v.deto_ip
    }
  }
}
