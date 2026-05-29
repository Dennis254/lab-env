# SIEM and Agent Integrations

Integrations are profile-based. Public profiles live here, while private
installers, tokens, certificates and tenant configuration stay in ignored local
files.

Common entrypoints:

```bash
./scripts/install-siem.sh --profile custom
./scripts/configure-agents.sh --profile custom --targets all
./scripts/verify-agents.sh --profile custom --targets all
./scripts/remove-agents.sh --profile custom --targets all
```

Profile aliases are also accepted for quick use:

```bash
./scripts/configure-agents.sh -Custom
./scripts/configure-agents.sh -Wazuh
./scripts/configure-agents.sh -Splunk
./scripts/configure-agents.sh -Velociraptor
```

## Profile Contract

Each profile may provide:

- `server.sh`: installs or verifies the SIEM/server side for the profile.
- `agent.sh`: installs, verifies or removes agents on lab targets.
- `config.env.example`: documented local settings.
- `README.md`: profile-specific usage and limitations.

Local runtime config should be copied to `integrations/<profile>/config.env`.
All `*.env` files are ignored by git.

## Initial Scope

- `custom`: generic private SIEM/agent hook via local env commands.
- `wazuh`: public profile placeholder.
- `splunk`: lab profile for Splunk Enterprise and Universal Forwarder.
- `velociraptor`: lab profile for Velociraptor server and clients.

The public repo must not contain private agent builds, license files, tokens,
certificates or tenant secrets.
