# ---------------------------------------------------------------------------
# Cloud-init network-config (version 2) — mall för labbets Linux-VMer.
# Variabler fylls i av Terraform: mgmt_ip/mgmt_mac, deto_ip/deto_mac.
#
# NIC:erna matchas på MAC-adress (satt explicit i Terraform) i stället för
# kärnans interfacenamn (enp1s0/ens3...), som varierar mellan distributioner.
# set-name ger dem stabila namn: mgmt och deto.
# ---------------------------------------------------------------------------

version: 2
ethernets:

  # lab-mgmt — NAT. Default-route och DNS ut mot värdens bryggа.
  mgmt:
    match:
      macaddress: "${mgmt_mac}"
    set-name: mgmt
    addresses:
      - ${mgmt_ip}/24
    routes:
      - to: 0.0.0.0/0
        via: ${mgmt_gateway}
    nameservers:
      addresses:
%{ for dns in mgmt_dns ~}
        - ${dns}
%{ endfor ~}

  # lab-detonation — isolerat. Ingen route, ingen gateway: ingen väg ut.
  deto:
    match:
      macaddress: "${deto_mac}"
    set-name: deto
    addresses:
      - ${deto_ip}/24
