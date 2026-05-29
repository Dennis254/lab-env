# Splunk Integration

This profile installs/configures Splunk Enterprise on the `collector` lab VM and
Splunk Universal Forwarder on lab endpoints.

Splunk binaries are not committed to this repo. Download Splunk Enterprise and
Universal Forwarder from Splunk, then point `config.env` at the local files or
at a URL reachable from the lab VMs.

```bash
cp integrations/splunk/config.env.example integrations/splunk/config.env
```

Minimum useful settings:

```bash
SPLUNK_PACKAGE="/path/to/splunk-linux-x86_64.tgz"
SPLUNK_ADMIN_PASSWORD="change-me"
SPLUNK_UF_LINUX_PACKAGE="/path/to/splunkforwarder-linux-x86_64.tgz"
SPLUNK_UF_ADMIN_USER="admin"
SPLUNK_UF_PASSWORD="change-me-too"
SPLUNK_UF_WINDOWS_PACKAGE="/path/to/splunkforwarder-x64.msi"
```

Typical flow:

```bash
./scripts/setup-splunk.sh --yes
```

Manual flow:

```bash
./scripts/install-siem.sh --profile splunk
./scripts/configure-agents.sh --profile splunk --targets all
./scripts/verify-agents.sh --profile splunk --targets all
./scripts/splunk/test-flow.sh
```

`server.sh` copies the Windows Universal Forwarder MSI to the `collector` VM and
serves it from `http://10.20.0.30:8081/` for Windows endpoint installation.

The profile configures:

- Linux inputs for audit/auth/syslog/messages logs.
- Windows Event Log inputs for Security, System, Application, Sysmon and
  PowerShell logs.
- Explicit sourcetypes such as `linux:audit`, `linux:auth`,
  `XmlWinEventLog:Security` and
  `XmlWinEventLog:Microsoft-Windows-Sysmon/Operational`.
- A lightweight `lab_env_normalization` Splunk app with props, eventtypes and
  tags. Use Splunk CIM and Technology Add-ons for deeper normalization later.
- Forwarding to `SPLUNK_INDEXER_HOST:SPLUNK_RECEIVER_PORT`. The default is
  `10.30.0.30:9997` so forwarding continues in detonation mode.
- End-to-end verification through Splunk's local API with
  `scripts/splunk/test-flow.sh`.

The profile is intentionally lab-focused. It does not install Splunk Enterprise
Security, Splunk Add-on for Microsoft Windows, TLS, deployment apps or
production indexer clustering yet.
