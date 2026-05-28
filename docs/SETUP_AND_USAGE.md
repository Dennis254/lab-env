# Setup och användning

Den här guiden beskriver hur miljön sätts upp och hur de delar som finns
byggda hittills används.

## Målbild

`setup-lab.sh --yes` är den supportade entrypointen. Scriptet kör:

1. `bootstrap.sh`
2. Packer-bygge/verifiering av Windows golden images
3. `tofu init`
4. `tofu apply`
5. VM console-konfiguration
6. Kali GUI/tooling
7. INetSim-konfiguration på `inetsim`
8. Lokal endpoint-logging

Om något redan finns och matchar förväntade inputs ska det hoppas över.

För befintliga labb används `scripts/update-lab.sh --yes`. Det scriptet
applicerar repoändringar in-place på redan skapade VMer och kör inte Packer
eller `tofu apply`.

## Förutsättningar

Hosten ska vara en Linux-maskin med fungerande KVM/libvirt.

På Fedora Workstation/KDE bör detta vara installerat och startat:

```bash
sudo dnf install -y @virtualization qemu-system-x86-core libvirt libvirt-daemon-qemu virt-install
sudo systemctl enable --now libvirtd.service
```

På Fedora-versioner med modulariserad libvirt kan motsvarande tjänster vara
`virtqemud.socket`, `virtnetworkd.socket` och `virtstoraged.socket`.
`bootstrap.sh` försöker starta rätt variant automatiskt.

Kontrollera gärna innan första körningen:

```bash
command -v qemu-system-x86_64
virt-host-validate
virsh --connect qemu:///system pool-list --all
```

Krav i praktiken:

- KVM aktiverat i BIOS/UEFI.
- libvirt installerat och `default` storage pool aktiv.
- Användaren ska kunna köra libvirt mot `qemu:///system`.
- Tillräckligt diskutrymme för ISOer, Packer-output och qcow2-diskar.
- Windows 11 Enterprise Eval ISO och Windows Server 2025 Eval ISO.

Windows-ISOerna måste hämtas manuellt från Microsoft och läggas i `iso/`.
Skapa stabila symlinks så resten av repot slipper bry sig om Microsofts långa
filnamn:

```bash
mkdir -p iso
ln -sf <windows-11-enterprise-eval>.iso iso/windows-11-enterprise.iso
ln -sf <windows-server-2025-eval>.iso iso/windows-server-2025.iso
```

## Första installation

Kör från repots rot:

```bash
./scripts/setup-lab.sh --yes
```

Första körningen kan ta lång tid eftersom den kan:

- installera saknade hostpaket,
- ladda ner Linux cloud-images,
- hämta Packer,
- ladda ner `virtio-win.iso`,
- bygga `win-srv` och `win-ep1` via Packer,
- skapa nätverk, diskar och VMer via OpenTofu,
- förbättra VM-konsolernas muspekare med USB tablet-input,
- installera Kali XFCE och `kali-linux-default`,
- promovera `win-srv` till DC,
- skapa fiktiva AD-labbanvändare,
- ansluta `win-ep1` till domänen,
- installera och konfigurera INetSim på `10.30.0.13`,
- konfigurera lokal endpoint-logging på Windows och Linux.

En senare körning ska vara mycket snabbare och normalt sluta med:

```text
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

## Vad setup-scriptet gör

### Bootstrap

`bootstrap.sh` skapar kataloger, kontrollerar hostverktyg och laddar ner Linux
cloud-images enligt `lab-images.json`.

Viktiga lokala kataloger:

- `images/`: cloud-images och Windows golden images.
- `iso/`: Windows-ISOer och `virtio-win.iso`.
- `tools/`: repo-lokal Packer-binär.
- `terraform/`: OpenTofu-state och konfiguration.

### Windows golden images

Packer bygger två syspreppade qcow2-images:

```text
images/win-srv-base.qcow2
images/win-ep1-base.qcow2
```

Bygget använder SeaBIOS/MBR, q35, IDE-disk under installation och e1000-NIC
under Packer-fasen. VirtIO guest tools installeras innan sysprep så de klonade
VMerna kan hanteras via QEMU Guest Agent.

Packer-byggena är manifeststyrda. Om template, scripts, ISO, unattend eller
virtio-ISO ändras byggs imagen om. Om manifestet matchar skrivs:

```text
Golden image är up-to-date
```

## Uppdatera befintligt labb

När repot har uppdaterats från GitHub och labbet redan finns, kör:

```bash
./scripts/update-lab.sh --yes
```

Det kör in-place-steg för befintliga VMer:

- VM console/mus/video
- svensk tangentbordslayout
- Kali GUI/tooling
- INetSim-konfiguration
- lokal endpoint-logging
- Splunk server/forwarder-konfiguration

Om en VM eller ett steg inte är tillgängligt fortsätter `update-lab.sh` med
resten och summerar felen på slutet. Kör om scriptet när saknade VMer är
startade. Vill du hellre stoppa direkt vid första fel:

```bash
./scripts/update-lab.sh --yes --strict
```

Det gör medvetet inte:

- Packer rebuild av Windows golden images
- `tofu apply`
- VM/volym-replacement

Vill du bara se vad OpenTofu skulle ändra:

```bash
./scripts/update-lab.sh --yes --with-tofu-plan
```

Granska alltid planen innan du kör `tofu apply`, särskilt efter ändringar i
volymnamn, nätverk eller VM-resurser.

Build-lösenordet för Packer genereras lokalt i `packer/.build-admin-password`
och committas inte. Sätt `PACKER_BUILD_ADMIN_PASSWORD` om du vill styra värdet
explicit vid build.

### OpenTofu

OpenTofu skapar:

- `lab-mgmt` NAT-nätverk, `10.20.0.0/24`
- `lab-detonation` isolerat nätverk, `10.30.0.0/24`
- `lab-wan` NAT-nätverk, `10.40.0.0/24`, för Kalis externa sida
- Linux-VMer från cloud-images
- Windows-VMer som clones från Packer-images
- AD/DC och domain join via QEMU Guest Agent
- svensk tangentbordslayout på Linux- och Windows-VMer

### Kali

Kali byggs från Kali cloud-image men görs om till en grafisk attackmaskin med
`scripts/configure-kali.sh`. Scriptet installerar XFCE, LightDM och
`kali-linux-default`, installerar vanlig Kali-kärna för grafisk libvirt-konsol,
sätter systemd default target till `graphical.target` och skriver en
idempotensmarkör i `/opt/lab-env/kali/kali-profile.json`.

GUI-inloggning i Kali använder `dennis` / `Lab12345` som labbdefault.

Kali-disken är satt till 80 GiB. qcow2 är thin-provisionerat, så allt utrymme
tas inte på hosten direkt, men det ger tillräcklig marginal för Kali-paket,
apt-cache och uppdateringar.

### Tangentbord

Labbets default är svensk tangentbordslayout.

- Nya Linux-VMer får `locale: sv_SE.UTF-8`, `keyboard.layout: se` och
  `Europe/Stockholm` via cloud-init.
- Befintliga Linux-VMer uppdateras med `localectl set-keymap se` och
  `localectl set-x11-keymap se pc105`.
- Windows-VMer får svensk input method `041D:0000041D` via QEMU Guest Agent
  och Packer/sysprep-unattend.

Kör manuellt:

```bash
./scripts/configure-keyboard.sh
./scripts/configure-keyboard.sh --targets linux
./scripts/configure-keyboard.sh --targets win-ep1,kali
```

### INetSim

`scripts/configure-inetsim.sh` ansluter till `inetsim` via mgmt-IP
`10.20.0.13`, installerar Debian-paketet `inetsim` och konfigurerar tjänsten
att lyssna på detonations-IP:t `10.30.0.13`.

Nyckelinställningar:

```text
service_bind_address 10.30.0.13
dns_default_ip 10.30.0.13
dns_default_hostname www
dns_default_domainname detonation.lab
create_reports yes
```

Verifiera manuellt från `kali`:

```bash
ssh -F /dev/null dennis@10.40.0.20
dig @10.30.0.13 example.com +short
curl http://10.30.0.13/
```

För DNS-baserad fake internet-trafik måste klienten använda `10.30.0.13` som
DNS-server i detonationsläge. `scripts/lab-mode.sh detonation --yes` anropar
`scripts/lab-dns.sh detonation`, som styr DNS på victim-endpoints mot INetSim.
Kali och domain controllern är inte victim-endpoints och lämnas utanför den
DNS-växlingen.

## Daglig användning

### Se status

```bash
virsh --connect qemu:///system list --all
./scripts/lab-mode.sh status
cd terraform
tofu plan
```

`tofu plan` ska vara tomt när verkligheten matchar repo-konfigurationen.

### Starta och stoppa VMer

```bash
virsh --connect qemu:///system start win-srv
virsh --connect qemu:///system shutdown win-srv
virsh --connect qemu:///system start win-ep1
```

För grafisk konsol kan du använda `virt-manager`, `virt-viewer` eller valfritt
libvirt-kompatibelt verktyg. Gör helst inte permanenta konfigurationsändringar
där; ändra Terraform och kör `tofu apply` i stället.

Om muspekaren känns svårstyrd i VM-fönstret kan du lägga till USB tablet-input
på befintliga VMer utan att bygga om dem:

```bash
./scripts/configure-vm-console.sh
```

### Växla lab-mode

`scripts/lab-mode.sh` styr libvirt interface link-state för de VMer som är
kopplade till `lab-mgmt` och `lab-detonation`.

Status:

```bash
./scripts/lab-mode.sh status
```

Dev-läge:

```bash
./scripts/lab-mode.sh dev --yes
```

Det sätter både `lab-mgmt` och `lab-detonation` till `up`.

Detonation-läge:

```bash
./scripts/lab-mode.sh detonation --yes
```

Det sätter victim-endpoint DNS mot INetSim, sätter `lab-mgmt` till `down`,
lämnar Kalis `lab-wan` `up` och lämnar `lab-detonation` `up`. Scriptet
kontrollerar också att `lab-detonation` saknar libvirt `<forward>` innan
växlingen.

Rollfördelning:

- `linux-srv`, `linux-dev`, `win-ep1`: victim/observerade endpoints, får
  INetSim-DNS i detonationsläge.
- `inetsim`: fejk-internet, lyssnar på `10.30.0.13`.
- `win-srv`: AD/DC, behåller sin DNS-roll och får inte INetSim-DNS som default.
- `kali`: operator/attackmaskin på `lab-wan`, får inte INetSim-DNS automatiskt.

DC:n kan absolut vara en attackerad maskin i ett scenario. Den är ändå
exkluderad från default-DNS-växlingen eftersom den samtidigt är AD/DNS-kärna
för labbet. Om ett test ska detonera mot DC bör det göras som ett uttalat
scenario-läge där vi accepterar att AD/DNS kan påverkas.

Kali ligger inte längre på `lab-mgmt`; den har `lab-wan` + `lab-detonation`.
Det gör att den kan simulera en extern angripare bättre utan att vara en vanlig
managed endpoint i labbet.

Dry-run:

```bash
./scripts/lab-mode.sh detonation --dry-run --yes
```

Scriptet ändrar link-state i både live-domain och persistent config. Det gör
att en VM som startas efter växlingen får samma nätläge.

### Snapshot och restore

`scripts/lab-snapshot.sh` skapar en koordinerad snapshot över alla labb-VMer.
Scriptet använder libvirt domain snapshots och tar snapshots när VMerna är
avstängda. Det ger enklare restore-semantik än live snapshots.

Skapa en ren dev-baseline:

```bash
./scripts/configure-inetsim.sh
./scripts/configure-logging.sh
./scripts/verify-logging.sh
./scripts/setup-splunk.sh --yes
./scripts/lab-mode.sh dev --yes
./scripts/lab-snapshot.sh create clean-dev-splunk --yes
```

Lista snapshots:

```bash
./scripts/lab-snapshot.sh list
```

Återställ labbet:

```bash
./scripts/lab-snapshot.sh restore clean-dev-splunk --yes
```

Ta bort en snapshot:

```bash
./scripts/lab-snapshot.sh delete clean-dev-splunk --yes
```

### Lokal logging-baseline

`scripts/configure-logging.sh` konfigurerar lokal logging på endpoints utan
central forwarding.

Windows:

- Sysmon installeras och konfigureras. Scriptet försöker först använda inbyggd
  Windows-feature och faller tillbaka till Microsoft Sysinternals Sysmon om
  feature saknas.
- Sysmon skriver till `Microsoft-Windows-Sysmon/Operational`.
- PowerShell Script Block Logging, Module Logging och Transcription aktiveras.
- Audit policy förstärks för processer, logon/logoff, kontoändringar och
  relevanta systemhändelser.
- Eventloggar får större lokal retention.

Linux:

- `auditd` installeras/aktiveras.
- `journald` görs persistent i `/var/log/journal`.
- `rsyslog` aktiveras lokalt.
- Audit-regler läggs i `/etc/audit/rules.d/99-lab-env.rules`.

Kör manuellt:

```bash
./scripts/configure-logging.sh
./scripts/verify-logging.sh
```

Verifieringen skapar testevents och kontrollerar lokalt att:

- Linux har `auditd`, `rsyslog`, persistent journal och audit-regler.
- Windows har Sysmon service, Sysmon process-event och PowerShell Operational
  events.

Efter verifierad lokal logging, före SIEM-integration, kan en logging-only
baseline tas:

```bash
./scripts/lab-snapshot.sh create clean-dev-logging --yes
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
```

### SIEM- och agentintegrationer

Integrationsramverket är profilbaserat. De publika entrypoints är:

```bash
./scripts/install-siem.sh --profile custom
./scripts/configure-agents.sh --profile custom --targets all
./scripts/verify-agents.sh --profile custom --targets all
./scripts/remove-agents.sh --profile custom --targets all
```

Snabbalias stöds också:

```bash
./scripts/configure-agents.sh -Custom
./scripts/configure-agents.sh -Wazuh --targets windows
./scripts/configure-agents.sh -Splunk --targets linux --dry-run
```

Profiler ligger i `integrations/`:

- `custom`: generisk privat SIEM-/agent-hook via lokal config.
- `wazuh`: publik profilplats, ännu inte implementerad.
- `splunk`: labbprofil för Splunk Enterprise på `splunk`-VM:n och Universal
  Forwarder på Linux/Windows endpoints.

För `custom`, skapa lokal config:

```bash
cp integrations/custom/config.env.example integrations/custom/config.env
```

`config.env` ignoreras av git. Lägg privata URLer, tokens, install-kommandon,
agent-builds och tenantvärden utanför det publika repot. Initialt bör agenten
köras i ett passivt läge, t.ex. `CUSTOM_AGENT_MODE=observe`.

Targets kan vara:

```text
all, linux, windows, win-ep1, win-srv, linux-srv, linux-dev, kali
```

Flera namngivna targets anges kommaseparerat:

```bash
./scripts/configure-agents.sh --profile custom --targets win-ep1,linux-srv
```

Det här ramverket installeras inte automatiskt av `setup-lab.sh`. Det är
avsiktligt: SIEM-/agenttester ska kunna väljas per profil utan att blanda
privata komponenter i standardbygget.

#### Splunk-profil

Splunk-profilen checkar inte in Splunk-binära filer. Hämta Splunk Enterprise
och Universal Forwarder från Splunk och peka `config.env` på lokala filer.
Splunk Enterprise installeras på labb-VM:n `splunk`:

```text
mgmt: 10.20.0.30
deto: 10.30.0.30
web:  http://10.20.0.30:8000
ingest: 10.30.0.30:9997
```

```bash
cp integrations/splunk/config.env.example integrations/splunk/config.env
```

Minsta praktiska värden:

```bash
SPLUNK_PACKAGE="/path/to/splunk-linux-x86_64.tgz"
SPLUNK_ADMIN_PASSWORD="change-me"
SPLUNK_UF_LINUX_PACKAGE="/path/to/splunkforwarder-linux-x86_64.tgz"
SPLUNK_UF_ADMIN_USER="admin"
SPLUNK_UF_PASSWORD="change-me-too"
SPLUNK_UF_WINDOWS_PACKAGE="/path/to/splunkforwarder-x64.msi"
```

Kör sedan:

```bash
./scripts/setup-splunk.sh --yes
```

Det kör idempotent serverinstall, agentkonfiguration, verifiering och
end-to-end-test. För mer kontrollerad körning kan stegen köras separat:

```bash
./scripts/install-siem.sh --profile splunk
./scripts/configure-agents.sh --profile splunk --targets all
./scripts/verify-agents.sh --profile splunk --targets all
./scripts/splunk/test-flow.sh
```

Profilen skapar Splunk-index för `endpoint`, `wineventlog`, `sysmon` och
`linux`, aktiverar receiver på port `9997` och konfigurerar forwarding från
Linux audit/auth/syslog samt Windows Security/System/Application/Sysmon och
PowerShell-eventloggar. Windows-MSI:n kopieras till `splunk`-VM:n och serveras
därifrån under dev-läge.

Splunk-profilen sätter explicita sourcetypes vid ingestion, till exempel
`linux:audit`, `linux:auth`, `XmlWinEventLog:Security` och
`XmlWinEventLog:Microsoft-Windows-Sysmon/Operational`. Serverprofilen skapar
även appen `lab_env_normalization` med grundläggande `props.conf`,
`eventtypes.conf` och `tags.conf`.

Det är en första normaliseringsnivå. Nästa nivå bör vara att lägga Splunk
Common Information Model och relevanta Technology Add-ons ovanpå:

- Splunk Common Information Model app för datamodeller.
- Splunk Add-on for Microsoft Windows för Windows Event Log-normalisering.
- Splunk Add-on for Unix and Linux för Linux auth/syslog.
- Sysmon-specifik TA om vi vill mappa Sysmon mot Endpoint/Process-modellen.

`scripts/splunk/test-flow.sh` skapar ofarliga testevents på Linux, Kali och
Windows, och verifierar via Splunks API att de landar i `linux`, `wineventlog`
eller `sysmon`. Verifieringen använder indexeringstid, eftersom Windows-eventens
eventtid kan avvika från labbhostens UTC-tid.

### Detonations-runbook

Verifierad baseline:

```bash
./scripts/lab-snapshot.sh list
./scripts/lab-snapshot.sh restore clean-dev-splunk --yes
./scripts/lab-mode.sh dev --yes
```

Starta detonationsläge:

```bash
./scripts/lab-mode.sh detonation --yes
./scripts/lab-mode.sh status
```

Förväntat nätläge:

- `lab-mgmt` är `down` på `inetsim`, `linux-srv`, `linux-dev`, `win-ep1` och
  `win-srv`.
- `lab-wan` är `up` på `kali`.
- `lab-detonation` är `up` på alla labb-VMer.

Verifiera INetSim från Kali:

```bash
ssh -F /dev/null dennis@10.40.0.20
dig @10.30.0.13 example.com +short
curl http://10.30.0.13/
```

Förväntat:

- DNS-svaret är `10.30.0.13`.
- HTTP-svaret visar INetSim default-sida.

Verifiera Linux-victims via detonationsnätet:

```bash
ssh -F /dev/null dennis@10.30.0.11 'getent hosts example.com; curl --connect-timeout 4 http://1.1.1.1/ || true'
ssh -F /dev/null dennis@10.30.0.12 'getent hosts example.com; curl --connect-timeout 4 http://1.1.1.1/ || true'
```

Förväntat:

- `example.com` slår upp till `10.30.0.13`.
- HTTP mot `http://example.com/` hamnar på INetSim.
- Direkt HTTP mot `1.1.1.1` misslyckas.

Verifierad Windows-DNS:

- `win-ep1` får `10.30.0.13` på deto-NIC och behåller `10.20.0.10` på
  mgmt-NIC.
- `win-srv` får inte INetSim-DNS i default-läget och behåller sin DC/DNS-roll.

Avsluta och återgå till dev:

```bash
./scripts/lab-mode.sh dev --yes
cd terraform
tofu plan
```

`tofu plan` ska sluta med `No changes`.

Restore stoppar körande VMer hårt, återställer snapshoten och startar de VMer
som var igång när snapshoten skapades. Det är avsiktligt: efter en detonation
ska vi inte försöka göra en ordnad shutdown inifrån ett potentiellt påverkat
guest-OS.

Manifest sparas lokalt i `snapshots/<name>.json`, men git-ignoreras eftersom
själva snapshots ligger i hostens libvirt/qcow2-volymer och inte är portabla.

### Hämta Windows-lösenord

```bash
cd terraform
tofu output -raw windows_admin_password
```

Lösenordet genereras vid första `tofu apply` och ligger i Terraform-state.
Standardvärdet i labbet är `Lab12345`, för att det ska gå att skriva manuellt
i VM-konsolen utan att slåss med specialtecken eller tangentbordslayout.

Windows-inloggningar:

- Lokal admin på VMer: `.\Administrator`
- Domänadmin efter DC-promotion: `CORP\Administrator`
- Domän: `corp.local`
- Fiktiva domänanvändare: `anna.lind`, `erik.svensson`, `maria.holm`,
  `johan.ek`

De fiktiva användarna får samma initiala lösenord som
`windows_admin_password`, om du inte ändrar `var.ad_lab_users` och seed-scriptet.

### Kontrollera Windows/AD

Snabba nätverkskontroller från host:

```bash
curl -i http://10.20.0.10:5985/wsman
curl -i http://10.20.0.21:5985/wsman
```

HTTP `405` är normalt här; det visar att WinRM svarar men inte accepterar en
vanlig HTTP GET.

QEMU Guest Agent används av Terraform-script för Windows post-clone-steg. Om
du felsöker manuellt:

```bash
virsh --connect qemu:///system qemu-agent-command win-ep1 '{"execute":"guest-ping"}'
```

## Bygga om delar

### Kör hela flödet igen

```bash
./scripts/setup-lab.sh --yes
```

Det är säkert att köra om. Redan aktuella filer och resurser ska hoppas över.

### Visa plan utan apply

```bash
./scripts/setup-lab.sh --yes --plan-only
```

### Linux-only på ny host

```bash
./scripts/setup-lab.sh --yes --no-windows
```

Det här är tänkt för en ny host där du saknar Windows-media. Om Windows redan
finns i Terraform-state stoppar scriptet i stället för att råka planera bort
Windows-resurserna.

### Bygg Windows-image manuellt

```bash
./scripts/build-image.sh --list
./scripts/build-image.sh win-srv
./scripts/build-image.sh win-ep1
```

Tvinga rebuild:

```bash
./scripts/build-image.sh win-ep1 --force
```

Debug-läge:

```bash
./scripts/build-image.sh win-ep1 --debug
```

Debug-läge sätter `headless=false` och kräver att QEMU kan starta en lokal
display. Headless-läget är det stabila standardläget.

## Säkerhetsmodell

Det finns tre nät:

- `lab-mgmt`: NAT, används för provisionering och administration.
- `lab-detonation`: isolerat, ingen forward/routing ut från libvirt-nätet.
- `lab-wan`: NAT, används av Kali som extern angriparsida.

Grundläggande växling mellan dev-läge och detonationsläge finns i
`scripts/lab-mode.sh`, och restore till en ren baseline finns i
`scripts/lab-snapshot.sh`. Det verifierade återställningsläget heter
`clean-dev-splunk`.

Rekommenderat manuellt flöde när de återstående delarna är klara:

```bash
./scripts/lab-snapshot.sh restore clean-dev-splunk --yes
./scripts/lab-mode.sh detonation --yes
# verifiera enligt Detonations-runbook
# kör test/detonation
./scripts/lab-snapshot.sh restore clean-dev-splunk --yes
./scripts/lab-mode.sh dev --yes
```

## Cockpit

[Cockpit](https://cockpit-project.org/) kan vara värt att använda som ett
valfritt webbgränssnitt på hosten. Projektet beskriver Cockpit som en
webbaserad serverkonsol som använder systemets befintliga APIer och verktyg.
Med tillägget
[cockpit-machines](https://cockpit-project.org/guide/195/feature-virtualmachines.html)
kan det hantera VMer via QEMU/libvirt.

Det passar bra för:

- överblick över CPU, minne, disk och journal,
- start/stopp av VMer,
- snabb terminal i webbläsaren,
- enkel kontroll av libvirt-VMer via `cockpit-machines`.

Det bör däremot inte ersätta `setup-lab.sh`, Packer eller OpenTofu. I det här
repot ska Terraform/OpenTofu vara källan till sanning. Om du ändrar VM-diskar,
nätverk eller devices direkt i Cockpit kan du skapa drift som nästa
`tofu plan` behöver rätta.

Rekommenderad hållning:

- Installera Cockpit manuellt eller via ett framtida opt-in-script.
- Använd det för status, loggar, terminal och tillfällig start/stopp.
- Gör permanenta labbändringar i repo-filerna och kör `tofu apply`.
- Exponera inte port `9090` mot osäkra nät.

Fedora-exempel:

```bash
sudo dnf install cockpit cockpit-machines libvirt-dbus
sudo systemctl enable --now cockpit.socket
sudo firewall-cmd --add-service=cockpit
sudo firewall-cmd --add-service=cockpit --permanent
```

Öppna sedan:

```text
https://<host-ip>:9090
```

## Vanlig felsökning

### Packer säger att WinRM aldrig kommer upp

Kontrollera att Windows-installationen faktiskt startade och att VNC-porten i
Packer-outputen går att öppna. Vid tidigare felsökning var de viktigaste
orsakerna bootmedia, NIC/storage-drivers och Windows nätverksprofil.

Det är normalt att `Waiting for WinRM to become available...` står kvar länge
under första Windows-installationen. Räkna med ungefär 15-30 minuter på en
normal laptop/desktop innan WinRM svarar; Packer-timeouten är två timmar.

### Fedora saknar `qemu-system-x86_64`

Det betyder att QEMU-emulatorn inte är komplett installerad även om `qemu-img`
finns. Installera virtualiseringsgruppen eller kör `bootstrap.sh` igen:

```bash
sudo dnf install -y @virtualization qemu-system-x86-core
```

### OpenTofu kan inte ansluta till `/var/run/libvirt/libvirt-sock`

Det betyder att system-libvirt inte är installerad eller inte kör. Starta
libvirt och verifiera anslutningen:

```bash
sudo systemctl enable --now libvirtd.service
virsh --connect qemu:///system version
```

Om `libvirtd.service` saknas på Fedora, kontrollera de modulariserade
tjänsterna:

```bash
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket virtlockd.socket
```

### Packer-plugin startar inte i sandbox

Körningen behöver ibland ske utanför begränsad sandbox eftersom Packer/QEMU
och vissa provider-pluginer behöver hostresurser. Det normala hostkommandot är
fortfarande:

```bash
./scripts/setup-lab.sh --yes
```

### Windows får tom disklista i setup

Nuvarande Packer-spår undviker det genom IDE-disk under installation. De
klonade Terraform-VMerna bootar via SATA-override i
`terraform/xsl/windows-image-sata.xsl`.

### `tofu plan` vill ändra saker efter manuell ändring

Anta att OpenTofu har rätt. Flytta den manuella ändringen till Terraform eller
återställ den manuella ändringen innan nästa apply.

### Windows-admin-lösenord saknas

```bash
cd terraform
tofu output -raw windows_admin_password
```

Om state tas bort skapas ett nytt lösenord vid nästa apply.
