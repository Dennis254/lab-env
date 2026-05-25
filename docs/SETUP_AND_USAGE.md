# Setup och användning

Den här guiden beskriver hur miljön sätts upp och hur de delar som finns
byggda hittills används.

## Målbild

`setup-lab.sh --yes` är den supportade entrypointen. Scriptet kör:

1. `bootstrap.sh`
2. Packer-bygge/verifiering av Windows golden images
3. `tofu init`
4. `tofu apply`
5. INetSim-konfiguration på `inetsim`

Om något redan finns och matchar förväntade inputs ska det hoppas över.

## Förutsättningar

Hosten ska vara en Linux-maskin med fungerande KVM/libvirt.

Kontrollera gärna innan första körningen:

```bash
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
- promovera `win-srv` till DC,
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
./scripts/lab-mode.sh dev --yes
./scripts/lab-snapshot.sh create clean-dev-logging --yes
```

Lista snapshots:

```bash
./scripts/lab-snapshot.sh list
```

Återställ labbet:

```bash
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
```

Ta bort en snapshot:

```bash
./scripts/lab-snapshot.sh delete clean-dev-logging --yes
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
- Audit-regler läggs i `/etc/audit/rules.d/99-aegis.rules`.

Kör manuellt:

```bash
./scripts/configure-logging.sh
./scripts/verify-logging.sh
```

Verifieringen skapar testevents och kontrollerar lokalt att:

- Linux har `auditd`, `rsyslog`, persistent journal och audit-regler.
- Windows har Sysmon service, Sysmon process-event och PowerShell Operational
  events.

Efter verifierad logging är normal baseline:

```bash
./scripts/lab-snapshot.sh create clean-dev-logging --yes
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
```

### Detonations-runbook

Verifierad baseline:

```bash
./scripts/lab-snapshot.sh list
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
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

Windows-inloggningar:

- Lokal admin på VMer: `.\Administrator`
- Domänadmin efter DC-promotion: `CORP\Administrator`
- Domän: `corp.local`

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
`clean-dev-logging`.

Rekommenderat manuellt flöde när de återstående delarna är klara:

```bash
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
./scripts/lab-mode.sh detonation --yes
# verifiera enligt Detonations-runbook
# kör test/detonation
./scripts/lab-snapshot.sh restore clean-dev-logging --yes
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
