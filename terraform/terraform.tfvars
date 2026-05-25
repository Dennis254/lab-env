# terraform.tfvars — Konkreta värden för Aegis detection-labbet
# ---------------------------------------------------------------------------
# Tre nätverk:
#   lab-mgmt        NAT. Provisioning, OS-uppdateringar, detection-dev mot
#                   host-baserad Aegis-backend.
#   lab-detonation  Isolerat (mode=none). Malware-detonation — ingen routing
#                   till host eller internet. INetSim-VM:n ger fejk-internet
#                   inuti detta nät.
#   lab-wan         NAT. Kalis externa sida; simulerar angripare på internet.
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

  lab-wan = {
    bridge         = "virbr-wan"
    mode           = "nat"
    cidr           = "10.40.0.0/24"
    domain         = "wan.local"
    dhcp           = true
    dns_local_only = false
  }
}

# --- Linux-VMer -------------------------------------------------------------
# os-nyckeln måste matcha en image i lab-images.json.
# IP-schema: mgmt 10.20.0.x, detonation 10.30.0.x (samma sista oktett).
# MAC-schema: 52:54:00:6c:NN:HH  (NN = 20 mgmt / 30 deto, HH = host).
linux_vms = {
  linux-srv = {
    os       = "ubuntu-24.04"
    vcpu     = 2
    memory   = 2048
    mgmt_ip  = "10.20.0.11"
    mgmt_mac = "52:54:00:6c:20:11"
    deto_ip  = "10.30.0.11"
    deto_mac = "52:54:00:6c:30:11"
  }

  linux-dev = {
    os       = "rocky-9"
    vcpu     = 2
    memory   = 2048
    mgmt_ip  = "10.20.0.12"
    mgmt_mac = "52:54:00:6c:20:12"
    deto_ip  = "10.30.0.12"
    deto_mac = "52:54:00:6c:30:12"
  }

  inetsim = {
    os       = "debian-12"
    vcpu     = 1
    memory   = 1024
    mgmt_ip  = "10.20.0.13"
    mgmt_mac = "52:54:00:6c:20:13"
    deto_ip  = "10.30.0.13"
    deto_mac = "52:54:00:6c:30:13"
  }

  kali = {
    os           = "kali"
    vcpu         = 2
    memory       = 4096
    mgmt_network = "lab-wan"
    mgmt_ip      = "10.40.0.20"
    mgmt_mac     = "52:54:00:6c:40:20"
    mgmt_gateway = "10.40.0.1"
    mgmt_dns     = ["10.40.0.1"]
    deto_ip      = "10.30.0.20"
    deto_mac     = "52:54:00:6c:30:20"
  }
}

# --- Windows-VMer -----------------------------------------------------------
# install_iso = exakt filnamn i iso/ (uppdatera om en nyare eval-ISO används).
# IP-schema: mgmt 10.20.0.x, detonation 10.30.0.x (samma sista oktett).
# MAC-schema: 52:54:00:6c:NN:HH  (NN = 20 mgmt / 30 deto, HH = host).
windows_vms = {
  win-srv = {
    edition    = "Windows Server 2025 SERVERSTANDARD"
    base_image = "win-srv-base.qcow2"
    vcpu       = 4
    memory     = 8192
    disk_bytes = 85899345920 # 80 GiB
    mgmt_ip    = "10.20.0.10"
    mgmt_mac   = "52:54:00:6c:20:10"
    deto_ip    = "10.30.0.10"
    deto_mac   = "52:54:00:6c:30:10"
  }

  win-ep1 = {
    edition    = "Windows 11 Enterprise Evaluation"
    base_image = "win-ep1-base.qcow2"
    vcpu       = 4
    memory     = 8192
    disk_bytes = 85899345920 # 80 GiB
    mgmt_ip    = "10.20.0.21"
    mgmt_mac   = "52:54:00:6c:20:21"
    deto_ip    = "10.30.0.21"
    deto_mac   = "52:54:00:6c:30:21"
  }
}
