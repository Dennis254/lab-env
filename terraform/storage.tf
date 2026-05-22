# storage.tf — Base cloud-images
# ---------------------------------------------------------------------------
# Importerar cloud-images till libvirts inbyggda "default"-pool. VM-diskar
# skapas i vms-*.tf som copy-on-write-kloner av dessa base-volymer.
#
# Image-katalogen läses direkt ur lab-images.json — SAMMA fil som
# bootstrap.sh använder. Det ger en enda källa till sanning: lägg till en
# image där, och både bootstrap (nedladdning) och Terraform (import) plockar
# upp den. Ingen filnamnsdubblering mellan verktygen.
#
# Default-poolen används i stället för en egen libvirt_pool av två skäl:
#   1. qemu-processen kommer alltid åt /var/lib/libvirt/images, men inte
#      nödvändigtvis åt filer under /home/<user> (behörigheter).
#   2. libvirt_pool-schemat ändrades mellan provider 0.7 och 0.8 — default-
#      poolen undviker den osäkerheten helt.
# ---------------------------------------------------------------------------

locals {
  # Plocka images-objektet ur lab-images.json. Nycklarna (ubuntu-24.04,
  # rocky-9, ...) blir resurs- och volymnycklar.
  lab_images = jsondecode(file("${local.lab_root}/lab-images.json")).images
}

resource "libvirt_volume" "base" {
  for_each = local.lab_images

  name   = "aegis-base-${each.key}.qcow2"
  pool   = "default"
  source = "${local.lab_root}/images/${each.value.filename}"
  format = "qcow2"
}

output "base_volumes" {
  description = "Importerade base-volymer (image-nyckel -> volym-ID)"
  value       = { for k, v in libvirt_volume.base : k => v.id }
}
