# packer/win-ep1.pkr.hcl — Win 11 Enterprise golden-image-bygge
# ===========================================================================
# Bygger en sysprep'ad qcow2-image som Terraform sedan klonar som backing-
# disk för win-ep1-VMen (och andra Win 11-endpoints i framtiden).
#
# Windows 11 25H2 golden-image-bygge med Proxmox-lik hårdvaruprofil:
# qemu/KVM + q35 + SeaBIOS + CPU host. Build-disken körs via IDE så
# Windows Setup alltid ser disken; virtio-drivers installeras före sysprep.
#
# Flöde:
#   1. Packer startar qemu med preppad Windows 11 ISO (SeaBIOS/q35)
#   2. Autounattend.xml är inbäddad i en Packer-specifik Windows-ISO
#   3. Windows installeras på IDE-disk utan extra WinPE-storage-driver
#   4. FirstLogon kör setup-winrm.ps1 från PROVISION-CD → WinRM öppnas
#   5. Packer ansluter via WinRM, installerar virtio-win-guest-tools.exe
#      från PROVISION-CD:n, kör cleanup + sysprep
#   6. Output: images/win-ep1-base.qcow2
#
# Säkerhet / lab-kontext:
#   - Image-bygget ligger nära din fungerande Proxmox-profil:
#     CPU host, SeaBIOS och q35. VirtIO-drivers installeras före sysprep.
# ===========================================================================

packer {
  required_plugins {
    qemu = {
      version = "~> 1.1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# --- Variabler -------------------------------------------------------------

variable "lab_root" {
  type        = string
  description = "Absolut sökväg till labbets rot (där iso/, images/ ligger)."
}

variable "win_iso_filename" {
  type        = string
  description = "Filnamn på Microsofts Windows install-ISO i iso/."
  default     = "windows-11-enterprise.iso"
}

variable "build_admin_password" {
  type        = string
  description = "Lokalt admin-lösenord ENDAST under image-bygget. Skickas av scripts/build-image.sh."
  sensitive   = true
}

variable "autounattend_file" {
  type        = string
  description = "Renderad Autounattend.xml med build-lösenord."
}

variable "disk_size_mb" {
  type    = number
  default = 61440 # 60 GB sparse
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "cpus" {
  type    = number
  default = 2
}

variable "headless" {
  type        = bool
  description = "true = ingen QEMU-GUI-konsol. Sätt false vid felsökning."
  default     = true
}

# --- Source: qemu ----------------------------------------------------------

source "qemu" "win-ep1" {
  # Packer-specifik Windows-ISO. Wrappern bygger den från Microsoft-ISOn,
  # bäddar in Autounattend.xml och patchar boot.wim så Setup körs explicit
  # unattended. Drivrutiner/scripts levereras via separat PROVISION-CD.
  iso_url      = "${var.lab_root}/iso/${var.win_iso_filename}"
  iso_checksum = "none"

  # Hårdvara:
  #   - disk: IDE under build; virtio-drivers installeras före sysprep
  #   - NIC:  e1000 under build så WinRM fungerar utan extra WinPE-NIC-driver
  #   - CPU:  host passthrough så Win11 24H2/25H2 ser POPCNT/SSE4.2
  #   - machine: q35 + SeaBIOS
  accelerator  = "kvm"
  machine_type = "q35"
  cpu_model    = "host"

  disk_size      = var.disk_size_mb
  disk_interface = "ide"
  # Låt Packer skapa CD-drive backend med if=none. Vi kopplar dem explicit
  # till AHCI nedan, annars krockar q35 + IDE-disk med CD:n på bus 0/unit 0.
  cdrom_interface = "none"
  format          = "qcow2"

  cpus       = var.cpus
  memory     = var.memory_mb
  headless   = var.headless
  net_device = "e1000"
  qemuargs = [
    ["-boot", "order=dc,menu=off"],
    ["-device", "ahci,id=ahci0"],
    ["-device", "ide-cd,bus=ahci0.0,drive=cdrom0,bootindex=1"],
    ["-device", "ide-cd,bus=ahci0.1,drive=cdrom1"],
    ["-vga", "qxl"],
  ]

  # PROVISION-CD med scripts och guest tools. Guest tools installeras först
  # efter att WinRM är uppe, men ligger på CD:n så vi slipper långsam WinRM-upload.
  cd_label = "PROVISION"
  cd_files = [
    var.autounattend_file,
    "${path.root}/http/sysprep-unattend.xml",
    "${path.root}/scripts/setup-winrm.ps1",
    "${path.root}/cdstaging/virtio-win-guest-tools.exe",
  ]

  # SeaBIOS bootar CD först. Skicka tangenten tidigt så den träffar
  # "Press any key to boot from CD/DVD" och inte Windows Setup-UI:t.
  # Vid Setup-rebootar skickas ingen ny tangent, så BIOS faller vidare till disk.
  boot_wait    = "3s"
  boot_command = ["<spacebar>"]

  # WinRM-kommunikatorn. Setup öppnar 5985 i FirstLogon-fasen.
  communicator   = "winrm"
  winrm_username = "packer"
  winrm_password = var.build_admin_password
  winrm_use_ntlm = false
  winrm_timeout  = "2h"
  winrm_use_ssl  = false
  winrm_insecure = true

  shutdown_command = "cmd.exe /c C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\\Windows\\System32\\Sysprep\\unattend.xml"
  shutdown_timeout = "30m"

  output_directory = "${var.lab_root}/packer/output-win-ep1"
  vm_name          = "win-ep1-base.qcow2"
}

# --- Build -----------------------------------------------------------------

build {
  name    = "win-ep1"
  sources = ["source.qemu.win-ep1"]

  provisioner "powershell" {
    inline = [
      "Write-Output ('Connected: ' + $env:COMPUTERNAME)",
      "Get-ComputerInfo -Property WindowsProductName,OsBuildNumber | Format-List",
    ]
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/install-virtio-tools.ps1"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/cleanup.ps1"
  }

  provisioner "powershell" {
    script = "${path.root}/scripts/sysprep.ps1"
  }
}
