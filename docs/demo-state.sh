#!/bin/bash
# Build a synthetic merge-medic state dir for recording docs/demo.gif —
# realistic-looking data, no real project names. Prints the root it created.
#
#   bash docs/demo-state.sh [target-dir]   # default: mktemp -d
set -euo pipefail

ROOT="${1:-$(mktemp -d)}"
mkdir -p "$ROOT/state/runs" "$ROOT/logs"
now="$(date +%s)"
today="$(date '+%Y-%m-%d')"

cat > "$ROOT/config.env" <<'EOF'
DAILY_AGENT_RUNS=6
EOF
echo 2 > "$ROOT/state/budget-$today"

# ── open MRs: status shas src tgt title ───────────────────────────────────────
mr() { echo "$2 aaa:bbb $3 $4 $5" > "$ROOT/state/mr-$1"; }
mr 214 conflict  feat-88  dev  "feat(map): cluster markers above zoom 14"
mr 213 mergeable feat-87  dev  "fix(api): dedupe webhook deliveries"
mr 212 mergeable feat-86  dev  "feat: bulk-edit tags in the sidebar"
mr 211 conflict  release-2.4 main "release 2.4"
mr 210 mergeable feat-84  dev  "Draft: feat(ui): keyboard palette"
mr 209 mergeable docs/onboarding dev "docs: quickstart for new devs"

# ── live fixers ───────────────────────────────────────────────────────────────
{
  printf '%s|START|feat-88 -> dev\n'                       "$((now-95))"
  printf '%s|WORKTREE|worktrees/wt-214\n'                  "$((now-93))"
  printf '%s|MERGE|origin/dev\n'                           "$((now-90))"
  printf '%s|AI_RESOLVE|2 file(s): map/cluster.ts map/zoom.ts\n' "$((now-60))"
} > "$ROOT/state/progress-214.log"

{
  printf '%s|START|release-2.4 -> main\n'                  "$((now-260))"
  printf '%s|PLAN|read-only plan for release-2.4 -> main\n' "$((now-250))"
  printf '%s|PLANNED|plan posted to MR — approve with a\n'  "$((now-190))"
} > "$ROOT/state/progress-211.log"

# ── history: DONE/ESCALATED spread over 9 days (sparkline + counters) ─────────
hist() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$ROOT/state/history.log"; }
for d in 8 7 7 6 5 5 5 3 2 1; do
  hist "$((now - d*86400 - 3600))" "$((180+d))" DONE ai
done
hist "$((now - 5*86400))" 195 DONE  clean
hist "$((now - 2*86400))" 201 FAIL  ai
hist "$((now - 90000))"   205 ESCALATED none
hist "$((now - 7200))"    208 DONE  clean
hist "$((now - 3600))"    209 DONE  ai

{
  printf '%s|START|docs/onboarding -> dev\n' "$((now-3700))"
  printf '%s|DONE|merged origin/dev, gates green, pushed\n' "$((now-3600))"
} > "$ROOT/state/runs/209-$((now-3600)).log"

# ── token ledger: ts|iid|model|in|out|cache|cost ──────────────────────────────
tok() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" 0 "$6" >> "$ROOT/state/tokens.log"; }
tok "$((now - 5*86400))" 190 claude-opus-5   18200 2100 0.61
tok "$((now - 2*86400))" 201 claude-opus-5   22400 3900 0.84
tok "$((now - 3600))"    209 claude-sonnet-5 14100 1800 0.19
tok "$((now - 60))"      214 claude-opus-5   16400 2300 0.57

# ── live feed ─────────────────────────────────────────────────────────────────
wl() { printf '%s  %s\n' "$(date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S')" "$2" >> "$ROOT/logs/watch.log"; }
wl "$((now-300))" "  !211  went into CONFLICT  (release-2.4 -> main)  release 2.4"
wl "$((now-296))" "  -> !211  release-2.4 -> main  [plan]"
wl "$((now-120))" "  !214  went into CONFLICT  (feat-88 -> dev)  feat(map): cluster markers above zoom 14"
wl "$((now-118))" "to fix: 1 MR(s); AI budget spent today: 2/6"
wl "$((now-117))" "  -> !214  feat-88 -> dev  [auto]"
wl "$((now-100))" "  fixer -> !214  (feat-88 -> dev) [auto]; log: fixer-214.log"

ev() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$ROOT/logs/events.log"; }
ev "$((now-3700))" 209 START "docs/onboarding -> dev"
ev "$((now-3650))" 209 MERGE_CLEAN "no conflict markers — AI not needed (0 tokens)"
ev "$((now-3600))" 209 DONE "merged origin/dev, gates green, pushed"
ev "$((now-250))"  211 PLAN "read-only plan for release-2.4 -> main"
ev "$((now-190))"  211 PLANNED "plan posted to MR — approve with a"
ev "$((now-95))"   214 START "feat-88 -> dev"
ev "$((now-90))"   214 MERGE "origin/dev"
ev "$((now-60))"   214 AI_RESOLVE "2 file(s): map/cluster.ts map/zoom.ts"

echo "$ROOT"
