#!/usr/bin/env bash

set -euo pipefail

ROOT="/opt/lab-env/telemetry"
AUDIT_RULES="$ROOT/audit.rules"
MARKER="$ROOT/linux-logging.json"

log() { printf '[logging] %s\n' "$*"; }

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins rsyslog
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y audit audit-libs rsyslog
    elif command -v yum >/dev/null 2>&1; then
        yum install -y audit audit-libs rsyslog
    else
        log "No supported package manager found; assuming auditd/rsyslog are already present."
    fi
}

configure_journald() {
    install -d -m 0755 /var/log/journal
    install -d -m 0755 /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-lab-env-telemetry.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=512M
RuntimeMaxUse=128M
MaxRetentionSec=30day
ForwardToSyslog=yes
EOF
    systemctl restart systemd-journald
}

configure_auditd() {
    install -d -m 0755 /etc/audit/rules.d
    awk '
        /^-w / {
            path=$2
            if (system("[ -e \"" path "\" ]") != 0) {
                next
            }
        }
        { print }
    ' "$AUDIT_RULES" > /etc/audit/rules.d/99-lab-env.rules
    chmod 0640 /etc/audit/rules.d/99-lab-env.rules

    if command -v augenrules >/dev/null 2>&1; then
        augenrules --load || true
    elif command -v auditctl >/dev/null 2>&1; then
        auditctl -R /etc/audit/rules.d/99-lab-env.rules || true
    fi

    systemctl enable --now auditd >/dev/null 2>&1 || service auditd start
}

configure_rsyslog() {
    systemctl enable --now rsyslog >/dev/null 2>&1 || service rsyslog start || true
}

write_marker() {
    local audit_status journald_storage rsyslog_status
    audit_status="$(systemctl is-active auditd 2>/dev/null || true)"
    journald_storage="$(journalctl --disk-usage 2>/dev/null | sed 's/"/\\"/g' || true)"
    rsyslog_status="$(systemctl is-active rsyslog 2>/dev/null || true)"

    cat > "$MARKER" <<EOF
{
  "configured_at": "$(date -Is)",
  "hostname": "$(hostname)",
  "auditd": "$audit_status",
  "rsyslog": "$rsyslog_status",
  "journald": "$journald_storage",
  "audit_rules": "/etc/audit/rules.d/99-lab-env.rules"
}
EOF
    cat "$MARKER"
}

install -d -m 0755 "$ROOT"

log "Installing local logging packages"
install_packages

log "Configuring persistent journald"
configure_journald

log "Configuring auditd"
configure_auditd

log "Configuring local syslog"
configure_rsyslog

write_marker
