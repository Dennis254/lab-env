# terraform.tfvars — Konkreta värden för Aegis detection-labbet
# ---------------------------------------------------------------------------
# Två nätverk:
#   lab-mgmt        NAT. Provisioning, OS-uppdateringar, detection-dev mot
#                   host-baserad Aegis-backend.
#   lab-detonation  Isolerat (mode=none). Malware-detonation — ingen routing
#                   till host eller internet. INetSim-VM:n ger fejk-internet
#                   inuti detta nät.
# ---------------------------------------------------------------------------

networks = {
  lab-mgmt = {
    bridge         = "virbr-mgmt"
    mode           = "nat"
    cidr           = "10.20.0.0/24"
    domain         = "lab.local"
    dhcp           = true
    dns_local_only = false
  }

  lab-detonation = {
    bridge         = "virbr-deto"
    mode           = "none"
    cidr           = "10.30.0.0/24"
    domain         = "detonation.lab"
    dhcp           = true
    dns_local_only = true
  }
}
