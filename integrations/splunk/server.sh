#!/usr/bin/env bash
#
# Splunk Enterprise lab-VM setup.

set -euo pipefail

ACTION="${1:-install}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${INTEGRATION_CONFIG:-$PROFILE_DIR/config.env}"

c_reset=$'\e[0m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

if [[ "${DRY_RUN:-false}" == "true" && ! -f "$CONFIG_FILE" ]]; then
    warn "Dry-run: config saknas, använder example defaults"
    CONFIG_FILE="$PROFILE_DIR/config.env.example"
fi

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SPLUNK_SERVER_HOST="${SPLUNK_SERVER_HOST:-10.20.0.30}"
SPLUNK_SERVER_SSH_USER="${SPLUNK_SERVER_SSH_USER:-dennis}"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_PACKAGE="${SPLUNK_PACKAGE:-}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
SPLUNK_RECEIVER_PORT="${SPLUNK_RECEIVER_PORT:-9997}"
SPLUNK_ENABLE_BOOT_START="${SPLUNK_ENABLE_BOOT_START:-false}"
SPLUNK_RUN_USER="${SPLUNK_RUN_USER:-splunk}"
SPLUNK_INDEXES="${SPLUNK_INDEXES:-endpoint wineventlog sysmon linux}"
SPLUNK_UF_WINDOWS_PACKAGE="${SPLUNK_UF_WINDOWS_PACKAGE:-}"
SPLUNK_INSTALLER_DIR="${SPLUNK_INSTALLER_DIR:-/opt/aegis/installers}"
SPLUNK_INSTALLER_HTTP_PORT="${SPLUNK_INSTALLER_HTTP_PORT:-8081}"

SSH_OPTS=(
    -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
)

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Saknar kommando: $1"
}

remote() {
    ssh "${SSH_OPTS[@]}" "${SPLUNK_SERVER_SSH_USER}@${SPLUNK_SERVER_HOST}" "$@"
}

remote_sudo_script() {
    ssh "${SSH_OPTS[@]}" "${SPLUNK_SERVER_SSH_USER}@${SPLUNK_SERVER_HOST}" 'sudo bash -s'
}

copy_file() {
    local src="$1" dst="$2"
    scp "${SSH_OPTS[@]}" "$src" "${SPLUNK_SERVER_SSH_USER}@${SPLUNK_SERVER_HOST}:$dst"
}

shell_quote() {
    printf '%q' "$1"
}

install_splunk() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle installera/starta Splunk på $SPLUNK_SERVER_HOST och aktivera receiver $SPLUNK_RECEIVER_PORT"
        return 0
    fi

    require_cmd ssh
    require_cmd scp
    [[ -n "$SPLUNK_PACKAGE" ]] || die "SPLUNK_PACKAGE måste peka på lokal Splunk Enterprise .tgz/.deb/.rpm"
    [[ -f "$SPLUNK_PACKAGE" ]] || die "SPLUNK_PACKAGE finns inte: $SPLUNK_PACKAGE"
    [[ -n "$SPLUNK_ADMIN_PASSWORD" ]] || die "SPLUNK_ADMIN_PASSWORD måste sättas i config.env"

    local remote_pkg="/tmp/$(basename "$SPLUNK_PACKAGE")"
    copy_file "$SPLUNK_PACKAGE" "$remote_pkg"

    local windows_pkg_name=""
    if [[ -n "$SPLUNK_UF_WINDOWS_PACKAGE" ]]; then
        [[ -f "$SPLUNK_UF_WINDOWS_PACKAGE" ]] || die "SPLUNK_UF_WINDOWS_PACKAGE finns inte: $SPLUNK_UF_WINDOWS_PACKAGE"
        windows_pkg_name="$(basename "$SPLUNK_UF_WINDOWS_PACKAGE")"
        remote "sudo install -d -m 0755 $(shell_quote "$SPLUNK_INSTALLER_DIR")"
        copy_file "$SPLUNK_UF_WINDOWS_PACKAGE" "/tmp/$windows_pkg_name"
        remote "sudo mv $(shell_quote "/tmp/$windows_pkg_name") $(shell_quote "$SPLUNK_INSTALLER_DIR/$windows_pkg_name") && sudo chmod 0644 $(shell_quote "$SPLUNK_INSTALLER_DIR/$windows_pkg_name")"
    fi

    remote_sudo_script <<EOF
set -euo pipefail
SPLUNK_HOME=$(shell_quote "$SPLUNK_HOME")
REMOTE_PKG=$(shell_quote "$remote_pkg")
SPLUNK_ADMIN_USER=$(shell_quote "$SPLUNK_ADMIN_USER")
SPLUNK_ADMIN_PASSWORD=$(shell_quote "$SPLUNK_ADMIN_PASSWORD")
SPLUNK_RECEIVER_PORT=$(shell_quote "$SPLUNK_RECEIVER_PORT")
SPLUNK_ENABLE_BOOT_START=$(shell_quote "$SPLUNK_ENABLE_BOOT_START")
SPLUNK_RUN_USER=$(shell_quote "$SPLUNK_RUN_USER")
SPLUNK_INDEXES=$(shell_quote "$SPLUNK_INDEXES")
SPLUNK_INSTALLER_DIR=$(shell_quote "$SPLUNK_INSTALLER_DIR")
SPLUNK_INSTALLER_HTTP_PORT=$(shell_quote "$SPLUNK_INSTALLER_HTTP_PORT")

if [[ ! -x "\$SPLUNK_HOME/bin/splunk" ]]; then
    case "\$REMOTE_PKG" in
        *.tgz|*.tar.gz)
            mkdir -p "\$(dirname "\$SPLUNK_HOME")"
            tar -xzf "\$REMOTE_PKG" -C "\$(dirname "\$SPLUNK_HOME")"
            ;;
        *.deb)
            dpkg -i "\$REMOTE_PKG"
            ;;
        *.rpm)
            rpm -Uvh "\$REMOTE_PKG"
            ;;
        *)
            echo "Okänt Splunk package-format: \$REMOTE_PKG" >&2
            exit 1
            ;;
    esac
fi

test -x "\$SPLUNK_HOME/bin/splunk"
if ! id -u "\$SPLUNK_RUN_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "\$SPLUNK_HOME" --shell /bin/bash "\$SPLUNK_RUN_USER"
fi
chown -R "\$SPLUNK_RUN_USER:\$SPLUNK_RUN_USER" "\$SPLUNK_HOME"

splunk_as_user() {
    runuser -u "\$SPLUNK_RUN_USER" -- "\$SPLUNK_HOME/bin/splunk" "\$@"
}

splunk_as_user start --accept-license --answer-yes --no-prompt --seed-passwd "\$SPLUNK_ADMIN_PASSWORD"

if [[ "\$SPLUNK_ENABLE_BOOT_START" == "true" ]]; then
    "\$SPLUNK_HOME/bin/splunk" enable boot-start -user "\$SPLUNK_RUN_USER" --accept-license --answer-yes --no-prompt || true
fi

splunk_as_user enable listen "\$SPLUNK_RECEIVER_PORT" -auth "\$SPLUNK_ADMIN_USER:\$SPLUNK_ADMIN_PASSWORD" || true

for index in \$SPLUNK_INDEXES; do
    splunk_as_user add index "\$index" -auth "\$SPLUNK_ADMIN_USER:\$SPLUNK_ADMIN_PASSWORD" || true
done

if [[ -d "\$SPLUNK_INSTALLER_DIR" ]]; then
    cat > /etc/systemd/system/aegis-splunk-installers.service <<UNIT
[Unit]
Description=Aegis lab Splunk installer HTTP server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=\$SPLUNK_INSTALLER_DIR
ExecStart=/usr/bin/python3 -m http.server \$SPLUNK_INSTALLER_HTTP_PORT --bind 0.0.0.0
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now aegis-splunk-installers.service
fi

splunk_as_user restart
EOF
}

verify_splunk() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle verifiera Splunk på $SPLUNK_SERVER_HOST"
        return 0
    fi

    require_cmd ssh
    remote_sudo_script <<EOF
set -euo pipefail
SPLUNK_HOME=$(shell_quote "$SPLUNK_HOME")
SPLUNK_ADMIN_USER=$(shell_quote "$SPLUNK_ADMIN_USER")
SPLUNK_ADMIN_PASSWORD=$(shell_quote "$SPLUNK_ADMIN_PASSWORD")
SPLUNK_RUN_USER=$(shell_quote "$SPLUNK_RUN_USER")

test -x "\$SPLUNK_HOME/bin/splunk"
runuser -u "\$SPLUNK_RUN_USER" -- "\$SPLUNK_HOME/bin/splunk" status
if [[ -n "\$SPLUNK_ADMIN_PASSWORD" ]]; then
    runuser -u "\$SPLUNK_RUN_USER" -- "\$SPLUNK_HOME/bin/splunk" btool inputs list splunktcp --debug | grep -E "splunktcp://\$|disabled|connection_host|acceptFrom" || true
fi
systemctl is-active --quiet aegis-splunk-installers.service 2>/dev/null || true
EOF
}

case "$ACTION" in
    install) install_splunk ;;
    verify)  verify_splunk ;;
    *) die "Okänd server-action: $ACTION" ;;
esac

ok "Splunk server action klar: $ACTION"
