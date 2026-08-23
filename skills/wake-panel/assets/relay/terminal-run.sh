#!/bin/sh
# terminal-run.sh - optional break-glass web terminal on the relay host.
#
# Serves a real shell in the browser. Purpose: when every managed machine is
# down, you still have a shell inside the network to hand-build commands from.
#
# Run this ON the relay host. It needs no root: if the account can reach the
# container socket it already has everything required.
#
# ---------------------------------------------------------------------------
# TWO MODES. proxy is the default and the better design.
#
#   MODE=proxy       ttyd binds LOOPBACK with --base-path, and your panel
#     (default)      reverse-proxies /terminal to it behind the panel's own
#                    auth. No tailnet ACL change is ever needed, there is one
#                    URL and one login, ttyd is unreachable from the network,
#                    and NO ttyd credential exists -- so no plaintext sits in
#                    `ps` or `docker inspect`. Requires a WebSocket-aware proxy
#                    route in the relay; see reference/TROUBLESHOOTING.md.
#
#   MODE=standalone  ttyd binds the tailnet interface on its own port behind
#                    HTTP basic auth. No relay changes needed, but that port
#                    needs a tailnet ACL grant before it is reachable at all,
#                    and the credential is a command-line argument, so it is
#                    visible on the host. Fails closed: no credential file
#                    means it refuses to start.
# ---------------------------------------------------------------------------
#
# THREE FLAGS ARE LOAD-BEARING IN BOTH MODES. Each cost real debugging time:
#
#   --writable        ttyd is READ-ONLY by default. Without this the terminal
#                     renders, paints a prompt, and silently eats keystrokes --
#                     which reads as a broken deploy.
#
#   bash, no flags    NEVER pass `-i` to the child command. `-i` is ttyd's own
#                     short flag for --interface; its parser grabs it even after
#                     the command, finds no argument, and SEGFAULTS -- exit 139
#                     with a completely EMPTY log. ttyd gives bash a PTY, so
#                     bash is already interactive and reads /root/.bashrc by
#                     itself. No flags needed.
#
#   || true           on `apk add`, so a relay with no internet still gets a
#                     BusyBox shell instead of a crash loop.
#
# And in proxy mode specifically:
#
#   --base-path       without it ttyd serves its assets and websocket from /,
#                     so the page loads through the proxy and the websocket
#                     then 404s.
set -e

# --- config -----------------------------------------------------------------
MODE=${MODE:-proxy}                 # proxy | standalone
NAME=${NAME:-wake-terminal}
PORT=${PORT:-7681}
BASE=${BASE:-/terminal}             # proxy mode only
IFACE=${IFACE:-tailscale0}          # standalone only; `ip -br addr` to confirm
IMAGE=${IMAGE:-alpine:3.20}
CFG=${CFG:-$HOME/.terminal}
CRED_FILE="$CFG/credential"
RELAY_CONTAINER=${RELAY_CONTAINER:-wakepanel}

# Container Station / Docker Desktop / plain docker all differ. Prefer PATH,
# fall back to the QNAP Container Station location.
if command -v docker >/dev/null 2>&1; then
    D=$(command -v docker)
else
    D=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker
fi
[ -x "$D" ] || { echo "no container engine found (tried PATH and $D)"; exit 1; }

case "$MODE" in
  proxy)
    TTYD_ARGS="--interface lo --port $PORT --base-path $BASE --writable"
    WHERE="127.0.0.1:${PORT}${BASE}   (reach it at <panel-url>${BASE}/)"
    ;;
  standalone)
    # Fail closed: no credential must mean REFUSE TO START, never "serve an
    # unauthenticated root shell".
    if [ ! -s "$CRED_FILE" ]; then
        echo "REFUSING TO START: no credential at $CRED_FILE"
        echo "Set one with assets/tools/set-terminal-password.ps1, or use the"
        echo "default MODE=proxy, which needs no credential at all."
        exit 1
    fi
    CRED=$(cat "$CRED_FILE")
    case "$CRED" in
        *:*) ;;
        *) echo "REFUSING TO START: credential must be in user:pass form"; exit 1 ;;
    esac
    TTYD_ARGS="--interface $IFACE --port $PORT --writable --credential $CRED"
    WHERE="${IFACE}:${PORT}"
    ;;
  *)
    echo "MODE must be 'proxy' or 'standalone' (got: $MODE)"; exit 1 ;;
esac

# --- (re)launch -------------------------------------------------------------
"$D" rm -f "$NAME" >/dev/null 2>&1 || true

# --pid host + --privileged + -v /:/host make `nas` (below) a genuine root shell
# on the host via nsenter. Mounting the container socket alone already grants
# host root, so these add convenience rather than exposure -- but be honest that
# whatever auth sits in front of this is all that stands before it.
"$D" run -d \
  --name "$NAME" \
  --network host \
  --pid host \
  --privileged \
  --restart unless-stopped \
  -v /:/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TERM=xterm-256color \
  -e TTYD_ARGS="$TTYD_ARGS" \
  -e RELAY_CONTAINER="$RELAY_CONTAINER" \
  "$IMAGE" \
  sh -c '
    # The container is deliberately the toolbox: a NAS BusyBox userland
    # typically has no nc, no python3, no dig. This does.
    apk add --no-cache ttyd bash openssh-client bind-tools iproute2 \
        nmap tcpdump curl util-linux docker-cli ethtool >/dev/null 2>&1 || true

    # Short aliases matter more than they look: on a phone, typing one word
    # beats pasting a long line that wraps and gets submitted in two halves.
    cat > /root/.bashrc <<RC
alias nas="nsenter -t 1 -m -u -n -i -p -- sh"
alias relaylog="docker logs --tail 60 -f $RELAY_CONTAINER"
PS1="terminal:\w# "
echo "break-glass terminal - container toolbox, host root fs at /host"
echo "  nas       real root shell on the relay host itself"
echo "  relaylog  follow the relay log"
echo "  tools     ssh nmap dig tcpdump curl ip ethtool docker"
RC

    exec ttyd $TTYD_ARGS bash
  '

echo "started $NAME ($MODE mode) on $WHERE"
echo
echo "VERIFY BEFORE TRUSTING IT:"
echo "  1. $D inspect $NAME --format 'state={{.State.Status}} restarts={{.RestartCount}}'"
echo "     (a crash loop still gives 'docker run' a zero exit code)"
echo "  2. netstat -tln | grep :$PORT"
echo "       proxy      -> 127.0.0.1 ONLY"
echo "       standalone -> the tailnet address ONLY, never 0.0.0.0"
echo "  3. an unauthenticated request is refused, AND one with WRONG credentials"
echo "     is also refused. Prove the guard can actually say no."
echo "  4. reachable from the phone. In standalone mode a tailnet ACL does NOT"
echo "     grant a new port automatically - until you add it this HANGS rather"
echo "     than refusing, which is the main reason to prefer proxy mode."
