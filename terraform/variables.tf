# variables.tf — Variabeldefinitioner för Aegis detection-labbet
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
