# Wazuh Integration

This profile is reserved for a public Wazuh integration.

Planned contract:

```bash
./scripts/install-siem.sh --profile wazuh
./scripts/configure-agents.sh --profile wazuh --targets all
./scripts/verify-agents.sh --profile wazuh --targets all
```

The first implementation should install a lab-default Wazuh server or document
where a local installer/config must be provided, then enroll Linux and Windows
agents against that server.
