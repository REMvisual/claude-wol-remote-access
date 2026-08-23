#!/usr/bin/env bash
set -euo pipefail

# Wake Panel uninstaller

SKILL_NAME="wake-panel"
SKILL_DIR="$HOME/.claude/skills/$SKILL_NAME"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }

if [ -d "$SKILL_DIR" ]; then
    rm -rf "$SKILL_DIR"
    info "Removed $SKILL_DIR"
else
    info "$SKILL_DIR not found (already removed?)"
fi

# Installs made by install.sh leave timestamped backups behind. Report them
# rather than deleting: they are the user's previous versions, not our litter.
BACKUPS="$(find "$(dirname "$SKILL_DIR")" -maxdepth 1 -name "$SKILL_NAME.backup-*" 2>/dev/null || true)"
if [ -n "$BACKUPS" ]; then
    warn "Previous versions kept (remove manually if you want them gone):"
    echo "$BACKUPS" | sed 's/^/    /'
fi

info "Uninstall complete. /$SKILL_NAME is no longer available."
echo ""
echo "  Note: this removes the Claude Code skill only. Anything you deployed to"
echo "  a relay host or target machines is left untouched."
echo ""
