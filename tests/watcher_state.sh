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

# ── agent coexistence: worktree presence and our own pushes ─────────────────
eval "$(sed -n '/^ours_at_head() {/,/^}/p' "$ROOT/fix-mr.sh")"
eval "$(sed -n '/^branch_worktree() {/,/^}/p' "$ROOT/fix-mr.sh")"

echo
echo "agent coexistence:"
# macOS hands out /var/... from mktemp but git reports the real /private/var
AGENT_REPO="$(cd "$(mktemp -d)" && pwd -P)/repo"
git init -q "$AGENT_REPO"
git -C "$AGENT_REPO" config user.email t@t
git -C "$AGENT_REPO" config user.name t
echo base > "$AGENT_REPO/f.txt"
git -C "$AGENT_REPO" add -A
git -C "$AGENT_REPO" commit -qm base
git -C "$AGENT_REPO" branch feat-1
git -C "$AGENT_REPO" worktree add -q "$AGENT_REPO/.worktrees/feat-1" feat-1

SRC=feat-1
check "registered worktree is found" "$AGENT_REPO/.worktrees/feat-1" "$(branch_worktree "$AGENT_REPO")"

SRC=feat-nope
check "a branch with no worktree yields nothing" "" "$(branch_worktree "$AGENT_REPO")"

# a worktree the repo does not know about, at the conventional path
mkdir -p "$AGENT_REPO/.worktrees/feat-detached"
SRC=feat-detached
check "unregistered worktree found by path" "$AGENT_REPO/.worktrees/feat-detached" "$(branch_worktree "$AGENT_REPO")"

# our own merge commit must not read as somebody working
SRC=feat-1
wt="$AGENT_REPO/.worktrees/feat-1"
echo mine > "$wt/m.txt"
git -C "$wt" add -A
git -C "$wt" commit -q -m "chore: merge origin/dev into feat-1" -m "Merge-Medic-Run: 42"
git -C "$AGENT_REPO" branch -f "origin/$SRC" feat-1 2>/dev/null || true
if git -C "$wt" log -1 --format='%B' | grep -q '^Merge-Medic-Run: '; then ours=1; else ours=0; fi
check "our own commit carries the trailer" "1" "$ours"

echo agent > "$wt/a.txt"
git -C "$wt" add -A
git -C "$wt" commit -q -m "feat: an agent's own commit"
if git -C "$wt" log -1 --format='%B' | grep -q '^Merge-Medic-Run: '; then ours=1; else ours=0; fi
check "an agent's commit does not"        "0" "$ours"

# ── launch queue: a tick killed while it waits for a slot keeps its queue ───
eval "$(sed -n '/^mark_tried() /p' "$ROOT/watch.sh")"
eval "$(sed -n '/^launch_fixers() {/,/^}/p' "$ROOT/watch.sh")"

echo
echo "launch queue:"
new_state; MARK=tried; PARALLEL_FIXERS=1
LQ="$(cd "$(mktemp -d)" && pwd -P)"
# the stand-in fixer notes whether its pair was marked by the time it started
# shellcheck disable=SC2016  # the fake fixer expands $1 itself, at run time
printf 'if [ -e "%s/tried-$1" ]; then echo marked; else echo unmarked; fi > "%s/started-$1"\n' \
  "$STATE" "$LQ" > "$LQ/fix-mr.sh"
# one free slot for the first launch, busy for good after that
# shellcheck disable=SC2329,SC2317  # called from the extracted launch_fixers body
running_fixers() { if [ -e "$LQ/slot-taken" ]; then echo 1; else : > "$LQ/slot-taken"; echo 0; fi; }
# shellcheck disable=SC2329,SC2317
logc() { printf '%s\n' "$*" >> "$LQ/log"; }
echo "conflict aaa:bbb feat-1 main none u x - one" > "$STATE/mr-1"
echo "conflict ccc:ddd feat-2 main none u x - two" > "$STATE/mr-2"
targets="$(printf '1\tfeat-1\tmain\tauto\tone\n2\tfeat-2\tmain\tauto\ttwo')"
ROOT="$LQ" LOGDIR="$LQ" launch_fixers &
launcher=$!
n=0
while ! grep -q 'waiting for a slot' "$LQ/log" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
mm_kill_tree "$launcher" TERM; wait "$launcher" 2>/dev/null
check "the launched MR is marked tried"       "aaa:bbb" "$(cat "$STATE/tried-1" 2>/dev/null)"
check "…before its fixer started"             "marked" "$(cat "$LQ/started-1" 2>/dev/null)"
check "an MR still waiting for a slot is not" "0" "$(count_state 'tried-2')"
rm -rf "$LQ"

# ── watcher deadlines: a hung forge or git call ends the tick ───────────────
# watch.sh itself, in an install of its own, with stand-ins for gh, glab and
# git that answer at once, or hang on the call MM_HANG names
echo
echo "watcher deadlines:"
WD="$(cd "$(mktemp -d)" && pwd -P)"
MM="$WD/mm"
mkdir -p "$MM" "$WD/bin" "$WD/watch/.git"
cp "$ROOT/watch.sh" "$ROOT/lib.sh" "$MM/"
MM_REAL_GIT="$(command -v git)"
export MM_REAL_GIT MM_HANG MM_PRS MM_MRS
cat > "$WD/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pr list") [ "$MM_HANG" = gh-list ] && { sleep 59.4343; exit 1; }
             printf '%s' "$MM_PRS" ;;
  "api "*)   printf 'bbb\n' ;;
  *)         exit 1 ;;
esac
EOF
cat > "$WD/bin/glab" <<'EOF'
#!/bin/sh
case "$2" in
  *state=opened*) [ "$MM_HANG" = glab-list ] && { sleep 59.4343; exit 1; }
                  printf '%s' "$MM_MRS" ;;
  *)              [ "$MM_HANG" = glab-detail ] && { sleep 59.4343; exit 1; }
                  printf '{}' ;;
esac
EOF
cat > "$WD/bin/git" <<'EOF'
#!/bin/sh
case " $* " in
  *" fetch "*|*" clone "*) [ "$MM_HANG" = git-fetch ] && { sleep 59.4343; exit 1; } ;;
esac
exec "$MM_REAL_GIT" "$@"
EOF
chmod +x "$WD/bin/gh" "$WD/bin/glab" "$WD/bin/git"

# watch_config <provider> [extra lines...] — config.env is sourced after
# watch.sh sets its own PATH, so the stand-ins can still go first
watch_config() {
  local provider="$1"; shift
  {
    printf '%s\n' "export PATH=\"$WD/bin:\$PATH\"" "PROVIDER=\"$provider\"" \
      'PROJECT_PATH="test/repo"' 'NOTIFY=0' 'NET_TIMEOUT=2' 'RADAR=0' \
      'MAX_MRS_PER_RUN=3' "WATCH_REPO=\"$WD/watch\"" "GIT_REMOTE_URL=\"$WD/remote.git\""
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
  } > "$MM/config.env"
}
# tick: one watcher run, itself bounded so a regression cannot stall the suite
tick() {
  rm -rf "$MM/state" "$MM/logs" "$MM/.lock"
  SECONDS=0
  mm_timeout 20 bash "$MM/watch.sh" >/dev/null 2>&1; RC=$?
  FAST=$(( SECONDS < 12 ? 1 : 0 ))
  LAST="$(tail -1 "$MM/logs/watch.log" 2>/dev/null)"
  if pgrep -f '^sleep 59.4343' >/dev/null 2>&1; then LEFT=1; else LEFT=0; fi
  pkill -f '^sleep 59.4343' 2>/dev/null
  if [ -d "$MM/.lock" ]; then LOCKED=1; else LOCKED=0; fi
}
has() { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }
pr() { # number mergeable — one PR as gh pr list prints it
  printf '{"number":%s,"title":"t","headRefName":"feat-%s","baseRefName":"main","mergeable":"%s","isDraft":false,"headRefOid":"aaa"}' "$1" "$1" "$2"
}

watch_config github; MM_HANG=gh-list; tick
check "a hung PR listing ends the tick as a failed one does" "1" "$RC"
check "…at its deadline"                       "1" "$FAST"
check "…saying it timed out"                   "1" "$(has "$LAST" "ERROR could not list PRs — timed out after 2s")"
check "…with nothing left running"             "0/0" "$LEFT/$LOCKED"

watch_config gitlab; MM_HANG=glab-list; tick
check "a hung MR listing ends the tick the same way" "1/1/1" "$RC/$FAST/$(has "$LAST" "ERROR could not list MRs — timed out after 2s")"
check "…with nothing left running"             "0/0" "$LEFT/$LOCKED"

MM_MRS='[{"iid":5,"sha":"aaa","source_branch":"feat-5","target_branch":"main","title":"t","draft":false,"detailed_merge_status":"conflict","has_conflicts":true}]'
MM_HANG=glab-detail; tick
check "a hung MR lookup does not end the tick" "0/1/0" "$RC/$FAST/$LEFT"
check "…the MR reads unknown, as after a failed lookup" "unknown" "$(cut -d' ' -f1 "$MM/state/mr-5" 2>/dev/null)"

watch_config github 'RADAR=1'; MM_PRS="[$(pr 7 MERGEABLE),$(pr 8 MERGEABLE)]"; MM_HANG=git-fetch; tick
check "a hung radar fetch does not end the tick" "0/1/0" "$RC/$FAST/$LEFT"
check "…which still reports"                   "1" "$(has "$LAST" "TICK 2 open")"

watch_config github 'DRY_RUN=0'; MM_PRS="[$(pr 7 CONFLICTING)]"; MM_HANG=git-fetch; tick
check "a hung fetch before launching ends the tick" "1/1/0" "$RC/$FAST/$LEFT"
check "…saying it timed out"                   "1" "$(has "$LAST" "ERROR git fetch timed out after 2s")"
if [ -e "$MM/logs/fixer-7.log" ]; then fx=1; else fx=0; fi
check "…and launches no fixer"                 "0" "$fx"
rm -rf "$WD"

[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
