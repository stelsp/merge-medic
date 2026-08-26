#!/bin/bash
# merge-medic uninstaller: removes the scheduler and the mrwatch symlink.
# Leaves this directory (logs/state/config) untouched.
set -euo pipefail
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  LABEL="com.merge-medic.watch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
elif [ "$OS" = "Linux" ]; then
  systemctl --user disable --now merge-medic.timer 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/merge-medic.service" \
        "$HOME/.config/systemd/user/merge-medic.timer"
  systemctl --user daemon-reload 2>/dev/null || true
fi
rm -f "$HOME/.local/bin/mrwatch"
echo "merge-medic scheduler removed. Directory left in place — delete it manually if you want."
