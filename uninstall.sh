#!/bin/bash
# merge-medic uninstaller: removes the scheduler and the mrwatch symlink.
# Leaves this directory (logs/state/config) untouched.
set -euo pipefail
OS="$(uname -s)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INST="$(basename "$ROOT")"; INST="${INST#.}"
if [ "$OS" = "Darwin" ]; then
  LABEL="com.$INST.watch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
elif [ "$OS" = "Linux" ]; then
  systemctl --user disable --now "$INST.timer" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$INST.service" \
        "$HOME/.config/systemd/user/$INST.timer"
  systemctl --user daemon-reload 2>/dev/null || true
fi
MRW="mrwatch"
if [ "$INST" != "merge-medic" ]; then
  SUF="${INST#merge-medic}"; SUF="${SUF#-}"
  MRW="mrwatch-${SUF:-$INST}"
fi
rm -f "$HOME/.local/bin/$MRW"
echo "merge-medic scheduler removed. Directory left in place — delete it manually if you want."
