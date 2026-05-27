# Custom SIEM Integration

This profile is for a private SIEM/agent stack that should not be committed to
the public lab repo.

Copy the example config and edit it locally:

```bash
cp integrations/custom/config.env.example integrations/custom/config.env
```

Then run:

```bash
./scripts/install-siem.sh --profile custom
./scripts/configure-agents.sh --profile custom --targets all
./scripts/verify-agents.sh --profile custom --targets all
```

The profile executes commands from `config.env`. For Linux targets, commands
are executed over SSH. For Windows targets, commands are executed through QEMU
Guest Agent as LocalSystem.

Keep initial agent mode conservative:

```bash
CUSTOM_AGENT_MODE=observe
```

More active response modes should be tested only after the benign telemetry
path is stable.
