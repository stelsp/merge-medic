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
SIGIL="$(mm_ref_sigil)"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
# logc writes a channel-tagged line the dashboard splits into columns:
#   <ts>  CHANNEL !42 detail        (channel, optional MR id, free detail)
# Plain log() lines still work and still render — the parser falls back.
# Channels: TICK CONFLICT CLEARED SKIP FIX RADAR BUDGET LOCK ROTATE WARN ERROR
logc() { local ch="$1" iid="$2"; shift 2; log "$ch${iid:+ $SIGIL$iid} $*"; }

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
  logc WARN "" "removing stale lock (pid ${prev:-?} is gone)"; rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
# heartbeat for the dashboard's health line (quiet ticks write no logs)
date +%s > "$STATE/.lastpoll"

# ── daily AI budget (guard; fixers do the real accounting) ────────────────────
today="$(date '+%Y-%m-%d')"
BUDGET_FILE="$STATE/budget-$today"
[ -f "$BUDGET_FILE" ] || echo 0 > "$BUDGET_FILE"
find "$STATE" -name 'budget-*' -mtime +3 -delete 2>/dev/null || true
# skip-* remember the last reason an MR was passed over; a week without a
# touch means the MR is long gone
find "$STATE" -name 'skip-*' -mtime +7 -delete 2>/dev/null || true
spent="$(cat "$BUDGET_FILE")"

# ── pick conflicted MRs/PRs not yet tried ─────────────────────────────────────
targets=""   # iid<TAB>source<TAB>target<TAB>title
N_OPEN=0; N_CONF=0
verbose=0
# why MRs were passed over this tick — reported as counts in the TICK line
# instead of one line per MR per tick (that would be pure noise at 3-minute
# intervals and would evict real events from the dashboard's log tail)
SK_DEDUP=0; SK_DRAFT=0; SK_EXCL=0; SK_INCL=0; SK_DEFER=0
OPEN_IIDS=" "     # every id the forge reported open this tick, space-delimited
LIST_CAP=500      # hard cap on how many open MRs one tick will enumerate
LIST_COMPLETE=1   # 0 = the listing was truncated; state must not be swept

# notify_once fires a desktop notification only when the situation changes.
# A broken token or an exhausted budget persists for hours: without this the
# watcher would notify on every tick (480/day at the default interval).
notify_once() { # kind key title body
  local f="$STATE/notified-$1"
  if [ "$(cat "$f" 2>/dev/null || echo '')" = "$2" ]; then return 0; fi
  printf '%s' "$2" > "$f"
  notify "$3" "$4"
}

# skip_once logs why an MR was passed over — but only when the reason (or its
# key, e.g. the sha pair) changed since last tick. Repeating it every tick
# would bury real events in the dashboard's fixed-size log tail.
skip_once() { # iid key detail
  local f="$STATE/skip-$1"
  if [ "$(cat "$f" 2>/dev/null || echo '')" = "$2" ]; then
    touch "$f"   # still true: keep it out of reach of the weekly sweep
    return 0
  fi
  printf '%s' "$2" > "$f"
  logc SKIP "$1" "$3"
  verbose=1
}

# Shared edge/dedup logic: called once per MR/PR with normalized fields.
consider() {
  local iid="$1" src="$2" tgt="$3" title="$4" draft="$5" status="$6" ssha="$7" tsha="$8" ci="${9:-none}" author="${10:-?}" upd="${11:-?}"
  local seen_file="$STATE/mr-$iid" prev_status
  N_OPEN=$((N_OPEN + 1))
  OPEN_IIDS="$OPEN_IIDS$iid "
  [ "$status" = "conflict" ] && N_CONF=$((N_CONF + 1))
  prev_status="$(cut -d' ' -f1 "$seen_file" 2>/dev/null || echo 'none')"
  # status shas src tgt ci author updated draft title — for the dashboard.
  # draft is its own field because only GitLab puts "Draft:" in the title;
  # GitHub keeps the flag out of band, so a title prefix cannot carry it.
  local dflag="-"; [ "$draft" = "true" ] && dflag="draft"
  echo "$status $ssha:$tsha $src $tgt $ci $author $upd $dflag $title" > "$seen_file"

  # edge: state change worth logging + notifying
  # only a definite "mergeable" closes a conflict: GitHub answers UNKNOWN
  # while it recomputes after a push, and a failed detail call falls back to
  # "unknown" — reporting either as resolved would be a lie the next tick
  # immediately contradicts
  if [ "$status" = "mergeable" ] && [ "$prev_status" = "conflict" ]; then
    logc CLEARED "$iid" "conflict resolved · $src -> $tgt"; verbose=1
  fi

  [ "$status" != "conflict" ] && return 0

  if [ "$prev_status" != "conflict" ]; then
    logc CONFLICT "$iid" "$src -> $tgt · $title"; verbose=1
    notify "Conflict in $SIGIL$iid" "$src -> $tgt: $title"
  fi

  if [ "${SKIP_DRAFTS:-1}" = "1" ] && [ "$draft" = "true" ]; then
    SK_DRAFT=$((SK_DRAFT + 1)); skip_once "$iid" "draft" "draft · SKIP_DRAFTS=1"; return 0
  fi

  local ex
  # shellcheck disable=SC2153  # EXCLUDE_BRANCHES comes from config.env
  for ex in ${EXCLUDE_BRANCHES:-}; do
    if [ "$src" = "$ex" ]; then
      SK_EXCL=$((SK_EXCL + 1)); skip_once "$iid" "excl:$ex" "excluded · EXCLUDE_BRANCHES matches '$ex'"; return 0
    fi
  done

  # allowlist: when INCLUDE_BRANCHES is set, only matching source branches
  # are handled at all (globs, space-separated); empty = every branch
  if [ -n "${INCLUDE_BRANCHES:-}" ]; then
    local inc ok=0
    for inc in $INCLUDE_BRANCHES; do
      # shellcheck disable=SC2254
      case "$src" in $inc) ok=1;; esac
    done
    if [ "$ok" != "1" ]; then
      SK_INCL=$((SK_INCL + 1)); skip_once "$iid" "incl" "filtered · '$src' matches no INCLUDE_BRANCHES glob"; return 0
    fi
  fi

  # routing: AUTO_BRANCHES sources are fixed fully automatically; everything
  # else runs the semi-auto plan -> human approve -> fix flow
  local mode="plan"
  mm_src_is_auto "$src" && mode="auto"
  # an approve marker upgrades ANY mode to fix-approved — it also unblocks
  # escalated auto-branch MRs after the human answered the bot's questions
  if [ -f "$STATE/approve-$iid" ]; then
    mode="fix-approved"
    rm -f "$STATE/approve-$iid"
    logc FIX "$iid" "approval consumed · mode=fix-approved"; verbose=1
  fi

  # deferred (branch was hot): retry on every tick — the fixer re-checks the
  # branch cheaply (fetch + git log, no AI) and re-defers if it is still hot,
  # so the fix lands one tick after the branch has been quiet for
  # QUIET_MINUTES, instead of a full quiet period after the last defer.
  # The 60s grace only shields the fixer launched by the previous tick.
  if [ -f "$STATE/deferred-$iid" ]; then
    dts="$(cat "$STATE/deferred-$iid")"
    local dage=$(( $(date +%s) - dts ))
    if [ "$dage" -lt 60 ]; then
      SK_DEFER=$((SK_DEFER + 1)); skip_once "$iid" "defer" "defer grace · deferred ${dage}s ago (<60s)"; return 0
    fi
    rm -f "$STATE/deferred-$iid" "$STATE/$MARK-$iid"
    logc FIX "$iid" "defer expired after ${dage}s · eligible again"; verbose=1
  fi

  # this exact commit pair was already tried and failed — don't burn tokens again
  if [ -f "$STATE/$MARK-$iid" ] && [ "$(cat "$STATE/$MARK-$iid")" = "$ssha:$tsha" ]; then
    SK_DEDUP=$((SK_DEDUP + 1))
    skip_once "$iid" "dedup:$ssha:$tsha" "dedup · already tried ${ssha:0:7}:${tsha:0:7} — push either branch to retry"
    return 0
  fi

  rm -f "$STATE/skip-$iid"   # this MR is being worked on; forget its last excuse

  targets+="$iid	$src	$tgt	$mode	$title
"
}

if mm_is_github; then
  # ── GitHub via gh ───────────────────────────────────────────────────────────
  command -v gh >/dev/null 2>&1 || { logc ERROR "" "PROVIDER=github but gh is not installed"; exit 1; }
  # --limit is a total cap, not a page size: gh paginates up to it. 500 keeps
  # the whole list in one variable while covering any realistic repo — and
  # sweep_closed refuses to run if we ever hit the cap (see LIST_COMPLETE).
  prs="$(gh pr list --repo "$PROJECT_PATH" --state open --limit "$LIST_CAP" \
        --json number,title,headRefName,baseRefName,mergeable,isDraft,headRefOid,statusCheckRollup,author,updatedAt 2>/dev/null || echo '')"
  if [ -z "$prs" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs"; then
    logc ERROR "" "could not list PRs — check: gh auth status"
    notify_once forge "prs" "merge-medic: cannot list PRs" "check gh auth status"
    exit 1
  fi
  [ "$(jq 'length' <<<"$prs")" -ge "$LIST_CAP" ] && LIST_COMPLETE=0
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
    # The dedup key's second half must be the MERGE BASE, not the current
    # head of the base branch. With the head, every merge into main changed
    # the key for every open PR at once: all of them looked new, every
    # conflicted one got a fresh fixer, and a couple of merges could burn a
    # whole day's AI budget. The merge base only moves when this PR is
    # rebased or its branch actually diverges. (GitLab has always used
    # diff_refs.base_sha, which is exactly this.)
    old_ssha="$(cut -d' ' -f2 "$STATE/mr-$iid" 2>/dev/null | cut -d: -f1 || true)"
    old_tsha="$(cut -d' ' -f2 "$STATE/mr-$iid" 2>/dev/null | cut -d: -f2 || true)"
    if [ "$ssha" != "$old_ssha" ] || [ -z "$old_tsha" ] || [ "$old_tsha" = "?" ]; then
      tsha="$(gh api "repos/$PROJECT_PATH/compare/$tgt...$ssha" \
                --jq '.merge_base_commit.sha' 2>/dev/null || echo '?')"
    else
      tsha="$old_tsha"   # unchanged head: the merge base cannot have moved
    fi
    ci="$(jq -r '(.statusCheckRollup // []) | map(.conclusion // .state // "") | if length==0 then "none" elif any(.=="FAILURE" or .=="ERROR" or .=="CANCELLED") then "failed" elif all(.=="SUCCESS" or .=="NEUTRAL" or .=="SKIPPED") then "success" else "running" end' <<<"$row")"
    author="$(jq -r '.author.login // "?"' <<<"$row")"
    upd="$(jq -r '.updatedAt // "?"' <<<"$row")"
    consider "$iid" "$src" "$tgt" "$title" "$draft" "$status" "$ssha" "$tsha" "$ci" "$author" "$upd"
  done < <(jq -c '.[]' <<<"$prs")
else
  # ── GitLab via glab ─────────────────────────────────────────────────────────
  ENC_PATH="${PROJECT_PATH//\//%2F}"
  export GITLAB_HOST
  # per_page caps at 100, so walk pages until one comes back short — an
  # unpaginated listing would make sweep_closed treat page 2 as closed
  mrs="[]"; page=1
  while :; do
    chunk="$(glab api "projects/$ENC_PATH/merge_requests?state=opened&per_page=100&page=$page" 2>/dev/null || echo '')"
    if [ -z "$chunk" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$chunk"; then
      if [ "$page" = "1" ]; then
        logc ERROR "" "could not list MRs — check: glab auth status / GITLAB_TOKEN"
        notify_once forge "mrs" "merge-medic: cannot list MRs" "check glab auth status"
        exit 1
      fi
      LIST_COMPLETE=0   # a later page failed: the list is partial, do not sweep
      break
    fi
    mrs="$(jq -cs '.[0] + .[1]' <<<"$mrs$chunk")"
    [ "$(jq 'length' <<<"$chunk")" -lt 100 ] && break
    page=$((page + 1))
    if [ "$page" -gt 20 ]; then LIST_COMPLETE=0; break; fi   # 2000 MRs: bail
  done
  # One request covers the whole tick: the list response carries everything
  # except head_pipeline/base_sha — a per-MR detail request happens only when
  # the head SHA moved (or mergeability is still being computed), so a quiet
  # tick is a single API call instead of one per MR.
  # GitLab reports mergeability as a single detailed_merge_status, which
  # answers "why can this not merge" — and a blocking reason outranks the
  # conflict: a draft MR reads "draft_status" even when it is conflicted.
  # has_conflicts is the authoritative answer, so it decides.
  gl_status() { # detailed_merge_status has_conflicts
    if [ "$2" = "true" ]; then echo conflict; return; fi
    case "$1" in
      conflict|broken_status) echo conflict ;;
      checking|unchecked|unknown) echo unknown ;;
      # draft_status, ci_must_pass, not_approved, discussions_not_resolved:
      # policy gates, not merge problems — the branches themselves fit
      *) echo mergeable ;;
    esac
  }
  while IFS= read -r row; do
    iid="$(jq -r '.iid' <<<"$row")"
    status="$(gl_status "$(jq -r '.detailed_merge_status // "unknown"' <<<"$row")" \
                        "$(jq -r '.has_conflicts // false' <<<"$row")")"
    ssha="$(jq -r '.sha // "?"' <<<"$row")"
    old_ssha="$(cut -d' ' -f2 "$STATE/mr-$iid" 2>/dev/null | cut -d: -f1 || true)"
    old_ci="$(cut -d' ' -f5 "$STATE/mr-$iid" 2>/dev/null || true)"
    old_tsha="$(cut -d' ' -f2 "$STATE/mr-$iid" 2>/dev/null | cut -d: -f2 || true)"
    if [ "$ssha" != "$old_ssha" ] || [ "$status" = "unknown" ] || [ -z "$old_tsha" ]; then
      mr="$(glab api "projects/$ENC_PATH/merge_requests/$iid" 2>/dev/null || echo '{}')"
      raw="$(jq -r '.detailed_merge_status // "unknown"' <<<"$mr")"
      if [ "$raw" = "checking" ] || [ "$raw" = "unchecked" ]; then
        sleep 5   # GitLab is still computing mergeability — ask once more
        mr="$(glab api "projects/$ENC_PATH/merge_requests/$iid" 2>/dev/null || echo '{}')"
        raw="$(jq -r '.detailed_merge_status // "unknown"' <<<"$mr")"
      fi
      status="$(gl_status "$raw" "$(jq -r '.has_conflicts // false' <<<"$mr")")"
      ssha="$(jq -r '.sha // .diff_refs.head_sha // "?"' <<<"$mr")"
      tsha="$(jq -r '.diff_refs.base_sha // "?"' <<<"$mr")"
      ci="$(jq -r '.head_pipeline.status // "none"' <<<"$mr")"
    else
      tsha="${old_tsha:-?}"
      ci="${old_ci:-none}"
    fi
    src="$(jq -r '.source_branch' <<<"$row")"
    tgt="$(jq -r '.target_branch' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    draft="$(jq -r '.draft' <<<"$row")"
    author="$(jq -r '.author.username // "?"' <<<"$row")"
    upd="$(jq -r '.updated_at // "?"' <<<"$row")"
    consider "$iid" "$src" "$tgt" "$title" "$draft" "$status" "$ssha" "$tsha" "$ci" "$author" "$upd"
  done < <(jq -c '.[]' <<<"$mrs")
fi

# sweep_closed drops the per-MR state of MRs the forge no longer lists.
# Nothing else expires it, so a merged MR kept feeding the radar for good:
# radar_scan reads every state/mr-* file, and closed ones never stopped
# pairing. Runs only when the listing itself succeeded — a failed API call
# must never look like "everything closed".
sweep_closed() {
  # "Not in the listing" only means "closed" when the listing was COMPLETE.
  # A truncated page would make every MR behind it look closed, and deleting
  # its state would discard a human's approval, lose the PLANNED marker that
  # makes a plan approvable at all, and drop the dedup mark that keeps the
  # resolver from paying twice for the same commit pair.
  if [ "$LIST_COMPLETE" != "1" ]; then
    logc WARN "" "listing truncated at $LIST_CAP — skipping the closed-MR sweep"
    return 0
  fi
  # A grace period on top of the membership test: a state file the previous
  # tick refreshed is spared even when this tick did not list it. That way a
  # single empty-but-successful listing (a token that lost its scope answers
  # [] rather than failing) cannot wipe every MR's state in one go — it takes
  # two consecutive ticks of the MR being genuinely absent.
  local grace_min fresh
  grace_min=$(( ($(mm_poll_interval) * 2 + 59) / 60 ))
  fresh="$(find "$STATE" -maxdepth 1 -name 'mr-*' -mmin "-$grace_min" 2>/dev/null | tr '\n' ' ')"
  local f iid gone=0
  for f in "$STATE"/mr-*; do
    [ -f "$f" ] || continue
    iid="${f##*/mr-}"
    case "$OPEN_IIDS" in *" $iid "*) continue ;; esac
    case " $fresh" in *" $f "*) continue ;; esac
    # a detached fixer outlives its tick, and its progress file is what the
    # run archive is copied from — leave a live run entirely alone
    if pgrep -f "fix-mr.sh $iid " >/dev/null 2>&1; then continue; fi
    rm -f "$STATE/mr-$iid" "$STATE/skip-$iid" "$STATE/deferred-$iid" \
          "$STATE/tried-$iid" "$STATE/dry-$iid" "$STATE/approve-$iid" \
          "$STATE/progress-$iid.log" "$STATE/plan-$iid.md" \
          "$STATE/esc-$iid.md" "$STATE/answers-$iid.md"
    gone=$((gone + 1))
  done
  [ "$gone" -gt 0 ] && logc TICK "" "$gone closed MR(s) swept from state"
  return 0
}
sweep_closed

# ── conflict radar: pairwise merge-tree between open MRs sharing a target ────
# "Your MR will conflict with !X when either merges" — detected before it
# hurts, for free (in-memory merge-tree, zero tokens, zero API calls).
radar_scan() {
  [ "${RADAR:-1}" = "1" ] || return 0
  local out="$STATE/radar.tmp" list="" f iid status shas src tgt rest
  # closed MRs are already gone from state (sweep_closed runs first) and the
  # dashboard drops pairs naming an MR it cannot see — no mtime guessing here
  : > "$out"
  for f in "$STATE"/mr-*; do
    [ -f "$f" ] || continue
    iid="${f##*/mr-}"
    # shellcheck disable=SC2034  # shas/rest are placeholders for unused fields
    read -r status shas src tgt rest < "$f" || continue
    if [ -z "$src" ] || [ -z "$tgt" ]; then continue; fi
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
      # numeric a<b keeps each pair once; malformed ids fail the test → skipped
      [ "$a_iid" -lt "$b_iid" ] 2>/dev/null || continue
      [ "$a_tgt" = "$b_tgt" ] || continue
      pairs=$((pairs+1)); [ "$pairs" -gt 30 ] && break 2
      git -C "$WATCH_REPO" rev-parse --quiet --verify "origin/$a_src" >/dev/null 2>&1 || continue
      git -C "$WATCH_REPO" rev-parse --quiet --verify "origin/$b_src" >/dev/null 2>&1 || continue
      if ! git -C "$WATCH_REPO" merge-tree --write-tree "origin/$a_src" "origin/$b_src" >/dev/null 2>&1; then
        printf '%s|%s|%s|%s\n' "$a_iid" "$b_iid" "$a_src" "$b_src" >> "$out"
        if ! grep -qF "$a_iid|$b_iid|" "$STATE/radar" 2>/dev/null; then
          logc RADAR "" "$SIGIL$a_iid×$SIGIL$b_iid · $a_src ↔ $b_src conflict with each other — first to merge wins"
          notify "Radar: $SIGIL$a_iid × $SIGIL$b_iid" "$a_src and $b_src conflict with each other"
        fi
      fi
    done <<<"$list"
  done <<<"$list"
  mv "$out" "$STATE/radar"
}
radar_scan

rm -f "$STATE/notified-forge"   # the forge answered — a later outage may notify


# one line per tick, carrying why nothing (or something) happened
tick_line() {
  local sk=$((SK_DEDUP + SK_DRAFT + SK_EXCL + SK_INCL + SK_DEFER)) why=""
  [ "$SK_DEDUP" -gt 0 ] && why="$why, $SK_DEDUP dedup"
  [ "$SK_DRAFT" -gt 0 ] && why="$why, $SK_DRAFT draft"
  [ "$SK_EXCL"  -gt 0 ] && why="$why, $SK_EXCL excluded"
  [ "$SK_INCL"  -gt 0 ] && why="$why, $SK_INCL filtered"
  [ "$SK_DEFER" -gt 0 ] && why="$why, $SK_DEFER deferred"
  [ -n "$why" ] && why=" (${why#, })"
  printf '%s open · %s conflicted · %s skipped%s · %s' \
    "$N_OPEN" "$N_CONF" "$sk" "$why" "$( [ "${DRY_RUN:-1}" = "1" ] && echo "watch-only" || echo "fixing" )"
}

if [ -z "$targets" ]; then
  if [ "$verbose" = "1" ]; then
    logc TICK "" "$(tick_line) — nothing new to fix"
  else
    logc TICK "" "$(tick_line) — nothing new"
  fi
  exit 0
fi

count="$(printf '%s' "$targets" | grep -c . || true)"
lim="${DAILY_AGENT_RUNS:-6}"
lim_label="$lim"; [ "$lim" = "0" ] && lim_label="∞"
logc TICK "" "$(tick_line) — $count to fix · AI budget $spent/$lim_label"

if [ "$lim" -gt 0 ] && [ "$spent" -ge "$lim" ]; then
  dropped="$(printf '%s' "$targets" | cut -f1 | tr '\n' ' ')"
  logc BUDGET "" "daily AI budget exhausted $spent/$lim — dropping: ${dropped% }"
  notify_once budget "$today:$lim" "AI budget exhausted ($spent/$lim)" "not fixing: ${dropped% }"
  exit 0
fi

if [ "$count" -gt "$MAX_MRS_PER_RUN" ]; then
  logc SKIP "" "cap · MAX_MRS_PER_RUN=$MAX_MRS_PER_RUN dropped $((count - MAX_MRS_PER_RUN)) target(s) to the next tick"
fi
targets="$(printf '%s' "$targets" | head -n "$MAX_MRS_PER_RUN")"
# Every $targets loop below reads via `<<<` herestring, NOT `printf | while`:
# a pipe would also work, but $( ) above already stripped the final \n and a
# piped `read` would then lose the last record — and with it the "already
# tried" mark, i.e. an eternal retry.
while IFS=$'\t' read -r iid src tgt mode _; do
  [ -n "$iid" ] && logc FIX "$iid" "queued · $src -> $tgt [$mode]"
done <<<"$targets"

# mark_tried records the (source,target) sha pair the fixer is about to work
# on — the dedup key that stops retry loops on crashes.
mark_tried() { cut -d' ' -f2 "$STATE/mr-$1" > "$STATE/$MARK-$1" 2>/dev/null || true; }

if [ "${DRY_RUN:-1}" = "1" ]; then
  logc TICK "" "watch-only (DRY_RUN=1) — $count conflict(s) detected, nothing merged or pushed"
  while IFS=$'\t' read -r iid _ _ _; do
    [ -z "$iid" ] && continue
    mark_tried "$iid"
  done <<<"$targets"
  exit 0
fi

# ── dedicated clone (created lazily, only when there is real work) ────────────
if [ ! -d "$WATCH_REPO/.git" ]; then
  logc FIX "" "cloning $GIT_REMOTE_URL -> $WATCH_REPO (first run)"
  git clone --quiet "$GIT_REMOTE_URL" "$WATCH_REPO" >>"$LOG" 2>&1
fi
git -C "$WATCH_REPO" fetch --prune --quiet origin >>"$LOG" 2>&1 || {
  logc ERROR "" "git fetch failed — see the lines above"
  notify_once forge "fetch" "merge-medic: git fetch failed" "the watcher cannot reach the remote"
  exit 1; }

# ── mark pairs as tried BEFORE launching (no retry loops on crashes) ──────────
while IFS=$'\t' read -r iid _ _ _; do
  [ -z "$iid" ] && continue
  mark_tried "$iid"
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
  if [ "$(running_fixers)" -ge "${PARALLEL_FIXERS:-1}" ]; then
    logc FIX "$iid" "waiting for a slot · $(running_fixers)/${PARALLEL_FIXERS:-1} fixers busy"
    while [ "$(running_fixers)" -ge "${PARALLEL_FIXERS:-1}" ]; do sleep 5; done
  fi
  nohup bash "$ROOT/fix-mr.sh" "$iid" "$src" "$tgt" "$title" "$mode" >> "$LOGDIR/fixer-$iid.log" 2>&1 &
  logc FIX "$iid" "fixer started · $src -> $tgt [$mode] pid=$! log: fixer-$iid.log"
  launched=$((launched + 1))
  sleep 1
done <<<"$targets"
logc FIX "" "$launched fixer(s) launched (cap ${PARALLEL_FIXERS:-1}) — results arrive as notifications"
