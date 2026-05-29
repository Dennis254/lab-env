# Velociraptor Integration

Velociraptor runs on the `collector` VM next to Splunk.

Default ports:

- Frontend for clients: `https://10.30.0.30:8001/`
- GUI: `https://10.30.0.30:8889/`
- Temporary installer/config HTTP: `http://10.30.0.30:8082/`

Quick setup:

```bash
cp integrations/velociraptor/config.env.example integrations/velociraptor/config.env
./scripts/setup-velociraptor.sh --yes
```

The profile downloads the latest Velociraptor release from the official GitHub
releases API on the collector VM. Pin `VELOCIRAPTOR_VERSION` in `config.env` if
you want reproducible builds.

Default lab GUI credentials are configured in `config.env.example` for
throwaway lab use only.
