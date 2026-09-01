#!/bin/bash
# Regression harness for the watcher's unattended state decisions — the ones
# that delete files or spend money. Run: bash tests/watcher_state.sh
# shellcheck disable=SC2034  # the guards below are read by sweep_closed
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fails=0
# count_state <glob> — how many state files match, glob-based (no ls|grep)
count_state() {
  local n=0 f
  for f in "$STATE"/$1; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

check() { # description expected actual
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: want %s, got %s\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

# the real function, the real helpers it leans on
# shellcheck source=lib.sh disable=SC1091
source "$ROOT/lib.sh"
eval "$(sed -n '/^sweep_closed() {/,/^}/p' "$ROOT/watch.sh")"
# shellcheck disable=SC2329,SC2317  # called from the extracted sweep_closed body
#                                    (the two shellcheck versions disagree on the code)
logc() { :; }

# state files are seeded "now", so the grace period would spare them all;
# age them past it the way a real closed MR ages
age_out() { find "$STATE" -maxdepth 1 -type f -exec touch -t 202001010000 {} + ; }

new_state() { STATE="$(mktemp -d)"; }
seed() { # iid
  : > "$STATE/mr-$1"; : > "$STATE/tried-$1"; : > "$STATE/approve-$1"
  : > "$STATE/progress-$1.log"; : > "$STATE/plan-$1.md"
}

echo "sweep_closed:"

# a complete listing sweeps what is missing and keeps what is open
new_state; seed 7; seed 8
OPEN_IIDS=" 8 "; LIST_COMPLETE=1; LIST_CAP=500
age_out; : > "$STATE/mr-8"; : > "$STATE/tried-8"; : > "$STATE/approve-8"
: > "$STATE/progress-8.log"; : > "$STATE/plan-8.md"
sweep_closed
check "closed MR removed"        "0" "$(count_state 'mr-7')"
check "closed MR's approve gone" "0" "$(count_state 'approve-7')"
check "closed MR's plan gone"    "0" "$(count_state 'plan-7.md')"
check "open MR untouched"        "5" "$(count_state '*-8*')"

# a truncated listing must sweep nothing: everything behind the cap would
# otherwise look closed — losing approvals, plans and dedup marks
new_state; seed 7
OPEN_IIDS=" 8 "; LIST_COMPLETE=0; LIST_CAP=500
sweep_closed
check "truncated listing sweeps nothing" "5" "$(count_state '*-7*')"

# no open MRs at all is a legitimate answer, and must still clean up
new_state; seed 7
OPEN_IIDS=" "; LIST_COMPLETE=1; LIST_CAP=500
age_out
sweep_closed
check "empty listing still sweeps" "0" "$(count_state '*-7*')"

# ids must match whole, not as substrings
new_state; seed 1; seed 10; seed 101
OPEN_IIDS=" 10 "; LIST_COMPLETE=1; LIST_CAP=500
age_out; : > "$STATE/mr-10"
sweep_closed
check "id 1 swept"        "0" "$(count_state 'mr-1')"
check "id 10 kept"        "1" "$(count_state 'mr-10')"
check "id 101 swept"      "0" "$(count_state 'mr-101')"

# a freshly refreshed file survives one absent listing (an empty-but-successful
# response must not wipe everything at once)
new_state; seed 7
OPEN_IIDS=" "; LIST_COMPLETE=1; LIST_CAP=500
sweep_closed
check "grace spares a just-refreshed MR" "5" "$(count_state '*-7*')"

# a running fixer keeps its whole state, archive source included
new_state; seed 7; age_out
bash -c 'exec -a "bash fix-mr.sh 7 feat main" sleep 5' &
sleeper=$!
sleep 0.3
OPEN_IIDS=" "; LIST_COMPLETE=1; LIST_CAP=500
sweep_closed
check "live fixer's state kept" "5" "$(count_state '*-7*')"
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null


# ── defer: the marker holds the retry time, not the defer time ───────────────
eval "$(sed -n '/^defer_gate() {/,/^}/p' "$ROOT/watch.sh")"
SK_DEFER=0; verbose=0; MARK=tried
# shellcheck disable=SC2329,SC2317  # invoked from the extracted defer_gate body
skip_once() { SKIPPED="$3"; return 0; }

echo
echo "defer gate:"
new_state; now=$(date +%s)

SKIPPED=""; echo "$((now + 240))" > "$STATE/deferred-7"
defer_gate 7 || true
check "hot branch stays deferred" "1" "$(count_state 'deferred-7')"
case "$SKIPPED" in *"retrying in 4m"*) ok=1 ;; *) ok=0 ;; esac
check "skip line names the wait" "1" "$ok"

SKIPPED=""; echo "$((now - 10))" > "$STATE/deferred-8"; : > "$STATE/tried-8"
defer_gate 8 || true
check "elapsed cool-off clears the marker" "0" "$(count_state 'deferred-8')"
check "and clears the dedup mark"          "0" "$(count_state 'tried-8')"

# markers written by an older fixer hold the defer time, always in the past
SKIPPED=""; echo "$((now - 3600))" > "$STATE/deferred-9"
defer_gate 9 || true
check "legacy marker does not wedge" "0" "$(count_state 'deferred-9')"

SKIPPED=""; printf 'garbage' > "$STATE/deferred-10"
defer_gate 10 || true
check "corrupt marker does not wedge" "0" "$(count_state 'deferred-10')"

[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
