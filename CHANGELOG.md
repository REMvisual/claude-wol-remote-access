# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-08-23

### Added
- Break-glass terminal now supports **proxy mode** (`MODE=proxy`, the new
  default): ttyd binds loopback with `--base-path` and is reverse-proxied
  through the panel behind its existing auth. No tailnet ACL grant is needed,
  there is one URL and one login, ttyd is unreachable from the network, and no
  ttyd credential exists at all -- removing the plaintext-in-argv weakness of
  standalone mode. Standalone mode is retained via `MODE=standalone`.
- Troubleshooting: a "SSH keys on Windows clients" section covering the
  `icacls /inheritance:r` trap (it does not remove *explicit* orphan ACEs --
  `/reset` first), why a Windows account name cannot be inferred from its
  profile folder, the three-error symptom ladder, proving key auth with
  `-o PasswordAuthentication=no`, and using ssh-agent instead of stripping a
  passphrase.
- Troubleshooting: Tailscale SSH is refused outright on QNAP at any version
  ("The Tailscale SSH server does not run on QNAP"), plus the requirement for
  BOTH an `acls` port-22 rule and an `ssh` rule where it *is* supported.
- Troubleshooting: pin keys with `from=` listing **both** the IPv4 and IPv6
  tailnet addresses -- a v4-only `from=` silently rejects a v6 connection.

### Changed
- `terminal-run.sh` takes a `MODE` variable and prints mode-aware verification
  steps. The relay container name is configurable via `RELAY_CONTAINER`.
- SKILL.md leads with proxy mode and explains when standalone is worth it.

## [1.0.1] - 2026-08-23

### Fixed
- `install.sh` could never find the skill inside the downloaded archive. The
  tarball extracts to `<repo>-<ref>/skills/<name>` (depth 3) but the search used
  `-maxdepth 2`, so every install aborted with "Could not find skills/wake-panel
  in the archive". Use v1.0.1 or later.

## [1.0.0] - 2026-08-23

### Added
- Initial public release.
- Eight-stage gated setup wizard: preflight, inventory, relay host, per-target
  preparation, relay deploy, password, verification, hand-off.
- Standard-library Python relay: Wake-on-LAN broadcast, SSH power actions,
  demand-driven telemetry polling, scrypt password auth that fails closed.
- Telemetry collectors for Windows (PowerShell) and Linux (shell), reporting
  GPU temperature, utilisation, VRAM, power and fan, plus CPU, RAM, uptime,
  disks, and which model is loaded on the GPU.
- `wol-listen.ps1` to prove whether a magic packet actually arrived, separating
  network faults from firmware faults.
- `discover-hosts.ps1` for inventory, selecting the adapter that has a default
  gateway rather than blocklisting adapter names.
- Optional break-glass terminal (`terminal-run.sh` + `set-terminal-password.ps1`):
  a tailnet-bound browser shell on the relay host, failing closed.
- Symptom-first troubleshooting reference covering Wake-on-LAN, SSH, BIOS
  access, the panel, the collector, NAS relay hosts, and Tailscale upgrades.
