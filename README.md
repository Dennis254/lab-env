# Detection Lab

En KVM/libvirt-baserad labbmiljö för detection engineering och malware-analys,
definierad som infrastruktur-as-code med OpenTofu.

## Översikt

`lab-env` bygger en reproducerbar virtualiseringsmiljö med Linux-endpoints,
Windows-endpoint, Windows Server-domain controller, Kali och en isolerad
detonationszon. Målet är att kunna generera telemetri, utveckla
detektionsregler och analysera beteende i en kontrollerad miljö.

En ny värd ska i normalfallet bara behöva:

1. Klona repot.
2. Lägga Windows-ISOer i `iso/`.
3. Köra `./scripts/setup-lab.sh --yes`.

Windows-ISOer laddas inte ner automatiskt eftersom Microsoft kräver ett
interaktivt download-flöde.

## Snabbstart

```bash
git clone <repo-url> lab-env
cd lab-env

mkdir -p iso
ln -sf <windows-11-enterprise-eval>.iso iso/windows-11-enterprise.iso
ln -sf <windows-server-2025-eval>.iso iso/windows-server-2025.iso

./scripts/setup-lab.sh --yes
```

Efter installation:

```bash
cd terraform
tofu output -raw windows_admin_password
tofu plan
```

Mer detaljer finns i [docs/SETUP_AND_USAGE.md](docs/SETUP_AND_USAGE.md).
Verktygsrekommendationer finns i
[docs/TOOLING_RECOMMENDATIONS.md](docs/TOOLING_RECOMMENDATIONS.md).

## Arkitektur

### Nätverk

| Nätverk          | Typ      | Subnät       | Syfte                                           |
|------------------|----------|--------------|-------------------------------------------------|
| `lab-mgmt`       | NAT      | 10.20.0.0/24 | Provisionering, WinRM/QGA, SSH, uppdateringar   |
| `lab-detonation` | Isolerat | 10.30.0.0/24 | Malware-detonation utan routing till internet   |
| `lab-wan`        | NAT      | 10.40.0.0/24 | Kalis externa sida, simulerad internetposition  |

### Virtuella maskiner

| VM          | OS                    | Admin/WAN-IP | Deto-IP    | Roll                              |
|-------------|-----------------------|------------|------------|-----------------------------------|
| `win-srv`   | Windows Server 2025   | 10.20.0.10 | 10.30.0.10 | Domain controller för `corp.local` |
| `linux-srv` | Ubuntu Server 24.04   | 10.20.0.11 | 10.30.0.11 | Linux endpoint                    |
| `linux-dev` | Rocky Linux 9         | 10.20.0.12 | 10.30.0.12 | Linux endpoint/dev                |
| `inetsim`   | Debian 12             | 10.20.0.13 | 10.30.0.13 | Fejk-internet i detonationsläge   |
| `kali`      | Kali Linux + XFCE     | 10.40.0.20 | 10.30.0.20 | Attackmaskin på `lab-wan`         |
| `win-ep1`   | Windows 11 Enterprise | 10.20.0.21 | 10.30.0.21 | Domänansluten Windows endpoint    |
| `splunk`    | Ubuntu Server 24.04   | 10.20.0.30 | 10.30.0.30 | Lab-SIEM för Splunk               |

Varje VM har två nätverkskort. De flesta har `lab-mgmt` + `lab-detonation`;
Kali har `lab-wan` + `lab-detonation`.

I detonationsläge växlas DNS bara för victim-endpoints (`linux-srv`,
`linux-dev`, `win-ep1`) till INetSim. `win-srv` behåller sin AD/DNS-roll och
`kali` behandlas som operator-/attackmaskin, inte som victim. DC:n kan senare
läggas till som scenario-victim, men bör inte vara default eftersom AD/DNS då
kan bli instabilt för resten av labbet.

## Vad som är automatiserat

- Host-bootstrap: verktyg, kataloger, OpenTofu/Packer och Linux cloud-images.
- Windows golden images via Packer:
  - `images/win-srv-base.qcow2`
  - `images/win-ep1-base.qcow2`
- Terraform/OpenTofu-provisionering av nätverk, diskar och VMer.
- Windows post-clone-konfiguration via QEMU Guest Agent.
- Active Directory:
  - `win-srv` promoveras till DC för `corp.local`.
  - `win-ep1` joinas till domänen.
  - Fyra fiktiva labbanvändare skapas under `OU=Aegis Lab`.
- VM-konsoler får USB tablet-input för bättre muspekare i virt-manager.
- Kali konfigureras med XFCE, vanlig Kali-kärna för grafisk konsol och
  `kali-linux-default`. GUI-login: `dennis` / `Lab12345`.
- INetSim installeras och binds till `10.30.0.13` på detonationsnätet.
- Lokal logging-baseline konfigureras:
  - Windows: Sysmon, PowerShell logging och förstärkt audit policy.
  - Linux: auditd, persistent journald och lokal rsyslog.
- Integrationsramverk för externa SIEM-/agentlösningar:
  - `custom` för privat agent/SIEM-kod utanför repot.
  - `splunk` körs inne i labbet och tar emot data på `10.30.0.30:9997`.
  - `wazuh` är publik profilplats för nästa SIEM-spår.
- Idempotens: redan aktuella downloads/images hoppas över.

## Viktiga kommandon

```bash
# Full setup eller uppdatering
./scripts/setup-lab.sh --yes

# Visa plan utan apply
./scripts/setup-lab.sh --yes --plan-only

# Växla/synka labbnätens läge
./scripts/lab-mode.sh status
./scripts/lab-mode.sh dev --yes
./scripts/lab-mode.sh detonation --yes

# Snapshot/restore för hela labbet
./scripts/lab-snapshot.sh create clean-dev-splunk --yes
./scripts/lab-snapshot.sh list
./scripts/lab-snapshot.sh restore clean-dev-splunk --yes

# Konfigurera INetSim manuellt
./scripts/configure-inetsim.sh

# Konfigurera/verifiera lokal endpoint-logging manuellt
./scripts/configure-logging.sh
./scripts/verify-logging.sh

# Konfigurera Kali GUI/tooling manuellt
./scripts/configure-kali.sh

# Förbättra muspekaren i virt-manager/virt-viewer på befintliga VMer
./scripts/configure-vm-console.sh

# SIEM-/agentintegrationer
./scripts/setup-splunk.sh --yes
./scripts/splunk/test-flow.sh

# Lista/builda Windows golden images manuellt
./scripts/build-image.sh --list
./scripts/build-image.sh win-srv
./scripts/build-image.sh win-ep1

# Terraform/OpenTofu direkt
cd terraform
tofu plan
tofu apply
tofu output -raw windows_admin_password
```

## Säkerhet

Det här labbet är avsett för defensivt säkerhetsarbete.

- `scripts/lab-mode.sh detonation --yes` styr victim-DNS mot INetSim, stänger
  `lab-mgmt`, lämnar `lab-wan` uppe för Kali och lämnar `lab-detonation` uppe.
- Verifierad dev-baseline med Splunk och forwarders heter `clean-dev-splunk`.
  Återställ med `./scripts/lab-snapshot.sh restore clean-dev-splunk --yes`.
- Terraform-state innehåller hemligheter, inklusive Windows-admin-lösenord.
  Committa aldrig statefiler.
- Använd OpenTofu och scripts som källa till sanning. Manuella ändringar i
  libvirt/Cockpit/virt-manager kan skapa drift.

## Repo-struktur

```text
lab-env/
├── bootstrap.sh                  Host-bootstrap
├── lab-images.json               Linux cloud-image-katalog
├── README.md                     Kort översikt
├── PLAN.md                       Minimal plan framåt
├── docs/
│   ├── SETUP_AND_USAGE.md        Praktisk setup- och användarguide
│   └── TOOLING_RECOMMENDATIONS.md Rekommenderade labbverktyg
├── packer/                       Windows golden image-byggen
├── integrations/                 SIEM-/agentprofiler
├── scripts/                      Entry points och hjälpscript
│   └── splunk/                   Splunk-specifika helpers
├── terraform/                    OpenTofu-konfiguration
├── cloud-init/                   Linux cloud-init-mallar
├── autounattend/                 Äldre/direct ISO Windows-mall
├── images/                       Lokala base images, git-ignorerad
└── iso/                          Windows/virtio ISOer, git-ignorerad
```

## Status

- [x] Host-bootstrap
- [x] En entrypoint för ny clone: `scripts/setup-lab.sh --yes`
- [x] Linux-VMer
- [x] Windows golden images via Packer
- [x] Terraform-kloning från Windows golden images
- [x] Active Directory bring-up (`corp.local`)
- [x] Grundläggande `lab-mode` för dev/detonation
- [x] Snapshot/restore-flöde för hela labbet
- [x] INetSim-konfiguration på `inetsim`
- [x] Kali på separat `lab-wan`
- [x] Verifierad detonations-runbook
- [x] Lokal logging-baseline på Windows och Linux
- [x] Integrationsramverk för SIEM-/agentprofiler
- [x] Första Splunk end-to-end-flödet

## Licens

Det här repot är licensierat under [MIT License](LICENSE).

Licensen gäller labbets egen kod, scripts, Terraform/Packer-konfiguration och
dokumentation. Den gäller inte Windows-ISOer, Microsoft Sysinternals/Sysmon,
VirtIO-drivers eller andra externa komponenter som laddas ner separat och
distribueras under sina respektive licenser.
