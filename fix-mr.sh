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
RESOLVER_TIMEOUT="$(mm_secs "${RESOLVER_TIMEOUT:-}" 900)"
GATE_TIMEOUT="$(mm_secs "${GATE_TIMEOUT:-}" 1800)"
NET_TIMEOUT="$(mm_secs "${NET_TIMEOUT:-}" 300)"
GIT_TIMEOUT="$(mm_secs "${GIT_TIMEOUT:-}" 300)"
SIGIL="$(mm_ref_sigil)"

# ── git policy for everything this run starts ─────────────────────────────────
# Hooks and commit signing run only when config.env asks for them. Either can
# wait on something nobody is there to give — a hook running a test suite, a
# signing agent that wants a passphrase or a touch — and inside the bot's own
# checkout, merge, commit and push that wait used to have no end.
# GIT_CONFIG_COUNT entries outrank every config file, the watch clone's own
# included. Nothing may prompt for credentials either: a prompt would hang.
git_policy() {
  local n=0
  if [ "${RUN_GIT_HOOKS:-0}" != "1" ]; then
    export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=/dev/null"
    n=$((n + 1))
  fi
  if [ "${SIGN_BOT_COMMITS:-0}" != "1" ]; then
    export "GIT_CONFIG_KEY_$n=commit.gpgSign" "GIT_CONFIG_VALUE_$n=false"
    n=$((n + 1))
  fi
  export GIT_CONFIG_COUNT="$n" GIT_TERMINAL_PROMPT=0
}
git_policy_off() {
  local i=0
  while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
  done
  unset GIT_CONFIG_COUNT
}
git_policy
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
# evx is a side note for the live rail only: it must NOT reach the progress
# file, whose LAST line is read as the fixer's current phase — a note there
# would hijack the dashboard's ACTIVE row and reset its progress bar.
evx() {
  printf '%s|%s|%s|%s\n' "$(date +%s)" "$IID" "$1" "${2:-}" >> "$LOGDIR/events.log"
}
# rc_text <status> — how a step ended, for events: "timed out" for
# mm_timeout's 124, "exit N" otherwise.
rc_text() {
  if [ "$1" = 124 ]; then printf 'timed out'; else printf 'exit %s' "$1"; fi
}
# gate_eval runs a gate command in its own subshell, so nothing it does to
# the shell (cd, exit, variables) reaches the fixer. The bot's git policy
# (git_policy) is for its own git steps: a gate sees git as configured, so a
# test or an install step that sets up hooks behaves as it does anywhere.
gate_eval() {
  ( git_policy_off; eval "$1" )
}
# run_gate <PHASE> <command> — one event before, one after, with the outcome
# token the dashboard colors by: "ok · 18s" / "red · exit 1 · <tail>".
# GATE_TIMEOUT bounds it: a hung install or test run would otherwise hold
# the fixer, and through it every later watcher tick, forever.
run_gate() {
  local phase="$1" cmd="$2" gs rc=0 tail_out
  ev "$phase" "run · $(printf '%s' "$cmd" | cut -c1-70)"
  gs="$(date +%s)"
  # `|| rc=$?` and NOT `if ...; then`: the status of a failed if-compound is
  # the if's own (zero), so every red gate would report "exit 0"
  mm_timeout "${GATE_TIMEOUT:-1800}" gate_eval "$cmd" >> "$LOGDIR/fixer-$IID.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    ev "$phase" "ok · $(( $(date +%s) - gs ))s"
    return 0
  fi
  tail_out="$(tail -n 3 "$LOGDIR/fixer-$IID.log" | mm_clean)"
  ev "$phase" "red · $(rc_text "$rc") · $tail_out"
  fail "$phase red ($(rc_text "$rc"), fixer-$IID.log)"
}
notify() { mm_notify "$@"; }
cleanup_wt() {
  git -C "$WATCH_REPO" worktree remove --force "$WT" 2>/dev/null || true
  # a directory left at $WT that git does not know as a worktree (something
  # wrote into it after it was removed) would fail every later worktree add
  if [ -e "$WT" ]; then
    rm -rf "$WT"
    git -C "$WATCH_REPO" worktree prune 2>/dev/null || true
  fi
}
# Durable all-time ledger (progress files get overwritten per run):
# ts|iid|OUTCOME|mode  where mode = none|clean|ai
resolve_mode="none"
# Durable outcome ledger + per-run phase archive (state/runs/<iid>-<ts>.log)
# so dashboards can show full history for every MR.
ledger() {
  local lts; lts="$(date +%s)"
  MM_LEDGER="$1"
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
    if mm_is_github; then
      mm_timeout "${NET_TIMEOUT:-300}" gh pr comment "$IID" --repo "$PROJECT_PATH" --body "$body" \
        || echo "post_note: gh pr comment failed (exit $?)"
    else
      ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
        mm_timeout "${NET_TIMEOUT:-300}" env GITLAB_HOST="${GITLAB_HOST:-}" \
          glab mr note create "$IID" -m "$body" ) \
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

# ── what the claude resolver may do ───────────────────────────────────────────
# The resolver is a model reading text from the branches it merges, run with
# the push rights of whoever installed merge-medic. It used to be allowed
# Bash(git:*), and `git -C . push`, an alias defined with -c, or a pager or
# hook set in config ran anything at all. Now the CLI loads none of the
# user's settings, hooks, plugins or MCP servers (--restricted,
# --strict-mcp-config), offers no tool but the file tools and Bash, denies
# whatever is not allowed below without asking anyone, and Bash may run only
# the git commands a resolution needs (tests/fixer_guards.sh pins the rules).
#
# claude_args <plan|resolve>: the permission flags, one argument per line
claude_args() {
  local c
  if [ "$1" = "plan" ]; then
    printf '%s\n' --tools "Read,Glob,Grep,Bash"
  else
    printf '%s\n' --tools "Read,Edit,Write,Glob,Grep,Bash"
  fi
  printf '%s\n' --restricted --strict-mcp-config \
    --permission-mode dontAsk --permission-prompts none --allowedTools Read Glob Grep
  [ "$1" = "plan" ] || printf '%s\n' Edit Write
  # reading git. Not every `git diff` though: given two paths, one of them
  # outside the repository, git falls back to --no-index and prints any file
  # on the machine. Against a revision or the index it never does.
  for c in status log show; do printf 'Bash(git %s)\nBash(git %s *)\n' "$c" "$c"; done
  printf '%s\n' 'Bash(git diff)' 'Bash(git diff --cached)' 'Bash(git diff --cached *)' \
    'Bash(git diff HEAD)' 'Bash(git diff HEAD *)' 'Bash(git diff MERGE_HEAD)' 'Bash(git diff MERGE_HEAD *)'
  if [ "$1" != "plan" ]; then
    printf '%s\n' 'Bash(git add *)' 'Bash(git rm *)' \
      'Bash(git checkout --ours *)' 'Bash(git checkout --theirs *)'
  fi
  # Denied in both modes even though nothing above allows them: a deny rule
  # wins over any allow rule, should one ever come from somewhere else.
  # --output writes a diff or log to any path on the machine, a redirection
  # writes anything anywhere, --no-index reads any file, and
  # --pathspec-from-file reads one too (git quotes its lines back in errors).
  printf '%s\n' --disallowedTools \
    'Bash(git push)' 'Bash(git push *)' 'Bash(git * push)' 'Bash(git * push *)' \
    'Bash(git -c *)' 'Bash(git -C *)' 'Bash(git --*)' 'Bash(git config *)' \
    'Bash(*--output*)' 'Bash(*>*)' 'Bash(*--no-index*)' 'Bash(*--pathspec-from-file*)'
}

# ── resolver abstraction: claude (default) | aider | custom ───────────────────
# resolver_call <plan|resolve> <prompt> <errlog>
# Runs the configured agent in the current worktree. Prints the agent's final
# answer text to stdout, returns its exit code. "plan" must not edit files.
# Token/cost accounting only where the provider reports it (claude).
# Whatever the resolver is and whatever it manages to run, git cannot reach
# a remote from inside it: GIT_ALLOW_PROTOCOL overrides every config and -c,
# and "none" names no protocol, so fetch, push and clone all refuse.
resolver_call() {
  evx RESOLVER "info · ${RESOLVER:-claude} ${CLAUDE_MODEL:-${RESOLVER_MODEL:-}} · $1"
  ( export GIT_ALLOW_PROTOCOL=none
    resolver_run "$@" )
}
resolver_run() {
  local mode="$1" prompt="$2" errlog="$3" rc=0 out
  case "${RESOLVER:-claude}" in
    claude)
      local -a cli
      local arg
      cli=(claude -p "$prompt" --model "${CLAUDE_MODEL:-opus}" --add-dir "$WT" --output-format json)
      [ -n "${CLAUDE_EFFORT:-}" ] && cli+=(--effort "$CLAUDE_EFFORT")
      # --restricted reads no settings file of the user's: auth or provider
      # setup kept in one (apiKeyHelper, env) has to be handed over here
      [ -n "${CLAUDE_SETTINGS:-}" ] && cli+=(--settings "$CLAUDE_SETTINGS")
      while IFS= read -r arg; do cli+=("$arg"); done < <(claude_args "$mode")
      out="$(mktemp "$MM_TMP/claude.XXXXXX")"
      "${cli[@]}" > "$out" 2>>"$errlog" || rc=$?
      jq -r '.result // empty' "$out" 2>/dev/null || true
      record_tokens "$out"
      # side note for the live rail: what this call actually cost
      evx COST "$(jq -r --arg mode "$mode" --arg model "${CLAUDE_MODEL:-opus}" '
        "info · $" + ((.total_cost_usd // 0) * 100 | round / 100 | tostring)
        + " · " + ((.usage.input_tokens // 0) | tostring) + " in / "
        + ((.usage.output_tokens // 0) | tostring) + " out · " + $mode + " · " + $model
      ' "$out" 2>/dev/null || echo "info · cost unavailable")"
      rm -f "$out"
      ;;
    aider)
      # Any model aider supports (OpenAI/Gemini/DeepSeek/OpenRouter/Ollama...).
      # API keys come from config.env (export them there) or the environment.
      # --dry-run keeps the plan phase read-only; we commit ourselves.
      # --no-gitignore: aider would otherwise append its own entries to the
      # project's .gitignore, an edit outside the conflict that fails the run.
      local dry=""
      [ "$mode" = "plan" ] && dry="--dry-run"
      # shellcheck disable=SC2086
      printf '%s' "$prompt" | aider $dry --yes-always --no-auto-commits --no-gitignore \
        ${RESOLVER_MODEL:+--model "$RESOLVER_MODEL"} \
        --message-file /dev/stdin 2>>"$errlog" || rc=$?
      ;;
    custom)
      # RESOLVER_CMD with {prompt_file} and {mode} substituted. The command
      # runs in the worktree, must edit files itself and exit 0 on success.
      [ -n "${RESOLVER_CMD:-}" ] || { echo "RESOLVER=custom but RESOLVER_CMD is empty" >>"$errlog"; return 78; }
      local pf cmd
      pf="$(mktemp "$MM_TMP/prompt.XXXXXX")"; printf '%s' "$prompt" > "$pf"
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
  if mm_is_github; then
    mm_timeout "${NET_TIMEOUT:-300}" gh pr view "$IID" --repo "$PROJECT_PATH" \
      --json author --jq '.author.login' 2>/dev/null || true
  else
    ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
      mm_timeout "${NET_TIMEOUT:-300}" env GITLAB_HOST="${GITLAB_HOST:-}" \
        glab api "projects/:fullpath/merge_requests/$IID" 2>/dev/null ) \
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
  if mm_is_github; then
    mm_timeout "${NET_TIMEOUT:-300}" gh pr view "$IID" --repo "$PROJECT_PATH" --json comments 2>/dev/null \
      | jq -r --argjson t "$cutoff" --argjson ok "$allowed_json" '[.comments[] | select([.author.login] | inside($ok)) | select(.body | test("^(## .? ?merge-medic|merge-medic)") | not) | select((.createdAt | fromdateiso8601) > $t) | "- " + .body] | join("\n")' 2>/dev/null || true
  else
    ( cd "$WT" 2>/dev/null || cd "$WATCH_REPO"
      mm_timeout "${NET_TIMEOUT:-300}" env GITLAB_HOST="${GITLAB_HOST:-}" \
        glab api "projects/:fullpath/merge_requests/$IID/notes?order_by=created_at&sort=desc&per_page=20" 2>/dev/null ) \
      | jq -r --argjson t "$cutoff" --argjson ok "$allowed_json" '[.[] | select(.system==false) | select([.author.username] | inside($ok)) | select(.body | test("^(## .? ?merge-medic|merge-medic)") | not) | select((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $t) | "- " + .body] | reverse | join("\n")' 2>/dev/null || true
  fi
}

# open_resolution_mr: URL of a resolution MR/PR this bot opened earlier for
# this MR that nobody has merged or closed yet (source merge-medic/fix-<iid>-*,
# target $SRC). Prints nothing when there is none; fails when the forge could
# not be asked.
open_resolution_mr() {
  local prefix="merge-medic/fix-$IID-" enc
  if mm_is_github; then
    mm_timeout "${NET_TIMEOUT:-300}" gh pr list --repo "$PROJECT_PATH" --state open \
        --base "$SRC" --limit 100 --json headRefName,url 2>/dev/null \
      | jq -er --arg p "$prefix" '[.[] | select(.headRefName | startswith($p)) | .url][0] // ""' 2>/dev/null
  else
    enc="$(jq -rn --arg s "$SRC" '$s | @uri')"
    mm_timeout "${NET_TIMEOUT:-300}" env GITLAB_HOST="${GITLAB_HOST:-}" glab api \
        "projects/${PROJECT_PATH//\//%2F}/merge_requests?state=opened&target_branch=$enc&per_page=100" 2>/dev/null \
      | jq -er --arg p "$prefix" '[.[] | select(.source_branch | startswith($p)) | .web_url][0] // ""' 2>/dev/null
  fi
}

# ── what the resolver is allowed to leave behind ─────────────────────────────
# The prompt asks it to touch nothing but the conflicted hunks; these checks
# are what hold it to that. Everything staged after the resolver ran is
# compared with the index as it was before, so an edit anywhere else — a
# protected file included — fails the run instead of riding along in the
# merge commit.

# index_snapshot: every merged (stage 0) index entry as "mode blob 0<TAB>path".
index_snapshot() {
  git -c core.quotePath=false ls-files -s | awk '$3 == 0'
}

# out_of_scope <snapshot> <allowed paths, one per line>: prints every path
# whose entry was added, removed or changed since the snapshot and is not
# allowed. Run it after staging; no output = the resolver stayed in scope.
out_of_scope() {
  local before="$1" allowed="$2"
  { printf '%s\n' "$before"; index_snapshot; } | sed '/^$/d' | LC_ALL=C sort | uniq -u \
    | cut -f2- | LC_ALL=C sort -u \
    | grep -vxF -f <(printf '%s\n' "$allowed" | sed '/^$/d') || true
}

# markers_left <file>: true when the resolved file still holds a conflict
# marker that neither side of the merge has at that place. `git diff --check`
# reports the marker lines a diff adds; a line added relative to BOTH parents
# came from neither of them, so it is a leftover. A marker-like line that one
# side really has (a fixture, a docs example, a 7-character setext underline)
# is added relative to one parent at most, and survives. CRLF files included.
markers_left() {
  local f="$1" vs_ours vs_theirs
  vs_ours="$(marker_lines HEAD "$f")"
  [ -n "$vs_ours" ] || return 1
  vs_theirs="$(marker_lines MERGE_HEAD "$f")"
  [ -n "$vs_theirs" ] || return 1
  grep -qxF -f <(printf '%s\n' "$vs_theirs") <<<"$vs_ours"
}
# marker_lines <commit> <file>: line numbers of the marker lines the file
# adds compared with <commit>, one per line
marker_lines() {
  git diff --check "$1" -- "$2" 2>/dev/null \
    | sed -n 's/^.*:\([0-9][0-9]*\): leftover conflict marker$/\1/p' || true
}

# A fresh checkout is not always clean on its own: a file committed with CRLF
# that .gitattributes now normalizes, or a filter this machine runs
# differently, makes git stage something new for a path nobody edited. The
# `git add -A` after the resolver then put that into the merge commit, and
# the scope check blamed the resolver for it.
#
# untracked_snapshot: "hash<TAB>path" of the untracked, unignored files
# there are before the resolver runs (a checkout normally leaves none)
untracked_snapshot() {
  local p
  git -c core.quotePath=false ls-files --others --exclude-standard | while IFS= read -r p; do
    [ -n "$p" ] && printf '%s\t%s\n' "$(raw_hash "$p")" "$p"
  done
  return 0
}
raw_hash() {
  if [ -L "$1" ]; then printf 'link:%s' "$(readlink "$1")"
  elif [ -f "$1" ]; then git hash-object --no-filters -- "$1"
  else printf 'missing'; fi
}
# restore_untouched <index snapshot> <untracked before> <missing before>
# <conflicts>: of the paths `git add -A` changed outside the conflict, put
# back the ones the resolver did not touch. A tracked file is untouched when
# its bytes and executable bit are still what a checkout of its old index
# entry writes (git cat-file --filters applies the same attributes); a file
# that was missing or untracked before is untouched when it still is
# missing, or has the same bytes. Only what out_of_scope flags is looked at,
# so a clean checkout costs nothing.
restore_untouched() {
  local p entry emode eblob h x
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    entry="$(P="$p" awk -F'\t' '$2 == ENVIRON["P"] { print $1; exit }' <<<"$1")"
    if [ -n "$entry" ]; then
      read -r emode eblob _ <<<"$entry"
      if grep -qxF -- "$p" <<<"$3"; then
        [ -e "$p" ] || [ -L "$p" ] || git update-index --cacheinfo "$emode,$eblob,$p"
        continue
      fi
      { [ "$emode" = 100644 ] || [ "$emode" = 100755 ]; } && [ -f "$p" ] && [ ! -L "$p" ] || continue
      if [ -x "$p" ]; then x=100755; else x=100644; fi
      [ "$x" = "$emode" ] || continue
      if git cat-file --filters --path="$p" "$eblob" 2>/dev/null | cmp -s - "$p"; then
        git update-index --cacheinfo "$emode,$eblob,$p"
      fi
    else
      h="$(P="$p" awk -F'\t' '$2 == ENVIRON["P"] { print $1; exit }' <<<"$2")"
      if [ -n "$h" ] && [ "$(raw_hash "$p")" = "$h" ]; then
        git rm -q --cached --ignore-unmatch -- ":(literal)$p" >/dev/null
      fi
    fi
  done < <(out_of_scope "$1" "$4")
}

# regular_conflict <path>: both sides changed the path (git recorded ours
# and theirs), every side it recorded is a regular file (mode 100644 or
# 100755), and so is the working copy. Only then are there lines a rule
# could decide: a symlink's content is its target, and reading through it
# would rewrite the file it points to; and the kept side of a modify/delete
# carries no markers of git's at all, so marker-shaped text in it (a test
# fixture, a docs example) would be taken for a hunk.
regular_conflict() {
  git ls-files -u -- ":(literal)$1" | awk '
    { if ($1 != "100644" && $1 != "100755") bad = 1; side[$3] = 1 }
    END { exit (NR == 0 || bad || !side[2] || !side[3]) }' || return 1
  [ -f "$1" ] && [ ! -L "$1" ]
}

# ── the resolver leaves git itself alone ──────────────────────────────────────
# It may edit and stage files. Changing how git behaves is another matter: an
# alias, a hooks path or a push URL in config, a hook, a branch or tag. All of
# that is compared around every AI call, and a push by remote name from inside
# it would show in the remote-tracking reflogs (one by URL leaves no trace:
# the claude resolver cannot run either, and no resolver's git can reach a
# remote unless the resolver itself removes GIT_ALLOW_PROTOCOL). A difference means something got past the
# resolver's permissions, so this run stops and so does every later one
# (state/quarantined) until a human has looked at the watch clone.
# Remote-tracking refs and tags are not compared: the watcher's fetches
# rewrite them while a resolver runs. The bot pushes by URL, which leaves no
# reflog entry, so its own pushes never look like the resolver's.
repo_state() {
  local common wtc
  common="$(git rev-parse --git-common-dir)"
  printf '# config\n'
  # Hooks count only when the bot runs them (RUN_GIT_HOOKS=1). Otherwise
  # neither a hook nor a hooks path can reach it, and another fixer's gate
  # may set them up at any moment (husky, lefthook, pre-commit install).
  if [ "${RUN_GIT_HOOKS:-0}" = "1" ]; then
    git config --local --list 2>/dev/null || true
  else
    git config --local --list 2>/dev/null | grep -vi '^core\.hookspath=' || true
  fi
  wtc="$(git rev-parse --git-path config.worktree)"
  if [ -f "$wtc" ]; then printf '# config.worktree\n'; cat "$wtc"; fi
  if [ "${RUN_GIT_HOOKS:-0}" = "1" ] && [ -d "$common/hooks" ]; then
    printf '# hooks\n'
    ( cd "$common/hooks" && find . -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort )
  fi
  printf '# refs\n'
  git for-each-ref --format='%(objectname) %(refname)' | grep -v -e ' refs/remotes/' -e ' refs/tags/' || true
}
# pushes_since <epoch>: remote-tracking reflogs a push wrote to since then
pushes_since() {
  local logs
  logs="$(git rev-parse --git-common-dir)/logs/refs/remotes"
  [ -d "$logs" ] || return 0
  ( cd "$logs" && find . -type f -exec awk -F'\t' -v t="$1" '
      $2 == "update by push" { n = split($1, f, " "); if (f[n - 1] + 0 >= t + 0) print substr(FILENAME, 3) }' {} + ) \
    2>/dev/null | sort -u || true
}
guard_start() {
  MM_GUARD="$(repo_state)"
  MM_GUARD_TS="$(date +%s)"
}
# guard_check <what ran>: quarantine when the repository changed under it.
# Only names reach the message: a config value can hold a credential.
guard_check() {
  local now pushed what
  now="$(repo_state)"
  pushed="$(pushes_since "$MM_GUARD_TS")"
  [ "$now" = "$MM_GUARD" ] && [ -z "$pushed" ] && return 0
  what="$( { diff <(printf '%s\n' "$MM_GUARD") <(printf '%s\n' "$now") || true; } \
    | sed -n 's/^[<>] //p' | sed -E 's/^([^= ]+)=.*/\1/; s/^[0-9a-f]{40,64} //; s/^[0-9]+ [0-9]+ //' \
    | LC_ALL=C sort -u | awk 'NR <= 5' | tr '\n' ' ')"
  [ -n "$pushed" ] && what="pushed to $(printf '%s' "$pushed" | tr '\n' ' ')$what"
  printf '%s %s%s: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$SIGIL" "$IID" "$1 changed ${what% }" \
    > "$ROOT/state/quarantined"
  git merge --abort 2>/dev/null || true
  fail "$1 changed git's own state (${what% }) — all fixing stopped: check $WATCH_REPO, then remove state/quarantined"
}

# ── no silent deaths ──────────────────────────────────────────────────────────
# fail, escalate, defer, a posted plan and a push are the ways a run is meant
# to end, and each leaves a trace: ledger, event, notification. Anything else
# (set -e tripping on a git command, a shutdown's TERM) used to end the run
# with none of that: no ledger line, the worktree left behind, the dashboard
# frozen on the last phase, and with the SHA pair already marked tried,
# nothing that would ever retry it. Such an exit is recorded as a failure.
MM_LEDGER=""        # set by ledger(): the run recorded how it ended
MM_ERR_CMD=""
MM_HOLD_BUDGET=0    # 1 while this run holds the budget lock
MM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/merge-medic.XXXXXX")"
on_exit() {
  local rc="$1" kids
  set +e
  [ "$MM_HOLD_BUDGET" = 1 ] && rmdir "$ROOT/state/.budget.lock" 2>/dev/null
  rm -rf "$MM_TMP"
  [ "$rc" = 0 ] && return 0
  # a TERM or a crash can land mid-step: stop whatever that step started
  # (a resolver still editing, a test run) before its worktree goes away
  kids="$(pgrep -P $$ 2>/dev/null | tr '\n' ' ')"
  # shellcheck disable=SC2086  # one pid per word
  [ -n "$kids" ] && mm_stop_tree $kids
  [ -n "$MM_LEDGER" ] && return 0
  ev FAIL "fixer died unexpectedly ($(rc_text "$rc")${MM_ERR_CMD:+ in: $(printf '%s' "$MM_ERR_CMD" | mm_clean | cut -c1-80)}) — see fixer-$IID.log"
  ledger FAIL
  notify "${SIGIL}$IID: fix failed" "fixer died unexpectedly ($(rc_text "$rc"))"
  cleanup_wt
}
set -E
# (the failing command, not $LINENO: bash 3.2 reports the enclosing block's
# closing line there)
trap 'MM_ERR_CMD=$BASH_COMMAND' ERR
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'on_exit $?' EXIT

: > "$PROG"
ev START "$SRC -> $TGT · mode=$MODE · $(printf '%s' "${TITLE:-}" | cut -c1-60)"

# a resolver that changed git's own state stops every later run as well,
# until a human has looked (see guard_check)
if [ -f "$ROOT/state/quarantined" ]; then
  fail "quarantined since $(cut -c1-120 "$ROOT/state/quarantined" | head -1) — check $WATCH_REPO, then remove state/quarantined"
fi

# ── push guard: non-AUTO branches are only ever pushed by an approved run ─────
src_is_auto=0
mm_src_is_auto "$SRC" && src_is_auto=1
if [ "$src_is_auto" = "0" ] && [ "$MODE" != "plan" ] && [ "$MODE" != "fix-approved" ]; then
  fail "policy · '$SRC' is not in AUTO_BRANCHES and no approval exists"
fi

cd "$WATCH_REPO"
mm_timeout "${NET_TIMEOUT:-300}" git fetch --prune --quiet origin \
  || { nrc=$?; fail "git fetch failed ($(rc_text "$nrc"))"; }

# ── defer while humans / other agent sessions are still working ───────────────
# The marker holds the unix time the fix is worth retrying at — not the time
# it was deferred. The watcher skips the MR until then, so a branch someone
# is actively pushing to costs one deferred fixer, not one per tick.
defer() { # message [retry_at]
  local until_ts="${2:-0}"
  # unknown cool-off (a dirty checkout): re-check next tick, it is cheap
  [ "$until_ts" = "0" ] && until_ts="$(date +%s)"
  ev DEFERRED "$1 — retrying $(date -r "$until_ts" '+%H:%M' 2>/dev/null || date -d "@$until_ts" '+%H:%M' 2>/dev/null || echo soon)"
  printf '%s' "$until_ts" > "$ROOT/state/deferred-$IID"
  cleanup_wt
  exit 0
}
# ours_at_head: the tip of the branch is a commit this bot made. A push of
# ours must never read as "an agent is working here" — otherwise the fixer
# defers itself for QUIET_MINUTES after every successful resolution.
ours_at_head() {
  git log -1 --format='%B' "origin/$SRC" 2>/dev/null | grep -q '^Merge-Medic-Run: '
}

# branch_worktree: where a coding agent would be working on this branch.
# Agents get one worktree per branch (<repo>/.worktrees/<branch>), so the
# registered list is the reliable lookup, with the conventional path as a
# fallback for worktrees this repo does not know about.
branch_worktree() { # user_repo
  local ur="$1" wt
  wt="$(git -C "$ur" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$SRC" '$1=="worktree"{w=$2} $1=="branch"&&$2==b{print w; exit}')"
  if [ -z "$wt" ] && [ -d "$ur/.worktrees/$SRC" ]; then
    wt="$ur/.worktrees/$SRC"
  fi
  printf '%s' "$wt"
}

if [ "${QUIET_MINUTES:-0}" -gt 0 ]; then
  if ours_at_head; then
    ev CONTEXT "info · branch tip is our own merge — not treating it as activity"
  else
    head_ts="$(git log -1 --format=%ct "origin/$SRC" 2>/dev/null || echo 0)"
    if [ "$head_ts" -gt 0 ]; then
      age_m=$(( ($(date +%s) - head_ts) / 60 ))
      # the branch is quiet QUIET_MINUTES after its last push — retry then
      [ "$age_m" -lt "$QUIET_MINUTES" ] && \
        defer "branch pushed ${age_m}m ago — someone is working on it" \
              "$(( head_ts + QUIET_MINUTES * 60 ))"
    fi
  fi

  for ur in ${USER_REPOS:-}; do
    uwt="$(branch_worktree "$ur")"
    if [ -z "$uwt" ] || [ ! -d "$uwt" ]; then continue; fi
    # uncommitted work is the strongest "hands off" signal there is
    if [ -n "$(git -C "$uwt" status --porcelain 2>/dev/null | head -1)" ]; then
      defer "uncommitted work in $uwt"
    fi
    # a local commit the agent has not pushed yet is just as much activity,
    # and origin/<branch> cannot see it
    local_ts="$(git -C "$uwt" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [ "$local_ts" -gt 0 ] && \
       ! git -C "$uwt" log -1 --format='%B' 2>/dev/null | grep -q '^Merge-Medic-Run: '; then
      local_age=$(( ($(date +%s) - local_ts) / 60 ))
      [ "$local_age" -lt "${QUIET_MINUTES:-0}" ] && \
        defer "unpushed commit ${local_age}m ago in $uwt" \
              "$(( local_ts + QUIET_MINUTES * 60 ))"
    fi
  done
fi

# ── one resolution MR per MR ──────────────────────────────────────────────────
# In mr mode a resolution waits for a human to merge it, and until then the
# MR is still conflicted. Every push to either branch changes the dedup key
# and used to start another resolver run and open another resolution MR for
# the same conflict. An open one means the answer is already up for review.
# (An approved run is a human asking for a fresh one: it is not held back.)
if [ "${PUSH_MODE:-mr}" != "direct" ] && [ "$MODE" != "fix-approved" ]; then
  if open_res="$(open_resolution_mr)"; then
    if [ -n "$open_res" ]; then
      defer "resolution MR already open, merge or close it first: $open_res" "$(( $(date +%s) + 3600 ))"
    fi
  else
    ev CONTEXT "info · could not look up open resolution MRs — continuing"
  fi
fi

ev WORKTREE "$WT"
cleanup_wt
# detached: no fixer moves a local branch, so local refs stay still while a
# resolver runs and any change to them is the resolver's (guard_check)
wrc=0
mm_timeout "$GIT_TIMEOUT" git worktree add --force --detach "$WT" "origin/$SRC" >/dev/null 2>&1 || wrc=$?
[ "$wrc" = 0 ] || fail "worktree add failed ($(rc_text "$wrc"))"
cd "$WT"
rm -f "$ESCFILE" "$SUMFILE"

MERGE_BASE="$(git merge-base HEAD "origin/$TGT" 2>/dev/null || echo '')"

ev MERGE "origin/$TGT"
ai_ran=0
summary=""
mrc=0
mm_timeout "$GIT_TIMEOUT" git -c merge.conflictStyle=zdiff3 merge --no-ff --no-edit \
  -m "chore: merge origin/$TGT into $SRC (${SIGIL}$IID)" "origin/$TGT" >/dev/null 2>&1 || mrc=$?
[ "$mrc" = 124 ] && fail "merge of origin/$TGT timed out after ${GIT_TIMEOUT}s"
if [ "$mrc" = 0 ]; then
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
  # quotePath=false: git would otherwise print any non-ASCII name as a
  # "C-quoted" string, which neither the escalation globs nor the file checks
  # below can match
  conflicts="$(git -c core.quotePath=false diff --name-only --diff-filter=U)"
  [ -z "$conflicts" ] && fail "merge failed without conflicting files"
  n="$(printf '%s\n' "$conflicts" | grep -c .)"

  # ── hard escalation zones: the bot never decides here ───────────────────────
  # (an approved re-run is a human decision — the zones are theirs to open)
  # mm_glob_match, not an unquoted loop: expanded in this worktree, a pattern
  # like "src/auth/*" would only ever match the files directly in src/auth.
  if [ "$MODE" != "fix-approved" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # still quoted (a quote, backslash or control character in the name):
      # no check below can be trusted with it
      case "$f" in
        \"*) git merge --abort 2>/dev/null || true
             escalate "policy · $f has a name git has to quote — resolve it by hand" ;;
      esac
      if pat="$(mm_glob_match "$f" "${ESCALATE_PATTERNS:-}")"; then
        git merge --abort 2>/dev/null || true
        escalate "policy · protected path $f matches ESCALATE_PATTERNS '$pat'"
      fi
    done <<<"$conflicts"
  fi

  # ── deterministic rules: close what needs no judgement, for free ───────────
  # Stamp lines every branch rewrites ("> verified: <sha>" and friends)
  # conflict constantly and carry no decision. Resolving them here costs no
  # tokens, no budget slot and no waiting, and shrinks what the model is
  # shown when something real is left behind.
  rules_only=0
  rules_on=0
  if [ -n "${RULES_KEEP_OURS:-}" ]; then
    # rules.awk refuses a pattern it cannot use (one that matches every line,
    # or one that does not parse): say so once, not once per file
    rrc=0
    awk -v keep_ours="$RULES_KEEP_OURS" -v ours_label=HEAD -v theirs_label="origin/$TGT" \
      -f "$ROOT/rules.awk" /dev/null >/dev/null 2>&1 || rrc=$?
    if [ "$rrc" = 3 ]; then
      rules_on=1
    else
      ev RULES "WARN · RULES_KEEP_OURS matches every line or does not parse — rules layer off"
    fi
  fi
  if [ "$rules_on" = 1 ]; then
    rules_left=""; rules_done=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # a modify/delete, a symlink or a submodule has no lines a rule could
      # decide: they go to the resolver exactly as git left them
      if ! regular_conflict "$f"; then
        rules_left="$rules_left$f
"
        continue
      fi
      rc=0
      awk -v keep_ours="$RULES_KEEP_OURS" -v ours_label=HEAD -v theirs_label="origin/$TGT" \
        -f "$ROOT/rules.awk" "$f" > "$MM_TMP/rules-out" 2>/dev/null || rc=$?
      # written back in place: a new file moved over it would lose the
      # executable bit
      case "$rc" in
        0) cat "$MM_TMP/rules-out" > "$f"; git add -- "$f"; rules_done=$((rules_done + 1)) ;;
        1) cat "$MM_TMP/rules-out" > "$f"                # partly decided: fewer hunks for the model
           rules_left="$rules_left$f
" ;;
        # unparsable, or no hunks at all (binary): leave the file exactly as
        # git left it
        *) rules_left="$rules_left$f
" ;;
      esac
    done <<<"$conflicts"
    [ "$rules_done" -gt 0 ] && ev RULES "ok · $rules_done of $n file(s) decided by rules, no model"
    conflicts="$(printf '%s' "$rules_left" | sed '/^$/d')"
    n="$(printf '%s\n' "$conflicts" | grep -c . || true)"
    if [ -z "$conflicts" ]; then
      # everything was mechanical: commit and go straight to the gates
      merge_msg="$(grep -v '^#' "$(git rev-parse --git-dir)/MERGE_MSG" 2>/dev/null | sed '/^$/d')"
      [ -n "$merge_msg" ] || merge_msg="chore: merge origin/$TGT into $SRC (${SIGIL}$IID)"
      crc=0
      mm_timeout "$GIT_TIMEOUT" git commit -m "$merge_msg" -m "Merge-Medic-Run: $IID" >/dev/null || crc=$?
      [ "$crc" = 0 ] || fail "commit failed ($(rc_text "$crc"))"
      resolve_mode="rules"
      rules_only=1
    fi
  fi

  if [ "$rules_only" = "0" ]; then

  # ── AI budget (atomic via mkdir lock) ───────────────────────────────────────
  today="$(date '+%Y-%m-%d')"; BUDGET_FILE="$ROOT/state/budget-$today"
  BLOCK="$ROOT/state/.budget.lock"
  # The lock covers a read-modify-write of one small file: microseconds. One
  # older than a minute was left by a run that died holding it, and every
  # later fixer would wait on it forever — take it over.
  waited=0
  until mkdir "$BLOCK" 2>/dev/null; do
    waited=$((waited + 1))
    if [ $((waited % 50)) = 0 ] && [ -n "$(find "$BLOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      evx WARN "info · took over a stale budget lock"
      rmdir "$BLOCK" 2>/dev/null || true
    fi
    sleep 0.2
  done
  MM_HOLD_BUDGET=1
  spent="$(cat "$BUDGET_FILE" 2>/dev/null || echo 0)"
  # DAILY_AGENT_RUNS=0 means unlimited — count runs, never refuse
  if [ "${DAILY_AGENT_RUNS:-6}" -gt 0 ] && [ "$spent" -ge "${DAILY_AGENT_RUNS:-6}" ]; then
    rmdir "$BLOCK"; MM_HOLD_BUDGET=0; git merge --abort 2>/dev/null || true
    fail "daily AI budget exhausted ($spent/${DAILY_AGENT_RUNS:-6})"
  fi
  echo $((spent + 1)) > "$BUDGET_FILE"; rmdir "$BLOCK"; MM_HOLD_BUDGET=0

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

  # the claude resolver is told what its permissions let it run, so it does
  # not spend turns on commands that are refused anyway
  tool_note=""
  if [ "${RESOLVER:-claude}" = "claude" ]; then
    if [ "$MODE" = "plan" ]; then
      tool_note="Your shell runs read-only git only: status, log, show, and diff alone or against --cached, HEAD or MERGE_HEAD."
    else
      tool_note="Your shell runs only these git commands: status, log, show, diff (alone or against --cached, HEAD or MERGE_HEAD), add, rm, checkout --ours, checkout --theirs. Anything else is refused."
    fi
  fi

  # ── plan mode: describe the resolution, post it, wait for a human ───────────
  if [ "$MODE" = "plan" ]; then
    ev PLAN "$n file(s): $(printf '%s' "$conflicts" | tr '\n' ' ' | cut -c1-120)"
    PLANFILE="$ROOT/state/plan-$IID.md"
    guard_start
    set +e
    mm_timeout "${RESOLVER_TIMEOUT:-900}" resolver_call plan "A merge of origin/$TGT into $SRC (${SIGIL}$IID${TITLE:+ — \"$TITLE\"}) has conflicts. You are in the worktree mid-merge with zdiff3 markers (||||||| shows the common ancestor). Do NOT edit anything — read the conflicted files and write a RESOLUTION PLAN as your answer.${tool_note:+ $tool_note}

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
    guard_check "the plan agent"
    git merge --abort 2>/dev/null || true
    [ "$prc" != "0" ] && fail "plan agent failed ($(rc_text "$prc"))"
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
  if [ "$MODE" = "fix-approved" ]; then
    cutoff_file=""
    if [ -f "$ROOT/state/plan-$IID.md" ]; then
      approved_ctx+="$(printf '\n\nApproved resolution plan (execute it):\n%s' "$(cat "$ROOT/state/plan-$IID.md")")"
      cutoff_file="$ROOT/state/plan-$IID.md"
    fi
    if [ -f "$ROOT/state/esc-$IID.md" ]; then
      approved_ctx+="$(printf '\n\nYour earlier escalation brief (you wrote this, the human has now answered):\n%s' "$(cat "$ROOT/state/esc-$IID.md")")"
      [ -z "$cutoff_file" ] && cutoff_file="$ROOT/state/esc-$IID.md"
    fi
    if [ -f "$ROOT/state/answers-$IID.md" ]; then
      approved_ctx+="$(printf '\n\nHuman ANSWERS to your questions — these are decisions, follow them:\n%s' "$(cat "$ROOT/state/answers-$IID.md")")"
    fi
    if [ -n "$cutoff_file" ]; then
      fb="$(collect_feedback "$cutoff_file")"
      [ -n "$fb" ] && approved_ctx+="$(printf '\n\nHuman corrections from MR comments — these OVERRIDE everything above:\n%s' "$fb")"
    fi
  fi

  ev AI_RESOLVE "$n file(s): $(printf '%s' "$conflicts" | tr '\n' ' ' | cut -c1-120)"
  AILOG="$LOGDIR/ai-$IID-$(date '+%Y%m%d-%H%M%S').log"
  pre_head="$(git rev-parse HEAD)"
  pre_index="$(index_snapshot)"
  pre_untracked="$(untracked_snapshot)"
  pre_missing="$(git -c core.quotePath=false ls-files --deleted)"
  guard_start
  set +e
  mm_timeout "${RESOLVER_TIMEOUT:-900}" resolver_call resolve "You are resolving git merge conflicts in a worktree (branch $SRC, origin/$TGT merged in, ${SIGIL}$IID${TITLE:+ — \"$TITLE\"}).

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
  neither the defaults nor the project rules decide it safely — do NOT guess.
  Instead write an ESCALATION BRIEF into a file named $ESCFILE in the repo
  root and stop. The brief is GitHub-flavored markdown with EXACTLY these
  sections: '## Blocked' (one line: why this needs a human),
  '## How I would resolve it' (your best resolution, concrete, per file),
  '## Questions' (a numbered list of the specific decisions you need answered
  — the human will answer them and re-run you).
- After editing: git add each resolved file. Do NOT commit, do NOT push.${tool_note:+
- $tool_note}
- Write a summary into a file named $SUMFILE in the repo root, as
  GitHub-flavored markdown: a '### <file path>' heading per file with bullets
  '**source:** …', '**target:** …', '**kept:** …'. No preamble.$approved_ctx$policy" \
    "$AILOG" > "$AILOG.ans"
  rc=$?
  set -e
  guard_check "the resolver"
  # keep the human-readable resolver answer at the end of AILOG
  cat "$AILOG.ans" >> "$AILOG" 2>/dev/null || true
  rm -f "$AILOG.ans"
  if [ -f "$ESCFILE" ]; then
    cp "$ESCFILE" "$ROOT/state/esc-$IID.md" 2>/dev/null || true
    reason="$(grep -m1 -A1 '^## Blocked' "$ESCFILE" 2>/dev/null | tail -1)"
    [ -z "$reason" ] && reason="$(head -3 "$ESCFILE" | tr '\n' ' ')"
    git merge --abort 2>/dev/null || true
    ev ESCALATED "AI declined: ${reason:-incompatible changes}"; ledger ESCALATED
    notify "${SIGIL}$IID: needs your answers" "mrwatch chat $IID"
    post_note "## 🩹 merge-medic — escalated: I need your answers

**MR:** \`$SRC\` → \`$TGT\` (${SIGIL}$IID)

$(cat "$ROOT/state/esc-$IID.md")

> [!NOTE]
> Answer the questions in a comment here (or run \`mrwatch chat $IID\` locally),
> then approve — I'll finish the resolution with your answers."
    cleanup_wt
    exit 2
  fi
  [ "$rc" != "0" ] && fail "resolver failed ($(rc_text "$rc"), log: ${AILOG##*/})"
  # the merge is the bot's to conclude: a resolver that committed or aborted
  # it has left a state nobody reviewed
  [ "$(git rev-parse HEAD)" = "$pre_head" ] || fail "resolver moved HEAD (it committed on its own) — nothing pushed"
  git rev-parse -q --verify MERGE_HEAD >/dev/null || fail "resolver ended the merge itself — nothing pushed"
  [ -n "$(git diff --name-only --diff-filter=U)" ] && fail "unresolved files remain"
  # per-file loop (not an unquoted $conflicts expansion): survives spaces in paths
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    markers_left "$cf" && fail "conflict markers remain in $cf"
  done <<<"$conflicts"
  rm -f "$ESCFILE"
  # capture the AI's summary BEFORE staging so it never lands in the commit
  [ -f "$SUMFILE" ] && summary="$(cat "$SUMFILE")" && rm -f "$SUMFILE"
  # aider keeps its chat history and repo-map cache (.aider*) in the repo
  # root: resolver bookkeeping, never part of the resolution
  git add -A -- . ':(exclude).aider*'
  restore_untouched "$pre_index" "$pre_untracked" "$pre_missing" "$conflicts"
  stray="$(out_of_scope "$pre_index" "$conflicts")"
  if [ -n "$stray" ]; then
    fail "resolver changed files outside the conflict — nothing pushed: $(printf '%s' "$stray" | tr '\n' ' ' | cut -c1-200)"
  fi
  # The trailer is how a later tick recognises this commit as ours: without
  # it a bot push and an agent push are indistinguishable, and the fixer
  # defers itself for QUIET_MINUTES after every resolution it lands.
  # git prepared the merge message in MERGE_MSG; keep it and append.
  merge_msg="$(grep -v '^#' "$(git rev-parse --git-dir)/MERGE_MSG" 2>/dev/null | sed '/^$/d')"
  [ -n "$merge_msg" ] || merge_msg="chore: merge origin/$TGT into $SRC (${SIGIL}$IID)"
  crc=0
  mm_timeout "$GIT_TIMEOUT" git commit -m "$merge_msg" -m "Merge-Medic-Run: $IID" >/dev/null || crc=$?
  [ "$crc" = 0 ] || fail "commit failed ($(rc_text "$crc"))"
  ai_ran=1
  resolve_mode="ai"
fi

fi   # rules_only: everything below runs for both paths

if [ -n "${VERIFY_CMD:-}" ]; then
  run_gate VERIFY "$VERIFY_CMD"
else
  ev VERIFY "skip · VERIFY_CMD is empty"
fi

# ── focused tests on the conflicted files (AI resolutions only) ───────────────
if [ "$ai_ran" = "1" ] && [ -n "${TEST_CMD_TEMPLATE:-}" ]; then
  files_flat="$(printf '%s' "${conflicts:-}" | tr '\n' ' ')"
  run_gate TESTS "${TEST_CMD_TEMPLATE//\{files\}/$files_flat}"
elif [ -z "${TEST_CMD_TEMPLATE:-}" ]; then
  ev TESTS "skip · TEST_CMD_TEMPLATE is empty"
else
  ev TESTS "skip · clean merge, no AI resolution to test"
fi

# ── regression suite ──────────────────────────────────────────────────────────
when="${REGRESSION_WHEN:-ai}"
if [ -z "${REGRESSION_CMD:-}" ]; then
  ev REGRESSION "skip · REGRESSION_CMD is empty"
elif [ "$when" = "always" ] || { [ "$when" = "ai" ] && [ "$ai_ran" = "1" ]; }; then
  run_gate REGRESSION "$REGRESSION_CMD"
else
  ev REGRESSION "skip · REGRESSION_WHEN=$when and this was a clean merge"
fi

# ── push: direct (into the source branch) or via a resolution MR/PR ───────────
# By URL, not by remote name: no remote-tracking reflog entry, so a push in
# guard_check's records is never the bot's own. No tags ride along, whatever
# push.followTags says. A pre-push hook (RUN_GIT_HOOKS=1) runs inside the
# push, so it gets GIT_TIMEOUT on top of NET_TIMEOUT.
res_link=""
push_url="$(git remote get-url --push origin)"
push_secs="$NET_TIMEOUT"
if [ "${RUN_GIT_HOOKS:-0}" = "1" ] && [ "$NET_TIMEOUT" != 0 ] && [ "$GIT_TIMEOUT" != 0 ]; then
  push_secs=$((NET_TIMEOUT + GIT_TIMEOUT))
fi
if [ "${PUSH_MODE:-mr}" != "direct" ]; then
  FIXBR="merge-medic/fix-$IID-$(date +%s)"
  ev PUSH "mr · resolution branch $FIXBR (your branch stays untouched)"
  mm_timeout "$push_secs" git push --no-follow-tags "$push_url" "HEAD:refs/heads/$FIXBR" >/dev/null 2>&1 \
    || { nrc=$?; fail "push of $FIXBR failed ($(rc_text "$nrc"))"; }
  res_title="merge-medic: resolve conflicts of ${SIGIL}$IID ($SRC <- $TGT)"
  res_body="Automated conflict resolution for ${SIGIL}$IID. Merge this into \`$SRC\` to clear the conflict — your branch is untouched until you do."
  if mm_is_github; then
    res_link="$(mm_timeout "${NET_TIMEOUT:-300}" gh pr create --repo "$PROJECT_PATH" --head "$FIXBR" --base "$SRC" \
      --title "$res_title" --body "$res_body" 2>>"$LOGDIR/fixer-$IID.log" || true)"
  else
    res_link="$(mm_timeout "${NET_TIMEOUT:-300}" env GITLAB_HOST="${GITLAB_HOST:-}" glab api "projects/:fullpath/merge_requests" \
      -f "source_branch=$FIXBR" -f "target_branch=$SRC" -f "title=$res_title" \
      -f "description=$res_body" -f remove_source_branch=true 2>>"$LOGDIR/fixer-$IID.log" \
      | jq -r '.web_url // empty' || true)"
  fi
  [ -n "$res_link" ] || fail "resolution branch pushed but the MR/PR could not be created ($FIXBR)"
  ev DONE "ok · resolution MR ready: $res_link"
  ledger DONE
  notify "${SIGIL}$IID resolved ✓" "review & merge: $res_link"
else
  ev PUSH "direct · origin $SRC"
  mm_timeout "$push_secs" git push --no-follow-tags "$push_url" "HEAD:refs/heads/$SRC" >/dev/null 2>&1 \
    || { nrc=$?; fail "push to $SRC failed ($(rc_text "$nrc")) — if $SRC moved ahead, the next tick retries"; }

  ev DONE "ok · merged origin/$TGT into $SRC, gates green, pushed $(git rev-parse --short HEAD)"
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
