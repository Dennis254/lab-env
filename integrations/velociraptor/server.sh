#!/usr/bin/env bash
#
# Velociraptor server profile for the collector VM.

set -euo pipefail

ACTION="${1:-install}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${INTEGRATION_CONFIG:-$PROFILE_DIR/config.env}"

c_reset=$'\e[0m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

if [[ ! -f "$CONFIG_FILE" && -f "$PROFILE_DIR/config.env.example" ]]; then
    warn "Config saknas, använder example defaults"
    CONFIG_FILE="$PROFILE_DIR/config.env.example"
fi

[[ -f "$CONFIG_FILE" ]] || die "Saknar config: $CONFIG_FILE. Kopiera config.env.example till config.env."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

VELOCIRAPTOR_SERVER_HOST="${VELOCIRAPTOR_SERVER_HOST:-10.20.0.30}"
VELOCIRAPTOR_SERVER_SSH_USER="${VELOCIRAPTOR_SERVER_SSH_USER:-dennis}"
VELOCIRAPTOR_FRONTEND_HOST="${VELOCIRAPTOR_FRONTEND_HOST:-10.30.0.30}"
VELOCIRAPTOR_FRONTEND_PORT="${VELOCIRAPTOR_FRONTEND_PORT:-8001}"
VELOCIRAPTOR_GUI_HOST="${VELOCIRAPTOR_GUI_HOST:-10.30.0.30}"
VELOCIRAPTOR_GUI_PORT="${VELOCIRAPTOR_GUI_PORT:-8889}"
VELOCIRAPTOR_BIN="${VELOCIRAPTOR_BIN:-/usr/local/bin/velociraptor}"
VELOCIRAPTOR_CONFIG_DIR="${VELOCIRAPTOR_CONFIG_DIR:-/etc/velociraptor}"
VELOCIRAPTOR_DATASTORE="${VELOCIRAPTOR_DATASTORE:-/var/lib/velociraptor}"
VELOCIRAPTOR_INSTALLER_DIR="${VELOCIRAPTOR_INSTALLER_DIR:-/opt/lab-env/velociraptor}"
VELOCIRAPTOR_INSTALLER_HTTP_PORT="${VELOCIRAPTOR_INSTALLER_HTTP_PORT:-8082}"
VELOCIRAPTOR_RUN_USER="${VELOCIRAPTOR_RUN_USER:-velociraptor}"
VELOCIRAPTOR_VERSION="${VELOCIRAPTOR_VERSION:-latest}"
VELOCIRAPTOR_GUI_USER="${VELOCIRAPTOR_GUI_USER:-admin}"
VELOCIRAPTOR_GUI_PASSWORD="${VELOCIRAPTOR_GUI_PASSWORD:-}"

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

remote_sudo_script() {
    ssh "${SSH_OPTS[@]}" "${VELOCIRAPTOR_SERVER_SSH_USER}@${VELOCIRAPTOR_SERVER_HOST}" 'sudo bash -s'
}

shell_quote() {
    printf '%q' "$1"
}

install_server() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle installera Velociraptor på $VELOCIRAPTOR_SERVER_HOST, frontend $VELOCIRAPTOR_FRONTEND_HOST:$VELOCIRAPTOR_FRONTEND_PORT, GUI $VELOCIRAPTOR_GUI_PORT"
        return 0
    fi

    require_cmd ssh
    [[ -n "$VELOCIRAPTOR_GUI_PASSWORD" ]] || die "VELOCIRAPTOR_GUI_PASSWORD måste sättas i config.env"

    remote_sudo_script <<EOF
set -euo pipefail
SERVER_BIN=$(shell_quote "$VELOCIRAPTOR_BIN")
CONFIG_DIR=$(shell_quote "$VELOCIRAPTOR_CONFIG_DIR")
DATASTORE=$(shell_quote "$VELOCIRAPTOR_DATASTORE")
INSTALLER_DIR=$(shell_quote "$VELOCIRAPTOR_INSTALLER_DIR")
HTTP_PORT=$(shell_quote "$VELOCIRAPTOR_INSTALLER_HTTP_PORT")
RUN_USER=$(shell_quote "$VELOCIRAPTOR_RUN_USER")
VERSION=$(shell_quote "$VELOCIRAPTOR_VERSION")
FRONTEND_HOST=$(shell_quote "$VELOCIRAPTOR_FRONTEND_HOST")
FRONTEND_PORT=$(shell_quote "$VELOCIRAPTOR_FRONTEND_PORT")
GUI_HOST=$(shell_quote "$VELOCIRAPTOR_GUI_HOST")
GUI_PORT=$(shell_quote "$VELOCIRAPTOR_GUI_PORT")
GUI_USER=$(shell_quote "$VELOCIRAPTOR_GUI_USER")
GUI_PASSWORD=$(shell_quote "$VELOCIRAPTOR_GUI_PASSWORD")
SERVER_CONFIG="\$CONFIG_DIR/server.config.yaml"
CLIENT_CONFIG="\$INSTALLER_DIR/client.config.yaml"

install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ca-certificates curl jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl jq
    else
        echo "Hittar ingen känd pakethanterare för curl/jq" >&2
        exit 1
    fi
}

release_json() {
    local api
    if [[ "\$VERSION" == "latest" ]]; then
        api="https://api.github.com/repos/Velocidex/velociraptor/releases/latest"
    else
        api="https://api.github.com/repos/Velocidex/velociraptor/releases/tags/\$VERSION"
    fi
    curl -fsSL "\$api"
}

download_asset() {
    local release="\$1" pattern="\$2" dest="\$3" mode="\$4" url
    url="\$(jq -r --arg pattern "\$pattern" '.assets[] | select(.name | test(\$pattern)) | .browser_download_url' <<< "\$release" | head -n1)"
    if [[ -z "\$url" || "\$url" == "null" ]]; then
        echo "Hittar ingen Velociraptor asset som matchar: \$pattern" >&2
        exit 1
    fi
    if [[ ! -f "\$dest" || "\$(cat "\$dest.url" 2>/dev/null || true)" != "\$url" ]]; then
        curl -fL --retry 3 -o "\$dest.tmp" "\$url"
        mv "\$dest.tmp" "\$dest"
        printf '%s\n' "\$url" > "\$dest.url"
    fi
    chmod "\$mode" "\$dest"
}

install_deps
install -d -m 0755 "\$CONFIG_DIR" "\$INSTALLER_DIR"
install -d -m 0750 "\$DATASTORE"

release="\$(release_json)"
download_asset "\$release" 'linux-amd64$' "\$SERVER_BIN" 0755
download_asset "\$release" 'linux-amd64$' "\$INSTALLER_DIR/velociraptor-linux-amd64" 0755
download_asset "\$release" 'windows-amd64\\.exe$' "\$INSTALLER_DIR/velociraptor-windows-amd64.exe" 0644

if ! id -u "\$RUN_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "\$DATASTORE" --shell /usr/sbin/nologin "\$RUN_USER"
fi
chown -R "\$RUN_USER:\$RUN_USER" "\$DATASTORE"
chmod 0750 "\$DATASTORE"

merge="\$(jq -nc \
    --arg frontend_host "\$FRONTEND_HOST" \
    --argjson frontend_port "\$FRONTEND_PORT" \
    --arg gui_host "\$GUI_HOST" \
    --argjson gui_port "\$GUI_PORT" \
    --arg datastore "\$DATASTORE" \
    '{
      Frontend: {
        hostname: \$frontend_host,
        bind_address: "0.0.0.0",
        bind_port: \$frontend_port
      },
      GUI: {
        bind_address: "0.0.0.0",
        bind_port: \$gui_port,
        public_url: ("https://" + \$gui_host + ":" + (\$gui_port|tostring) + "/app/index.html")
      },
      Client: {
        server_urls: [("https://" + \$frontend_host + ":" + (\$frontend_port|tostring) + "/")]
      },
      Datastore: {
        location: \$datastore,
        filestore_directory: \$datastore
      }
    }')"
"\$SERVER_BIN" config generate --merge "\$merge" > "\$SERVER_CONFIG"
chmod 0640 "\$SERVER_CONFIG"

chown root:"\$RUN_USER" "\$SERVER_CONFIG"
runuser -u "\$RUN_USER" -- "\$SERVER_BIN" --config "\$SERVER_CONFIG" user add --role administrator "\$GUI_USER" "\$GUI_PASSWORD" >/dev/null
runuser -u "\$RUN_USER" -- "\$SERVER_BIN" --config "\$SERVER_CONFIG" config client > "\$CLIENT_CONFIG"
chmod 0644 "\$CLIENT_CONFIG"

cat > /etc/systemd/system/velociraptor-server.service <<UNIT
[Unit]
Description=Velociraptor server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=\$RUN_USER
Group=\$RUN_USER
WorkingDirectory=\$DATASTORE
ExecStart=\$SERVER_BIN --config \$SERVER_CONFIG frontend -v
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/lab-env-velociraptor-installers.service <<UNIT
[Unit]
Description=LabEnv Velociraptor installer HTTP server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=\$INSTALLER_DIR
ExecStart=/usr/bin/python3 -m http.server \$HTTP_PORT --bind 0.0.0.0
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now velociraptor-server.service
systemctl restart velociraptor-server.service
systemctl enable --now lab-env-velociraptor-installers.service
EOF
}

verify_server() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "Dry-run: skulle verifiera Velociraptor på $VELOCIRAPTOR_SERVER_HOST"
        return 0
    fi

    require_cmd ssh
    remote_sudo_script <<EOF
set -euo pipefail
SERVER_BIN=$(shell_quote "$VELOCIRAPTOR_BIN")
SERVER_CONFIG=$(shell_quote "$VELOCIRAPTOR_CONFIG_DIR/server.config.yaml")
INSTALLER_DIR=$(shell_quote "$VELOCIRAPTOR_INSTALLER_DIR")
GUI_PORT=$(shell_quote "$VELOCIRAPTOR_GUI_PORT")
FRONTEND_PORT=$(shell_quote "$VELOCIRAPTOR_FRONTEND_PORT")

test -x "\$SERVER_BIN"
test -s "\$SERVER_CONFIG"
test -s "\$INSTALLER_DIR/client.config.yaml"
test -x "\$INSTALLER_DIR/velociraptor-linux-amd64"
test -s "\$INSTALLER_DIR/velociraptor-windows-amd64.exe"
systemctl is-active --quiet velociraptor-server.service
systemctl is-active --quiet lab-env-velociraptor-installers.service
python3 - "\$GUI_PORT" "\$FRONTEND_PORT" <<'PY'
import socket
import sys

for port in sys.argv[1:]:
    with socket.create_connection(("127.0.0.1", int(port)), timeout=5):
        pass
PY
EOF
}

case "$ACTION" in
    install) install_server ;;
    verify)  verify_server ;;
    *) die "Okänd server-action: $ACTION" ;;
esac

ok "Velociraptor server action klar: $ACTION"
