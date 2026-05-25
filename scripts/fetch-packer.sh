#!/usr/bin/env bash
#
# fetch-packer.sh — säker nedladdning + verifiering av HashiCorp Packer
# ---------------------------------------------------------------------------
# Hämtar Packer från releases.hashicorp.com med fullständig
# verifieringskedja:
#
#   1. Hämtar zip, SHA256SUMS (manifest) och SHA256SUMS.sig (GPG-signatur)
#   2. Hämtar HashiCorps publika GPG-nyckel från well-known-URL
#   3. Verifierar nyckelns fingerprint mot pinnat värde nedan
#      (nyckeln importeras i ett tillfälligt GNUPGHOME — påverkar inte
#       användarens egna keyring)
#   4. GPG-verifierar SHA256SUMS-signaturen med den pinnade nyckeln
#   5. Verifierar zip-filens sha256 mot manifestet
#   6. Extraherar binären till tools/packer (repo-lokal, gitignored)
#
# Avbryter med exit-kod ≠0 om något steg failar. Lämnar aldrig en
# overifierad binär kvar.
#
# Idempotent: hoppar över om rätt version redan finns i tools/packer.
#
# Användning:
#   ./scripts/fetch-packer.sh             # hämta + verifiera + installera
#   ./scripts/fetch-packer.sh --force     # tvinga rebuild även om version stämmer
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Pinnad konfiguration --------------------------------------------------
#
# OBS: PACKER_VERSION och HASHICORP_GPG_FINGERPRINT är medvetet hårdkodade.
# Höjning sker som ett explicit code-change — aldrig automatisk "latest".
#
# Om HashiCorp roterar sin signing-nyckel kommer scriptet stoppa med
# tydligt felmeddelande. Verifiera nya fingerprintet på:
#   https://www.hashicorp.com/trust/security
# och uppdatera HASHICORP_GPG_FINGERPRINT nedan.

PACKER_VERSION="1.15.3"
PACKER_ARCH="linux_amd64"

# HashiCorps primära kod-signeringsnyckel.
# Format: 40 hex-tecken utan blanksteg (som gpg --with-colons returnerar).
# Källa: https://www.hashicorp.com/trust/security
HASHICORP_GPG_FINGERPRINT="C874011F0AB405110D02105534365D9472D7468F"
HASHICORP_GPG_KEY_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"

# --- Paths -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$LAB_ROOT/tools"
PACKER_BIN="$TOOLS_DIR/packer"

# --- Argumenthantering -----------------------------------------------------

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 25
            exit 0
            ;;
        *) echo "Okänt argument: $arg" >&2; exit 1 ;;
    esac
done

# --- Utskriftshjälpare (matchar bootstrap.sh) -----------------------------

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'

info()  { printf '%s==>%s %s\n'  "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n'  "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n'  "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n'  "$c_red"    "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

# --- Förkontroller ---------------------------------------------------------

for cmd in curl gpg sha256sum unzip mktemp; do
    command -v "$cmd" &>/dev/null || die "Saknar verktyg: $cmd (installeras av bootstrap.sh)"
done

# --- Idempotens-check ------------------------------------------------------

if [[ -x "$PACKER_BIN" ]] && ! $FORCE; then
    # Använder command substitution + parameter expansion istället för
    # pipe till `head` — `packer version` skriver mer data efter sin
    # versionrad och skulle annars få SIGPIPE under `set -o pipefail`.
    CURRENT_VERSION_OUT="$("$PACKER_BIN" version 2>/dev/null || true)"
    CURRENT_VERSION_LINE="${CURRENT_VERSION_OUT%%$'\n'*}"
    if [[ "$CURRENT_VERSION_LINE" == *"v${PACKER_VERSION}"* ]]; then
        ok "Packer ${PACKER_VERSION} finns redan i $PACKER_BIN"
        exit 0
    else
        warn "Packer finns men annan version än ${PACKER_VERSION} — bygger om"
    fi
fi

# --- Temp-katalog (rensas alltid) ------------------------------------------

WORK_DIR="$(mktemp -d -t packer-fetch-XXXXXX)"
GNUPGHOME_TEMP="$(mktemp -d -t lab-gpg-XXXXXX)"
chmod 700 "$GNUPGHOME_TEMP"
trap 'rm -rf "$WORK_DIR" "$GNUPGHOME_TEMP"' EXIT

# --- Hämta artefakter ------------------------------------------------------

BASE_URL="https://releases.hashicorp.com/packer/${PACKER_VERSION}"
ZIP_NAME="packer_${PACKER_VERSION}_${PACKER_ARCH}.zip"
SUMS_NAME="packer_${PACKER_VERSION}_SHA256SUMS"
SIG_NAME="packer_${PACKER_VERSION}_SHA256SUMS.sig"

info "Hämtar Packer ${PACKER_VERSION} från releases.hashicorp.com"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK_DIR/$ZIP_NAME"  "$BASE_URL/$ZIP_NAME"  || die "Kunde inte hämta $ZIP_NAME"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK_DIR/$SUMS_NAME" "$BASE_URL/$SUMS_NAME" || die "Kunde inte hämta $SUMS_NAME"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK_DIR/$SIG_NAME"  "$BASE_URL/$SIG_NAME"  || die "Kunde inte hämta $SIG_NAME"
ok "Artefakter hämtade"

# --- Hämta + verifiera GPG-nyckel ------------------------------------------

info "Hämtar HashiCorps GPG-nyckel från well-known-URL"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK_DIR/hashicorp.asc" "$HASHICORP_GPG_KEY_URL" \
    || die "Kunde inte hämta GPG-nyckel från $HASHICORP_GPG_KEY_URL"

export GNUPGHOME="$GNUPGHOME_TEMP"
gpg --quiet --batch --import "$WORK_DIR/hashicorp.asc" 2>/dev/null \
    || die "GPG kunde inte importera nyckeln"

# Plocka ut primärt fingerprint ur det isolerade keyringet
ACTUAL_FP="$(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"

if [[ "$ACTUAL_FP" != "$HASHICORP_GPG_FINGERPRINT" ]]; then
    err "GPG-FINGERPRINT STÄMMER INTE — avbryter."
    err "  Förväntat: $HASHICORP_GPG_FINGERPRINT"
    err "  Faktiskt:  ${ACTUAL_FP:-<inget>}"
    err ""
    err "Möjliga orsaker:"
    err "  1. HashiCorp har roterat sin signing-nyckel — verifiera på"
    err "     https://www.hashicorp.com/trust/security och uppdatera"
    err "     HASHICORP_GPG_FINGERPRINT i detta script."
    err "  2. Nedladdningen från well-known-URL har manipulerats."
    die "Installerar INTE en overifierad binär."
fi
ok "GPG-nyckel verifierad (fingerprint matchar pinnat värde)"

# --- Verifiera signatur ----------------------------------------------------

info "Verifierar signatur på SHA256SUMS"
gpg --quiet --batch --verify "$WORK_DIR/$SIG_NAME" "$WORK_DIR/$SUMS_NAME" 2>/dev/null \
    || die "GPG-signaturverifiering FAILADE — installerar inte."
ok "Signatur giltig"

# --- Verifiera zip-hash ----------------------------------------------------

info "Verifierar sha256 på $ZIP_NAME"
(cd "$WORK_DIR" && sha256sum --quiet --check --ignore-missing "$SUMS_NAME") \
    || die "sha256 stämmer inte — kasserar nedladdning."
ok "Hash verifierad"

# --- Extrahera ------------------------------------------------------------

mkdir -p "$TOOLS_DIR"
unzip -q -o "$WORK_DIR/$ZIP_NAME" -d "$TOOLS_DIR"
chmod +x "$PACKER_BIN"

if [[ ! -x "$PACKER_BIN" ]]; then
    die "Förväntad binär saknas efter extraktion: $PACKER_BIN"
fi

# Se kommentar vid idempotens-checken ovan om varför vi undviker `| head`.
INSTALLED_OUT="$("$PACKER_BIN" version 2>/dev/null || true)"
INSTALLED_VERSION="${INSTALLED_OUT%%$'\n'*}"
ok "Packer installerad: ${INSTALLED_VERSION:-(okänd version)} → $PACKER_BIN"
