---
name: wake-panel
description: Use when setting up remote wake-on-LAN, remote power control, or a machine-status dashboard reachable over Tailscale — including "wake my PC from my phone", "remote reboot my workstation", "WoL over VPN/WAN doesn't work", "GPU temp dashboard", or hosting a control panel on a NAS, Raspberry Pi, or other always-on device.
---

# Wake Panel

Build a password-protected web panel, hosted on an always-on device, that wakes
and monitors the user's computers from anywhere on their tailnet.

## The one fact that drives the whole design

**A Wake-on-LAN magic packet is a layer-2 broadcast. Tailscale is layer 3 and
forwards no broadcast traffic.** A phone off the home LAN therefore cannot wake
anything directly — not with Moonlight's "Wake PC", not with any WoL app, not
through a Tailscale subnet router. This is not a limitation to engineer around;
it is how WoL works.

So the packet must originate on the LAN. An always-on device hosts a relay:

```
phone (anywhere) --Tailscale--> relay host --LAN broadcast--> target PC
```

The relay must NOT live on one of the machines being controlled — a PC cannot
wake itself, and two PCs that are both off cannot wake each other.

## Running this

Work through the stages in order. **Each stage ends with a gate — do not
proceed past a failed gate.** Later stages assume earlier ones actually worked,
and a silent failure at stage 3 surfaces as an inexplicable one at stage 6.

Do as much as possible yourself over SSH. Hand the user a command ONLY when it
needs local elevation, physical access, or a password you must not see.

Read `reference/TROUBLESHOOTING.md` when anything fails. Nearly every failure in
this domain has a specific, non-obvious cause already catalogued there.

### Stage 0 — Preflight

Establish and confirm with the user:

| Need | Why |
|---|---|
| An always-on device on the same LAN as the targets | The relay; it sends the broadcast |
| Tailscale on that device and on the user's phone | Remote reach |
| Target machines **wired via Ethernet** | Wi-Fi WoL (WoWLAN) is unreliable; say so |
| Admin on each target | Installing sshd, changing power settings |
| Docker on the relay host, **or** Python 3.9+ | Two deploy paths, stage 4 |
| The relay's Tailscale client is **current** | A NAS app store may be years stale; it is the single point of failure |

Ask what the user wants controlled and confirm the relay host choice.

**GATE:** user confirms the relay host is always on, wired or reliably
connected, and on the same LAN segment as the targets.

### Stage 1 — Inventory

For each target, collect: hostname, LAN IP, **wired NIC MAC**, OS, SSH username.

Run `assets/tools/discover-hosts.ps1` (or `ip neigh` / `arp -a`) to enumerate.
Confirm each MAC belongs to the **Ethernet** adapter, not Wi-Fi or a virtual one
— this is a common silent mistake that produces a panel that never wakes anything.

**GATE:** every target has a MAC you have positively identified as its wired NIC.

### Stage 2 — Relay host

Get SSH access to the relay host and record its **Tailscale IP** (`tailscale ip -4`).

Determine the deploy path: Docker available → containerised; otherwise → systemd
service running Python directly. Both are in stage 4.

**GATE:** you can SSH to the relay host non-interactively and know its tailnet IP.

### Stage 3 — Prepare each target

Per target, in this order:

1. **Generate one dedicated relay keypair** (not the user's personal key) — the
   relay holds a key that can power off machines; keep it separately revocable.
2. **Install/enable an SSH server.** Windows: `assets/agent/setup-host.ps1`
   does this plus keys plus the collector. It needs elevation, so the user runs
   it — it is idempotent and prints exactly what changed.

   **The bootstrap problem, and how to keep it to ONE line.** A fresh machine
   has no SSH, so you cannot reach it yet — exactly one command must be typed at
   its console. Do not make the user copy files around. Serve the assets from
   the machine you are on, then hand them a single self-contained line:

   ```
   python -m http.server 8765 --bind <your-lan-ip> --directory <skill>/assets
   ```

   ```powershell
   irm http://<your-lan-ip>:8765/agent/setup-host.ps1 -OutFile $env:TEMP\setup-host.ps1; `
   irm http://<your-lan-ip>:8765/agent/telemetry.ps1  -OutFile $env:TEMP\telemetry.ps1; `
   powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\setup-host.ps1 -PublicKey '<relay public key>'
   ```

   **`-ExecutionPolicy Bypass` is mandatory, not defensive.** A fresh Windows
   defaults Windows PowerShell to `Restricted`, so invoking the downloaded
   script directly (`& $env:TEMP\setup-host.ps1`) fails outright with
   "running scripts is disabled on this system". Verified on a clean Win11 25H2
   install. Passing it as `-File` to a child process bypasses for that one
   invocation and changes no machine policy.

   Both files must land in the same directory — `setup-host.ps1` copies
   `telemetry.ps1` from its own folder. Stop the server afterwards.

   From this point on everything is remote; this is the only console step.
3. **Disable Fast Startup** on Windows (`powercfg /h off`). Fast Startup makes
   "shutdown" a hybrid hibernate and usually breaks WoL from S5.
4. **Install the telemetry collector** (`assets/agent/telemetry.ps1`).
5. **Verify** `ssh -i <relay key> user@host` works from the **relay host**, not
   just from your machine.

**GATE:** the relay host can SSH to every target with the relay key and get
valid JSON from the collector.

### Stage 4 — Deploy the relay

Write `hosts.json` from stage 1 (see `assets/relay/hosts.example.json`).

**`network_mode: host` (Docker) or running directly on the host OS is
mandatory.** In a bridge network the broadcast dies inside the container's
private subnet and never reaches the LAN — the relay looks perfectly healthy and
simply never wakes anything.

The container needs an SSH client; the compose file installs `openssh-client` at
start with `|| true` so a relay host with no internet still boots degraded
rather than failing entirely.

**GATE:** `curl http://<relay>:8099/healthz` returns `{"ok": true}`.

### Stage 5 — Password

Have the user run `assets/tools/set-password.py`. It
prompts locally, derives a scrypt hash, and writes only the hash.

**Never ask the user to type a password into the conversation.**

The relay **fails closed**: with no config it serves nobody. Verify this — `/`
should redirect and `/api/status` should 401 before the password is set.

**GATE:** unauthenticated requests are refused; the user can log in.

### Stage 6 — Verify for real

Testing in this order matters, because S3 succeeding tells you nothing about S5:

1. **Sleep → wake.** Proves the whole packet path. Fast, low risk.
2. **Shutdown → wake.** The real test. Warn the user first: if it fails the
   machine needs a physical power button press.

If S3 works and S5 does not, the cause is nearly always firmware. See
TROUBLESHOOTING — and note that the usual internet answer (ErP) is often *not*
the culprit.

**GATE:** each machine has actually been woken from full shutdown, or is
explicitly marked unverified. **The panel blocks shutdown for any machine whose
wake is unverified** — keep it that way rather than trusting a setting.

### Stage 7 — Hand off

Tell the user to open `http://<tailnet-ip>:8099` on their phone and **Add to
Home Screen** — it launches full-screen and behaves like an installed app.

Summarise: what works, what is unverified, and any BIOS change still outstanding.

## Optional — a break-glass terminal

The panel gives you fixed verbs: wake, sleep, reboot, shutdown. When something
unforeseen breaks, you want a shell *inside* the network instead. Since the relay
host is by definition the always-on box, it is the right place to put one.

This is optional and additive; the panel works without it. Add it when the user
asks for "a terminal", "access when everything is down", or hand-built commands
against the rest of the network.

**Run it as a separate container, not another service in the panel's compose
project.** Re-running `docker compose up` against the project that owns a working
relay risks recreating it for no reason, and on a locked-down NAS the account may
not even be able to create a new project directory. A standalone container with
`--restart unless-stopped` survives reboots identically and cannot disturb the
panel.

Both pieces ship with this skill:

| Asset | Purpose |
|---|---|
| `assets/relay/terminal-run.sh` | run on the relay host; launches and verifies the terminal |
| `assets/tools/set-terminal-password.ps1` | only for standalone mode (see below); prompts and pipes the credential over SSH |

**Two modes. Prefer PROXY.**

*Proxy mode (default, recommended)* — ttyd binds loopback with
`--base-path /terminal`, and the relay proxies `/terminal*` behind its own auth:

```sh
ttyd --interface lo --port 7681 --base-path /terminal --writable bash
```

No ACL change is ever needed (the panel's port is already permitted), there is
one URL and one login, ttyd is unreachable from the network, and **no ttyd
credential exists at all** — so no plaintext sits in `ps` or `docker inspect`.
This requires adding a WebSocket-aware proxy route to the relay; see
TROUBLESHOOTING for the shape.

*Standalone mode* — ttyd binds the tailnet interface on its own port with
`--credential`. Simpler to deploy, no relay changes, but it needs a tailnet ACL
grant for that port and it carries a second, weaker credential:

```sh
ttyd --interface tailscale0 --port 7681 --writable --credential "$CRED" bash
```

Either way the container is the toolbox — a NAS BusyBox userland typically has no
`nc`, no `python3`, no `dig`. Run it with `--pid host --privileged` and `/:/host`,
then one alias gets a genuine root shell on the host:

```sh
alias nas='nsenter -t 1 -m -u -n -i -p -- sh'
```

`nsenter` beats `chroot /host` because it enters the host's real namespaces, so
`/proc`, `/sys` and the host's own tooling all behave normally.

Three flags are load-bearing in both modes, and each has its own TROUBLESHOOTING
entry:

- **`--writable`** — without it the terminal is read-only and looks broken.
- **plain `bash`, no flags** — a `-i` passed to the child segfaults ttyd with an
  empty log, because `-i` is ttyd's own `--interface`.
- **`|| true` on `apk add`** — a relay with no internet still gets a usable shell
  instead of a crash loop.

> This is a deliberately privileged container. The Docker socket alone already
> grants host root, so `--privileged` adds convenience rather than exposure — but
> be honest that the panel's password is what stands in front of it.

**GATE — all four, in this order:**

1. `docker inspect` shows `state=running` with `restarts=0`. A crash loop reads
   as "started successfully" from the `docker run` exit code alone.
2. `netstat -tln` shows the tailnet address and **nothing on `0.0.0.0`**. Check
   the actual binding; do not trust the flag.
3. An unauthenticated request returns **401**, and so does a request with *wrong*
   credentials. Prove the guard refuses, not just that the page loads.
4. It is reachable from the user's phone. In proxy mode this is automatic. In
   standalone mode, **a tailnet ACL will not grant a new port automatically** —
   a bound, healthy service is unreachable until you add it, and the failure
   looks like a hang rather than a refusal, which is the main reason to prefer
   proxy mode.

Add the ACL rule **additively**, never by editing an existing rule: you are
almost certainly connected through the tailnet while you edit it, and a
narrowing mistake locks you out of the box you are working on.

Pair it with a genuinely **independent** fallback — a phone SSH client with its
own key, generated on the phone so the private key never touches another
machine. A single break-glass mechanism that shares a failure mode with the
thing it rescues is not a fallback. If the terminal container is what's broken,
SSH still works; if the tailnet client is what's broken, neither does, which is
why keeping that client current matters (see TROUBLESHOOTING).

## Design rules to preserve when modifying

- **Fail closed on auth.** Missing config must lock everyone out, never expose
  working reboot buttons.
- **Poll only while watched.** The panel stamps a timestamp; the poller goes
  dormant when nobody is looking. Otherwise it SSHes into the user's machines
  every few seconds forever, for nobody.
- **Collector runs ON the target and queries its own localhost.** Keeps
  monitoring tools off the network entirely; SSH stays the only remote surface.
- **Block shutdown until wake is proven.** An unverified shutdown can strand a
  machine that needs physical access.
- **Bind privileged extras to the tailnet interface, never `0.0.0.0`.** And
  verify the binding with `netstat`, not by trusting the flag you passed.
- **Any added service fails closed too.** No credential file must mean refuses
  to start, not serves unauthenticated.

- **Address every host through an ORDERED LIST, never one field.** LAN first,
  VPN second; try in order, cache the winner briefly, re-probe. A single `ip`
  field is the root of nearly every "the panel says it is offline and it isn't":
  a machine that leaves the LAN, or a LAN path that breaks inbound only, takes
  the whole card down. Show which path is live, so failover is visible.
- **Never reuse the liveness address for a service probe.** One field serving
  both means a VPN ACL or a broken LAN makes a healthy service look wedged — and
  if the panel auto-repairs, it will "fix" a service that was never broken.
- **Prefer asking the target over probing it.** A check run ON the host against
  its own localhost, returned over the existing SSH channel, survives VPN ACLs
  and LAN breakage that a direct network probe cannot — and keeps the service
  off the network, which is the same reason the collector works that way.
- **Never disable a control because of state.** A greyed-out button fails
  precisely when the state reading is wrong, which is exactly when the operator
  needs it. Make destructive actions *deliberate* (explicit confirm carrying live
  reachability) rather than *forbidden*.
- **The relay gets no power buttons.** It is what wakes everything else; a reboot
  control there is the one button capable of stranding the entire setup, sitting
  next to the ones pressed daily. Give it a status card instead.
- **A check that cannot fail is worse than no check.** Keep verdicts honest and
  three-valued where the evidence is: "cannot tell" must never be counted as
  failure, or a broken network path escalates into a repair on a healthy machine.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Relay on a machine being controlled | Cannot wake itself; both off = stuck |
| Bridge networking in Docker | Looks healthy, never wakes anything |
| Wi-Fi MAC instead of Ethernet | Packet goes nowhere |
| Trusting `powercfg /devicequery wake_armed` | Only reflects S3; says OK while S5 is dead |
| Skipping the S5 test | "Working" panel that strands a machine |
| Ollama-only model detection | Misses llama.cpp / ComfyUI holding the GPU |
| Passing `-i` to ttyd's child command | ttyd segfaults, exit 139, empty log |
| Probing with a tool the NAS lacks (`nc`) | `rc=127` scores every host as down |
| Assuming a new port is reachable | Tailnet ACL drops it; looks like a hang |
| Leaving the relay's Tailscale client stale | Single point of failure for every remote path |
| One `ip` field for liveness, SSH and service probes | A dead path reports every machine offline |
| Disabling buttons when a host reads offline | Controls vanish exactly when the reading is wrong |
| Only broadcasting magic packets | Leaves the S3 directed-packet wake vector unused |
| Treating "cannot tell" as a failure | Watchdog "repairs" a healthy machine over a broken path |
| Testing the collector in pwsh 7, deploying to 5.1 | Byte[] vs String makes detectors read the opposite way |
| Giving the relay a reboot button | The one control that can strand everything |
