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

LOGDIR="$ROOT/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/watch.log"
STATE="$ROOT/state"; mkdir -p "$STATE"

# Dedup markers are split per mode: what was "already shown" in a dry run must
# not silence live mode. Otherwise flipping DRY_RUN=1 -> 0 does nothing until
# somebody moves a branch.
MARK="tried"; [ "${DRY_RUN:-1}" = "1" ] && MARK="dry"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# macOS notification (NOTIFY=1 in config.env). osascript errors never kill us.
notify() {
  [ "${NOTIFY:-0}" = "1" ] || return 0
  local title="$1" body="$2"
  osascript -e "display notification \"${body//\"/\\\"}\" with title \"merge-medic\" subtitle \"${title//\"/\\\"}\" sound name \"${NOTIFY_SOUND:-Submarine}\"" >/dev/null 2>&1 || true
}

# ── log rotation ──────────────────────────────────────────────────────────────
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv -f "$LOG" "$LOG.1"
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

# ── list open MRs ─────────────────────────────────────────────────────────────
ENC_PATH="${PROJECT_PATH//\//%2F}"
export GITLAB_HOST

mrs="$(glab api "projects/$ENC_PATH/merge_requests?state=opened&per_page=100" 2>/dev/null || echo '')"
if [ -z "$mrs" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$mrs"; then
  log "ERROR: could not list MRs (check glab auth status / GITLAB_TOKEN)"; exit 1
fi

# ── pick conflicted MRs not yet tried ─────────────────────────────────────────
targets=""   # iid<TAB>source<TAB>target<TAB>title
verbose=0
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

  seen_file="$STATE/mr-$iid"
  prev_status="$(cut -d' ' -f1 "$seen_file" 2>/dev/null || echo 'none')"
  echo "$status $ssha:$tsha" > "$seen_file"

  [ "$status" != "conflict" ] && continue

  # edge: state change worth logging + notifying
  if [ "$prev_status" != "conflict" ]; then
    log "  !$iid  went into CONFLICT  ($src -> $tgt)  $title"; verbose=1
    notify "Conflict in MR !$iid" "$src -> $tgt: $title"
  fi

  if [ "$SKIP_DRAFTS" = "1" ] && [ "$draft" = "true" ]; then continue; fi

  skip=0
  for ex in $EXCLUDE_BRANCHES; do [ "$src" = "$ex" ] && skip=1; done
  [ "$skip" = "1" ] && continue

  # this exact commit pair was already tried and failed — don't burn tokens again
  if [ -f "$STATE/$MARK-$iid" ] && [ "$(cat "$STATE/$MARK-$iid")" = "$ssha:$tsha" ]; then
    continue
  fi

  targets+="$iid	$src	$tgt	$title
"
done

if [ -z "$targets" ]; then
  [ "$verbose" = "1" ] && log "no new conflicts to fix"
  exit 0
fi

count="$(printf '%s' "$targets" | grep -c . || true)"
log "to fix: $count MR(s); AI budget spent today: $spent/$DAILY_AGENT_RUNS"

if [ "$spent" -ge "$DAILY_AGENT_RUNS" ]; then
  log "daily AI budget exhausted — skipping"; exit 0
fi

# herestring (not a pipe): $( ) strips the final \n and `read` would lose the
# last record — and with it the "already tried" mark, i.e. an eternal retry.
targets="$(printf '%s' "$targets" | head -n "$MAX_MRS_PER_RUN")"
while IFS=$'\t' read -r iid src tgt _; do
  [ -n "$iid" ] && log "  -> !$iid  $src -> $tgt"
done <<<"$targets"

if [ "$DRY_RUN" = "1" ]; then
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
while IFS=$'\t' read -r iid src tgt _; do
  [ -z "$iid" ] && continue
  while [ "$(running_fixers)" -ge "${PARALLEL_FIXERS:-1}" ]; do sleep 5; done
  log "  fixer -> !$iid  ($src -> $tgt); log: fixer-$iid.log"
  nohup bash "$ROOT/fix-mr.sh" "$iid" "$src" "$tgt" >> "$LOGDIR/fixer-$iid.log" 2>&1 &
  launched=$((launched + 1))
  sleep 1
done <<<"$targets"
log "fixers launched: $launched (cap ${PARALLEL_FIXERS:-1}); results arrive as notifications"
