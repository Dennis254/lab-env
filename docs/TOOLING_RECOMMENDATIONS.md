# Tooling Recommendations

This lab should keep core images reasonably small, then install optional tool
packs explicitly per scenario or baseline.

## Windows

Recommended baseline additions:

- Sysinternals Suite: useful for investigation and scenario generation.
  Sysmon is already handled separately by the logging baseline, but the full
  suite adds tools such as Procmon, Autoruns, Sigcheck, Handle, PsTools and
  TCPView.
- Velociraptor client or osquery: useful later for endpoint query and triage.
- PowerShell 7: useful for repeatable cross-version scripts, but keep Windows
  PowerShell logging enabled because many attacker tradecraft tests still use
  it.
- Microsoft Defender defaults: keep enabled unless a scenario explicitly needs
  it changed.

Do not install offensive tooling on Windows endpoints by default. Keep those on
Kali or in scenario-specific staging.

## Linux

Recommended baseline additions:

- auditd and rsyslog: already configured by `configure-logging.sh`.
- osquery or Velociraptor client: useful for endpoint state queries.
- sysstat, lsof, strace, tcpdump: useful investigation tools.
- yara: useful for file-scanning scenarios.

## Network and Malware-Lab Utilities

Recommended optional additions:

- Zeek or Suricata on a future sensor/collector VM.
- Arkime for packet indexing if disk budget allows it.
- MISP or OpenCTI only if threat-intel workflow becomes part of the lab.
- Caldera, Atomic Red Team or Prelude Operator for controlled adversary
  emulation. Keep real malware separate from benign validation tests.

## SIEM Profiles

Recommended order:

1. Splunk: first public SIEM profile.
2. Wazuh: good public open-source comparison because it is agent-centered.
3. Custom/private: consume the same agent-profile contract without committing
   private server, agent, token or tenant details.

## Default Rule

If a tool changes endpoint behavior significantly, install it through an
explicit profile or scenario instead of baking it silently into every baseline.
