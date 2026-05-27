# packer/win-srv.pkr.hcl - Windows Server 2025 golden-image build
# ===========================================================================
# Builds a sysprepped qcow2 image that Terraform can clone as win-srv.
# Mirrors the proven win-ep1 path: q35 + SeaBIOS, IDE build disk, e1000 build
# NIC, VirtIO guest tools before sysprep, then QGA/WinRM post-clone config.
# ===========================================================================

packer {
  required_plugins {
    qemu = {
      version = "~> 1.1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "lab_root" {
  type        = string
  description = "Absolute path to the lab root containing iso/ and images/."
}

variable "win_iso_filename" {
  type        = string
  description = "Windows Server install ISO filename in iso/."
  default     = "windows-server-2025.iso"
}

variable "build_admin_password" {
  type        = string
  description = "Local admin password used only during image build. Provided by scripts/build-image.sh."
  sensitive   = true
}

variable "autounattend_file" {
  type        = string
  description = "Rendered Autounattend.xml containing the build password."
}

variable "disk_size_mb" {
  type    = number
  default = 81920 # 80 GB sparse
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
  description = "true = no QEMU GUI console. Set false while debugging."
  default     = true
}

source "qemu" "win-srv" {
  iso_url      = "${var.lab_root}/iso/${var.win_iso_filename}"
  iso_checksum = "none"

  accelerator  = "kvm"
  machine_type = "q35"
  cpu_model    = "host"

  disk_size       = var.disk_size_mb
  disk_interface  = "ide"
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

  cd_label = "PROVISION"
  cd_files = [
    var.autounattend_file,
    "${path.root}/http/sysprep-unattend.xml",
    "${path.root}/scripts/setup-winrm.ps1",
    "${path.root}/cdstaging/virtio-win-guest-tools.exe",
    "${path.root}/cdstaging/qemu-ga-x86_64.msi",
  ]

  boot_wait    = "3s"
  boot_command = ["<spacebar>"]

  communicator   = "winrm"
  winrm_username = "packer"
  winrm_password = var.build_admin_password
  winrm_use_ntlm = false
  winrm_timeout  = "2h"
  winrm_use_ssl  = false
  winrm_insecure = true

  shutdown_command = "cmd.exe /c C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm /unattend:C:\\Windows\\System32\\Sysprep\\unattend.xml"
  shutdown_timeout = "30m"

  output_directory = "${var.lab_root}/packer/output-win-srv"
  vm_name          = "win-srv-base.qcow2"
}

build {
  name    = "win-srv"
  sources = ["source.qemu.win-srv"]

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
