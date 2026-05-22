# networks.tf — Lab-nätverk
# ---------------------------------------------------------------------------
# Skapar ett libvirt_network per post i var.networks. for_each gör att
# tillägg av ett nytt nät bara är en post till i terraform.tfvars.
#
# mode = "none" ger ett isolerat nätverk: VMs kan prata med varandra och
# med host-bryggan, men det finns ingen NAT/routing ut. Det är vad som gör
# lab-detonation säkert för malware-arbete.
# ---------------------------------------------------------------------------

resource "libvirt_network" "lab" {
  for_each = var.networks

  name      = each.key
  mode      = each.value.mode
  domain    = each.value.domain
  addresses = [each.value.cidr]
  autostart = true

  # Explicit bryggnamn från tfvars — hålls under 15 tecken (IFNAMSIZ).
  bridge = each.value.bridge

  dhcp {
    enabled = each.value.dhcp
  }

  dns {
    local_only = each.value.dns_local_only
  }
}

output "networks" {
  description = "Skapade lab-nätverk"
  value = {
    for k, n in libvirt_network.lab : k => {
      mode      = n.mode
      bridge    = n.bridge
      addresses = n.addresses
    }
  }
}
