# vms-windows.tf — Windows-VMer (Server 2025 + Win 11 Enterprise)
# ---------------------------------------------------------------------------
# Windows använder inte cloud-init. Det finns två flöden:
#   - install_iso: direkt installation från Windows-ISO med autounattend.xml
#   - base_image: kloning från Packer-byggd sysprepad qcow2
#
# ISO-flödet bakar en per-VM autounattend.xml direkt in i en ombyggd kopia av
# Windows install-ISOn (via prep-windows-iso.sh), tillsammans med ett byte
# cdboot.efi → cdboot_noprompt.efi. Det är vad som gör installationen
# obevakad på Server 2025:
#   - Press-any-key-prompten vid UEFI-boot försvinner (cdboot_noprompt).
#   - Den nya Setup-UI:n plockar upp autounattend automatiskt eftersom
#     den ligger i ISO-rot — en separat unattend-CDROM räcker inte alltid.
#
# ISO-bygget sker i fyra steg per VM:
#   1. local_file        — renderar autounattend.xml till build/<vm>/
#   2. null_resource     — kör prep-windows-iso.sh och producerar
#                          build/<vm>/install.iso med autounattend embedded
#   3. libvirt_volume    — laddar upp ISOn till default-poolen
#   4. libvirt_domain    — startar VM:n med install + virtio som SATA-CDROMer
#
# UEFI + Secure Boot + vTPM speglar en realistisk modern Windows-endpoint.
# ---------------------------------------------------------------------------

# --- Lokalt admin-lösenord -------------------------------------------------
# Genereras vid första apply, persisteras i state, och återanvänds vid
# efterföljande apply. var.windows_admin_password = override för den som
# vill diktera ett specifikt lösen (sätts t.ex. via env: TF_VAR_windows_admin_password=...).
resource "random_password" "windows_admin" {
  length      = 24
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
  # Exkluderar tecken som krockar med XML-attribut, PowerShell-quoting eller
  # SQL-style escape: " ' ` \ / : ; < > & % $
  override_special = "!@#^*-_=+?.,"
}

locals {
  windows_admin_password = coalesce(var.windows_admin_password, random_password.windows_admin.result)

  windows_iso_vms = {
    for k, v in var.windows_vms : k => v
    if try(v.base_image, null) == null
  }

  windows_image_vms = {
    for k, v in var.windows_vms : k => v
    if try(v.base_image, null) != null
  }

  windows_dc_vms = {
    for k, v in local.windows_image_vms : k => v
    if k == var.windows_dc_name
  }

  windows_domain_member_vms = {
    for k, v in local.windows_image_vms : k => v
    if k != var.windows_dc_name && length(local.windows_dc_vms) == 1
  }
}

# --- virtio-win-ISO (delad, read-only) -------------------------------------
# Drivers för NetKVM + viostor + vioscsi. Samma fil för alla Windows-VMer.
moved {
  from = libvirt_volume.virtio_win_iso
  to   = libvirt_volume.virtio_win_iso[0]
}

resource "libvirt_volume" "virtio_win_iso" {
  count = length(var.windows_vms) > 0 ? 1 : 0

  name   = "lab-env-virtio-win.iso"
  pool   = "default"
  source = "${local.lab_root}/iso/${var.virtio_win_iso}"
  # ISO 9660 är ett filsystem inuti en raw image. libvirt-poolen klassar
  # filer av denna typ som "iso" och skriver tillbaka det i state — om vi
  # deklarerar "raw" här hamnar vi i evig drift (forces replacement).
  format = "iso"
}

# --- Per-VM autounattend.xml -----------------------------------------------
# Renderas av Terraform; varje fil hamnar i build/<vm>/autounattend.xml.
# Innehållshashen styr ISO-namnet längre ner så att ändringar i mallen leder
# till att libvirt-volymen återskapas.
resource "local_file" "autounattend_xml" {
  for_each = local.windows_iso_vms

  filename = "${path.module}/build/${each.key}/autounattend.xml"
  content = templatefile("${local.lab_root}/autounattend/windows.xml.tpl", {
    hostname       = each.key
    edition        = each.value.edition
    admin_password = local.windows_admin_password
    mgmt_mac       = each.value.mgmt_mac
    mgmt_ip        = each.value.mgmt_ip
    mgmt_prefix    = 24
    mgmt_gateway   = "10.20.0.1"
    mgmt_dns       = "10.20.0.1"
  })
  file_permission = "0600"
}

# --- Per-VM prepped install-ISO --------------------------------------------
# Bygger en ombyggd kopia av Windows install-ISOn där:
#   - autounattend.xml ligger i ISO-rot (plockas upp av nya Setup-UI:n)
#   - cdboot.efi och efisys.bin bytts mot _noprompt-versioner
#     (skippar "Press any key to boot from CD or DVD")
#
# Output landar i terraform/build/<vm>/install.iso (git-ignorerat).
resource "null_resource" "prep_iso" {
  for_each = local.windows_iso_vms

  triggers = {
    # Triggas om autounattend.xml, källan-ISO eller scriptet ändras.
    xml_sha    = local_file.autounattend_xml[each.key].content_sha256
    input_iso  = each.value.install_iso
    script_sha = filesha256("${local.lab_root}/scripts/prep-windows-iso.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/prep-windows-iso.sh'",
      "'${local.lab_root}/iso/${each.value.install_iso}'",
      "'${path.module}/build/${each.key}/install.iso'",
      "'${path.module}/build/${each.key}/autounattend.xml'",
      "--patch-boot-wim",
    ])
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [local_file.autounattend_xml]
}

# --- Ladda upp prepped install-ISO som libvirt-volym -----------------------
# Innehållshashen i namnet tvingar replacement när XML, källan-ISO eller
# prep-scriptet ändras — libvirt-providern detekterar inte ändringar i
# 'source' annars. Vi hashar SAMMA fält som null_resource.prep_iso triggar
# på så namn och innehåll alltid hänger ihop.
locals {
  prep_iso_hash = {
    for k, v in local.windows_iso_vms : k => substr(sha256(join("|", [
      local_file.autounattend_xml[k].content_sha256,
      v.install_iso,
      filesha256("${local.lab_root}/scripts/prep-windows-iso.sh"),
    ])), 0, 8)
  }
}

resource "libvirt_volume" "windows_install_iso" {
  for_each = local.windows_iso_vms

  name   = "${each.key}-install-${local.prep_iso_hash[each.key]}.iso"
  pool   = "default"
  source = "${path.module}/build/${each.key}/install.iso"
  format = "iso"

  depends_on = [null_resource.prep_iso]
}

# --- Base-images från Packer -----------------------------------------------
resource "libvirt_volume" "windows_base" {
  for_each = local.windows_image_vms

  name   = "lab-env-base-${each.key}.qcow2"
  pool   = "default"
  source = "${local.lab_root}/images/${each.value.base_image}"
  format = "qcow2"
}

# --- Boot-disk per VM ------------------------------------------------------
resource "libvirt_volume" "windows_vm" {
  for_each = local.windows_iso_vms

  name   = "${each.key}.qcow2"
  pool   = "default"
  format = "qcow2"
  size   = each.value.disk_bytes
}

resource "libvirt_volume" "windows_clone" {
  for_each = local.windows_image_vms

  name           = "${each.key}-golden.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.windows_base[each.key].id
  format         = "qcow2"
  size           = each.value.disk_bytes
}

# --- Windows-domäner -------------------------------------------------------
resource "libvirt_domain" "windows" {
  for_each = local.windows_iso_vms

  name   = each.key
  vcpu   = each.value.vcpu
  memory = each.value.memory

  # UEFI + Secure Boot. NVRAM-filen genereras per VM från template.
  firmware = var.ovmf_code_path
  nvram {
    template = var.ovmf_vars_template
  }

  # q35 + SMM krävs för Secure Boot.
  machine = "q35"

  cpu {
    mode = "host-passthrough"
  }

  # vTPM 2.0 — Win 11-krav (och good practice för Server 2025).
  tpm {
    backend_type    = "emulator"
    backend_version = "2.0"
    model           = "tpm-crb"
  }

  # Boot-disken — virtio-blk för prestanda. viostor-drivern laddas i
  # WinPE-fasen via DriverPaths i autounattend.xml.
  disk {
    volume_id = libvirt_volume.windows_vm[each.key].id
  }

  # Installations-ISOn (Windows Setup-mediat med embedded autounattend.xml).
  disk {
    volume_id = libvirt_volume.windows_install_iso[each.key].id
  }

  # virtio-win drivers (NetKVM + viostor + vioscsi).
  disk {
    volume_id = libvirt_volume.virtio_win_iso[0].id
  }

  # NIC 1 — lab-mgmt (NAT). Matchas via MAC i autounattend så IPn sätts rätt.
  network_interface {
    network_id = libvirt_network.lab["lab-mgmt"].id
    mac        = each.value.mgmt_mac
  }

  # NIC 2 — lab-detonation (isolerat).
  network_interface {
    network_id = libvirt_network.lab["lab-detonation"].id
    mac        = each.value.deto_mac
  }

  # Boot från CDROM först så installern startar; därefter HD.
  boot_device {
    dev = ["cdrom", "hd"]
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  qemu_agent = true

  # cdrom.xsl konverterar varje disk med .iso-källfil till SATA-CDROM
  # (provider 0.8 exponerar inte device=cdrom direkt).
  xml {
    xslt = file("${path.module}/xsl/cdrom.xsl")
  }
}

resource "libvirt_domain" "windows_image" {
  for_each = local.windows_image_vms

  name   = each.key
  vcpu   = each.value.vcpu
  memory = each.value.memory

  # SeaBIOS/MBR-klon från Packer-image. Secure Boot/vTPM tas upp i ett
  # separat UEFI/GPT-spår senare.
  machine = "q35"

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.windows_clone[each.key].id
  }

  network_interface {
    network_id = libvirt_network.lab["lab-mgmt"].id
    mac        = each.value.mgmt_mac
  }

  network_interface {
    network_id = libvirt_network.lab["lab-detonation"].id
    mac        = each.value.deto_mac
  }

  boot_device {
    dev = ["hd"]
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  qemu_agent = true

  xml {
    xslt = file("${path.module}/xsl/windows-image-sata.xsl")
  }
}

resource "null_resource" "windows_image_config" {
  for_each = local.windows_image_vms

  triggers = {
    domain_id = libvirt_domain.windows_image[each.key].id
    hostname  = each.key
    mgmt_mac  = each.value.mgmt_mac
    mgmt_ip   = each.value.mgmt_ip
    deto_mac  = each.value.deto_mac
    deto_ip   = each.value.deto_ip
    # Keeps this bootstrap step stable if the lab password is rotated later.
    admin_password_sha = nonsensitive(sha256(random_password.windows_admin.result))
    script_sha         = filesha256("${local.lab_root}/scripts/windows-qga-config.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/windows-qga-config.sh'",
      "'${each.key}'",
      "'${each.key}'",
      "'${each.value.mgmt_mac}'",
      "'${each.value.mgmt_ip}'",
      "'24'",
      "'10.20.0.1'",
      "'10.20.0.1'",
      "'${each.value.deto_mac}'",
      "'${each.value.deto_ip}'",
    ])
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WINDOWS_ADMIN_PASSWORD = local.windows_admin_password
    }
  }
}

moved {
  from = null_resource.windows_dc
  to   = null_resource.windows_dc["win-srv"]
}

resource "null_resource" "windows_dc" {
  for_each = local.windows_dc_vms

  triggers = {
    domain_id       = libvirt_domain.windows_image[each.key].id
    image_config_id = null_resource.windows_image_config[each.key].id
    ad_domain_name  = var.ad_domain_name
    ad_netbios_name = var.ad_netbios_name
    dc_ip           = each.value.mgmt_ip
    # Keeps this bootstrap step stable if the lab password is rotated later.
    admin_password_sha = nonsensitive(sha256(random_password.windows_admin.result))
    script_sha         = filesha256("${local.lab_root}/scripts/windows-promote-dc.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/windows-promote-dc.sh'",
      "'${each.key}'",
      "'${var.ad_domain_name}'",
      "'${var.ad_netbios_name}'",
      "'${each.value.mgmt_ip}'",
    ])
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WINDOWS_ADMIN_PASSWORD = local.windows_admin_password
    }
  }

  depends_on = [null_resource.windows_image_config]
}

resource "null_resource" "windows_domain_join" {
  for_each = local.windows_domain_member_vms

  triggers = {
    domain_id       = libvirt_domain.windows_image[each.key].id
    image_config_id = null_resource.windows_image_config[each.key].id
    dc_config_id    = null_resource.windows_dc[var.windows_dc_name].id
    ad_domain_name  = var.ad_domain_name
    ad_netbios_name = var.ad_netbios_name
    dc_ip           = var.windows_vms[var.windows_dc_name].mgmt_ip
    mgmt_mac        = each.value.mgmt_mac
    # Keeps this bootstrap step stable if the lab password is rotated later.
    admin_password_sha = nonsensitive(sha256(random_password.windows_admin.result))
    script_sha         = filesha256("${local.lab_root}/scripts/windows-join-domain.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/windows-join-domain.sh'",
      "'${each.key}'",
      "'${each.key}'",
      "'${var.ad_domain_name}'",
      "'${var.ad_netbios_name}'",
      "'${var.windows_vms[var.windows_dc_name].mgmt_ip}'",
      "'${each.value.mgmt_mac}'",
    ])
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WINDOWS_ADMIN_PASSWORD = local.windows_admin_password
    }
  }
}

resource "null_resource" "windows_local_admin_password" {
  for_each = local.windows_domain_member_vms

  triggers = {
    domain_id          = libvirt_domain.windows_image[each.key].id
    image_config_id    = null_resource.windows_image_config[each.key].id
    admin_password_sha = nonsensitive(sha256(local.windows_admin_password))
    script_sha         = filesha256("${local.lab_root}/scripts/windows-local-admin-password.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/windows-local-admin-password.sh'",
      "'${each.key}'",
    ])
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WINDOWS_ADMIN_PASSWORD = local.windows_admin_password
    }
  }

  depends_on = [null_resource.windows_domain_join]
}

resource "null_resource" "windows_ad_users" {
  for_each = local.windows_dc_vms

  triggers = {
    domain_id          = libvirt_domain.windows_image[each.key].id
    dc_config_id       = null_resource.windows_dc[each.key].id
    ad_domain_name     = var.ad_domain_name
    ad_netbios_name    = var.ad_netbios_name
    admin_password_sha = nonsensitive(sha256(local.windows_admin_password))
    users_sha          = sha256(jsonencode(var.ad_lab_users))
    script_sha         = filesha256("${local.lab_root}/scripts/windows-ad-users.sh")
  }

  provisioner "local-exec" {
    command = join(" ", [
      "'${local.lab_root}/scripts/windows-ad-users.sh'",
      "'${each.key}'",
      "'${var.ad_domain_name}'",
      "'${var.ad_netbios_name}'",
    ])
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WINDOWS_ADMIN_PASSWORD = local.windows_admin_password
      AD_LAB_USERS_JSON      = jsonencode(var.ad_lab_users)
    }
  }

  depends_on = [null_resource.windows_dc]
}

output "windows_vms" {
  description = "Windows-VMer: namn -> edition och IP-adresser"
  value = {
    for k, v in var.windows_vms : k => {
      edition = v.edition
      mgmt_ip = v.mgmt_ip
      deto_ip = v.deto_ip
    }
  }
}

output "windows_admin_password" {
  description = "Lokalt admin-lösenord för Windows-VMerna. Hämta med: tofu output -raw windows_admin_password"
  value       = local.windows_admin_password
  sensitive   = true
}
