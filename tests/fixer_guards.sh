#!/bin/bash
# Guards the fixer leans on when nobody is watching: which paths count as
# protected, what the resolver may touch, how long anything may run.
# Run: bash tests/fixer_guards.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
fails=0

check() { # description expected actual
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s:\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# shellcheck source=lib.sh disable=SC1091
source "$ROOT/lib.sh"

# ── glob lists: a pattern means the pattern, wherever the caller stands ──────
echo "glob matching:"
# a tree shaped like the one a fixer's worktree has: when the loop expanded
# "apps/auth/*" here, it became the list of names below and stopped matching
# anything nested
mkdir -p "$TMP/tree/apps/auth/mobile" "$TMP/tree/feat-local"
: > "$TMP/tree/apps/auth/jwt.ts"
: > "$TMP/tree/apps/auth/mobile/qr.ts"
cd "$TMP/tree" || exit 1
pats="apps/auth/* apps/billing/*"
check "direct child matches"     "apps/auth/*" "$(mm_glob_match apps/auth/jwt.ts "$pats")"
check "nested file matches"      "apps/auth/*" "$(mm_glob_match apps/auth/mobile/qr.ts "$pats")"
check "pattern with no files on disk still matches" \
                                 "apps/billing/*" "$(mm_glob_match apps/billing/x/y.ts "$pats")"
if mm_glob_match apps/web/main.ts "$pats" >/dev/null; then hit=1; else hit=0; fi
check "unrelated path does not match" "0" "$hit"
if mm_glob_match anything "" >/dev/null; then hit=1; else hit=0; fi
check "empty pattern list matches nothing" "0" "$hit"

case "$-" in *f*) nog=1 ;; *) nog=0 ;; esac
check "pathname expansion is back on afterwards" "0" "$nog"
set -f
mm_glob_match apps/auth/jwt.ts "$pats" >/dev/null
case "$-" in *f*) nog=1 ;; *) nog=0 ;; esac
set +f
check "a caller's own set -f is left alone" "1" "$nog"

# AUTO_BRANCHES goes through the same function: a directory called
# feat-local next to the watcher must not turn "feat-*" into "feat-local"
AUTO_BRANCHES="feat-*"
if mm_src_is_auto feat-99; then hit=1; else hit=0; fi
check "feat-* stays a glob beside a feat-local directory" "1" "$hit"
cd "$ROOT" || exit 1

# ── resolver scope: what an AI run may leave behind ─────────────────────────
eval "$(sed -n '/^index_snapshot() {/,/^}/p' "$ROOT/fix-mr.sh")"
eval "$(sed -n '/^out_of_scope() {/,/^}/p' "$ROOT/fix-mr.sh")"
eval "$(sed -n '/^markers_left() {/,/^}/p' "$ROOT/fix-mr.sh")"
eval "$(sed -n '/^marker_lines() {/,/^}/p' "$ROOT/fix-mr.sh")"

echo
echo "resolver scope:"
REPO="$TMP/scope"
git init -q "$REPO"
cd "$REPO" || exit 1
git config user.email t@t; git config user.name t; git config commit.gpgsign false
printf 'shared\n' > conflict.txt
printf 'untouched\n' > other.txt
# a file that is ABOUT conflicts: marker-like lines on both sides, legitimately
printf 'example:\n<<<<<<< HEAD\n=======\n>>>>>>> theirs\n' > fixture.md
git add -A; git commit -qm base
git checkout -qb theirs
printf 'theirs\n' > conflict.txt; git commit -qam theirs
git checkout -q -
printf 'ours\n' > conflict.txt; git commit -qam ours
git -c merge.conflictStyle=zdiff3 merge -q theirs >/dev/null 2>&1
conflicts="$(git diff --name-only --diff-filter=U)"
check "the harness produced one conflict" "conflict.txt" "$conflicts"

before="$(index_snapshot)"
printf 'resolved\n' > conflict.txt
git add -A
check "resolving only the conflicted file is in scope" "" "$(out_of_scope "$before" "$conflicts")"

printf 'edited behind our back\n' > other.txt
printf 'new\n' > created.txt
git add -A
check "an edit elsewhere and a new file are both caught" "created.txt
other.txt" "$(out_of_scope "$before" "$conflicts")"
git rm -q --cached created.txt; rm -f created.txt; git checkout -q HEAD -- other.txt

git rm -q other.txt
check "a deletion elsewhere is caught" "other.txt" "$(out_of_scope "$before" "$conflicts")"
git checkout -q HEAD -- other.txt

if markers_left fixture.md; then ml=1; else ml=0; fi
check "marker-like lines both sides already had are not leftovers" "0" "$ml"
printf 'resolved\n=======\n' > conflict.txt
if markers_left conflict.txt; then ml=1; else ml=0; fi
check "a stray ======= is a leftover" "1" "$ml"
printf 'resolved\n>>>>>>> theirs\n' > conflict.txt
if markers_left conflict.txt; then ml=1; else ml=0; fi
check "a stray >>>>>>> is a leftover" "1" "$ml"
printf 'resolved\n' > conflict.txt
if markers_left conflict.txt; then ml=1; else ml=0; fi
check "a clean resolution has no leftovers" "0" "$ml"
printf 'resolved\r\n=======\r\n' > conflict.txt
if markers_left conflict.txt; then ml=1; else ml=0; fi
check "a stray =======<CR> in a CRLF file is a leftover" "1" "$ml"
git reset -q --hard

# both sides append a section with a 7-character setext underline: the union
# has one more "=======" than either side, and is still a clean resolution
git checkout -qb docs-theirs
printf '# Doc\n\nTesting\n=======\n' > notes.md; git add notes.md; git commit -qm theirs-docs
git checkout -q -
printf '# Doc\n\nInstall\n=======\n' > notes.md; git add notes.md; git commit -qm ours-docs
git -c merge.conflictStyle=zdiff3 merge -q docs-theirs >/dev/null 2>&1
printf '# Doc\n\nInstall\n=======\n\nTesting\n=======\n' > notes.md
if markers_left notes.md; then ml=1; else ml=0; fi
check "both sides' setext underlines are not leftovers" "0" "$ml"
git reset -q --hard
cd "$ROOT" || exit 1

# ── deadlines: nothing a fixer starts may run forever ───────────────────────
echo
echo "deadlines:"
out="$(mm_timeout 5 sh -c 'echo hi; exit 3')"; rc=$?
check "a quick command keeps its output"      "hi" "$out"
check "…and its exit status"                  "3" "$rc"

# shellcheck disable=SC2329,SC2317  # invoked through mm_timeout
#                                    (the two shellcheck versions disagree on the code)
fn_under_test() { echo "from a function"; return 7; }
out="$(mm_timeout 5 fn_under_test)"; rc=$?
check "a shell function runs under a deadline" "from a function/7" "$out/$rc"

SECONDS=0
out="$(mm_timeout 30 echo fast)"
check "a finished command does not wait out the deadline" "fast/1" "$out/$(( SECONDS < 3 ? 1 : 0 ))"

# a stuck command AND what it spawned are both stopped
mm_timeout 1 bash -c 'sleep 4711 & sleep 4711; wait'; rc=$?
check "a stuck command times out with 124"    "124" "$rc"
sleep 0.3
if pgrep -f 'sleep 4711' >/dev/null 2>&1; then left=1; else left=0; fi
check "…and nothing it started is left behind" "0" "$left"
pkill -f 'sleep 4711' 2>/dev/null

mm_timeout 0 true; rc=$?
check "0 seconds means no limit"               "0" "$rc"

# a function whose child ignores TERM: the KILL that follows must reach it,
# although the function's own subshell dies on the TERM
# shellcheck disable=SC2329,SC2317  # invoked through mm_timeout
stubborn_step() { bash -c 'trap "" TERM; sleep 4712; :' 2>/dev/null; }
SECONDS=0
mm_timeout 1 stubborn_step; rc=$?
check "a TERM-ignoring step still times out"   "124" "$rc"
if pgrep -f 'sleep 4712' >/dev/null 2>&1; then left=1; else left=0; fi
check "…and is gone when mm_timeout returns"   "0" "$left"
check "…within the TERM grace period"          "1" "$(( SECONDS <= 8 ? 1 : 0 ))"
pkill -KILL -f 'sleep 4712' 2>/dev/null

check "a deadline in whole seconds is kept"    "600" "$(mm_secs 600 900)"
check "0 keeps meaning no deadline"            "0" "$(mm_secs 0 900)"
check "\"15m\" falls back to the default"      "900" "$(mm_secs 15m 900)"
check "empty falls back to the default"        "900" "$(mm_secs '' 900)"

# ── counting fixers: one fixer, however many times it has forked ───────────
echo
echo "fixer count:"
FAKE_ROOT="$TMP/mm-root"
bash -c "exec -a 'bash $FAKE_ROOT/fix-mr.sh 7 feat-7 main' bash -c '( sleep 3; : ) & ( sleep 3; : ) & wait'" 2>/dev/null &
fake=$!
sleep 0.5
raw="$(pgrep -f "$FAKE_ROOT/fix-mr.sh" | wc -l | tr -d ' ')"
check "the fake fixer really shows as several processes" "1" "$(( raw > 1 ? 1 : 0 ))"
check "a fixer with two subshells counts once" "1" "$(mm_fixer_count "$FAKE_ROOT")"
mm_kill_tree "$fake" TERM; wait "$fake" 2>/dev/null
check "no fixer, no count"                     "0" "$(mm_fixer_count "$FAKE_ROOT")"

# a process that exits between pgrep and ps has no parent left to look up
# shellcheck disable=SC2329,SC2317  # called from mm_fixer_count
pgrep() { printf '101\n102\n'; }
# shellcheck disable=SC2329,SC2317
ps() { if [ "$4" = 101 ]; then echo '    1'; else return 1; fi; }
check "a fork that exits mid-count is not one more fixer" "1" "$(mm_fixer_count "$FAKE_ROOT")"
unset -f pgrep ps

# a fixer killed outright (no traps run) while mm_timeout waits leaves the
# watchdog behind, carrying the fixer's command line: once the command it
# guards is done, it must not hold a fixer slot until the deadline
bash -c "exec -a 'bash $FAKE_ROOT/fix-mr.sh 9 feat-9 main' bash -c '. \"$ROOT/lib.sh\"; mm_timeout 4713 sleep 2.4713'" 2>/dev/null &
fake=$!
# (anchored: the fake fixer's own command line mentions the sleep too)
n=0
while ! pgrep -f '^sleep 2.4713' >/dev/null 2>&1 && [ "$n" -lt 25 ]; do sleep 0.2; n=$((n + 1)); done
sleep 0.3
kill -KILL "$fake"; wait "$fake" 2>/dev/null
raw="$(pgrep -f "$FAKE_ROOT/fix-mr.sh" | wc -l | tr -d ' ')"
check "the killed fixer really leaves its watchdog behind" "1" "$(( raw > 0 ? 1 : 0 ))"
n=0
while pgrep -f '^sleep 2.4713' >/dev/null 2>&1 && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
n=0
while [ "$(mm_fixer_count "$FAKE_ROOT")" != 0 ] && [ "$n" -lt 15 ]; do sleep 0.2; n=$((n + 1)); done
check "a killed fixer's watchdog frees the slot once its command is done" \
                                               "0" "$(mm_fixer_count "$FAKE_ROOT")"
for p in $(pgrep -f "$FAKE_ROOT/fix-mr.sh"); do mm_kill_tree "$p" KILL; done
pkill -f '^sleep 2.4713' 2>/dev/null; pkill -f '^sleep 4713' 2>/dev/null

# ── resolution MRs: one per MR, and never treated as work ───────────────────
echo
echo "resolution MRs:"
eval "$(sed -n '/^bot_login() {/,/^}/p' "$ROOT/fix-mr.sh")"
eval "$(sed -n '/^open_resolution_mr() {/,/^}/p' "$ROOT/fix-mr.sh")"
# stand-ins for the forge CLIs: print what the test sets, exit how it says;
# "api user" asks who the bot is
mkdir -p "$TMP/bin"
for cli in gh glab; do
  # shellcheck disable=SC2016  # the stub expands these itself, at run time
  printf '#!/bin/sh\ncase "$*" in "api user"*) printf "%%s" "$FORGE_USER"; exit "${FORGE_USER_RC:-0}" ;; esac\nprintf "%%s" "$FORGE_OUT"\nexit "${FORGE_RC:-0}"\n' \
    > "$TMP/bin/$cli"
  chmod +x "$TMP/bin/$cli"
done
PATH="$TMP/bin:$PATH"
# shellcheck disable=SC2034  # read by the extracted open_resolution_mr body
{ IID=7; SRC=feat-7; PROJECT_PATH=group/repo; }

PROVIDER=github
export FORGE_RC=0 FORGE_USER=mm-bot
export FORGE_OUT='[{"headRefName":"merge-medic/fix-70-1700000000","url":"https://x/pull/2","author":{"login":"mm-bot"},"isCrossRepository":false},
  {"headRefName":"merge-medic/fix-7-1700000000","url":"https://x/pull/3","author":{"login":"mm-bot"},"isCrossRepository":false}]'
check "github: finds this MR's open resolution" "https://x/pull/3" "$(open_resolution_mr)"
export FORGE_OUT='[{"headRefName":"merge-medic/fix-70-1700000000","url":"https://x/pull/2","author":{"login":"mm-bot"},"isCrossRepository":false}]'
out="$(open_resolution_mr)"; rc=$?
check "github: another MR's resolution is not ours" "/0" "$out/$rc"
export FORGE_OUT='[{"headRefName":"merge-medic/fix-7-1700000000","url":"https://x/pull/4","author":{"login":"someone"},"isCrossRepository":false}]'
out="$(open_resolution_mr)"; rc=$?
check "github: a look-alike branch somebody else opened is not ours" "/0" "$out/$rc"
export FORGE_OUT='[{"headRefName":"merge-medic/fix-7-1700000000","url":"https://x/pull/5","author":{"login":"mm-bot"},"isCrossRepository":true}]'
out="$(open_resolution_mr)"; rc=$?
check "github: one from a fork is not ours" "/0" "$out/$rc"
export FORGE_OUT='' FORGE_RC=1
if open_resolution_mr >/dev/null; then rc=0; else rc=1; fi
check "github: a failed lookup is reported, not read as none" "1" "$rc"
export FORGE_RC=0 FORGE_USER_RC=1
if open_resolution_mr >/dev/null; then rc=0; else rc=1; fi
check "github: not knowing who the bot is fails the lookup" "1" "$rc"
unset FORGE_USER_RC

# shellcheck disable=SC2034  # read by the extracted open_resolution_mr body
PROVIDER=gitlab
export FORGE_RC=0 FORGE_USER='{"username":"mm-bot"}'
export FORGE_OUT='[{"source_branch":"merge-medic/fix-7-1700000000","web_url":"https://x/-/merge_requests/9","author":{"username":"mm-bot"},"source_project_id":1,"target_project_id":1}]'
check "gitlab: finds this MR's open resolution" "https://x/-/merge_requests/9" "$(open_resolution_mr)"
export FORGE_OUT='[{"source_branch":"merge-medic/fix-7-1700000000","web_url":"https://x/-/merge_requests/10","author":{"username":"someone"},"source_project_id":1,"target_project_id":1}]'
out="$(open_resolution_mr)"; rc=$?
check "gitlab: a look-alike branch somebody else opened is not ours" "/0" "$out/$rc"
export FORGE_OUT='[{"source_branch":"merge-medic/fix-7-1700000000","web_url":"https://x/-/merge_requests/11","author":{"username":"mm-bot"},"source_project_id":2,"target_project_id":1}]'
out="$(open_resolution_mr)"; rc=$?
check "gitlab: one from a fork is not ours" "/0" "$out/$rc"
export FORGE_OUT='{"message":"401 Unauthorized"}'
if open_resolution_mr >/dev/null; then rc=0; else rc=1; fi
check "gitlab: an error answer is a failed lookup" "1" "$rc"
unset FORGE_OUT FORGE_RC FORGE_USER

# the watcher: an MR whose source is our own resolution branch is not work
eval "$(sed -n '/^consider() {/,/^}/p' "$ROOT/watch.sh")"
# shellcheck disable=SC2329,SC2317  # called from the extracted consider body
logc() { :; }
# shellcheck disable=SC2329,SC2317
notify() { :; }
# shellcheck disable=SC2329,SC2317
skip_once() { :; }
# shellcheck disable=SC2329,SC2317
defer_gate() { return 0; }
# shellcheck disable=SC2034  # read by the extracted consider body
{ STATE="$TMP/state"; N_OPEN=0; N_CONF=0; OPEN_IIDS=" "; SK_DRAFT=0; SK_EXCL=0
  SK_INCL=0; SK_DEDUP=0; verbose=0; MARK=tried; SIGIL='!'; targets=""; AUTO_BRANCHES="feat-*"; }
mkdir -p "$STATE"
consider 12 merge-medic/fix-7-1700000000 feat-7 "resolution" false conflict aaa bbb
check "our own resolution MR is skipped"        "/1" "$targets/$SK_EXCL"
consider 7 feat-7 main "a feature" false conflict ccc ddd
check "an ordinary conflicted MR is still picked" "7	feat-7	main	auto" "$(printf '%s' "$targets" | cut -f1-4)"

# ── the claude resolver's permissions ───────────────────────────────────────
echo
echo "resolver permissions:"
eval "$(sed -n '/^claude_args() {/,/^}/p' "$ROOT/fix-mr.sh")"
# rules <mode> <allowed|denied>: the rules after --allowedTools or --disallowedTools
rules() {
  claude_args "$1" | awk -v want="--$2Tools" '/^--/ { on = ($0 == want); next } on'
}
for mode in plan resolve; do
  args="$(claude_args "$mode")"
  for flag in --restricted --strict-mcp-config; do
    check "$mode: $flag" "1" "$(grep -cxF -- "$flag" <<<"$args")"
  done
  check "$mode: anything not allowed is denied, nobody asked" "dontAsk/none" \
    "$(awk '/^--permission-mode$/ { getline; m = $0 } /^--permission-prompts$/ { getline; p = $0 } END { print m "/" p }' <<<"$args")"
  check "$mode: no blanket git rule" "0" "$(rules "$mode" allowed | grep -cE '^Bash\(git( \*|:\*|\*)\)$')"
  check "$mode: every Bash rule names its git command" "" \
    "$(rules "$mode" allowed | grep '^Bash(' \
       | grep -vE '^Bash\(git (status|log|show|add|rm|checkout --ours|checkout --theirs)( \*)?\)$' \
       | grep -vE '^Bash\(git diff( --cached| HEAD| MERGE_HEAD)?( \*)?\)$')"
  # two paths to `git diff`, one outside the repository, read any file
  check "$mode: git diff takes no free arguments" "0" "$(rules "$mode" allowed | grep -cxF 'Bash(git diff *)')"
  for deny in 'Bash(git push *)' 'Bash(git * push *)' 'Bash(git -c *)' 'Bash(git -C *)' 'Bash(*--output*)' \
              'Bash(*>*)' 'Bash(*--no-index*)' 'Bash(*--pathspec-from-file*)'; do
    check "$mode: $deny is denied" "1" "$(rules "$mode" disallowed | grep -cxF -- "$deny")"
  done
done
check "plan: no tool that writes" "Read,Glob,Grep,Bash" "$(claude_args plan | awk '/^--tools$/ { getline; print }')"
check "plan: git is read-only" "" "$(rules plan allowed | grep -E 'git (add|rm|checkout)')"
check "resolve: may stage and pick sides" "4" "$(rules resolve allowed | grep -cE 'git (add|rm|checkout --ours|checkout --theirs) \*')"

# the resolver's environment keeps git off the network, and only the resolver's
eval "$(sed -n '/^resolver_call() {/,/^}/p' "$ROOT/fix-mr.sh")"
# shellcheck disable=SC2329,SC2317  # called from the extracted resolver_call body
evx() { :; }
# shellcheck disable=SC2329,SC2317
resolver_run() { printf '%s' "${GIT_ALLOW_PROTOCOL-unset}"; }
check "the resolver runs with every git transport refused" "none" "$(resolver_call resolve x /dev/null)"
resolver_call resolve x /dev/null >/dev/null
check "…and the fixer itself does not"            "unset" "${GIT_ALLOW_PROTOCOL-unset}"

rm -rf "$TMP"
[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
