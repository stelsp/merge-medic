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

# Phase event: per-run progress file (dashboards) + the shared events stream
# (`mrwatch live` tails it in a separate terminal).
ev() {
  local ets; ets="$(date +%s)"
  printf '%s|%s|%s\n' "$ets" "$1" "${2:-}" >> "$PROG"
  printf '%s|%s|%s|%s\n' "$ets" "$IID" "$1" "${2:-}" >> "$LOGDIR/events.log"
}
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
  post_note "## 🩹 merge-medic — escalated to a human

**MR:** \`$SRC\` → \`$TGT\` (${SIGIL}$IID)

> [!WARNING]
> $1

The bot will not touch this conflict. Resolve it manually, or adjust \`policy.md\` / \`ESCALATE_PATTERNS\` if the bot should have handled it."
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

# Token/cost ledger: one line per model per AI call, from the CLI's own
# usage accounting (no hardcoded price tables).
# state/tokens.log: ts|iid|model|in|out|cache_read|cost_usd
record_tokens() { # $1 = claude --output-format json result file
  local rts; rts="$(date +%s)"
  jq -r --arg ts "$rts" --arg iid "$IID" --arg m "${CLAUDE_MODEL:-unknown}" '
    if (.modelUsage // null) != null then
      .modelUsage | to_entries[]
      | "\($ts)|\($iid)|\(.key)|\(.value.inputTokens // 0)|\(.value.outputTokens // 0)|\(.value.cacheReadInputTokens // 0)|\(.value.costUSD // 0)"
    else
      "\($ts)|\($iid)|\($m)|\(.usage.input_tokens // 0)|\(.usage.output_tokens // 0)|\(.usage.cache_read_input_tokens // 0)|\(.total_cost_usd // 0)"
    end
  ' "$1" >> "$ROOT/state/tokens.log" 2>/dev/null || true
}

# ── resolver abstraction: claude (default) | aider | custom ───────────────────
# resolver_call <plan|resolve> <prompt> <errlog>
# Runs the configured agent in the current worktree. Prints the agent's final
# answer text to stdout, returns its exit code. "plan" must not edit files.
# Token/cost accounting only where the provider reports it (claude).
resolver_call() {
  local mode="$1" prompt="$2" errlog="$3" rc=0 out
  case "${RESOLVER:-claude}" in
    claude)
      local tools dtools
      if [ "$mode" = "plan" ]; then
        tools="Read Grep Glob Bash(git:*)"
        dtools="Edit Write WebFetch WebSearch Bash(curl:*) Bash(rm:*)"
      else
        tools="Read Edit Write Glob Grep Bash(git:*)"
        dtools="WebFetch WebSearch Bash(curl:*) Bash(rm:*) Bash(git push:*)"
      fi
      out="$(mktemp)"
      claude -p "$prompt" \
        --model "${CLAUDE_MODEL:-opus}" \
        --permission-mode acceptEdits \
        --allowedTools "$tools" \
        --disallowedTools "$dtools" \
        --add-dir "$WT" \
        --output-format json > "$out" 2>>"$errlog" || rc=$?
      jq -r '.result // empty' "$out" 2>/dev/null || true
      record_tokens "$out"
      rm -f "$out"
      ;;
    aider)
      # Any model aider supports (OpenAI/Gemini/DeepSeek/OpenRouter/Ollama...).
      # API keys come from config.env (export them there) or the environment.
      # --dry-run keeps the plan phase read-only; we commit ourselves.
      local dry=""
      [ "$mode" = "plan" ] && dry="--dry-run"
      # shellcheck disable=SC2086
      printf '%s' "$prompt" | aider $dry --yes-always --no-auto-commits \
        ${RESOLVER_MODEL:+--model "$RESOLVER_MODEL"} \
        --message-file /dev/stdin 2>>"$errlog" || rc=$?
      ;;
    custom)
      # RESOLVER_CMD with {prompt_file} and {mode} substituted. The command
      # runs in the worktree, must edit files itself and exit 0 on success.
      [ -n "${RESOLVER_CMD:-}" ] || { echo "RESOLVER=custom but RESOLVER_CMD is empty" >>"$errlog"; return 78; }
      local pf cmd
      pf="$(mktemp)"; printf '%s' "$prompt" > "$pf"
      cmd="${RESOLVER_CMD//\{prompt_file\}/$pf}"
      cmd="${cmd//\{mode\}/$mode}"
      ( eval "$cmd" ) 2>>"$errlog" || rc=$?
      rm -f "$pf"
      ;;
    *)
      echo "unknown RESOLVER '$RESOLVER'" >>"$errlog"; return 78 ;;
  esac
  return $rc
}

# mr_author prints the MR/PR author's username (the default trusted commenter).
mr_author() {
  if [ "${PROVIDER:-gitlab}" = "github" ]; then
    gh pr view "$IID" --repo "$PROJECT_PATH" --json author --jq '.author.login' 2>/dev/null || true
  else
    ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
      GITLAB_HOST="${GITLAB_HOST:-}" glab api "projects/:fullpath/merge_requests/$IID" 2>/dev/null ) \
      | jq -r '.author.username // empty' 2>/dev/null || true
  fi
}

# Human MR/PR comments newer than the plan file — corrections for the
# approved run. These comments become INSTRUCTIONS for an agent with push
# rights, so only trusted authors are read: TRUSTED_AUTHORS from config, or
# (when unset) just the MR author. Bot comments (merge-medic prefix) skipped.
collect_feedback() { # $1 = plan file; its mtime is the cutoff
  local cutoff trusted allowed_json
  cutoff="$(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0)"
  trusted="${TRUSTED_AUTHORS:-}"
  [ -z "$trusted" ] && trusted="$(mr_author)"
  [ -z "$trusted" ] && return 0   # cannot establish trust — read nobody
  # shellcheck disable=SC2086
  allowed_json="$(printf '%s\n' $trusted | jq -R . | jq -cs .)"
  if [ "${PROVIDER:-gitlab}" = "github" ]; then
    gh pr view "$IID" --repo "$PROJECT_PATH" --json comments 2>/dev/null \
      | jq -r --argjson t "$cutoff" --argjson ok "$allowed_json" '[.comments[] | select([.author.login] | inside($ok)) | select(.body | test("^(## .? ?merge-medic|merge-medic)") | not) | select((.createdAt | fromdateiso8601) > $t) | "- " + .body] | join("\n")' 2>/dev/null || true
  else
    ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
      GITLAB_HOST="${GITLAB_HOST:-}" glab api "projects/:fullpath/merge_requests/$IID/notes?order_by=created_at&sort=desc&per_page=20" 2>/dev/null ) \
      | jq -r --argjson t "$cutoff" --argjson ok "$allowed_json" '[.[] | select(.system==false) | select([.author.username] | inside($ok)) | select(.body | test("^(## .? ?merge-medic|merge-medic)") | not) | select((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $t) | "- " + .body] | reverse | join("\n")' 2>/dev/null || true
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

# ── defer while humans / other agent sessions are still working ───────────────
# watch.sh retries a deferred MR on every tick; this check is cheap (fetch +
# git log, no AI), so the fix lands one tick after the branch goes quiet.
defer() {
  ev DEFERRED "$1 — retrying every tick until quiet for ${QUIET_MINUTES:-5}m"
  date +%s > "$ROOT/state/deferred-$IID"
  cleanup_wt
  exit 0
}
if [ "${QUIET_MINUTES:-0}" -gt 0 ]; then
  head_ts="$(git log -1 --format=%ct "origin/$SRC" 2>/dev/null || echo 0)"
  if [ "$head_ts" -gt 0 ]; then
    age_m=$(( ($(date +%s) - head_ts) / 60 ))
    [ "$age_m" -lt "$QUIET_MINUTES" ] && defer "branch pushed ${age_m}m ago — someone is working on it"
  fi
  for ur in ${USER_REPOS:-}; do
    uwt="$(git -C "$ur" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$SRC" '$1=="worktree"{w=$2} $1=="branch"&&$2==b{print w; exit}')"
    if [ -n "$uwt" ] && [ -n "$(git -C "$uwt" status --porcelain 2>/dev/null | head -1)" ]; then
      defer "uncommitted work in $uwt"
    fi
  done
fi

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
    post_note "## 🩹 merge-medic — plan (approval required)

**MR:** \`$SRC\` → \`$TGT\` (${SIGIL}$IID) · **Mode:** clean merge, no conflicts

\`origin/$TGT\` merges cleanly. On approve the bot redoes the merge, runs the gates and pushes.

> [!NOTE]
> **Approve:** press \`a\` in the dashboard. **Corrections:** comment below before approving — the approved run reads them."
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
  # DAILY_AGENT_RUNS=0 means unlimited — count runs, never refuse
  if [ "${DAILY_AGENT_RUNS:-6}" -gt 0 ] && [ "$spent" -ge "${DAILY_AGENT_RUNS:-6}" ]; then
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
    resolver_call plan "A merge of origin/$TGT into $SRC (${SIGIL}$IID${TITLE:+ — \"$TITLE\"}) has conflicts. You are in the worktree mid-merge with zdiff3 markers (||||||| shows the common ancestor). Do NOT edit anything — read the conflicted files and write a RESOLUTION PLAN as your answer.

Conflicting files:
$conflicts

What the source branch ($SRC) did to these files:
${src_hist:-<no commits found>}

What the target branch ($TGT) did to these files:
${tgt_hist:-<no commits found>}

Write GitHub-flavored markdown, no preamble: a '### <file path>' heading per file with bullets '**source changed:** …', '**target changed:** …', '**proposed resolution:** …', '**risk:** …'. Be specific enough that a reviewer can approve or correct it in a comment. End with an '#### Overall risk' section.$policy" \
      "$LOGDIR/fixer-$IID.log" > "$PLANFILE"
    prc=$?
    set -e
    git merge --abort 2>/dev/null || true
    [ "$prc" != "0" ] && fail "plan agent exited with code $prc"
    [ -s "$PLANFILE" ] || fail "plan agent returned no text"
    ev PLANNED "awaiting approve (a) — plan posted to ${SIGIL}$IID"
    ledger PLANNED
    post_note "## 🩹 merge-medic — resolution plan (approval required)

**MR:** \`$SRC\` → \`$TGT\` (${SIGIL}$IID) · **Conflicts:** $n file(s)

> [!NOTE]
> **Approve:** press \`a\` in the dashboard — the bot executes this plan.
> **Corrections:** comment below first; the approved run reads them and they **override** the plan.

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
  resolver_call resolve "You are resolving git merge conflicts in a worktree (branch $SRC, origin/$TGT merged in, ${SIGIL}$IID${TITLE:+ — \"$TITLE\"}).

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
- Write a summary into a file named $SUMFILE in the repo root, as
  GitHub-flavored markdown: a '### <file path>' heading per file with bullets
  '**source:** …', '**target:** …', '**kept:** …'. No preamble.$approved_ctx$policy" \
    "$AILOG" > "$AILOG.ans"
  rc=$?
  set -e
  # keep the human-readable resolver answer at the end of AILOG
  cat "$AILOG.ans" >> "$AILOG" 2>/dev/null || true
  rm -f "$AILOG.ans"
  if [ -f "$ESCFILE" ]; then
    reason="$(head -3 "$ESCFILE" | tr '\n' ' ')"
    git merge --abort 2>/dev/null || true
    escalate "AI declined to guess: ${reason:-incompatible changes}"
  fi
  [ "$rc" != "0" ] && fail "resolver exited with code $rc (log: ${AILOG##*/})"
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

# ── push: direct (into the source branch) or via a resolution MR/PR ───────────
res_link=""
if [ "${PUSH_MODE:-direct}" = "mr" ]; then
  FIXBR="merge-medic/fix-$IID-$(date +%s)"
  ev PUSH "resolution branch $FIXBR"
  git push origin "HEAD:refs/heads/$FIXBR" >/dev/null 2>&1 || fail "push of $FIXBR rejected"
  res_title="merge-medic: resolve conflicts of ${SIGIL}$IID ($SRC <- $TGT)"
  res_body="Automated conflict resolution for ${SIGIL}$IID. Merge this into \`$SRC\` to clear the conflict — your branch is untouched until you do."
  if [ "${PROVIDER:-gitlab}" = "github" ]; then
    res_link="$(gh pr create --repo "$PROJECT_PATH" --head "$FIXBR" --base "$SRC" \
      --title "$res_title" --body "$res_body" 2>>"$LOGDIR/fixer-$IID.log" || true)"
  else
    res_link="$(GITLAB_HOST="${GITLAB_HOST:-}" glab api "projects/:fullpath/merge_requests" \
      -f "source_branch=$FIXBR" -f "target_branch=$SRC" -f "title=$res_title" \
      -f "description=$res_body" -f remove_source_branch=true 2>>"$LOGDIR/fixer-$IID.log" \
      | jq -r '.web_url // empty' || true)"
  fi
  [ -n "$res_link" ] || fail "resolution branch pushed but the MR/PR could not be created ($FIXBR)"
  ev DONE "resolution MR ready: $res_link"
  ledger DONE
  notify "${SIGIL}$IID resolved ✓" "review & merge: $res_link"
else
  ev PUSH "origin $SRC"
  git push origin "HEAD:$SRC" >/dev/null 2>&1 || fail "push rejected (branch moved ahead?)"

  ev DONE "merged origin/$TGT, gates green, pushed"
  ledger DONE
  notify "${SIGIL}$IID fixed ✓" "$SRC: merge $TGT + gates + push"
fi
if [ "$ai_ran" = "1" ] && [ -n "$summary" ]; then
  g_tests="—"; [ -n "${TEST_CMD_TEMPLATE:-}" ] && g_tests="✅ \`$(printf '%s' "$TEST_CMD_TEMPLATE" | cut -c1-60)\`"
  g_regr="—"
  if [ -n "${REGRESSION_CMD:-}" ] && { [ "$when" = "always" ] || [ "$when" = "ai" ]; }; then
    g_regr="✅ \`$(printf '%s' "$REGRESSION_CMD" | cut -c1-60)\`"
  fi
  approved_tag=""; [ "$MODE" = "fix-approved" ] && approved_tag=" · human-approved plan"
  if [ -n "$res_link" ]; then
    tail_note="**Your branch is untouched.** The resolution lives in its own MR — review the diff and merge it: $res_link"
  else
    tail_note="<sub>The merge commit is on the branch — review as usual; nothing was merged into \`$TGT\`.</sub>"
  fi
  post_note "## 🩹 merge-medic — conflicts resolved automatically

**MR:** \`$SRC\` → \`$TGT\` (${SIGIL}$IID) · **Mode:** AI resolution$approved_tag

### What was resolved

$summary

### Gates (all green before push)

| Gate | Result |
|---|---|
| verify | ✅ \`$(printf '%s' "${VERIFY_CMD:-—}" | cut -c1-60)\` |
| focused tests | $g_tests |
| regression | $g_regr |

$tail_note"
fi
cleanup_wt
