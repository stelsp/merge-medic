#!/bin/bash
# merge-medic uninstaller: unloads launchd, removes the plist and the mrwatch
# symlink. Leaves this directory (logs/state/config) untouched.
set -euo pipefail
LABEL="com.merge-medic.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/mrwatch"
echo "merge-medic daemon removed. Directory left in place — delete it manually if you want."
