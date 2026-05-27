# main.tf — Provider-konfiguration för lab environment
# ---------------------------------------------------------------------------
# Använder dmacvicar/libvirt-providern för att hantera KVM/libvirt-resurser
# deklarativt. Anslutningen går mot systemets libvirt-instans (qemu:///system),
# samma instans som virt-manager och `virsh` (med LIBVIRT_DEFAULT_URI satt).
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # ~> 0.8.0 (tre komponenter) = >= 0.8.0, < 0.9.0 — låser till legacy-
      # providern. OBS: "~> 0.8" (två komponenter) skulle betyda < 1.0.0 och
      # släppa in v0.9.x, som är en komplett omskrivning med annat schema.
      version = "~> 0.8.0"
    }

    # null + local används för att rendera autounattend.xml och bygga en
    # ISO av den per Windows-VM via local-exec (genisoimage). random
    # används för att generera Windows admin-lösenord per host.
    null   = { source = "hashicorp/null", version = "~> 3.2" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Labbets rotkatalog härleds automatiskt som förälder till terraform/-mappen.
# Gör hela konfigurationen portabel — ingen maskinspecifik sökväg behöver
# sättas, oavsett var labbet klonas eller vilken användare som kör det.
locals {
  lab_root = abspath("${path.root}/..")
}
