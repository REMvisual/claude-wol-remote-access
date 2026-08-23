# Wake Panel — Troubleshooting

Symptom-first. Nearly every failure here has a specific, non-obvious cause, and
several of them look exactly like something else.

---

## Wake-on-LAN

### Wakes from sleep, but NOT from a full shutdown

**The single most misleading failure in this domain.** S3 succeeding tells you
nothing about S5, because they arm the NIC through different paths.

Check in this order:

1. **`Power On By PCI-E` / `Wake on PCIe` / `Resume by PCI-E` in BIOS → Enabled.**
   This is usually it. Enable it *even if* ErP is already disabled.
2. **`ErP Ready` / `EuP 2013` → Disabled.** ErP cuts +5VSB to the NIC in S5 only,
   leaving S3 untouched — which produces exactly this symptom, and is the answer
   you'll find everywhere online. It is often **not** the actual cause. On ASUS
   boards ErP being enabled greys out the PCI-E option, so disable ErP first.
3. **Fast Startup** (`powercfg /h off`). Makes "shutdown" a hybrid hibernate,
   which on most NICs drops the WoL arming.
4. Intel PROSet exposes a *separate* "from power-off state" property on some
   driver builds. Check the adapter's Advanced tab.

> **`powercfg /devicequery wake_armed` cannot see any of this.** It reflects S3
> only. A machine can list its NIC as wake-armed, have `*WakeOnMagicPacket=1` and
> `EnablePME=1` in the registry, and still be completely unable to wake from S5.
> Only an actual shutdown → wake test proves it.

### Won't wake from SLEEP, and you only ever send magic packets

A magic packet is not the only way to wake a sleeping machine, and if it is the
only thing the relay sends you are leaving an entire vector unused.

Most NICs expose **`*WakeOnPattern`** alongside `*WakeOnMagicPacket`. With it
enabled, **any directed packet** — a plain TCP SYN, an ARP request the NIC must
answer — wakes the machine from **S3** with no magic packet involved. Intel's
adapter documentation calls this Wake on Directed Packet.

So send everything, every time:

1. **Broadcast** magic packet, to `255.255.255.255` *and* the `/24` directed
   broadcast, on ports **9 and 7**. Some NICs ignore the global broadcast and
   honour only the subnet one; some firmware listens on only one port.
2. **Unicast** magic packet to the host's LAN IP. A sleeping NIC answers ARP
   from its own offload engine, so the switch still has a port for it — this
   lands where broadcast is rate-limited or filtered.
3. **Directed packet** — simply attempt a TCP connect. Whether it succeeds is
   irrelevant; the SYN is the trigger. This is the S3 vector above.
4. **Repeat.** Three rounds a second or two apart. Single packets do get lost;
   machines that wake on the second or third attempt are common.

> **Directed packets do NOT work from S5.** In full power-off the NIC honours
> magic packets only, so this complements the broadcast rather than replacing
> it. The two states still need testing separately.

### Doesn't wake at all, from any state

- **Wrong MAC.** Confirm on the machine itself (`Get-NetAdapter -Physical` /
  `ip -br link`), not from an ARP sweep. Wi-Fi and virtual adapter MACs are the
  classic mistake.
- **Wi-Fi instead of Ethernet.** WoWLAN is unreliable; use a wired connection.
- **NIC not wake-armed:** Device Manager → adapter → Power Management → "Allow
  this device to wake the computer"; Advanced → "Wake on Magic Packet" = Enabled.
- **Relay isn't on the target's LAN segment.** Broadcast does not cross subnets.

### Works on the home LAN, fails from outside

Working as designed, and the reason this project exists. A magic packet is a
layer-2 broadcast; Tailscale is layer 3 and forwards no broadcast. This affects
*any* remote WoL app equally.

Do not try to fix it with a Tailscale subnet router — advertising the LAN does
not make subnet broadcasts traverse the tunnel. The relay must run on a device
physically on the LAN.

### Relay reports "magic packet sent ×4" but nothing wakes

**Almost always Docker bridge networking.** In the default bridge network the
broadcast dies inside the container's private subnet. The relay is healthy, the
packet is genuinely sent, and it never reaches your LAN.

Fix: `network_mode: host`. There is no port-mapping workaround.

---

## SSH

### "running scripts is disabled on this system" when bootstrapping a target

Fresh Windows defaults Windows PowerShell to `Restricted`, so a downloaded
`.ps1` will not run at all — including `setup-host.ps1`. Verified on a clean
Win11 25H2 (build 26200) install.

Invoke it as a child process instead of dot-sourcing it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\setup-host.ps1 -PublicKey '<key>'
```

This bypasses for that one invocation and changes no machine policy. Do **not**
tell users to run `Set-ExecutionPolicy RemoteSigned` machine-wide — it is a
persistent security change to fix a one-off script run.

### Key auth fails on Windows despite the key being in `~/.ssh/authorized_keys`

For any account in the **Administrators** group, Windows OpenSSH **ignores**
`~\.ssh\authorized_keys` completely. It reads only:

```
C:\ProgramData\ssh\administrators_authorized_keys
```

…and only if the ACL grants nothing beyond SYSTEM and Administrators:

```powershell
icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'
```

Wrong file or a loose ACL = silently rejected, with nothing useful in the log.

### `Permission denied (publickey,password,keyboard-interactive)` on a NAS

- **Wrong username.** Many NAS vendors push you to disable the built-in `admin`;
  once disabled it can never authenticate. Check which home directories exist
  (`/share/homes`, `/volume1/homes`) and prefer the recently-modified one.
- **A per-user SSH allow-list.** Being an administrator is not always enough;
  some NAS UIs keep a separate "who may SSH" list.
- **2-step verification** blocks password SSH outright. Use key auth — which
  means getting the key in by another route (a writable share, or the NAS's own
  file manager).

### Commands work interactively but fail from the relay

The relay uses `BatchMode=yes` — anything that would prompt fails instead of
hanging. It also sets `StrictHostKeyChecking=no` so a changed host key doesn't
wedge it. If your manual test works but the relay's doesn't, compare the exact
flags before assuming the key is wrong.

### A command works by hand, but the relay's key is refused

If the relay's key is capped by a **forced command** (a `command="..."` option in
`authorized_keys`, or `ForceCommand` in `sshd_config`) then the incoming command
goes to a dispatcher that allowlists specific actions and refuses everything
else. Adding a new relay capability then fails with something like:

```
relay-dispatch: refused: powershell ... -File C:\Users\x\panel-actions.ps1
```

This reads as a bug in the new script, because **everything else keeps working**
— telemetry, sleep, reboot — so the key is obviously valid and the path is
obviously right.

Add the new verb to the dispatcher on *every* host, preserving its two
properties: the incoming string is never re-executed, and only bounded, validated
fragments are interpolated. Bound paths with a character class that **excludes
`.`** so `..` traversal is impossible, and bound verbs with a **fixed
alternation**, never a character class.

> Give the dispatcher a dry-run switch — an env var that makes it print which
> branch matched and exit without running it. Indispensable when the allowlist
> contains `shutdown`. And always confirm it still *refuses* a bad input: a
> guard that cannot refuse is not a guard.

### `shutdown /r /o` returns "The parameter is incorrect. (87)"

`/o` (boot to recovery options) requires a real interactive desktop session, and
Windows OpenSSH runs in session 0. Workaround — run it as a scheduled task with
an interactive token:

```
schtasks /create /tn BootToFw /tr "shutdown.exe /r /o /t 0" /sc once /st 23:59 \
  /sd 01/01/2099 /ru MACHINE\User /it /f
schtasks /run /tn BootToFw
```

`/ru` needs the fully-qualified `MACHINE\User` form — a bare username gives a
`UserId` parse error. Pin `/sd` far in the future or the one-shot trigger will
fire for real later. Delete the task afterwards.

### Remote `shutdown /m \\host` gives "Access is denied. (5)"

`LocalAccountTokenFilterPolicy` strips admin rights from local accounts
authenticating over the network. Don't fight it — use SSH.

---

## Getting into BIOS

### Del / F2 do nothing; it boots straight to Windows

**BIOS Fast Boot** skips USB initialisation during POST, so the keyboard isn't
powered when the key window passes. Not the same thing as Windows Fast Startup.

In order of effort:

1. **Hold** the key from a *cold* power-on (not a restart), keyboard in a rear
   **USB 2.0** port. USB 3 / Type-C enumerate later.
2. **Force a failed POST** — power on, hard-kill with a 4-second power-button
   hold as it starts POSTing, 2–3 times. The board then does a full POST *with*
   USB init and offers a setup prompt. Preserves all settings.
3. **Clear CMOS** (rear button, CLRTC jumper, or pull the coin cell). Resets Fast
   Boot — but also wipes your memory profile (XMP/EXPO), so re-enable it while
   you're in there.
4. **BIOS FlashBack**, if the board has it — reflashing resets settings without
   opening the case.

### `shutdown /r /fw` reports success but boots to Windows anyway

`/fw` and Windows Recovery's "UEFI Firmware Settings" both set the *same* UEFI
`OsIndications` flag, and some boards **silently ignore it while Fast Boot is
enabled**. The recovery menu still *offers* the entry, so its presence proves
nothing. Three attempts through two code paths is one mechanism failing three
times — switch to the physical routes above.

If a gaming keyboard with onboard memory never works, try a cheap basic one:
RGB keyboards can take 2–3 seconds to enumerate, longer than the whole POST.

---

## Panel

### Locked out — `/login` returns 503

No credentials configured. **This is deliberate** — the relay fails closed rather
than serving working reboot buttons to anything that can reach the port. Run
`set-password.py` and restart.

### Everything shows "offline" but the machines are up

Check `probe_port` in `hosts.json`. It must be a port that is genuinely open.

**Use 22.** `setup-host.ps1` opens it across all firewall profiles. It is
tempting to use 445 so the dot works even when sshd is stopped — don't. Windows
11 puts new networks on the **Public** profile, which blocks File and Printer
Sharing, so 445 is closed on a fresh install and the machine reads as
permanently offline. Verified on a clean Win11 25H2.

The relay uses a TCP connect rather than ping because ICMP needs raw sockets
(root) inside a container.

### Panel says offline, but that machine reaches the relay perfectly

Classic **asymmetric routing**: outbound works, inbound is dead. Testing from the
machine proves nothing, which is why this survives for days.

On Windows it happens when a NIC loses the auto-created **on-link route for its
own subnet**. Every LAN peer is then treated as off-link, so replies leave for
the default gateway's MAC — and a router that will not hairpin drops them.
`ping` and outbound TCP from that machine still succeed throughout.

```powershell
Get-NetRoute -InterfaceIndex <idx>      # expect 192.168.x.0/24 on-link + x.255/32
New-NetRoute -DestinationPrefix '192.168.x.0/24' -InterfaceIndex <idx> `
             -NextHop '0.0.0.0' -RouteMetric 256 -PolicyStore ActiveStore
```

Resolve the NIC by **MAC**, never a hardcoded `ifIndex` — the index changes when
an adapter is disabled or re-seated, and you will silently repair the wrong one.

> `New-NetRoute` **refuses** `-PolicyStore PersistentStore` for an on-link route,
> so it cannot be made persistent that way. If the route vanishes repeatedly,
> repair it on a **timer**: it can disappear mid-session, and a boot-time task
> will never catch that.

**Diagnose from the relay**, never the target:

```
docker exec <relay> python -c "import socket;socket.create_connection(('<ip>',22),timeout=3);print('OPEN')"
```

### One host is unreachable at its LAN address but fine over the VPN

It has left the LAN — Ethernet unplugged, moved to Wi-Fi, or taken off-site. A
single hardcoded address per host cannot express that, so the panel reports a
perfectly healthy machine as offline.

Give each host an **ordered list of addresses** (LAN first, VPN second), try them
in order, cache the winner briefly, and show which path is in use so a silent
failover is visible. Keep any service-specific probe address **separate** from
the liveness address: one field serving both means a VPN ACL or a broken LAN
takes out both at once, and can make a service look wedged when only the path to
it is broken.

> If the host is off the LAN, **Wake-on-LAN cannot reach it** — the magic packet
> is a layer-2 broadcast on the relay's own segment. Say so in the UI rather
> than offering a Wake button that silently cannot work.

### Card shows "online" but no stats

- `collector` path wrong, or the script isn't on that machine.
- The relay's key isn't authorised on that host (see the Windows ACL note above).
- Test the exact command by hand from the **relay host**, not from your laptop.

### Readings look wrong / disagree with FanControl or HWiNFO

They almost certainly don't. `nvidia-smi` reads NVML — the GPU's own sensor —
and every Windows monitoring tool reads that same API for NVIDIA cards. A
difference is **sampling time**, not accuracy: under load a die can swing 10 °C
in seconds while the panel polls every 8. The card shows "Ns ago" for this reason.

One real difference: `temperature.gpu` is the core/edge temp. Tools showing
*hotspot* or *memory junction* read 10–15 °C higher by definition.

### No CPU temperature

Windows has no reliable built-in source (`MSAcpi_ThermalZoneTemperature` is
unsupported on most desktop boards), so it needs a helper app:

| Option | Verdict |
|---|---|
| **FanControl** | **Cannot work.** Its plugin system is inbound-only and it exposes no API — verified by it having zero listening ports. It *links* the LibreHardwareMonitor library but starts no server. |
| **LibreHardwareMonitor** standalone | Works (`:8085`), must run elevated. But it shares a global SuperIO mutex with FanControl's embedded copy — there are documented reports of fans misbehaving when both run. |
| **HWiNFO** free | Shared memory is capped at **12 hours/day**, then needs manual re-enabling. Unsuitable unattended. |
| **HWiNFO Pro** | Works properly, paid. |
| **Skip it** | Often the right call. |

GPU temps need none of this. On Linux, `/sys/class/thermal` is built in and
`telemetry.sh` reads it with no helper app at all.

### GPU shows a blob hash instead of a model name

Ollama spawns its own `llama-server` per model on ephemeral ports, and those
report the on-disk blob path as the model id. The collector drops any detail
containing a path separator or `sha256-`, since Ollama's own API names them
properly. If you see hashes, your collector is out of date.

### A machine's card shows *another* machine's models

Something on the default Ollama port (11434) is a proxy or router forwarding to
a different host. The collector tries 11435 first for exactly this reason. Adjust
`$OllamaPorts` if your setup differs.

### "on GPU" is full of junk (lock screen, mouse drivers, antivirus)

Your collector predates the allowlist. On a desktop practically everything holds
a graphics context, so filtering noise by name never converges — the collector
matches an allowlist of compute apps instead.

---

## Break-glass terminal

An optional second service on the relay host: a browser terminal (`ttyd`) bound
to the tailnet interface, so that when every managed machine is down you still
have a shell *inside* the network to work from.

### ttyd dies instantly, exit 139, and the log is completely empty

**`-i` is ttyd's own short flag for `--interface`.** Its option parser grabs a
`-i` appearing *after* the command too, finds no argument for it, and
segfaults — before it has written a single line, so `docker logs` shows nothing
at all and there is no message to search for.

```sh
ttyd ... bash --rcfile /etc/x.rc -i     # SEGFAULT, exit 139, silent
ttyd ... bash                           # fine
```

You do not need `-i` anyway: ttyd hands the child a PTY, so bash is already
interactive and reads `~/.bashrc` by itself. Put your aliases and banner in
`/root/.bashrc` and pass the command with **no flags at all**.

> The same trap applies to any short flag ttyd defines (`-p`, `-c`, `-t`…). If
> the child command genuinely needs flags, separate them with `--`, or wrap the
> whole thing in `sh -c '...'` so ttyd only ever sees one bare word.

### The terminal renders but you cannot type into it

`ttyd` is **read-only by default**. Add `--writable`. This looks exactly like a
broken deploy — the shell prompt appears and paints correctly, keystrokes just
vanish.

### The terminal is bound correctly but unreachable from another tailnet node

Check the shape of the failure before touching the service — it tells you which
layer is at fault:

| Symptom from the client | Meaning |
|---|---|
| Hangs, then times out (curl `rc=28`/`124`) | Packets **dropped** — tailnet ACL does not grant that port |
| Instant refusal (`http=000`, `rc=7`, fails in ms) | Nothing **listening** on that address |
| `401` | Working correctly, you just need credentials |

A dropped packet and a dead service are completely different problems that both
present as "it doesn't work". Confirm by testing the same port **from the relay
host itself**, which bypasses the ACL entirely:

```sh
docker exec <terminal-container> curl -s -o /dev/null -w '%{http_code}\n' \
    http://<relay-tailnet-ip>:7681/
```

`401` there plus a timeout from elsewhere is conclusive: the service is healthy
and the ACL is the blocker. Grant the port **additively** — add a new rule
rather than editing an existing one, so you cannot accidentally revoke the
access you are currently using to reach the box.

### Where the terminal's password lives, and why it isn't hashed

Unlike the panel, **ttyd takes its credential as a command-line argument**, so it
cannot be a hash — the relay host holds the plaintext and it is visible in `ps`
and `docker inspect` *on that host*.

That is acceptable only because anyone who can read those already has a shell
there. It means the **tailnet ACL is the primary boundary and the password is
the second layer**, which is the reverse of the panel's posture. Say so out loud
in the script header; it changes how tightly the ACL should be scoped.

Keep the launcher **failing closed**: with no credential file it must refuse to
start rather than serve an unauthenticated root shell.

### Should the terminal be a container shell or the host's shell?

Prefer the container, and give it a way *out*. A NAS's own userland is usually
BusyBox with nothing in it, while a container can install a real toolbox in
seconds (`openssh-client`, `bind-tools`, `nmap`, `tcpdump`, `iproute2`,
`ethtool`, `docker-cli`).

Run it with `--pid host --privileged` and mount `/:/host`, then one alias gets
you a genuine root shell on the host itself:

```sh
alias nas='nsenter -t 1 -m -u -n -i -p -- sh'
```

`nsenter` beats `chroot /host` here because it enters the host's real namespaces,
so `/proc`, `/sys` and the host's own service tooling all behave normally.

> This is a deliberately privileged container. Mounting the Docker socket alone
> already grants host root (`docker run -v /:/host …`), so `--privileged` adds
> convenience rather than exposure — but be honest that the ACL and one password
> are all that stand in front of it.

### Packages vanish after the container is recreated

`apk add` at container start writes to the container's writable layer, so a
`restart` keeps them but a **recreate** re-downloads them — and if the host has
no internet at that moment you get a bare BusyBox shell instead of the toolbox.

Build a proper image if you can. On some NAS platforms you cannot: `docker build`
needs to write into the container runtime's own data directory, which an
unprivileged NAS account has no access to:

```
ERROR: mkdir /share/.../container-station/homes: permission denied
```

Then runtime `apk add … || true` is the only option. Keep the `|| true` so a
no-internet start degrades to a usable shell rather than a crash loop.

### Better: proxy the terminal through the panel instead of giving it its own port

Binding ttyd to the tailnet on its own port works, but it is the weaker of the
two designs and it fails in a specific, annoying way: **a tailnet ACL does not
grant a new port automatically**, so a perfectly healthy terminal is unreachable
until you edit the policy, and the symptom is a hang rather than a refusal.

Mount it under the panel instead:

```sh
ttyd --interface lo --port 7681 --base-path /terminal --writable bash
```

and add a proxy route to the relay for `/terminal*`. Four things get better at
once:

- **No ACL change ever.** The panel's port is already permitted.
- **One URL, one login, one home-screen icon.**
- **ttyd leaves the network entirely** — loopback only, unreachable from the
  tailnet, so the only way in is through the panel's auth.
- **The plaintext credential disappears.** In proxy mode ttyd needs no
  `--credential` at all, so nothing sits in `ps` or `docker inspect`. The
  panel's hashed password becomes the single gate.

`--base-path` is required: without it ttyd serves its assets and websocket from
`/`, the page loads through the proxy, and then the websocket 404s.

Have the proxy **drop any inbound `Authorization` header** rather than forwarding
it. The request was already authorised by the panel; passing through a header you
never validated lets a client aim credentials at ttyd through you.

If the relay is a `BaseHTTPRequestHandler`, the proxy is a byte pipe: rebuild the
request line and headers, add `Connection: close` for non-upgrade requests so the
copy loop can end on EOF instead of parsing chunked framing, then `select()` on
the two raw sockets. Stop using the handler's `wfile` once you start — it will
re-frame a WebSocket stream.

### Tailscale SSH will not enable on a NAS

If you were planning to reach the relay host with Tailscale SSH instead of a key,
check that it is supported *before* designing around it. On QNAP it is refused
outright, at any version:

```
$ tailscale set --ssh=true --accept-risk=lose-ssh
The Tailscale SSH server does not run on QNAP.
$ tailscale debug prefs | grep RunSSH
        "RunSSH": false,
```

This is a hardcoded platform check, not a configuration problem. Use ordinary
sshd with a key instead — the tailnet still provides the encrypted transport and
the ACL still bounds who may reach port 22.

> **Tailscale SSH needs BOTH rule types when it *is* supported**: a network rule
> permitting port 22 in `acls`, *and* a rule in the `ssh` section. Miss the first
> and the packet filter drops the connection before the SSH policy is ever
> evaluated — which reads as "Tailscale SSH is broken" rather than "the ACL
> denies it". The network rule is also what plain sshd needs, so it is worth
> adding either way.

### Pin the key to the tailnet address, and remember tailnets are dual-stack

An `authorized_keys` options prefix bounds a key to where it may be used:

```
from="100.x.y.z,fd7a:115c:a1e0::abcd",restrict,pty ssh-ed25519 AAAA... laptop
```

- **List the IPv6 address as well as the IPv4 one.** Every tailnet node has both,
  and a v4-only `from=` silently rejects a connection that happened to arrive
  over v6.
- `restrict` disables agent forwarding, port forwarding and X11; `pty` puts back
  the terminal you actually need. Without `pty` an interactive shell fails.
- Revocation stays centralised despite being a local file: remove the device from
  the tailnet and the address in `from=` can no longer be presented.

---

## SSH keys on Windows clients

### "UNPROTECTED PRIVATE KEY FILE" survives `icacls /inheritance:r`

`/inheritance:r` removes **inherited** ACEs only. An **explicit** ACE — commonly
an orphaned SID left by a renamed or deleted account — survives it untouched, so
ssh keeps refusing the key however many times you run it.

Reset first, then lock it down:

```powershell
icacls "$env:USERPROFILE\.ssh\mykey" /reset
icacls "$env:USERPROFILE\.ssh\mykey" /inheritance:r /grant:r "$(whoami):(F)"
icacls "$env:USERPROFILE\.ssh\mykey"
```

`/reset` wipes explicit ACEs and restores inheritance; the second line then
strips inheritance and leaves exactly one entry. The third prints the result —
check it names a real principal.

### The account name is not the profile folder name

`C:\Users\jane` does **not** prove the account is `jane`. A renamed account keeps
its original profile directory, so granting to the folder name fails:

```
jane: No mapping between account names and security IDs was done.
```

Use `whoami` (which returns `MACHINE\account`) and never infer the username from
a path. The symptom ladder if you get this wrong is confusing, because each step
looks like a different bug:

| Error | Cause |
|---|---|
| `UNPROTECTED PRIVATE KEY FILE` / "too open" | an explicit orphan ACE |
| `Permission denied` loading the key | granted to a principal that is not you |
| `Enter passphrase for key` | **working** — this one is success |

### Your key "works", but you were actually authenticating with a password

If the host accepts passwords, a plain `ssh host` that succeeds proves nothing
about your key — ssh silently falls back, and a passphrase prompt and a password
prompt look nearly identical at a glance.

Always prove it with the fallback disabled:

```
ssh -o PasswordAuthentication=no host "id"
```

Check what the server actually offers, too:

```
ssh -o PreferredAuthentications=none host
# Permission denied (publickey,password,keyboard-interactive).
```

A relay host that still lists `password` is usually the weakest SSH surface in
the estate, and it is often the one holding the keys to everything else.

### Stop the passphrase prompt without stripping the passphrase

Load the key into the Windows ssh-agent service, which persists keys across
reboots:

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add "$env:USERPROFILE\.ssh\mykey"
```

Prefer this to removing the passphrase. File permissions protect a key only while
it sits on that filesystem; a passphrase keeps it useless to anyone who copies it
off. This also matters if an agent or script needs to call ssh non-interactively —
a passphrase prompt blocks it, and the agent removes the prompt without removing
the protection.

---

## Relay host is a NAS

### Every reachability test reports FAIL — including ones you know are up

**Check that the tool you are testing with exists.** A NAS's BusyBox userland
frequently ships without `nc`, `python3`, `dig` or `curl`, and a missing binary
gives `command not found` / `rc=127`, which a naive `if ...; then OK else FAIL`
scores as a failure for **every** target uniformly.

```sh
nc -z host 22   # sh: nc: command not found   -> rc 127 -> "FAIL", for everything
```

A test that reports the same answer for every input is not measuring anything.
The tell is uniformity: real network faults are patchy, not total. Prove the
check can *pass* against a target you are certain of before believing a failure.

Run such probes from a container with real tooling instead:

```sh
docker run --rm --network host alpine sh -c \
  'apk add --no-cache netcat-openbsd >/dev/null; nc -z -w4 <ip> 22 && echo OK'
```

### You need a root-owned file but the NAS account cannot sudo

Common on NAS platforms: the SSH account is in the administrators group yet
`sudo` still demands a password, `/etc/config` is unwritable, and root-owned
`0600` files are unreadable.

If the account can reach the Docker socket, **it already has root** — a container
is the escalation path, and it is the supported way to read, back up or repair
system files non-interactively:

```sh
docker run --rm -v /path/to/protected:/src:ro -v /destination:/dst alpine \
    cp -a /src/. /dst/
```

Use it for inspection and backups. Do **not** use it to drive the NAS's package
manager through `nsenter` hacks — a half-finished package operation on the box
that provides your only remote access is the one failure you cannot recover from
remotely. Hand genuine install/upgrade steps to the vendor GUI.

### A backup directory comes out world-writable despite `chmod 700`

`cp -a src/. dst/` copies the **source directory's own mode** onto the
destination, silently undoing a `chmod` you did beforehand:

```sh
mkdir -p "$B" && chmod 700 "$B"
cp -a /src/. "$B"/          # $B is now whatever /src was — often 0777
chmod 700 "$B"              # re-assert AFTERWARDS
```

Mode `0777` on a directory allows unlink-and-replace even when the files inside
are `0600`, so a secret can be swapped out without ever being readable. Always
re-check with `ls -ld` after copying, not before.

---

## Tailscale on the relay host

### The NAS app store's Tailscale is years out of date

QNAP's App Center has shipped **1.40.0-1 (published 2023/06/12)** for years —
a catalogue refreshed in 2026 still offers it. "Update" in the GUI does nothing
because there is nothing newer there. This is a long-running, acknowledged issue
([tailscale-qpkg#130](https://github.com/tailscale/tailscale-qpkg/issues/130)).

This matters more than a normal stale package: **the tailnet client is the single
point of failure for every remote path you have**. Panel, terminal and SSH all
die together if the control plane ever stops serving a client that old.

Get the current package straight from the vendor and install it through the
GUI's *Install Manually*:

```
https://pkgs.tailscale.com/stable/          # find the file for your arch
Tailscale_<version>_x86_64.qpkg             # x86_64 for most Intel/AMD NAS
```

Verify the download against the published checksum before installing:

```sh
curl -s https://pkgs.tailscale.com/stable/<file>.sha256
sha256sum <file>
```

Expect a **digital-signature warning** — the vendor's own package is not signed
by the NAS manufacturer, so App Center must be allowed to install unsigned
packages. The matching checksum is the check that actually carries weight here.

> Because this path is manual, it will rot again. If the relay host runs a
> container engine, consider running Tailscale as a **container** instead, which
> tracks upstream and updates like anything else.

### Upgrading the relay's Tailscale without stranding yourself

The client you are upgrading is usually the client you are connected through.

1. **Back up the state directory first** — it holds the node identity. Losing it
   means re-authenticating a headless box. It is root-owned, so back it up via a
   container (see above) and verify with `sha256sum` on both copies.
2. **Keep a non-tailnet path open** — an SSH session over the LAN, or physical
   access. Do the whole operation over that path, not over the tailnet.
3. **Verify identity survived, not just that it started.** Same node ID, same
   tailnet IP, and auto-start still enabled:

   ```sh
   tailscale debug prefs | grep -E 'NodeID|WantRunning|LoggedOut|RunSSH'
   tailscale status
   ```

4. **Re-check the things that depend on it** — that the relay still reaches every
   host on every configured path, and that a saved connectivity baseline from
   *before* the change still diffs clean.

A jump across dozens of minor versions is normally fine and preserves the state
directory, but "normally" is not "verified" — the backup costs one command.

> `tailscale debug netmap` does not exist in older clients, so on a stale relay
> you cannot read the delivered packet filter from that host. Read it from a
> *current* node instead, or from the admin console.

---

## Collector (PowerShell)

### A detector reports false while the thing it checks is demonstrably true

Two PowerShell traps produce exactly this, and both are silent because a
collector normally runs under `$ErrorActionPreference = 'SilentlyContinue'`.

**`[ref]` on an untyped `$null`.** Fails overload resolution outright — *"Cannot
find an overload for TryParseExact and the argument count: 5"* — and the error is
swallowed, leaving the value permanently false:

```powershell
$ts = $null                                  # WRONG - silently never parses
[datetime]$ts = [datetime]::MinValue         # RIGHT - typed ref binds
[datetime]::TryParseExact($s,'yyyy-MM-dd HH:mm:ss',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None,[ref]$ts)
```

**`Invoke-WebRequest .Content` is not always a string.** When the response
carries **no `Content-Type` header**, PowerShell 7 returns `.Content` as a
`System.Byte[]`, where `-match` never matches — while Windows PowerShell 5.1
returns a `String` for the identical response. Normalise rather than trust:

```powershell
$raw  = $r.Content
$body = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
```

> **Test the collector in the shell that will actually run it.** A relay invoking
> `powershell` gets 5.1; your terminal is probably `pwsh` 7. These two cases
> answer *opposite* ways in each, so testing in the wrong one ships a false green.

When a fact is not directly observable, gather **several independent signals** and
have the payload report *which ones fired*. When it later disagrees with reality,
that field is the only way to tell which detector lied.

## Performance

### Is this hammering my machines?

Measured: **~470 ms of CPU per poll**, roughly 0.4% of a 16-thread desktop at one
poll per 8s — and **only while someone has the panel open**. After 45s with no
viewer the poller goes fully dormant: zero SSH logins, zero shell processes.

If wall-time per poll is seconds, something is timing out. A dead local port
burns the *full* HTTP timeout, so the collector does a 200 ms TCP pre-check
before any localhost HTTP request. Removing that check took one poll from
0.5s to 5s.
