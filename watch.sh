#!/bin/bash
# merge-medic watcher: polls open MRs, detects merge conflicts for free
# (bash + glab api, zero tokens), and hands each newly-conflicted MR to a
# phase-driven fixer (fix-mr.sh). The expensive AI resolver runs only when:
#   * an MR is really in `conflict` state, AND
#   * this (source_sha, target_sha) pair has not been tried yet, AND
#   * the daily AI budget is not exhausted.
# So the poll interval can be short without burning anything.
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
ROOT="$(cd "$(dirname "$SELF")" && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck source=/dev/null
source "$ROOT/config.env"
# shellcheck source=lib.sh
source "$ROOT/lib.sh"

LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/watch.log"
STATE="$ROOT/state"; mkdir -p "$STATE"

# Dedup markers are split per mode: what was "already shown" in a dry run must
# not silence live mode. Otherwise flipping DRY_RUN=1 -> 0 does nothing until
# somebody moves a branch.
MARK="tried"; [ "${DRY_RUN:-1}" = "1" ] && MARK="dry"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

notify() { mm_notify "$@"; }

# ── log rotation ──────────────────────────────────────────────────────────────
if [ -f "$LOG" ] && [ "$(mm_filesize "$LOG")" -gt 5242880 ]; then
  mv -f "$LOG" "$LOG.1"
fi
if [ -f "$LOGDIR/events.log" ] && [ "$(mm_filesize "$LOGDIR/events.log")" -gt 5242880 ]; then
  mv -f "$LOGDIR/events.log" "$LOGDIR/events.log.1"
fi

# ── single instance ───────────────────────────────────────────────────────────
LOCK="$ROOT/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  prev="$(cat "$LOCK/pid" 2>/dev/null || echo '')"
  if [ -n "$prev" ] && kill -0 "$prev" 2>/dev/null; then
    exit 0   # previous tick still running — leave silently
  fi
  log "WARN: removing stale lock (pid ${prev:-?})"; rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# ── daily AI budget (guard; fixers do the real accounting) ────────────────────
today="$(date '+%Y-%m-%d')"
BUDGET_FILE="$STATE/budget-$today"
[ -f "$BUDGET_FILE" ] || echo 0 > "$BUDGET_FILE"
find "$STATE" -name 'budget-*' -mtime +3 -delete 2>/dev/null || true
spent="$(cat "$BUDGET_FILE")"

# ── pick conflicted MRs/PRs not yet tried ─────────────────────────────────────
targets=""   # iid<TAB>source<TAB>target<TAB>title
verbose=0
SIGIL="$(mm_ref_sigil)"

# Shared edge/dedup logic: called once per MR/PR with normalized fields.
consider() {
  local iid="$1" src="$2" tgt="$3" title="$4" draft="$5" status="$6" ssha="$7" tsha="$8" ci="${9:-none}" author="${10:-?}" upd="${11:-?}"
  local seen_file="$STATE/mr-$iid" prev_status
  prev_status="$(cut -d' ' -f1 "$seen_file" 2>/dev/null || echo 'none')"
  # status shas src tgt ci author updated title — for the dashboard
  echo "$status $ssha:$tsha $src $tgt $ci $author $upd $title" > "$seen_file"

  [ "$status" != "conflict" ] && return 0

  # edge: state change worth logging + notifying
  if [ "$prev_status" != "conflict" ]; then
    log "  $SIGIL$iid  went into CONFLICT  ($src -> $tgt)  $title"; verbose=1
    notify "Conflict in $SIGIL$iid" "$src -> $tgt: $title"
  fi

  if [ "${SKIP_DRAFTS:-1}" = "1" ] && [ "$draft" = "true" ]; then return 0; fi

  local ex
  # shellcheck disable=SC2153  # EXCLUDE_BRANCHES comes from config.env
  for ex in ${EXCLUDE_BRANCHES:-}; do [ "$src" = "$ex" ] && return 0; done

  # allowlist: when INCLUDE_BRANCHES is set, only matching source branches
  # are handled at all (globs, space-separated); empty = every branch
  if [ -n "${INCLUDE_BRANCHES:-}" ]; then
    local inc ok=0
    for inc in $INCLUDE_BRANCHES; do
      # shellcheck disable=SC2254
      case "$src" in $inc) ok=1;; esac
    done
    [ "$ok" = "1" ] || return 0
  fi

  # routing: AUTO_BRANCHES sources are fixed fully automatically; everything
  # else runs the semi-auto plan -> human approve -> fix flow
  local mode="plan" ab
  for ab in ${AUTO_BRANCHES:-feat-*}; do
    # shellcheck disable=SC2254
    case "$src" in $ab) mode="auto";; esac
  done
  if [ "$mode" = "plan" ] && [ -f "$STATE/approve-$iid" ]; then
    mode="fix-approved"
    rm -f "$STATE/approve-$iid"
  fi

  # deferred (branch was hot): retry on every tick — the fixer re-checks the
  # branch cheaply (fetch + git log, no AI) and re-defers if it is still hot,
  # so the fix lands one tick after the branch has been quiet for
  # QUIET_MINUTES, instead of a full quiet period after the last defer.
  # The 60s grace only shields the fixer launched by the previous tick.
  if [ -f "$STATE/deferred-$iid" ]; then
    dts="$(cat "$STATE/deferred-$iid")"
    if [ $(( $(date +%s) - dts )) -lt 60 ]; then
      return 0
    fi
    rm -f "$STATE/deferred-$iid" "$STATE/$MARK-$iid"
  fi

  # this exact commit pair was already tried and failed — don't burn tokens again
  if [ -f "$STATE/$MARK-$iid" ] && [ "$(cat "$STATE/$MARK-$iid")" = "$ssha:$tsha" ]; then
    return 0
  fi

  targets+="$iid	$src	$tgt	$mode	$title
"
}

if [ "${PROVIDER:-gitlab}" = "github" ]; then
  # ── GitHub via gh ───────────────────────────────────────────────────────────
  command -v gh >/dev/null 2>&1 || { log "ERROR: PROVIDER=github but gh is not installed"; exit 1; }
  prs="$(gh pr list --repo "$PROJECT_PATH" --state open --limit 100 \
        --json number,title,headRefName,baseRefName,mergeable,isDraft,headRefOid,statusCheckRollup,author,updatedAt 2>/dev/null || echo '')"
  if [ -z "$prs" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs"; then
    log "ERROR: could not list PRs (check gh auth status)"; exit 1
  fi
  while IFS= read -r row; do
    iid="$(jq -r '.number' <<<"$row")"
    mergeable="$(jq -r '.mergeable' <<<"$row")"
    # GitHub computes mergeability asynchronously — give it a moment
    if [ "$mergeable" = "UNKNOWN" ]; then
      sleep 5
      mergeable="$(gh pr view "$iid" --repo "$PROJECT_PATH" --json mergeable --jq .mergeable 2>/dev/null || echo UNKNOWN)"
    fi
    case "$mergeable" in
      CONFLICTING) status="conflict" ;;
      MERGEABLE)   status="mergeable" ;;
      *)           status="unknown" ;;
    esac
    src="$(jq -r '.headRefName' <<<"$row")"
    tgt="$(jq -r '.baseRefName' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    draft="$(jq -r '.isDraft' <<<"$row")"
    ssha="$(jq -r '.headRefOid // "?"' <<<"$row")"
    tsha="$(gh api "repos/$PROJECT_PATH/commits/$tgt" --jq .sha 2>/dev/null || echo '?')"
    ci="$(jq -r '(.statusCheckRollup // []) | map(.conclusion // .state // "") | if length==0 then "none" elif any(.=="FAILURE" or .=="ERROR" or .=="CANCELLED") then "failed" elif all(.=="SUCCESS" or .=="NEUTRAL" or .=="SKIPPED") then "success" else "running" end' <<<"$row")"
    author="$(jq -r '.author.login // "?"' <<<"$row")"
    upd="$(jq -r '.updatedAt // "?"' <<<"$row")"
    consider "$iid" "$src" "$tgt" "$title" "$draft" "$status" "$ssha" "$tsha" "$ci" "$author" "$upd"
  done < <(jq -c '.[]' <<<"$prs")
else
  # ── GitLab via glab ─────────────────────────────────────────────────────────
  ENC_PATH="${PROJECT_PATH//\//%2F}"
  export GITLAB_HOST
  mrs="$(glab api "projects/$ENC_PATH/merge_requests?state=opened&per_page=100" 2>/dev/null || echo '')"
  if [ -z "$mrs" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$mrs"; then
    log "ERROR: could not list MRs (check glab auth status / GITLAB_TOKEN)"; exit 1
  fi
  for iid in $(jq -r '.[].iid' <<<"$mrs"); do
    mr="$(glab api "projects/$ENC_PATH/merge_requests/$iid" 2>/dev/null || echo '{}')"
    status="$(jq -r '.detailed_merge_status // "unknown"' <<<"$mr")"

    # GitLab computes mergeability asynchronously — give it a moment
    if [ "$status" = "checking" ] || [ "$status" = "unchecked" ]; then
      sleep 5
      mr="$(glab api "projects/$ENC_PATH/merge_requests/$iid" 2>/dev/null || echo '{}')"
      status="$(jq -r '.detailed_merge_status // "unknown"' <<<"$mr")"
    fi

    src="$(jq -r '.source_branch' <<<"$mr")"
    tgt="$(jq -r '.target_branch' <<<"$mr")"
    title="$(jq -r '.title' <<<"$mr")"
    draft="$(jq -r '.draft' <<<"$mr")"
    ssha="$(jq -r '.sha // .diff_refs.head_sha // "?"' <<<"$mr")"
    tsha="$(jq -r '.diff_refs.base_sha // "?"' <<<"$mr")"
    ci="$(jq -r '.head_pipeline.status // "none"' <<<"$mr")"
    author="$(jq -r '.author.username // "?"' <<<"$mr")"
    upd="$(jq -r '.updated_at // "?"' <<<"$mr")"
    consider "$iid" "$src" "$tgt" "$title" "$draft" "$status" "$ssha" "$tsha" "$ci" "$author" "$upd"
  done
fi

# ── conflict radar: pairwise merge-tree between open MRs sharing a target ────
# "Your MR will conflict with !X when either merges" — detected before it
# hurts, for free (in-memory merge-tree, zero tokens, zero API calls).
radar_scan() {
  [ "${RADAR:-1}" = "1" ] || return 0
  local out="$STATE/radar.tmp" list="" f iid status shas src tgt rest
  : > "$out"
  for f in "$STATE"/mr-*; do
    [ -f "$f" ] || continue
    iid="${f##*/mr-}"
    # shellcheck disable=SC2034  # shas/rest are placeholders for unused fields
    read -r status shas src tgt rest < "$f" || continue
    [ -n "$src" ] && [ -n "$tgt" ] || continue
    list+="$iid $src $tgt
"
  done
  if [ "$(printf '%s' "$list" | grep -c . || true)" -lt 2 ]; then
    mv "$out" "$STATE/radar"; return 0
  fi
  if [ ! -d "$WATCH_REPO/.git" ]; then
    git clone --quiet "$GIT_REMOTE_URL" "$WATCH_REPO" >>"$LOG" 2>&1 || { rm -f "$out"; return 0; }
  fi
  git -C "$WATCH_REPO" fetch --prune --quiet origin >>"$LOG" 2>&1 || { rm -f "$out"; return 0; }
  local pairs=0 a_iid a_src a_tgt b_iid b_src b_tgt
  while IFS=' ' read -r a_iid a_src a_tgt; do
    [ -z "$a_iid" ] && continue
    while IFS=' ' read -r b_iid b_src b_tgt; do
      [ -z "$b_iid" ] && continue
      [ "$a_iid" -lt "$b_iid" ] 2>/dev/null || continue
      [ "$a_tgt" = "$b_tgt" ] || continue
      pairs=$((pairs+1)); [ "$pairs" -gt 30 ] && break 2
      git -C "$WATCH_REPO" rev-parse --quiet --verify "origin/$a_src" >/dev/null 2>&1 || continue
      git -C "$WATCH_REPO" rev-parse --quiet --verify "origin/$b_src" >/dev/null 2>&1 || continue
      if ! git -C "$WATCH_REPO" merge-tree --write-tree "origin/$a_src" "origin/$b_src" >/dev/null 2>&1; then
        printf '%s|%s|%s|%s\n' "$a_iid" "$b_iid" "$a_src" "$b_src" >> "$out"
        if ! grep -qF "$a_iid|$b_iid|" "$STATE/radar" 2>/dev/null; then
          log "RADAR: $SIGIL$a_iid ($a_src) and $SIGIL$b_iid ($b_src) conflict with EACH OTHER — first to merge wins"
          notify "Radar: $SIGIL$a_iid × $SIGIL$b_iid" "$a_src and $b_src conflict with each other"
        fi
      fi
    done <<<"$list"
  done <<<"$list"
  mv "$out" "$STATE/radar"
}
radar_scan

if [ -z "$targets" ]; then
  [ "$verbose" = "1" ] && log "no new conflicts to fix"
  exit 0
fi

count="$(printf '%s' "$targets" | grep -c . || true)"
lim="${DAILY_AGENT_RUNS:-6}"
lim_label="$lim"; [ "$lim" = "0" ] && lim_label="∞"
log "to fix: $count MR(s); AI budget spent today: $spent/$lim_label"

if [ "$lim" -gt 0 ] && [ "$spent" -ge "$lim" ]; then
  log "daily AI budget exhausted — skipping"; exit 0
fi

# herestring (not a pipe): $( ) strips the final \n and `read` would lose the
# last record — and with it the "already tried" mark, i.e. an eternal retry.
targets="$(printf '%s' "$targets" | head -n "$MAX_MRS_PER_RUN")"
while IFS=$'\t' read -r iid src tgt mode _; do
  [ -n "$iid" ] && log "  -> $SIGIL$iid  $src -> $tgt  [$mode]"
done <<<"$targets"

if [ "${DRY_RUN:-1}" = "1" ]; then
  log "DRY_RUN=1 — not merging or pushing anything"
  while IFS=$'\t' read -r iid _ _ _; do
    [ -z "$iid" ] && continue
    cut -d' ' -f2 "$STATE/mr-$iid" > "$STATE/$MARK-$iid" 2>/dev/null || true
  done <<<"$targets"
  exit 0
fi

# ── dedicated clone (created lazily, only when there is real work) ────────────
if [ ! -d "$WATCH_REPO/.git" ]; then
  log "cloning $GIT_REMOTE_URL -> $WATCH_REPO"
  git clone --quiet "$GIT_REMOTE_URL" "$WATCH_REPO" >>"$LOG" 2>&1
fi
git -C "$WATCH_REPO" fetch --prune --quiet origin >>"$LOG" 2>&1 || {
  log "ERROR: git fetch failed"; exit 1; }

# ── mark pairs as tried BEFORE launching (no retry loops on crashes) ──────────
while IFS=$'\t' read -r iid _ _ _; do
  [ -z "$iid" ] && continue
  cut -d' ' -f2 "$STATE/mr-$iid" > "$STATE/$MARK-$iid" 2>/dev/null || true
done <<<"$targets"

# ── launch fixers (fix-mr.sh, one per MR; cap PARALLEL_FIXERS) ────────────────
# Each fixer decides on its own whether AI is needed (only on real conflict
# markers), accounts the AI budget, and writes phases to
# state/progress-<iid>.log for `mrwatch top`.
running_fixers() { pgrep -f "$ROOT/fix-mr.sh" 2>/dev/null | wc -l | tr -d ' '; }

notify "Conflicts: $count MR(s)" "Launching fixers (mrwatch top for progress)"
launched=0
while IFS=$'\t' read -r iid src tgt mode title; do
  [ -z "$iid" ] && continue
  while [ "$(running_fixers)" -ge "${PARALLEL_FIXERS:-1}" ]; do sleep 5; done
  log "  fixer -> $SIGIL$iid  ($src -> $tgt) [$mode]; log: fixer-$iid.log"
  nohup bash "$ROOT/fix-mr.sh" "$iid" "$src" "$tgt" "$title" "$mode" >> "$LOGDIR/fixer-$iid.log" 2>&1 &
  launched=$((launched + 1))
  sleep 1
done <<<"$targets"
log "fixers launched: $launched (cap ${PARALLEL_FIXERS:-1}); results arrive as notifications"
