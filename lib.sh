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

# True when the configured forge is GitHub (default: GitLab).
mm_is_github() {
  [ "${PROVIDER:-gitlab}" = "github" ]
}

# Reference sigil for MR/PR ids: GitLab !42, GitHub #42.
mm_ref_sigil() {
  if mm_is_github; then printf '#'; else printf '!'; fi
}

# mm_glob_match <string> <globs> — print the first of the space-separated
# globs that matches <string> and succeed; fail when none does.
# Pathname expansion is off while the list is split. An unquoted
# `for g in $globs` expands "src/auth/*" against whatever directory the
# caller stands in, and the case test then compares the string with the
# names found there instead of with the glob: "src/auth/sub/x.ts" silently
# stops matching. In a case pattern `*` also matches "/", so a glob covers
# the whole subtree.
mm_glob_match() {
  local s="$1" globs="$2" g hit="" was_noglob=0
  case "$-" in *f*) was_noglob=1 ;; esac
  set -f
  for g in $globs; do
    # shellcheck disable=SC2254  # unquoted on purpose: $g is the glob
    case "$s" in $g) hit="$g"; break ;; esac
  done
  [ "$was_noglob" = 1 ] || set +f
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# True when branch $1 matches any glob in AUTO_BRANCHES (default feat-*) —
# such sources are fixed fully automatically, everything else needs approval.
mm_src_is_auto() {
  mm_glob_match "$1" "${AUTO_BRANCHES:-feat-*}" >/dev/null
}

# Squeeze foreign text (git stderr, test output) into one safe log detail:
# no ANSI, no control bytes, single line, capped — an uncapped detail would
# evict real events from the dashboard's fixed-size log tail.
mm_clean() {
  LC_ALL=C sed $'s/\033\[[0-9;]*[a-zA-Z]//g' \
    | tr -d '\000-\010\013-\037' \
    | tr '\n' ' ' | cut -c1-160
}

# Poll interval in whole seconds, sanitised: config.env is hand-edited, and
# a stray "3m" or 0 would otherwise poison every interval calculation.
mm_poll_interval() {
  local v="${POLL_INTERVAL:-180}"
  case "$v" in
    ''|*[!0-9]*) v=180 ;;
  esac
  [ "$v" -lt 30 ] && v=30
  printf '%s' "$v"
}

# Read KEY out of config file $1 without sourcing it (quotes stripped).
mm_cfg_get() {
  sed -n "s/^$2=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$1" | head -1
}
