#!/bin/bash
# Drives fix-mr.sh end to end against a local bare remote, with a scripted
# stand-in for the model: fetch, merge, escalation, rules, resolver, checks,
# push — the whole unattended run, with no forge and no tokens involved.
# Run: bash tests/fixer_e2e.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
fails=0

check() { # description expected actual
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s:\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# hermetic git: nothing from the machine's own config (signing, hooks,
# default branch) may change what the fixer does here
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

# a merge-medic install of its own: fix-mr.sh reads config.env next to itself
MM="$TMP/mm"
mkdir -p "$MM"
cp "$ROOT/fix-mr.sh" "$ROOT/lib.sh" "$ROOT/rules.awk" "$MM/"

# the stand-in resolver; MM_FAKE picks the behaviour
FAKE="$TMP/fake-resolver.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
: > "$MM_FAKE_CALLED"
case "$MM_FAKE" in
  resolve)   printf 'resolved\n' > conflict.txt; git add conflict.txt ;;
  overreach) printf 'resolved\n' > conflict.txt; git add conflict.txt
             printf 'slipped in\n' > apps/auth/token.ts ;;
  hang)      sleep 59.4242 ;;
  stubborn)  trap '' TERM                 # ignores the deadline's TERM, keeps writing
             for _ in $(seq 1 150); do printf x >> "$PWD/late.txt"; sleep 0.2; done ;;
  commit)    printf 'resolved\n' > conflict.txt; git add conflict.txt
             git commit -qm "the resolver's own commit" ;;
  crash)     printf 'resolved\n' > conflict.txt; git add conflict.txt
             : > "$(git rev-parse --git-dir)/index.lock" ;;   # the fixer's own git add dies
  keepfile)  git add kept.txt ;;
esac
EOF
export MM_FAKE_CALLED="$TMP/fake-called"

REMOTE="$TMP/remote.git"
# new_repo <kind>: a remote whose feat-1 conflicts with main, and a fresh
# watch clone. kind: plain | protected | quoted | stamp | moddel
new_repo() {
  rm -rf "$REMOTE" "$TMP/seed" "$TMP/watch" "$MM/state" "$MM/logs" "$MM/worktrees"
  git init -q --bare "$REMOTE"
  git init -q "$TMP/seed"
  (
    cd "$TMP/seed" || exit 1
    mkdir -p apps/auth/mobile docs
    printf 'base\n' > conflict.txt
    printf 'base\n' > apps/auth/token.ts
    printf 'base\n' > apps/auth/mobile/qr.ts
    printf 'base\n' > apps/auth/ключ.ts
    printf '# Doc\n> verified: 0000000\nbody\n' > docs/arch.md
    printf 'base\n' > kept.txt
    git add -A; git commit -qm base
    git branch feat-1
    case "$1" in
      plain)     printf 'main\n' > conflict.txt ;;
      protected) printf 'main\n' > apps/auth/mobile/qr.ts ;;
      quoted)    printf 'main\n' > apps/auth/ключ.ts ;;
      stamp)     printf '# Doc\n> verified: bbbb222\nbody\n' > docs/arch.md ;;
      moddel)    git rm -q kept.txt ;;
    esac
    git commit -qam "main side"
    git checkout -q feat-1
    case "$1" in
      plain)     printf 'feat\n' > conflict.txt ;;
      protected) printf 'feat\n' > apps/auth/mobile/qr.ts ;;
      quoted)    printf 'feat\n' > apps/auth/ключ.ts ;;
      stamp)     printf '# Doc\n> verified: aaaa111\nbody\n' > docs/arch.md ;;
      moddel)    printf 'feat changed it\n' > kept.txt ;;
    esac
    git commit -qam "feat side"
    git push -q "$REMOTE" main feat-1
  )
  git clone -q "$REMOTE" "$TMP/watch"
  rm -f "$MM_FAKE_CALLED"
}

# write_config [extra lines...]
write_config() {
  {
    printf '%s\n' 'PROVIDER="github"' 'PROJECT_PATH="test/repo"' \
      "WATCH_REPO=\"$TMP/watch\"" 'PUSH_MODE="direct"' 'POST_RESOLUTION_NOTE=0' \
      'NOTIFY=0' 'QUIET_MINUTES=0' 'AUTO_BRANCHES="feat-*"' 'DAILY_AGENT_RUNS=0' \
      'RESOLVER="custom"' "RESOLVER_CMD=\"bash $FAKE {mode}\"" \
      'ESCALATE_PATTERNS="apps/auth/*"' 'VERIFY_CMD=""' 'REGRESSION_CMD=""'
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
  } > "$MM/config.env"
}

# run_fixer: one full fixer run for MR 1 (feat-1 -> main)
run_fixer() {
  before_tip="$(git --git-dir "$REMOTE" rev-parse feat-1)"
  SECONDS=0
  bash "$MM/fix-mr.sh" 1 feat-1 main "e2e" auto > "$TMP/fixer.out" 2>&1
  RC=$?
  ELAPSED=$SECONDS
  OUTCOME="$(tail -1 "$MM/state/history.log" 2>/dev/null | cut -d'|' -f3)"
  MODE_USED="$(tail -1 "$MM/state/history.log" 2>/dev/null | cut -d'|' -f4)"
  LAST_EVENT="$(tail -1 "$MM/state/progress-1.log" 2>/dev/null | cut -d'|' -f2-)"
  if [ "$(git --git-dir "$REMOTE" rev-parse feat-1)" = "$before_tip" ]; then PUSHED=0; else PUSHED=1; fi
  if [ -e "$MM_FAKE_CALLED" ]; then CALLED=1; else CALLED=0; fi
}

contains() { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }

echo "fixer end to end:"

# a conflict in a protected subdirectory goes to a human, never to the model
new_repo protected; write_config; MM_FAKE=resolve run_fixer
check "nested protected path escalates"          "ESCALATED/2" "$OUTCOME/$RC"
check "…before the resolver is called"           "0" "$CALLED"
check "…and nothing is pushed"                   "0" "$PUSHED"

# a protected name git would print C-quoted (non-ASCII) is still matched
new_repo quoted; write_config; MM_FAKE=resolve run_fixer
check "a non-ASCII protected name escalates too" "ESCALATED/0" "$OUTCOME/$CALLED"

# the ordinary run still works: resolve, commit with the trailer, push
new_repo plain; write_config; MM_FAKE=resolve run_fixer
check "a clean AI resolution lands"              "DONE/ai/1" "$OUTCOME/$MODE_USED/$PUSHED"
check "…as our merge commit"                     "Merge-Medic-Run: 1" \
  "$(git --git-dir "$REMOTE" log -1 --format=%B feat-1 | grep '^Merge-Medic-Run:')"

# an edit outside the conflict fails the run instead of riding along
new_repo plain; write_config; MM_FAKE=overreach run_fixer
check "an edit outside the conflict fails the run" "FAIL/0" "$OUTCOME/$PUSHED"
check "…naming the file"                         "1" "$(contains "$LAST_EVENT" apps/auth/token.ts)"

# the resolver may not conclude the merge itself
new_repo plain; write_config; MM_FAKE=commit run_fixer
check "a resolver's own commit fails the run"    "FAIL/0" "$OUTCOME/$PUSHED"
check "…because it moved HEAD"                   "1" "$(contains "$LAST_EVENT" "moved HEAD")"

# a hung resolver is stopped, with everything it started
new_repo plain; write_config 'RESOLVER_TIMEOUT=2'; MM_FAKE=hang run_fixer
check "a hung resolver times out"                "FAIL/0" "$OUTCOME/$PUSHED"
check "…reported as a timeout"                   "1" "$(contains "$LAST_EVENT" "timed out")"
check "…at its deadline, not the hang's end"     "1" "$(( ELAPSED < 20 ? 1 : 0 ))"
if pgrep -f 'sleep 59.4242' >/dev/null 2>&1; then left=1; else left=0; fi
check "…and leaves no process behind"            "0" "$left"
pkill -f 'sleep 59.4242' 2>/dev/null

# a resolver that ignores TERM is killed before its worktree is removed, so
# nothing re-creates the directory and wedges the next run
new_repo plain; write_config 'RESOLVER_TIMEOUT=2'; MM_FAKE=stubborn run_fixer
check "a TERM-ignoring resolver times out"       "FAIL/0" "$OUTCOME/$PUSHED"
check "…at its deadline plus the KILL grace"     "1" "$(( ELAPSED < 20 ? 1 : 0 ))"
sleep 1
if pgrep -f "$FAKE" >/dev/null 2>&1; then left=1; else left=0; fi
check "…is not left running"                     "0" "$left"
pkill -KILL -f "$FAKE" 2>/dev/null
if [ -e "$MM/worktrees/wt-1" ]; then wt=1; else wt=0; fi
check "…and its worktree stays gone"             "0" "$wt"
MM_FAKE=resolve run_fixer
check "…so the next run for the MR works"        "DONE" "$OUTCOME"

# an unplanned death is recorded, not silent
new_repo plain; write_config; MM_FAKE=crash run_fixer
check "a fixer that dies is still recorded"      "FAIL/0" "$OUTCOME/$PUSHED"
check "…as an unexpected death"                  "1" "$(contains "$LAST_EVENT" "died unexpectedly")"
if [ -d "$MM/worktrees/wt-1" ]; then wt=1; else wt=0; fi
check "…and its worktree is cleaned up"          "0" "$wt"

# the rules layer still decides a stamp-only conflict on its own
new_repo stamp; write_config "RULES_KEEP_OURS='^> verified: '"; MM_FAKE=resolve run_fixer
check "a stamp-only conflict is decided by rules" "DONE/rules/0" "$OUTCOME/$MODE_USED/$CALLED"

# …but a modify/delete conflict has no markers and is not its to decide
new_repo moddel; write_config "RULES_KEEP_OURS='^> verified: '"; MM_FAKE=keepfile run_fixer
check "a modify/delete conflict goes to the resolver" "DONE/ai/1" "$OUTCOME/$MODE_USED/$CALLED"

if [ "$fails" != "0" ]; then
  echo "--- last fixer output:"; tail -20 "$TMP/fixer.out"
fi
rm -rf "$TMP"
[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
