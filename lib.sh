#!/bin/bash
# merge-medic shared helpers — sourced by watch.sh and fix-mr.sh.
# Expects config.env to be sourced already (NOTIFY, NOTIFY_SOUND).

# True when running inside WSL (Linux kernel built by Microsoft).
mm_is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

# Desktop notification: osascript on macOS, Windows toast from WSL,
# notify-send on plain Linux (if present).
mm_notify() {
  [ "${NOTIFY:-0}" = "1" ] || return 0
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body//\"/\\\"}\" with title \"merge-medic\" subtitle \"${title//\"/\\\"}\" sound name \"${NOTIFY_SOUND:-Submarine}\"" >/dev/null 2>&1 || true
  elif mm_is_wsl && command -v powershell.exe >/dev/null 2>&1; then
    # notify-send inside WSL never reaches the Windows desktop — bridge to a
    # native toast via WinRT (no modules needed)
    local pt="${title//\'/\'\'}" pb="${body//\'/\'\'}"
    powershell.exe -NoProfile -Command "
      [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
      \$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
      \$t.GetElementsByTagName('text').Item(0).InnerText = 'merge-medic — ${pt}'
      \$t.GetElementsByTagName('text').Item(1).InnerText = '${pb}'
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('merge-medic').Show([Windows.UI.Notifications.ToastNotification]::new(\$t))
    " >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "merge-medic — $title" "$body" >/dev/null 2>&1 || true
  fi
}

# File size in bytes: BSD stat (macOS) or GNU stat (Linux).
mm_filesize() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# Reference sigil for MR/PR ids: GitLab !42, GitHub #42.
mm_ref_sigil() {
  if [ "${PROVIDER:-gitlab}" = "github" ]; then printf '#'; else printf '!'; fi
}
