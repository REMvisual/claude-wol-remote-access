#!/usr/bin/env bash
set -euo pipefail

# Wake Panel installer
# Usage:        curl -fsSL https://raw.githubusercontent.com/REMvisual/claude-wol-remote-access/main/install.sh | bash
# Pin version:  curl -fsSL https://raw.githubusercontent.com/REMvisual/claude-wol-remote-access/main/install.sh | bash -s v1.0.0

REPO="REMvisual/claude-wol-remote-access"
SKILL_NAME="wake-panel"
SKILL_DIR="$HOME/.claude/skills/$SKILL_NAME"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
fail() { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

VERSION="${1:-main}"
info "Installing wake-panel ($VERSION)"

command -v curl >/dev/null 2>&1 || fail "curl is required but not installed"
command -v tar  >/dev/null 2>&1 || fail "tar is required but not installed"

# The skill is a directory tree (SKILL.md, reference/, assets/), not a single
# file, so fetch the whole archive rather than curling files one by one -- that
# way adding a file upstream never silently produces a half-installed skill.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TARBALL="https://codeload.github.com/$REPO/tar.gz/$VERSION"
info "Downloading $TARBALL"
curl -fsSL "$TARBALL" -o "$TMP/src.tar.gz" || fail "Download failed. Is '$VERSION' a valid branch or tag?"
tar -xzf "$TMP/src.tar.gz" -C "$TMP" || fail "Extract failed"

# The archive extracts to <repo>-<ref>/skills/<name>, i.e. depth 3 under $TMP.
# A too-shallow -maxdepth here silently finds nothing and aborts the install.
SRC="$(find "$TMP" -maxdepth 4 -type d -path "*/skills/$SKILL_NAME" | head -n 1)"
[ -n "$SRC" ] || fail "Could not find skills/$SKILL_NAME in the archive"
[ -f "$SRC/SKILL.md" ] || fail "Archive looks wrong: no SKILL.md in $SRC"

if [ -d "$SKILL_DIR" ]; then
    BACKUP="$SKILL_DIR.backup-$(date +%Y%m%d-%H%M%S)"
    warn "Existing install found; moving it to $BACKUP"
    mv "$SKILL_DIR" "$BACKUP"
fi

mkdir -p "$(dirname "$SKILL_DIR")"
cp -R "$SRC" "$SKILL_DIR" || fail "Copy failed"

# Verify what actually landed, rather than trusting the copy's exit code.
for f in SKILL.md README.md reference/TROUBLESHOOTING.md assets/relay/app.py; do
    [ -f "$SKILL_DIR/$f" ] || fail "Install incomplete: missing $f"
done
COUNT="$(find "$SKILL_DIR" -type f | wc -l | tr -d ' ')"

info "Installed $COUNT files to $SKILL_DIR"
echo ""
echo "  Usage: type /$SKILL_NAME in Claude Code"
echo ""
echo "  Uninstall:"
echo "    curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
echo ""
