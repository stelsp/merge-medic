#!/bin/bash
# merge-medic fixer for a single MR: worktree → merge target (zdiff3 markers)
# → (AI only when there are real conflict markers, with intent context from
# both sides' history) → verify → tests → regression → push. Every phase is
# appended to state/progress-<iid>.log so the dashboards can draw progress.
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

IID="$1"; SRC="$2"; TGT="$3"; TITLE="${4:-}"; MODE="${5:-auto}"
SIGIL="$(mm_ref_sigil)"
PROG="$ROOT/state/progress-$IID.log"
LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR" "$ROOT/worktrees" "$ROOT/state"
WT="$ROOT/worktrees/wt-$IID"
ESCFILE=".merge-medic-escalate"
SUMFILE=".merge-medic-summary"

ev() { printf '%s|%s|%s\n' "$(date +%s)" "$1" "${2:-}" >> "$PROG"; }
notify() { mm_notify "$@"; }
cleanup_wt() { git -C "$WATCH_REPO" worktree remove --force "$WT" 2>/dev/null || true; }
# Durable all-time ledger (progress files get overwritten per run):
# ts|iid|OUTCOME|mode  where mode = none|clean|ai
resolve_mode="none"
# Durable outcome ledger + per-run phase archive (state/runs/<iid>-<ts>.log)
# so dashboards can show full history for every MR.
ledger() {
  local lts; lts="$(date +%s)"
  printf '%s|%s|%s|%s\n' "$lts" "$IID" "$1" "$resolve_mode" >> "$ROOT/state/history.log"
  mkdir -p "$ROOT/state/runs"
  cp "$PROG" "$ROOT/state/runs/$IID-$lts.log" 2>/dev/null || true
}
fail() {
  ev FAIL "$1"; ledger FAIL
  notify "${SIGIL}$IID: fix failed" "$1"
  cleanup_wt
  exit 1
}
escalate() {
  ev ESCALATED "$1"; ledger ESCALATED
  notify "${SIGIL}$IID: needs human" "$1"
  post_note "merge-medic: conflict escalated to a human — $1"
  cleanup_wt
  exit 2
}

# Comment on the MR/PR (POST_RESOLUTION_NOTE=1). Never fatal, but failures
# land in the fixer log — a silently lost note is a blind spot.
post_note() {
  [ "${POST_RESOLUTION_NOTE:-0}" = "1" ] || return 0
  local body="$1"
  {
    if [ "${PROVIDER:-gitlab}" = "github" ]; then
      gh pr comment "$IID" --repo "$PROJECT_PATH" --body "$body" \
        || echo "post_note: gh pr comment failed (exit $?)"
    else
      ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
        GITLAB_HOST="${GITLAB_HOST:-}" glab mr note create "$IID" -m "$body" ) \
        || echo "post_note: glab mr note failed (exit $?)"
    fi
  } >> "$LOGDIR/fixer-$IID.log" 2>&1 || true
}

# Human MR/PR comments newer than the plan file — corrections for the
# approved run. Bot-authored comments (merge-medic prefix) are skipped.
collect_feedback() { # $1 = plan file; its mtime is the cutoff
  local cutoff
  cutoff="$(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0)"
  if [ "${PROVIDER:-gitlab}" = "github" ]; then
    gh pr view "$IID" --repo "$PROJECT_PATH" --json comments 2>/dev/null \
      | jq -r --argjson t "$cutoff" '[.comments[] | select(.body | startswith("merge-medic") | not) | select((.createdAt | fromdateiso8601) > $t) | "- " + .body] | join("\n")' 2>/dev/null || true
  else
    ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
      GITLAB_HOST="${GITLAB_HOST:-}" glab api "projects/:fullpath/merge_requests/$IID/notes?order_by=created_at&sort=desc&per_page=20" 2>/dev/null ) \
      | jq -r --argjson t "$cutoff" '[.[] | select(.system==false) | select(.body | startswith("merge-medic") | not) | select((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $t) | "- " + .body] | reverse | join("\n")' 2>/dev/null || true
  fi
}

: > "$PROG"
ev START "$SRC -> $TGT"

# ── push guard: non-AUTO branches are only ever pushed by an approved run ─────
src_is_auto=0
for ab in ${AUTO_BRANCHES:-feat-*}; do
  # shellcheck disable=SC2254
  case "$SRC" in $ab) src_is_auto=1;; esac
done
if [ "$src_is_auto" = "0" ] && [ "$MODE" != "plan" ] && [ "$MODE" != "fix-approved" ]; then
  fail "source branch '$SRC' is not in AUTO_BRANCHES and no approve exists"
fi

cd "$WATCH_REPO"
git fetch --prune --quiet origin || fail "git fetch failed"

ev WORKTREE "$WT"
cleanup_wt
git worktree add --force "$WT" -B "$SRC" "origin/$SRC" >/dev/null 2>&1 \
  || fail "worktree add failed (branch held by another worktree?)"
cd "$WT"
rm -f "$ESCFILE" "$SUMFILE"

MERGE_BASE="$(git merge-base HEAD "origin/$TGT" 2>/dev/null || echo '')"

ev MERGE "origin/$TGT"
ai_ran=0
summary=""
if git -c merge.conflictStyle=zdiff3 merge --no-ff --no-edit \
     -m "chore: merge origin/$TGT into $SRC (${SIGIL}$IID)" "origin/$TGT" >/dev/null 2>&1; then
  ev MERGE_CLEAN "no conflict markers — AI not needed (0 tokens)"
  resolve_mode="clean"
  if [ "$MODE" = "plan" ]; then
    ev PLANNED "clean merge — approve (a) to push"
    ledger PLANNED
    post_note "merge-medic plan for ${SIGIL}$IID: origin/$TGT merges cleanly — no conflicts. Approve in the dashboard (hotkey a) and the bot will redo the merge, run the gates and push. Comment corrections here before approving; the approved run reads them."
    notify "${SIGIL}$IID: plan ready" "clean merge — approve in dashboard (a)"
    cleanup_wt
    exit 0
  fi
else
  conflicts="$(git diff --name-only --diff-filter=U)"
  [ -z "$conflicts" ] && fail "merge failed without conflicting files"
  n="$(printf '%s\n' "$conflicts" | grep -c .)"

  # ── hard escalation zones: the bot never decides here ───────────────────────
  for f in $conflicts; do
    for pat in ${ESCALATE_PATTERNS:-}; do
      # shellcheck disable=SC2254
      case "$f" in
        $pat)
          git merge --abort 2>/dev/null || true
          escalate "conflict in protected path: $f (matches '$pat')"
          ;;
      esac
    done
  done

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

  # ── intent context: what each side did to the conflicted files ──────────────
  src_hist=""; tgt_hist=""
  if [ -n "$MERGE_BASE" ]; then
    # shellcheck disable=SC2086
    src_hist="$(git log --oneline "$MERGE_BASE..origin/$SRC" -- $conflicts 2>/dev/null | head -15)"
    # shellcheck disable=SC2086
    tgt_hist="$(git log --oneline "$MERGE_BASE..origin/$TGT" -- $conflicts 2>/dev/null | head -15)"
  fi

  # Project-specific resolution rules, appended to the default policy.
  policy=""
  if [ -n "${RESOLVE_POLICY_FILE:-}" ]; then
    pf="$RESOLVE_POLICY_FILE"
    [ "${pf#/}" = "$pf" ] && pf="$ROOT/$pf"
    if [ -f "$pf" ]; then
      policy="$(printf '\n\nProject-specific resolution rules (they override the defaults above where they conflict):\n%s' "$(cat "$pf")")"
    else
      ev AI_RESOLVE "WARN: RESOLVE_POLICY_FILE not found: $pf"
    fi
  fi

  # ── plan mode: describe the resolution, post it, wait for a human ───────────
  if [ "$MODE" = "plan" ]; then
    ev PLAN "$n file(s): $(printf '%s' "$conflicts" | tr '\n' ' ' | cut -c1-120)"
    PLANFILE="$ROOT/state/plan-$IID.md"
    set +e
    claude -p "A merge of origin/$TGT into $SRC (${SIGIL}$IID${TITLE:+ — \"$TITLE\"}) has conflicts. You are in the worktree mid-merge with zdiff3 markers (||||||| shows the common ancestor). Do NOT edit anything — read the conflicted files and write a RESOLUTION PLAN as your answer.

Conflicting files:
$conflicts

What the source branch ($SRC) did to these files:
${src_hist:-<no commits found>}

What the target branch ($TGT) did to these files:
${tgt_hist:-<no commits found>}

For each file: what each side changed, what you would keep and why, and any risk worth a human's attention. Be specific enough that a reviewer can approve or correct it in a comment. End with an overall risk assessment.$policy" \
      --model "${CLAUDE_MODEL:-opus}" \
      --permission-mode acceptEdits \
      --allowedTools "Read Grep Glob Bash(git:*)" \
      --disallowedTools "Edit Write WebFetch WebSearch Bash(curl:*) Bash(rm:*)" \
      --add-dir "$WT" \
      --output-format text > "$PLANFILE" 2>>"$LOGDIR/fixer-$IID.log"
    prc=$?
    set -e
    git merge --abort 2>/dev/null || true
    [ "$prc" != "0" ] && fail "plan agent exited with code $prc"
    ev PLANNED "awaiting approve (a) — plan posted to ${SIGIL}$IID"
    ledger PLANNED
    post_note "merge-medic resolution plan for ${SIGIL}$IID. Approve in the dashboard (hotkey a) to let the bot execute it; comment corrections here first — the approved run reads them and they override the plan.

$(cat "$PLANFILE")"
    notify "${SIGIL}$IID: plan ready" "review & approve in dashboard (a)"
    cleanup_wt
    exit 0
  fi

  # approved run: feed the posted plan + newer human comments into the prompt
  approved_ctx=""
  if [ "$MODE" = "fix-approved" ] && [ -f "$ROOT/state/plan-$IID.md" ]; then
    approved_ctx="$(printf '\n\nApproved resolution plan (execute it):\n%s' "$(cat "$ROOT/state/plan-$IID.md")")"
    fb="$(collect_feedback "$ROOT/state/plan-$IID.md")"
    [ -n "$fb" ] && approved_ctx+="$(printf '\n\nHuman corrections from MR comments — these OVERRIDE the plan and the defaults:\n%s' "$fb")"
  fi

  ev AI_RESOLVE "$n file(s): $(printf '%s' "$conflicts" | tr '\n' ' ' | cut -c1-120)"
  AILOG="$LOGDIR/ai-$IID-$(date '+%Y%m%d-%H%M%S').log"
  set +e
  claude -p "You are resolving git merge conflicts in a worktree (branch $SRC, origin/$TGT merged in, ${SIGIL}$IID${TITLE:+ — \"$TITLE\"}).

Conflict markers use zdiff3 style: between <<<<<<< and >>>>>>> you also see the
common-ancestor version (||||||| block) — use it to understand what EACH side
actually changed relative to the base.

Conflicting files:
$conflicts

What the source branch ($SRC) did to these files:
${src_hist:-<no commits found>}

What the target branch ($TGT) did to these files:
${tgt_hist:-<no commits found>}

Rules:
- Resolve ALL conflict markers, preserving the intent of both sides; when in
  doubt, prefer $SRC for its own feature code and $TGT for everything else.
- Do not rewrite anything outside the conflicted hunks. No refactoring.
- If both sides made substantive, INCOMPATIBLE changes to the same logic and
  neither the defaults nor the project rules decide it safely — do NOT guess:
  write a one-line reason into a file named $ESCFILE in the repo root and stop.
- After editing: git add each resolved file. Do NOT commit, do NOT push.
- Write a short summary (per file: what each side wanted, what you kept and
  why) into a file named $SUMFILE in the repo root.$approved_ctx$policy" \
    --model "${CLAUDE_MODEL:-opus}" \
    --permission-mode acceptEdits \
    --allowedTools "Read Edit Write Glob Grep Bash(git:*)" \
    --disallowedTools "WebFetch WebSearch Bash(curl:*) Bash(rm:*) Bash(git push:*)" \
    --add-dir "$WT" \
    --output-format text >> "$AILOG" 2>&1
  rc=$?
  set -e
  if [ -f "$ESCFILE" ]; then
    reason="$(head -3 "$ESCFILE" | tr '\n' ' ')"
    git merge --abort 2>/dev/null || true
    escalate "AI declined to guess: ${reason:-incompatible changes}"
  fi
  [ "$rc" != "0" ] && fail "claude exited with code $rc (log: ${AILOG##*/})"
  [ -n "$(git diff --name-only --diff-filter=U)" ] && fail "unresolved files remain"
  # shellcheck disable=SC2086
  if grep -rl '^<<<<<<< ' $conflicts 2>/dev/null | head -1 | grep -q .; then
    fail "conflict markers remain"
  fi
  rm -f "$ESCFILE"
  # capture the AI's summary BEFORE staging so it never lands in the commit
  [ -f "$SUMFILE" ] && summary="$(cat "$SUMFILE")" && rm -f "$SUMFILE"
  git add -A
  git commit --no-edit >/dev/null 2>&1 \
    || git commit -m "chore: merge origin/$TGT into $SRC (${SIGIL}$IID)" >/dev/null
  ai_ran=1
  resolve_mode="ai"
fi

ev VERIFY "${VERIFY_CMD:-<skipped>}"
if [ -n "${VERIFY_CMD:-}" ]; then
  ( eval "$VERIFY_CMD" ) >> "$LOGDIR/fixer-$IID.log" 2>&1 || fail "verify red (fixer-$IID.log)"
fi

# ── focused tests on the conflicted files (AI resolutions only) ───────────────
if [ "$ai_ran" = "1" ] && [ -n "${TEST_CMD_TEMPLATE:-}" ]; then
  files_flat="$(printf '%s' "${conflicts:-}" | tr '\n' ' ')"
  tcmd="${TEST_CMD_TEMPLATE//\{files\}/$files_flat}"
  ev TESTS "$tcmd"
  ( eval "$tcmd" ) >> "$LOGDIR/fixer-$IID.log" 2>&1 || fail "focused tests red (fixer-$IID.log)"
fi

# ── regression suite ──────────────────────────────────────────────────────────
when="${REGRESSION_WHEN:-ai}"
if [ -n "${REGRESSION_CMD:-}" ] && { [ "$when" = "always" ] || { [ "$when" = "ai" ] && [ "$ai_ran" = "1" ]; }; }; then
  ev REGRESSION "$REGRESSION_CMD"
  ( eval "$REGRESSION_CMD" ) >> "$LOGDIR/fixer-$IID.log" 2>&1 || fail "regression suite red (fixer-$IID.log)"
fi

ev PUSH "origin $SRC"
git push origin "HEAD:$SRC" >/dev/null 2>&1 || fail "push rejected (branch moved ahead?)"

ev DONE "merged origin/$TGT, gates green, pushed"
ledger DONE
notify "${SIGIL}$IID fixed ✓" "$SRC: merge $TGT + gates + push"
if [ "$ai_ran" = "1" ] && [ -n "$summary" ]; then
  post_note "merge-medic resolved conflicts with origin/$TGT automatically.

$summary

Gates: verify$([ -n "${TEST_CMD_TEMPLATE:-}" ] && printf ' + focused tests')$([ -n "${REGRESSION_CMD:-}" ] && printf ' + regression') green before push."
fi
cleanup_wt
