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

rm -rf "$TMP"
[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
