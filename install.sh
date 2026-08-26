#!/bin/bash
# merge-medic installer: checks dependencies, seeds config.env, renders the
# launchd plist, loads it, and symlinks `mrwatch` into ~/.local/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LABEL="com.merge-medic.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL="${MERGE_MEDIC_INTERVAL:-180}"   # seconds between watcher ticks

echo "merge-medic installer"
echo "  root: $ROOT"

# ── dependencies ──────────────────────────────────────────────────────────────
missing=0
for dep in glab jq git claude; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "  MISSING: $dep"; missing=1
  fi
done
[ "$missing" = "1" ] && { echo "install the missing tools first (glab: brew install glab; claude: https://code.claude.com)"; exit 1; }
glab auth status >/dev/null 2>&1 || echo "  WARN: glab is not authenticated — run: glab auth login"

# ── config ────────────────────────────────────────────────────────────────────
if [ ! -f "$ROOT/config.env" ]; then
  cp "$ROOT/config.example.env" "$ROOT/config.env"
  echo "  created config.env from example — EDIT IT before going live:"
  echo "    $ROOT/config.env"
  echo "  (it starts in DRY_RUN=1, so loading the daemon now is safe)"
fi

chmod +x "$ROOT/watch.sh" "$ROOT/fix-mr.sh" "$ROOT/bin/mrwatch"
mkdir -p "$ROOT/logs" "$ROOT/state" "$ROOT/worktrees"

# ── mrwatch on PATH ───────────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/mrwatch" "$HOME/.local/bin/mrwatch"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  NOTE: add ~/.local/bin to your PATH" ;;
esac

# ── launchd ───────────────────────────────────────────────────────────────────
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/watch.sh</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.log</string>
</dict>
</plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "  launchd job loaded ($LABEL, every ${INTERVAL}s)"

echo
echo "Done. Next steps:"
echo "  1. edit $ROOT/config.env (project, host, verify command)"
echo "  2. watch a few DRY_RUN ticks:  mrwatch log -f"
echo "  3. set DRY_RUN=0 when happy;  mrwatch top  for the live dashboard"
