#!/usr/bin/env bash
#
# bootstrap.sh — Aegis Detection Lab bootstrap
# ---------------------------------------------------------------------------
# Förbereder en Linux-värd för Aegis detection-labbet:
#   * skapar katalogstruktur
#   * installerar nödvändiga värdverktyg
#   * laddar ner och verifierar cloud-images definierade i lab-images.json
#   * hämtar build-verktyg som Packer
#
# Cloud-images styrs helt av lab-images.json — lägg till ett nytt objekt
# där så hämtar scriptet det automatiskt vid nästa körning. Redan
# nedladdade images hoppas över (idempotent).
#
# Skapar INTE nätverk eller VMs — det hanteras av Terraform/OpenTofu.
# För en hel ny-clone-körning, använd scripts/setup-lab.sh som anropar
# bootstrap, Windows image-bygge och tofu init/apply i rätt ordning.
#
# Användning:
#   ./bootstrap.sh              # kör alla steg
#   ./bootstrap.sh --no-deps    # hoppa över paketinstallation
#   ./bootstrap.sh --no-images  # hoppa över nedladdning av cloud-images
#   ./bootstrap.sh --no-tools   # hoppa över nedladdning av build-verktyg (packer)
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Konfiguration ---------------------------------------------------------

# Labbets rotkatalog = katalogen där detta script ligger. Gör hela labbet
# portabelt: kopiera mappen till valfri Linux-värd och scriptet fungerar.
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$LAB_ROOT/lab-images.json"

INSTALL_DEPS=true
DOWNLOAD_IMAGES=true
DOWNLOAD_TOOLS=true
ASSUME_YES=false

for arg in "$@"; do
    case "$arg" in
        --no-deps)   INSTALL_DEPS=false ;;
        --no-images) DOWNLOAD_IMAGES=false ;;
        --no-tools)  DOWNLOAD_TOOLS=false ;;
        -y|--yes)    ASSUME_YES=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 22
            exit 0
            ;;
        *) echo "Okänt argument: $arg" >&2; exit 1 ;;
    esac
done

# --- Utskriftshjälpare -----------------------------------------------------

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'

info()  { printf '%s==>%s %s\n'  "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n'  "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n'  "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n'  "$c_red"    "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

systemd_unit_exists() {
    local unit="$1"
    command -v systemctl &>/dev/null || return 1
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .
}

ensure_libvirt_running() {
    command -v systemctl &>/dev/null || {
        warn "systemctl saknas — kan inte starta libvirt automatiskt."
        return 0
    }

    info "Säkerställer att libvirt-systemtjänster kör"
    if systemd_unit_exists libvirtd.service; then
        sudo systemctl enable --now libvirtd.service
        ok "libvirtd.service kör"
    else
        local units=()
        local unit
        for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket virtlogd.socket virtlockd.socket; do
            if systemd_unit_exists "$unit"; then
                units+=("$unit")
            fi
        done
        if [[ ${#units[@]} -gt 0 ]]; then
            sudo systemctl enable --now "${units[@]}"
            ok "libvirt modulara sockets kör: ${units[*]}"
        else
            warn "Hittar varken libvirtd.service eller modulara libvirt-sockets."
        fi
    fi

    if virsh --connect qemu:///system version >/dev/null 2>&1; then
        ok "libvirt qemu:///system svarar"
    elif sudo virsh --connect qemu:///system version >/dev/null 2>&1; then
        warn "libvirt svarar bara via sudo. Lägg användaren i rätt grupp eller kontrollera polkit innan tofu apply."
    else
        die "libvirt qemu:///system svarar inte. Kontrollera libvirt-installation och tjänster."
    fi
}

# --- Förkontroller ---------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "Detta script kräver Linux."
[[ $EUID -ne 0 ]] || die "Kör inte som root. Scriptet anropar sudo vid behov."

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
else
    die "Ingen stödd pakethanterare hittad (dnf/apt)."
fi
info "Pakethanterare: $PKG_MGR"
info "Labbrot: $LAB_ROOT"

# --- Bildnedladdningsfunktioner --------------------------------------------

# Verifierar en fils checksum.  $1=fil  $2=algoritm(sha256|sha512)  $3=förväntad
verify_checksum() {
    local file="$1" algo="$2" expected="$3" actual
    actual="$(${algo}sum "$file" 2>/dev/null | awk '{print $1}')"
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

# Hämtar förväntad checksum för en image ur dess checksum-fil.
# Skriver hashen till stdout, eller tom sträng om checksum ej är definierad.
# $1 = image-nyckel
fetch_expected_checksum() {
    local key="$1" url pattern
    url="$(jq -r ".images[\"$key\"].checksum.url // empty" "$CONFIG_FILE")"
    pattern="$(jq -r ".images[\"$key\"].checksum.pattern // empty" "$CONFIG_FILE")"
    [[ -z "$url" || -z "$pattern" ]] && return 0
    # Hashen kan ligga var som helst på raden. 64 hex-tecken = sha256,
    # 128 = sha512 — {64,} fångar båda.
    curl -fsSL "$url" 2>/dev/null \
        | grep -F "$pattern" | grep -oE '[0-9a-f]{64,}' | head -n1 || true
}

# Laddar ner en direkt qcow2-image.  $1=nyckel  $2=url  $3=destination
download_qcow2() {
    local key="$1" url="$2" dest="$3" algo expected
    algo="$(jq -r ".images[\"$key\"].checksum.algo // \"sha256\"" "$CONFIG_FILE")"
    expected="$(fetch_expected_checksum "$key")"

    info "Laddar ner $key ..."
    curl -fL --progress-bar -o "$dest.part" "$url"
    mv "$dest.part" "$dest"

    if [[ -n "$expected" ]]; then
        if verify_checksum "$dest" "$algo" "$expected"; then
            ok "$(basename "$dest") nedladdad och checksumverifierad ($algo)"
        else
            rm -f "$dest"
            die "$(basename "$dest"): CHECKSUM MISSMATCH — filen kasserad."
        fi
    else
        warn "$(basename "$dest") nedladdad (ingen checksum tillgänglig)"
    fi
}

# Laddar ner en tar.xz med raw-disk och konverterar till qcow2.
# $1=nyckel  $2=url  $3=destination
download_tarxz_raw() {
    local key="$1" url="$2" dest="$3" tmp_archive tmp_extract raw_file
    info "Laddar ner $key (tar.xz-arkiv) ..."
    tmp_archive="$(mktemp --suffix=.tar.xz)"
    if ! curl -fL --progress-bar -o "$tmp_archive" "$url"; then
        rm -f "$tmp_archive"
        err "Kunde inte ladda ner $key ($url)"
        warn "URL:en kan ha ändrats — uppdatera posten i lab-images.json."
        die "Avbryter."
    fi
    info "Extraherar och konverterar $key till qcow2 ..."
    tmp_extract="$(mktemp -d)"
    tar -xJf "$tmp_archive" -C "$tmp_extract"
    raw_file="$(find "$tmp_extract" -name '*.raw' -type f | head -n1)"
    if [[ -z "$raw_file" ]]; then
        rm -rf "$tmp_extract" "$tmp_archive"
        die "Hittade ingen .raw-disk i arkivet för $key — arkivstrukturen kan ha ändrats."
    fi
    qemu-img convert -f raw -O qcow2 "$raw_file" "$dest"
    rm -rf "$tmp_extract" "$tmp_archive"
    ok "$(basename "$dest") skapad från $key"
}

# --- Steg 1: Katalogstruktur ----------------------------------------------

info "Steg 1: Skapar katalogstruktur"

DIRS=(
    networks            # libvirt-nätverks-XML (referens)
    images              # nedladdade cloud-images (read-only base)
    disks               # VM-diskar (skapas av Terraform)
    cloud-init          # cloud-init user-data/meta-data per VM
    iso                 # Windows-ISOs + virtio-win
    scripts             # hjälpscript
    terraform           # infrastruktur-as-code
    snapshots           # exporterade snapshot-metadata (valfritt)
)

for d in "${DIRS[@]}"; do
    if [[ -d "$LAB_ROOT/$d" ]]; then
        ok "$d/ finns redan"
    else
        mkdir -p "$LAB_ROOT/$d"
        ok "$d/ skapad"
    fi
done

# --- Steg 2: Värdverktyg ---------------------------------------------------

if $INSTALL_DEPS; then
    info "Steg 2: Kontrollerar och installerar värdverktyg"

    # Kommandonamn för detektering. '|' = endera duger.
    declare -A NEEDED=(
        [qemu-img]="qemu-img"
        [qemu-system-x86_64]="qemu-system-x86_64"
        [virsh]="virsh"
        [virt-install]="virt-install"
        [genisoimage]="genisoimage|xorriso"
        [xorriso]="xorriso"
        [7z]="7z"
        [wimlib-imagex]="wimlib-imagex"
        [curl]="curl"
        [jq]="jq"
        [sha256sum]="sha256sum"
        [tar]="tar"
        [xz]="xz"
        # swtpm = vTPM 2.0-emulator för Windows-VMerna (Win 11-krav).
        # edk2/OVMF = UEFI + Secure Boot-firmware.
        [swtpm]="swtpm"
        # unzip + gpg används av scripts/fetch-packer.sh för att
        # extrahera och verifiera Packer-binären.
        [unzip]="unzip"
        [gpg]="gpg|gpg2"
    )

    missing=()
    for tool in "${!NEEDED[@]}"; do
        found=false
        IFS='|' read -ra alts <<< "${NEEDED[$tool]}"
        for alt in "${alts[@]}"; do
            if command -v "$alt" &>/dev/null; then found=true; break; fi
        done
        if $found; then ok "$tool finns"; else missing+=("$tool"); fi
    done

    if command -v systemctl &>/dev/null &&
       ! systemd_unit_exists libvirtd.service &&
       ! systemd_unit_exists virtqemud.socket; then
        missing+=("libvirt-daemon")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Saknade verktyg: ${missing[*]}"
        if [[ "$PKG_MGR" == "dnf" ]]; then
            PKGS=(
                @virtualization
                qemu-img
                qemu-system-x86-core
                libvirt
                libvirt-client
                libvirt-daemon-qemu
                virt-install
                genisoimage
                xorriso
                p7zip
                p7zip-plugins
                wimlib-utils
                curl
                jq
                coreutils
                tar
                xz
                swtpm
                swtpm-tools
                edk2-ovmf
                unzip
                gnupg2
            )
            info "Installerar via dnf: ${PKGS[*]}"
            sudo dnf install -y "${PKGS[@]}"
        else
            PKGS=(
                qemu-system-x86
                qemu-utils
                libvirt-daemon-system
                libvirt-clients
                virtinst
                genisoimage
                xorriso
                p7zip-full
                wimtools
                curl
                jq
                coreutils
                tar
                xz-utils
                swtpm
                swtpm-tools
                ovmf
                unzip
                gnupg
            )
            info "Installerar via apt: ${PKGS[*]}"
            sudo apt-get update && sudo apt-get install -y "${PKGS[@]}"
        fi
        ok "Värdverktyg installerade"
    fi

    command -v qemu-system-x86_64 &>/dev/null || \
        die "qemu-system-x86_64 saknas efter paketinstallation. På Fedora: sudo dnf install @virtualization qemu-system-x86-core"

    ensure_libvirt_running

    # OpenTofu (open source-fork av Terraform). Standalone-metoden undviker
    # packagecloud-repots SSL-inkompatibilitet med DNF5 (Fedora 41+).
    if command -v tofu &>/dev/null; then
        ok "OpenTofu finns ($(tofu version | head -n1))"
    elif command -v terraform &>/dev/null; then
        ok "Terraform finns ($(terraform version | head -n1))"
    else
        warn "Varken OpenTofu eller Terraform hittad."
        info "Installerar OpenTofu (standalone — undviker repo/SSL-problem)"
        curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-tofu.sh
        chmod +x /tmp/install-tofu.sh
        sudo /tmp/install-tofu.sh --install-method standalone
        rm -f /tmp/install-tofu.sh
        ok "OpenTofu installerad (/usr/local/bin/tofu)"
    fi
else
    info "Steg 2: Hoppar över paketinstallation (--no-deps)"
fi

# --- Steg 3: Cloud-images (styrt av lab-images.json) -----------------------

if $DOWNLOAD_IMAGES; then
    info "Steg 3: Laddar ner cloud-images enligt lab-images.json"

    [[ -f "$CONFIG_FILE" ]] || die "Hittar inte $CONFIG_FILE"
    command -v jq &>/dev/null || die "jq krävs för att läsa $CONFIG_FILE (kör utan --no-deps)."
    jq empty "$CONFIG_FILE" 2>/dev/null || die "$CONFIG_FILE är inte giltig JSON."

    mapfile -t image_keys < <(jq -r '.images | keys[]' "$CONFIG_FILE")
    [[ ${#image_keys[@]} -gt 0 ]] || warn "Inga images definierade i $CONFIG_FILE"

    for key in "${image_keys[@]}"; do
        filename="$(jq -r ".images[\"$key\"].filename" "$CONFIG_FILE")"
        format="$(jq -r ".images[\"$key\"].format"   "$CONFIG_FILE")"
        url="$(jq -r ".images[\"$key\"].url"          "$CONFIG_FILE")"
        dest="$LAB_ROOT/images/$filename"

        # Idempotens: befintliga images verifieras mot upstream-checksum när
        # sådan finns. Om checksummen har ändrats laddar vi ner på nytt.
        if [[ -f "$dest" ]]; then
            algo="$(jq -r ".images[\"$key\"].checksum.algo // \"sha256\"" "$CONFIG_FILE")"
            expected="$(fetch_expected_checksum "$key")"
            if [[ -n "$expected" ]]; then
                if verify_checksum "$dest" "$algo" "$expected"; then
                    ok "$filename finns redan och checksum stämmer — hoppar över"
                    continue
                fi
                warn "$filename finns men checksum stämmer inte längre — laddar ner på nytt"
                rm -f "$dest"
            else
                ok "$filename finns redan — hoppar över (ingen checksum definierad)"
                continue
            fi
        fi

        case "$format" in
            qcow2)      download_qcow2     "$key" "$url" "$dest" ;;
            tarxz-raw)  download_tarxz_raw "$key" "$url" "$dest" ;;
            *)          err "Okänt format '$format' för '$key' i lab-images.json — hoppar över" ;;
        esac
    done
else
    info "Steg 3: Hoppar över nedladdning av cloud-images (--no-images)"
fi

# --- Steg 4: SSH-nyckel ----------------------------------------------------
# Terraform förväntar sig en ed25519-nyckel; lägger annars in den i alla
# Linux-VMer för passwordless SSH. Saknas nyckeln kraschar 'tofu apply'
# innan något hinner skapas — så vi frågar användaren om vi får skapa en.

info "Steg 4: SSH-nyckel"

SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ -f "$SSH_KEY.pub" ]]; then
    ok "$SSH_KEY.pub finns"
else
    warn "Hittar inte $SSH_KEY.pub — Terraform kommer krascha utan den."
    if $ASSUME_YES; then
        reply="y"
    else
        read -r -p "  Skapa en ny ed25519-nyckel utan passphrase? [Y/n] " reply
        reply="${reply:-y}"
    fi
    case "$reply" in
        [Yy]*)
            mkdir -p "$(dirname "$SSH_KEY")"
            chmod 700 "$(dirname "$SSH_KEY")"
            ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "aegis-lab-$(hostname)"
            ok "SSH-nyckel skapad: $SSH_KEY"
            ;;
        *)
            warn "Hoppar över — skapa själv med: ssh-keygen -t ed25519 -f $SSH_KEY"
            ;;
    esac
fi

# --- Steg 5: Windows-media (manuellt) -------------------------------------

info "Steg 5: Windows-media"

warn "Windows-ISOs kan inte laddas ner automatiskt (Microsoft kräver formulär)."
warn "Ladda ner följande manuellt och placera i $LAB_ROOT/iso/:"
printf '       - Windows 11 Enterprise Eval ISO\n'
printf '       - Windows Server 2025 Eval ISO   (för AD/domänkontrollant)\n'
echo
printf '       Windows 11:           https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise\n'
printf '       Windows Server 2025:  https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025\n'
echo
printf '       Konvention: skapa stabila symlinks så scripts/templates inte\n'
printf '       behöver röras vid ISO-refresh:\n'
printf '         ln -sf <microsoft-original>.iso iso/windows-11-enterprise.iso\n'
printf '         ln -sf <microsoft-original>.iso iso/windows-server-2025.iso\n'
echo
printf '       Hash-verifiering är ditt ansvar — Microsoft Eval Center\n'
printf '       publicerar inga stabila sha256:or.\n'

# virtio-win KAN laddas ner automatiskt
if $DOWNLOAD_IMAGES && [[ ! -f "$LAB_ROOT/iso/virtio-win.iso" ]]; then
    info "Laddar ner virtio-win.iso automatiskt ..."
    curl -fL --progress-bar -o "$LAB_ROOT/iso/virtio-win.iso.part" \
        "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    mv "$LAB_ROOT/iso/virtio-win.iso.part" "$LAB_ROOT/iso/virtio-win.iso"
    ok "virtio-win.iso nedladdad"
elif [[ -f "$LAB_ROOT/iso/virtio-win.iso" ]]; then
    ok "virtio-win.iso finns redan"
fi

# --- Steg 6: Build-verktyg (Packer) ---------------------------------------
# Packer används för att bygga golden Windows-qcow2-images som Terraform
# sedan klonar. Hämtas med fullständig verifieringskedja:
# pinnad version → HashiCorp GPG-fingerprint → signaturkontroll → sha256.
# Se scripts/fetch-packer.sh för detaljer.

if $DOWNLOAD_TOOLS; then
    info "Steg 6: Build-verktyg (Packer)"
    if [[ -x "$LAB_ROOT/scripts/fetch-packer.sh" ]]; then
        "$LAB_ROOT/scripts/fetch-packer.sh"
    else
        warn "scripts/fetch-packer.sh saknas eller är ej körbar — hoppar över"
    fi
else
    info "Steg 6: Hoppar över build-verktyg (--no-tools)"
fi

# --- Sammanfattning --------------------------------------------------------

echo
info "Bootstrap klar."
echo
cat <<EOF
  Labbrot:        $LAB_ROOT
  Image-config:   $CONFIG_FILE
  Cloud-images:   $LAB_ROOT/images/
  Windows-media:  $LAB_ROOT/iso/    (lägg ISOs här manuellt)
  Build-verktyg:  $LAB_ROOT/tools/  (packer m.fl., hämtas av scripts/fetch-*.sh)
  Terraform-kod:  $LAB_ROOT/terraform/

  Lägga till en ny image:
    Lägg till ett objekt under "images" i lab-images.json och kör scriptet
    igen. Redan nedladdade images hoppas över automatiskt.

  Nästa steg:
    1. Lägg Windows 11- och Server 2025-ISOs i $LAB_ROOT/iso/
    2. Kör: $LAB_ROOT/scripts/setup-lab.sh --yes

  Verifiera värdberedskap för isolerat malware-arbete:
    - getenforce            (ska visa: Enforcing)
    - virt-host-validate    (QEMU-raderna ska vara PASS)
EOF
