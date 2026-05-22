# Detection Lab

En KVM/libvirt-baserad labbmiljö för detection engineering och malware-analys,
definierad som infrastruktur-as-code med OpenTofu.

## Översikt

`lab-env` är en reproducerbar virtualiseringsmiljö för detection engineering
och malware-analys. Labbet tillhandahåller endpoint-VMer (Linux och Windows),
en attackmaskin, och en isolerad detonationsmiljö där riktig skadlig kod kan
köras utan risk för värdsystemet — en kontrollerad plats att generera
telemetri, utveckla detektionsregler och validera dem mot verkliga
attacktekniker.

Hela labbet definieras som kod. En ny värd klonar repot, kör två kommandon,
och får en identisk miljö — inga maskinspecifika sökvägar, inget manuellt
klickande i virt-manager.

## Arkitektur

### Nätverk

Två libvirt-nätverk med medvetet olika säkerhetsprofiler:

| Nätverk          | Typ          | Subnät          | Syfte                                              |
|------------------|--------------|-----------------|----------------------------------------------------|
| `lab-mgmt`       | NAT          | 10.20.0.0/24    | Provisionering, OS-uppdateringar, detection-dev    |
| `lab-detonation` | Isolerat     | 10.30.0.0/24    | Malware-detonation — ingen routing till värd/internet |

`lab-detonation` har inget `forward`-läge: VMer på nätet kan prata med
varandra, men det finns ingen väg ut till värden eller internet. Det är vad
som gör miljön säker för skadlig kod.

### Virtuella maskiner

| VM          | OS                          | Roll                                  |
|-------------|-----------------------------|---------------------------------------|
| `linux-srv` | Ubuntu Server 24.04         | Övervakad endpoint                    |
| `linux-dev` | Rocky Linux 9               | Övervakad endpoint                    |
| `win-ep1`   | Windows 11 Enterprise       | Övervakad endpoint, domänansluten     |
| `win-srv`   | Windows Server 2025         | Domänkontrollant (`corp.local`)       |
| `kali`      | Kali Linux                  | Attackmaskin                          |
| `inetsim`   | Debian 12                   | Fejk-internet i detonationsläge       |

Varje VM har två nätverkskort — ett på `lab-mgmt`, ett på `lab-detonation`.

### Lab-lägen

Labbet växlar mellan två tillstånd:

- **Dev-läge** — mgmt-nätverket aktivt på alla VMer. Används för
  provisionering, uppdateringar, och detection-utveckling — insamling av
  telemetri och iterering på detektionsregler.
- **Detonation-läge** — mgmt-NIC nedstängt på samtliga VMer. Endast det
  isolerade `lab-detonation`-nätet är aktivt. `inetsim`-VM:n simulerar
  internet inåt så skadlig kod beter sig realistiskt, men inget når värden
  eller verkligt internet.

## Designprinciper

- **Portabilitet** — ingen konfiguration innehåller maskinspecifika
  sökvägar. `bootstrap.sh` och Terraform härleder labbets rot från sina
  egna filplatser. Labbet kan klonas till valfri värd och valfri användare.
- **Malware-isolering** — detonationsnätet är fysiskt isolerat. KVM:s
  sVirt (SELinux per-VM) ger ytterligare ett inneslutningslager. VMer som
  hanterar skadlig kod får inga delade mappar, ingen USB-passthrough.
- **En källa till sanning** — `lab-images.json` definierar samtliga
  cloud-images. Både `bootstrap.sh` (nedladdning) och Terraform (import)
  läser den. Inga filnamn dupliceras mellan verktygen.
- **Infrastruktur som kod** — all topologi (nätverk, storage, VMer)
  definieras i OpenTofu. `tofu apply` bygger, `tofu destroy` river.

## Förutsättningar

- Linux-värd med KVM (Intel VT-x/AMD-V samt IOMMU aktiverat i BIOS)
- libvirt med modulära daemons, `default`-storage-pool aktiv
- OpenTofu (installeras av `bootstrap.sh` om det saknas)
- `qemu-img`, `virt-install`, `jq`, `genisoimage` (installeras av `bootstrap.sh`)
- Windows-ISOer (laddas ner manuellt — se nedan)

## Kom igång

```bash
git clone <repo-url> lab-env
cd lab-env

# Verktyg, kataloger, cloud-images
./bootstrap.sh

# Windows-ISOer kan inte git-versionshanteras eller laddas ner automatiskt.
# Lägg följande i iso/ manuellt:
#   - Windows 11 Enterprise Eval ISO
#   - Windows Server 2025 Eval ISO

# Bygg infrastrukturen
cd terraform
tofu init
tofu apply
```

Varje värd får sitt eget Terraform-state. Labbet kan därför köras oberoende
på flera maskiner samtidigt.

## Repo-struktur

```
lab-env/
├── bootstrap.sh        Förbereder värd: verktyg, kataloger, cloud-images
├── lab-images.json     Katalog över cloud-images (en källa till sanning)
├── images/             Nedladdade cloud-images        (git-ignorerad)
├── iso/                Windows-ISOer                  (git-ignorerad)
├── terraform/          Infrastruktur som kod (OpenTofu)
│   ├── main.tf         Provider, härledd lab-rot
│   ├── variables.tf    Variabeldefinitioner
│   ├── terraform.tfvars Konkreta värden
│   ├── networks.tf     De två lab-nätverken
│   └── storage.tf      Import av base-images
├── cloud-init/         Cloud-init-mallar för Linux-VMer
├── scripts/            Hjälpscript (lab-mode m.m.)
└── snapshots/          Exporterad snapshot-metadata
```

## Status & Roadmap

- [x] Bootstrap-script (värdverktyg, cloud-images)
- [x] Lab-nätverk (`lab-mgmt`, `lab-detonation`)
- [x] Base-images importerade till storage
- [ ] Linux-VMer (`linux-srv`, `linux-dev`, `inetsim`, `kali`)
- [ ] Windows-VMer (`win-ep1`, `win-srv`) + Active Directory
- [ ] `lab-mode`-script (växla dev- / detonationsläge)
- [ ] INetSim-konfiguration i `inetsim`-VM:n
- [ ] Utrullning av telemetri-/sensoragent på endpoints

## Säkerhet

Detta labb är avsett för defensivt säkerhetsarbete — utveckling av
detektionsregler och analys av skadlig kod i kontrollerad miljö.

- **Kör endast skadlig kod i detonationsläge.** I det läget är mgmt-nätet
  nedstängt och VMerna saknar väg till värd och internet.
- **Verifiera isolering före varje detonation** — kontrollera att
  `getenforce` returnerar `Enforcing` (sVirt aktivt) och att mgmt-NIC är
  nedkopplat på samtliga VMer.
- **Återställ till ren snapshot efter varje detonation.**
- Repot innehåller endast labb-konfiguration — ingen produktionsdata.
  Terraform-state och eventuella hemligheter versionshanteras aldrig
  (se `.gitignore`). Det är särskilt viktigt om repot görs publikt.

## Licens

Ingen licens vald ännu. Lägg till en `LICENSE`-fil innan repot publiceras
om koden ska få återanvändas av andra.
