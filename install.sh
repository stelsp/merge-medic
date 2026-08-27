#!/bin/bash
# merge-medic installer: checks dependencies, seeds config.env, sets up the
# scheduler (launchd on macOS, systemd user timer on Linux), and symlinks
# `mrwatch` into ~/.local/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INTERVAL="${MERGE_MEDIC_INTERVAL:-180}"   # seconds between watcher ticks
OS="$(uname -s)"

echo "merge-medic installer"
echo "  root: $ROOT  os: $OS"

# ── dependencies ──────────────────────────────────────────────────────────────
missing=0
for dep in glab jq git claude; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "  MISSING: $dep"; missing=1
  fi
done
[ "$missing" = "1" ] && { echo "install the missing tools first (glab: https://gitlab.com/gitlab-org/cli; claude: https://code.claude.com)"; exit 1; }
glab auth status >/dev/null 2>&1 || echo "  WARN: glab is not authenticated — run: glab auth login"
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
if [ "$IS_WSL" = "1" ]; then
  echo "  detected WSL — notifications bridge to Windows toasts via powershell.exe"
elif [ "$OS" = "Linux" ] && ! command -v notify-send >/dev/null 2>&1; then
  echo "  NOTE: notify-send not found — desktop notifications will be silent"
fi

# ── config ────────────────────────────────────────────────────────────────────
if [ ! -f "$ROOT/config.env" ]; then
  cp "$ROOT/config.example.env" "$ROOT/config.env"
  echo "  created config.env from example — EDIT IT before going live:"
  echo "    $ROOT/config.env"
  echo "  (it starts in DRY_RUN=1, so enabling the scheduler now is safe)"
fi

chmod +x "$ROOT/watch.sh" "$ROOT/fix-mr.sh" "$ROOT/bin/mrwatch"
mkdir -p "$ROOT/logs" "$ROOT/state" "$ROOT/worktrees"

# ── mrtop (optional Go TUI; bash `mrwatch top` is the fallback) ───────────────
if command -v go >/dev/null 2>&1; then
  if (cd "$ROOT" && make build >/dev/null 2>&1); then
    echo "  built bin/mrtop (Go TUI dashboard)"
  else
    echo "  WARN: mrtop build failed — bash dashboard will be used"
  fi
else
  echo "  NOTE: Go not found — mrwatch top uses the bash dashboard (install Go and re-run for mrtop)"
fi

# ── mrwatch on PATH ───────────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/mrwatch" "$HOME/.local/bin/mrwatch"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  NOTE: add ~/.local/bin to your PATH" ;;
esac

# ── scheduler ─────────────────────────────────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
  LABEL="com.merge-medic.watch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
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
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.log</string>
</dict>
</plist>
PL
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "  launchd job loaded ($LABEL, every ${INTERVAL}s)"
elif [ "$OS" = "Linux" ]; then
  # WSL ships with systemd disabled by default — without it the user timer
  # cannot run, so fail with the exact fix instead of a cryptic systemctl error
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    if [ "$IS_WSL" = "1" ]; then
      echo "  ERROR: systemd is not running in this WSL distro."
      # shellcheck disable=SC2028  # the \n must stay literal — it's part of the command we print
      echo "  Enable it:  printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf"
      echo "  then from Windows:  wsl --shutdown   — and re-run ./install.sh"
    else
      echo "  ERROR: systemd user session unavailable — run watch.sh from cron instead:"
      echo "    */3 * * * * /bin/bash $ROOT/watch.sh"
    fi
    exit 1
  fi
  UNITDIR="$HOME/.config/systemd/user"
  mkdir -p "$UNITDIR"
  cat > "$UNITDIR/merge-medic.service" <<UNIT
[Unit]
Description=merge-medic MR conflict watcher tick

[Service]
Type=oneshot
ExecStart=/bin/bash $ROOT/watch.sh
# fixers are launched detached by watch.sh and must outlive the tick
KillMode=process
UNIT
  cat > "$UNITDIR/merge-medic.timer" <<UNIT
[Unit]
Description=merge-medic watcher schedule

[Timer]
OnBootSec=${INTERVAL}s
OnUnitActiveSec=${INTERVAL}s

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now merge-medic.timer
  echo "  systemd user timer enabled (merge-medic.timer, every ${INTERVAL}s)"
else
  echo "  WARN: unsupported OS '$OS' — run watch.sh from your own scheduler"
fi

echo
echo "Done. Next steps:"
echo "  1. edit $ROOT/config.env (project, host, verify command)"
echo "  2. watch a few DRY_RUN ticks:  mrwatch log -f"
echo "  3. set DRY_RUN=0 when happy;  mrwatch top  for the live dashboard"
