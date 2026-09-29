#!/bin/bash
# Tests for rules.awk — the deterministic layer that resolves conflicts with
# no model involved. It edits the user's files, so every case where it must
# REFUSE matters more than the ones where it acts.
# Run: bash tests/rules.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
fails=0
RC=0
OUT=""

# The exit status matters as much as the output. Calling this inside $( )
# would lose it to the subshell, so run it plainly and read OUT afterwards.
run() { # pattern file  -> sets OUT and RC
  awk -v keep_ours="$1" -f "$ROOT/rules.awk" "$2" > "$TMP/.out" 2>/dev/null
  RC=$?
  OUT="$(cat "$TMP/.out")"
}

check() { # description expected actual
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s:\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

echo "rules.awk:"

# ── the case this exists for: a stamp line both branches rewrote ────────────
cat > "$TMP/stamp" <<'EOF'
intro
<<<<<<< HEAD
> verified: aaaa111
||||||| base
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev
outro
EOF
run '^> verified: ' "$TMP/stamp"; rc=$RC; out="$OUT"
check "stamp hunk decided"        "0" "$rc"
check "ours kept"                 "intro
> verified: aaaa111
outro" "$out"

# ── refuse when a real change rides along in the same hunk ──────────────────
cat > "$TMP/mixed" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
const timeout = 30
||||||| base
> verified: 0000000
const timeout = 10
=======
> verified: bbbb222
const timeout = 60
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/mixed"; rc=$RC; out="$OUT"
check "mixed hunk refused"          "1" "$rc"
check "refused hunk kept verbatim"  "$(cat "$TMP/mixed")" "$out"

# ── a file with two hunks, one decidable: the rest still goes to the model ──
cat > "$TMP/partial" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
=======
> verified: bbbb222
>>>>>>> origin/dev
middle
<<<<<<< HEAD
real code ours
=======
real code theirs
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/partial"; rc=$RC; out="$OUT"
check "partial file reports leftovers" "1" "$rc"
check "decided hunk collapsed"         "1" "$(printf '%s\n' "$out" | grep -c '^> verified: aaaa111$')"
check "undecided hunk still marked"    "1" "$(printf '%s\n' "$out" | grep -c '^real code theirs$')"

# ── no pattern configured: the layer must do nothing at all ─────────────────
run '' "$TMP/stamp"; rc=$RC; out="$OUT"
check "empty pattern decides nothing" "1" "$rc"
check "empty pattern changes nothing" "$(cat "$TMP/stamp")" "$out"

# ── a clean file passes through untouched ───────────────────────────────────
printf 'a\nb\n' > "$TMP/clean"
run '^> verified: ' "$TMP/clean"; rc=$RC; out="$OUT"
check "clean file untouched" "a
b" "$out"
check "clean file exits 0"   "0" "$rc"

# ── diff3 markers without a description, and no base block at all ───────────
cat > "$TMP/nobase" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/nobase"; rc=$RC; out="$OUT"
check "hunk without a base block decided" "0" "$rc"
check "…keeping ours"                     "> verified: aaaa111" "$out"

# ── content that merely mentions a marker must not derail the parser ────────
cat > "$TMP/quoted" <<'EOF'
The docs explain that <<<<<<< marks a conflict.
<<<<<<< HEAD
> verified: aaaa111
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/quoted"; rc=$RC; out="$OUT"
check "prose mentioning a marker survives" "1" "$(printf '%s\n' "$out" | grep -c 'marks a conflict')"
check "…and the real hunk is still decided" "0" "$rc"

# ── truncated hunk: refuse loudly rather than emit half a file ──────────────
printf '<<<<<<< HEAD\nours\n=======\ntheirs\n' > "$TMP/truncated"
run '^> verified: ' "$TMP/truncated"; rc=$RC
check "unterminated hunk is an error" "2" "$rc"

# ── a pattern matching everything must still not invent content ─────────────
cat > "$TMP/anypat" <<'EOF'
<<<<<<< HEAD
ours line
=======
theirs line
>>>>>>> origin/dev
EOF
run '.' "$TMP/anypat"; rc=$RC; out="$OUT"
check "greedy pattern keeps ours only" "ours line" "$out"

rm -rf "$TMP"
[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
