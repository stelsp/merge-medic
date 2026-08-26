#!/bin/bash
# merge-medic fixer for a single MR: worktree → merge target → (AI only when
# there are real conflict markers) → verify → push. Every phase is appended to
# state/progress-<iid>.log so `mrwatch top` can draw live progress bars.
# Launched by watch.sh (capped by PARALLEL_FIXERS).
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
ROOT="$(cd "$(dirname "$SELF")" && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck source=/dev/null
source "$ROOT/config.env"
# shellcheck source=lib.sh
source "$ROOT/lib.sh"

IID="$1"; SRC="$2"; TGT="$3"
SIGIL="$(mm_ref_sigil)"
PROG="$ROOT/state/progress-$IID.log"
LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR" "$ROOT/worktrees" "$ROOT/state"
WT="$ROOT/worktrees/wt-$IID"

ev() { printf '%s|%s|%s\n' "$(date +%s)" "$1" "${2:-}" >> "$PROG"; }
notify() { mm_notify "$@"; }
cleanup_wt() { git -C "$WATCH_REPO" worktree remove --force "$WT" 2>/dev/null || true; }
fail() {
  ev FAIL "$1"
  notify "${SIGIL}$IID: fix failed" "$1"
  cleanup_wt
  exit 1
}

: > "$PROG"
ev START "$SRC -> $TGT"

cd "$WATCH_REPO"
git fetch --prune --quiet origin || fail "git fetch failed"

ev WORKTREE "$WT"
cleanup_wt
git worktree add --force "$WT" -B "$SRC" "origin/$SRC" >/dev/null 2>&1 \
  || fail "worktree add failed (branch held by another worktree?)"
cd "$WT"

ev MERGE "origin/$TGT"
if git merge --no-ff --no-edit -m "chore: merge origin/$TGT into $SRC (${SIGIL}$IID)" "origin/$TGT" >/dev/null 2>&1; then
  ev MERGE_CLEAN "no conflict markers — AI not needed (0 tokens)"
else
  conflicts="$(git diff --name-only --diff-filter=U)"
  [ -z "$conflicts" ] && fail "merge failed without conflicting files"
  n="$(printf '%s\n' "$conflicts" | grep -c .)"

  # ── AI budget (atomic via mkdir lock) ───────────────────────────────────────
  today="$(date '+%Y-%m-%d')"; BUDGET_FILE="$ROOT/state/budget-$today"
  BLOCK="$ROOT/state/.budget.lock"
  until mkdir "$BLOCK" 2>/dev/null; do sleep 0.2; done
  spent="$(cat "$BUDGET_FILE" 2>/dev/null || echo 0)"
  if [ "$spent" -ge "${DAILY_AGENT_RUNS:-6}" ]; then
    rmdir "$BLOCK"; git merge --abort 2>/dev/null || true
    fail "daily AI budget exhausted ($spent/${DAILY_AGENT_RUNS:-6})"
  fi
  echo $((spent + 1)) > "$BUDGET_FILE"; rmdir "$BLOCK"

  ev AI_RESOLVE "$n file(s): $(printf '%s' "$conflicts" | tr '\n' ' ' | cut -c1-120)"
  AILOG="$LOGDIR/ai-$IID-$(date '+%Y%m%d-%H%M%S').log"
  set +e
  claude -p "You are resolving git merge conflicts in a worktree (branch $SRC, origin/$TGT merged in, ${SIGIL}$IID).

Conflicting files:
$conflicts

Rules:
- Resolve ALL conflict markers (<<<<<<< ======= >>>>>>>), preserving the intent of both sides; when in doubt, prefer $SRC for its own feature code and $TGT for everything else.
- Do not rewrite anything outside the conflicted hunks. No refactoring.
- After editing: git add each resolved file. Do NOT commit, do NOT push.
- Finish with a short text summary of what you resolved and how." \
    --model "${CLAUDE_MODEL:-opus}" \
    --permission-mode acceptEdits \
    --allowedTools "Read Edit Write Glob Grep Bash(git:*)" \
    --disallowedTools "WebFetch WebSearch Bash(curl:*) Bash(rm:*) Bash(git push:*)" \
    --add-dir "$WT" \
    --output-format text >> "$AILOG" 2>&1
  rc=$?
  set -e
  [ "$rc" != "0" ] && fail "claude exited with code $rc (log: ${AILOG##*/})"
  [ -n "$(git diff --name-only --diff-filter=U)" ] && fail "unresolved files remain"
  if grep -rl '^<<<<<<< ' $conflicts 2>/dev/null | head -1 | grep -q .; then
    fail "conflict markers remain"
  fi
  git add -A
  git commit --no-edit >/dev/null 2>&1 \
    || git commit -m "chore: merge origin/$TGT into $SRC (${SIGIL}$IID)" >/dev/null
fi

ev VERIFY "${VERIFY_CMD:-<skipped>}"
if [ -n "${VERIFY_CMD:-}" ]; then
  ( eval "$VERIFY_CMD" ) >> "$LOGDIR/fixer-$IID.log" 2>&1 || fail "verify red (fixer-$IID.log)"
fi

ev PUSH "origin $SRC"
git push origin "HEAD:$SRC" >/dev/null 2>&1 || fail "push rejected (branch moved ahead?)"

ev DONE "merged origin/$TGT, verify green, pushed"
notify "${SIGIL}$IID fixed ✓" "$SRC: merge $TGT + verify + push"
cleanup_wt
