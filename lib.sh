#!/bin/bash
# merge-medic shared helpers — sourced by watch.sh and fix-mr.sh.
# Expects config.env to be sourced already (NOTIFY, NOTIFY_SOUND).

# Desktop notification: osascript on macOS, notify-send on Linux (if present).
mm_notify() {
  [ "${NOTIFY:-0}" = "1" ] || return 0
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body//\"/\\\"}\" with title \"merge-medic\" subtitle \"${title//\"/\\\"}\" sound name \"${NOTIFY_SOUND:-Submarine}\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "merge-medic — $title" "$body" >/dev/null 2>&1 || true
  fi
}

# File size in bytes: BSD stat (macOS) or GNU stat (Linux).
mm_filesize() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}
