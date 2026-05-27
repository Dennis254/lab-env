# variables.tf — Variabeldefinitioner för lab environment
# ---------------------------------------------------------------------------
# Konkreta värden sätts i terraform.tfvars. Detta steg täcker enbart
# nätverken; variabler för VMs läggs till när vi bygger dem.
# ---------------------------------------------------------------------------

variable "networks" {
  description = "Lab-nätverkens definitioner"
  type = map(object({
    bridge         = string # bryggnamn, max 15 tecken (Linux IFNAMSIZ-gräns)
    mode           = string # "nat" = routad ut till host/internet; "none" = isolerat
    cidr           = string # subnät i CIDR-notation
    domain         = string # intern DNS-domän
    dhcp           = bool   # aktivera DHCP i nätverket
    dns_local_only = bool   # true = forwarda inte DNS-frågor uppåt (isolerat)
  }))

  validation {
    condition     = alltrue([for n in var.networks : contains(["nat", "none", "route"], n.mode)])
    error_message = "Nätverksläge måste vara 'nat', 'none' eller 'route'."
  }
}

variable "linux_vms" {
  description = "Linux-VMer i labbet. os-nyckeln måste matcha en image i lab-images.json."
  type = map(object({
    os           = string                        # image-nyckel ur lab-images.json (ubuntu-24.04, rocky-9, ...)
    vcpu         = number                        # antal virtuella CPU-kärnor
    memory       = number                        # RAM i MB
    disk_bytes   = optional(number)              # boot-disken i bytes, default sätts i vms-linux.tf
    mgmt_network = optional(string, "lab-mgmt")  # nät för default-route/admin-NIC
    mgmt_ip      = string                        # statisk IP på admin/default-route-NIC
    mgmt_mac     = string                        # MAC på admin/default-route-NIC (matchas i cloud-init)
    mgmt_gateway = optional(string, "10.20.0.1") # gateway på admin/default-route-NIC
    mgmt_dns     = optional(list(string), ["10.20.0.1"])
    deto_ip      = string # statisk IP på lab-detonation
    deto_mac     = string # MAC på lab-detonation-NIC
  }))
}

# --- Windows-VMer ----------------------------------------------------------
# Windows använder inte cloud-init. Installation drivs av autounattend.xml
# (genererad per VM från en mall) som monteras som CDROM tillsammans med
# install-mediat och virtio-driver-ISOn.
#
# install_iso och virtio_iso pekar på filer i iso/ (laddas ner manuellt enligt
# README). edition matchar /image/name i install-WIM:en.
variable "windows_vms" {
  description = "Windows-VMer i labbet. Sätt install_iso för direkt installation eller base_image för kloning från Packer-byggd qcow2."
  type = map(object({
    edition     = string           # WIM image-namn (t.ex. \"Windows Server 2025 SERVERSTANDARD\")
    install_iso = optional(string) # filnamn i iso/ för OS-installationsmediat
    base_image  = optional(string) # filnamn i images/ för Packer-byggd qcow2
    vcpu        = number
    memory      = number # MB
    disk_bytes  = number # boot-disken i bytes
    mgmt_ip     = string
    mgmt_mac    = string
    deto_ip     = string
    deto_mac    = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, vm in var.windows_vms :
      try(vm.install_iso, null) != null || try(vm.base_image, null) != null
    ])
    error_message = "Varje Windows-VM måste ha antingen install_iso eller base_image."
  }
}

variable "virtio_win_iso" {
  description = "Filnamn i iso/ för virtio-win-drivers (gemensam för alla Windows-VMer)."
  type        = string
  default     = "virtio-win.iso"
}

variable "windows_admin_password" {
  description = "Valfri override för lokalt admin-lösenord på Windows-VMerna. Lämnas null genereras ett 24-tecken random_password per host (rekommenderat — repot kan vara publikt utan att läcka hemligheter). Hämta det aktiva lösenordet med: tofu output -raw windows_admin_password"
  type        = string
  default     = null
  sensitive   = true
}

variable "ad_domain_name" {
  description = "Active Directory DNS-namn som skapas i labbet."
  type        = string
  default     = "corp.local"
}

variable "ad_netbios_name" {
  description = "Active Directory NetBIOS-namn."
  type        = string
  default     = "CORP"
}

variable "windows_dc_name" {
  description = "Windows-VM som ska promoveras till domain controller."
  type        = string
  default     = "win-srv"
}

variable "ad_lab_users" {
  description = "Fiktiva AD-användare som skapas i labbdomänen efter DC-promovering."
  type = list(object({
    sam_account_name = string
    given_name       = string
    surname          = string
    display_name     = string
    department       = string
    title            = string
  }))
  default = [
    {
      sam_account_name = "anna.lind"
      given_name       = "Anna"
      surname          = "Lind"
      display_name     = "Anna Lind"
      department       = "Finance"
      title            = "Finance Analyst"
    },
    {
      sam_account_name = "erik.svensson"
      given_name       = "Erik"
      surname          = "Svensson"
      display_name     = "Erik Svensson"
      department       = "IT"
      title            = "Helpdesk Technician"
    },
    {
      sam_account_name = "maria.holm"
      given_name       = "Maria"
      surname          = "Holm"
      display_name     = "Maria Holm"
      department       = "HR"
      title            = "HR Manager"
    },
    {
      sam_account_name = "johan.ek"
      given_name       = "Johan"
      surname          = "Ek"
      display_name     = "Johan Ek"
      department       = "Engineering"
      title            = "Developer"
    }
  ]
}

variable "ovmf_code_path" {
  description = "Sökväg till OVMF Secure Boot-firmware på värden (Fedora-default)."
  type        = string
  default     = "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd"
}

variable "ovmf_vars_template" {
  description = "Sökväg till OVMF Secure Boot vars-mall (kopieras per VM av libvirt)."
  type        = string
  default     = "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd"
}
