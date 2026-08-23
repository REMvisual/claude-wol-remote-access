# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
