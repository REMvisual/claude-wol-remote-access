#!/bin/sh
# terminal-run.sh - optional break-glass web terminal on the relay host.
#
# Serves a real shell in the browser, bound ONLY to the tailnet interface and
# behind HTTP basic auth. Purpose: when every managed machine is down, you still
# have a shell inside the network to hand-build commands from.
#
# Run this ON the relay host. It needs no root: if the account can reach the
# container socket it already has everything required.
#
# ---------------------------------------------------------------------------
# FOUR THINGS BELOW ARE LOAD-BEARING. Each cost real debugging time:
#
#   --interface $IFACE   binds the tailnet address only. Without it ttyd
#                        listens on 0.0.0.0 and a root shell is exposed to the
#                        whole LAN. VERIFY with netstat; do not trust the flag.
#
#   --writable           ttyd is READ-ONLY by default. Without this the terminal
#                        renders, paints a prompt, and silently eats keystrokes
#                        -- which reads as a broken deploy.
#
#   bash (no flags)      NEVER pass `-i` to the child command. `-i` is ttyd's
#                        own short flag for --interface; its parser grabs it
#                        even after the command, finds no argument, and
#                        SEGFAULTS -- exit 139 with a completely EMPTY log.
#                        ttyd gives bash a PTY, so bash is already interactive
#                        and reads /root/.bashrc on its own. No flags needed.
#
#   || true on apk add   a relay with no internet still gets a BusyBox shell
#                        instead of a crash loop.
# ---------------------------------------------------------------------------
#
# SECURITY POSTURE, stated plainly: ttyd takes its credential as a COMMAND-LINE
# ARGUMENT, so unlike the panel's scrypt hash the relay must hold the plaintext,
# and it is visible in `ps` / `docker inspect` on this host. Anyone who can read
# those already has a shell here, so the marginal exposure is small -- but it
# means the TAILNET ACL IS THE PRIMARY BOUNDARY and this password is the second
# layer. Scope the ACL to specific devices accordingly.
set -e

# --- config -----------------------------------------------------------------
NAME=${NAME:-wake-terminal}
PORT=${PORT:-7681}
IFACE=${IFACE:-tailscale0}          # tailnet interface; `ip -br addr` to confirm
IMAGE=${IMAGE:-alpine:3.20}
CFG=${CFG:-$HOME/.terminal}
CRED_FILE="$CFG/credential"

# Container Station / Docker Desktop / plain docker all differ. Prefer PATH,
# fall back to the QNAP Container Station location.
if command -v docker >/dev/null 2>&1; then
    D=$(command -v docker)
else
    D=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker
fi
[ -x "$D" ] || { echo "no container engine found (tried PATH and $D)"; exit 1; }

# --- fail closed ------------------------------------------------------------
# No credential must mean REFUSE TO START, never "serve an unauthenticated
# root shell". Same rule as the panel.
if [ ! -s "$CRED_FILE" ]; then
    echo "REFUSING TO START: no credential at $CRED_FILE"
    echo "Set one first (see assets/tools/set-terminal-password.ps1)."
    exit 1
fi
CRED=$(cat "$CRED_FILE")
case "$CRED" in
    *:*) ;;
    *) echo "REFUSING TO START: credential must be in user:pass form"; exit 1 ;;
esac

# --- (re)launch -------------------------------------------------------------
"$D" rm -f "$NAME" >/dev/null 2>&1 || true

# --pid host + --privileged + -v /:/host make `nas` (below) a genuine root shell
# on the host via nsenter. Mounting the container socket alone already grants
# host root, so these add convenience rather than exposure -- but be honest that
# the ACL plus one password is all that stands in front of it.
"$D" run -d \
  --name "$NAME" \
  --network host \
  --pid host \
  --privileged \
  --restart unless-stopped \
  -v /:/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TERM=xterm-256color \
  -e TTYD_CRED="$CRED" \
  -e TTYD_IFACE="$IFACE" \
  -e TTYD_PORT="$PORT" \
  "$IMAGE" \
  sh -c '
    # The container is deliberately the toolbox: a NAS BusyBox userland
    # typically has no nc, no python3, no dig. This does.
    apk add --no-cache ttyd bash openssh-client bind-tools iproute2 \
        nmap tcpdump curl util-linux docker-cli ethtool >/dev/null 2>&1 || true

    cat > /root/.bashrc <<"RC"
alias nas="nsenter -t 1 -m -u -n -i -p -- sh"
alias relaylog="docker logs --tail 60 -f wakepanel"
PS1="terminal:\w# "
echo "break-glass terminal - container toolbox, host root fs at /host"
echo "  nas       real root shell on the relay host itself"
echo "  relaylog  follow the wake-panel relay log"
echo "  tools     ssh nmap dig tcpdump curl ip ethtool docker"
RC

    exec ttyd --interface "$TTYD_IFACE" --port "$TTYD_PORT" --writable \
         --credential "$TTYD_CRED" bash
  '

echo "started $NAME on ${IFACE}:${PORT}"
echo
echo "VERIFY BEFORE TRUSTING IT -- all four:"
echo "  1. $D inspect $NAME --format 'state={{.State.Status}} restarts={{.RestartCount}}'"
echo "     (a crash loop still gives 'docker run' a zero exit code)"
echo "  2. netstat -tln | grep :$PORT     -> tailnet address ONLY, never 0.0.0.0"
echo "  3. curl -so /dev/null -w '%{http_code}\\n' http://<tailnet-ip>:$PORT/   -> 401"
echo "     and again with WRONG credentials -> still 401 (prove it refuses)"
echo "  4. reachable from the phone. A tailnet ACL does NOT grant a new port"
echo "     automatically -- until you add it this hangs rather than refusing."
