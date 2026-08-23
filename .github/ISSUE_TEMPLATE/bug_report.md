---
name: Bug Report
about: Something isn't working as expected
title: '[Bug] '
labels: bug
assignees: ''
---

## Describe the bug
A clear description of what went wrong.

## Which stage
Which stage of `/wake-panel` were you in, or which component (relay, collector,
terminal, install script)?

## Steps to reproduce
1.
2.
3.

## Expected vs actual
What should have happened, and what did.

## Already checked
- [ ] I read the relevant section of TROUBLESHOOTING.md
- [ ] For wake failures: I have tested wake from **sleep** and from **full
      shutdown** separately (they fail independently)
- [ ] For wake failures: I confirmed the MAC belongs to the **wired** adapter

## Environment
- Relay host: [e.g. QNAP TS-x53D / Raspberry Pi 5 / Debian 12 VM]
- Relay deploy: [Docker / bare Python]
- Target OS: [e.g. Windows 11 25H2 / Ubuntu 24.04]
- Tailscale version on the relay:

## Output
Paste relevant output. `docker logs <relay-container>` is usually the useful one.
