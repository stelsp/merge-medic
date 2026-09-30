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

# mm_tree_pids <pid> — the process and everything it started, children first.
mm_tree_pids() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do mm_tree_pids "$c"; done
  printf '%s\n' "$1"
}

# mm_kill_tree <pid> <signal> — signal a process and everything it started.
# The tree is listed before the first signal: a child whose parent dies is
# re-parented, and a walk that starts from the dead parent no longer finds it.
mm_kill_tree() {
  local p
  for p in $(mm_tree_pids "$1"); do kill "-$2" "$p" 2>/dev/null || true; done
}

# mm_stop_tree <pid>... — stop processes and everything they started: TERM,
# up to 5s to exit, then KILL for whatever is still there (a step that traps
# TERM, a docker CLI waiting on its container). Returns once all are gone.
mm_stop_tree() {
  local root pids="" p n=0 alive
  for root in "$@"; do pids="$pids $(mm_tree_pids "$root" | tr '\n' ' ')"; done
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$n" -lt 25 ]; do
    alive=0
    for p in $pids; do if kill -0 "$p" 2>/dev/null; then alive=1; break; fi; done
    [ "$alive" = 0 ] && return 0
    sleep 0.2; n=$((n + 1))
  done
  for p in $pids; do kill -0 "$p" 2>/dev/null && mm_kill_tree "$p" KILL; done
  return 0
}

# mm_timeout <seconds> <command...> — run the command (a function works too);
# if it is still running after <seconds>, stop it and everything it started
# (mm_stop_tree) before returning 124, GNU timeout's code. Otherwise returns
# the command's own status. Empty or 0 seconds = no limit.
# macOS ships no timeout(1), and timeout(1) could not run a shell function.
# The command runs in the background, so its stdin is /dev/null — nothing a
# fixer runs unattended should be waiting for input anyway.
mm_timeout() {
  local secs="$1" fired pid wd rc=0
  shift
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  if [ "$secs" -eq 0 ]; then "$@"; return; fi
  fired="$(mktemp "${TMPDIR:-/tmp}/mm-timeout.XXXXXX")" && rm -f "$fired"
  "$@" &
  pid=$!
  # The watchdog fires only if its sleep ran out AND the command is still
  # there: when the command finishes first, the sleep is killed, and the
  # `&&` chain must stop right there instead of reporting a timeout.
  # It must not hold the caller's stdout either: inside $( ) that would keep
  # the substitution waiting for the full deadline.
  ( sleep "$secs" && kill -0 "$pid" 2>/dev/null && : > "$fired" && mm_stop_tree "$pid" ) \
    >/dev/null 2>&1 &
  wd=$!
  # (2>/dev/null: bash's own "Terminated" job notice, not the command's output)
  wait "$pid" 2>/dev/null || rc=$?
  if [ -e "$fired" ]; then
    # timed out: let the watchdog finish, so nothing the step started is
    # still running (or still writing into its worktree) when we return
    wait "$wd" 2>/dev/null || true
    rm -f "$fired"
    return 124
  fi
  mm_kill_tree "$wd" TERM
  wait "$wd" 2>/dev/null || true
  rm -f "$fired"
  return "$rc"
}

# mm_secs <value> <default> — a deadline from hand-edited config: a whole
# number of seconds, 0 for none. Anything else ("15m", "1.5", empty) falls
# back to the default instead of silently meaning "no deadline".
mm_secs() {
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# mm_fixer_count <root> — how many fixers are running. A fixer forks while it
# works (a gate's subshell, mm_timeout's job and watchdog), and every fork
# carries the fixer's command line, so counting pgrep matches would count one
# fixer several times. Only processes whose parent is not itself a fixer are
# counted.
mm_fixer_count() {
  local pids p pp n=0
  pids=" $(pgrep -f "$1/fix-mr.sh" 2>/dev/null | tr '\n' ' ')"
  for p in $pids; do
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$pids" in *" $pp "*) ;; *) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
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
