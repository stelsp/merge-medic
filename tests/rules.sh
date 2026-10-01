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
# The labels default to what `git merge origin/dev` writes from HEAD; pass
# '' to leave one empty.
run() { # pattern file [ours_label] [theirs_label]  -> sets OUT and RC
  awk -v keep_ours="$1" -v ours_label="${3-HEAD}" -v theirs_label="${4-origin/dev}" \
    -f "$ROOT/rules.awk" "$2" > "$TMP/.out" 2>/dev/null
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

# ── no hunk at all: git called it conflicted but wrote no markers ───────────
# (modify/delete, binary). There is nothing a line rule can decide, and
# "decided" here would have the caller stage the file as git left it.
printf 'a\nb\n' > "$TMP/clean"
run '^> verified: ' "$TMP/clean"; rc=$RC; out="$OUT"
check "markerless file untouched"          "a
b" "$out"
check "markerless file is refused, not decided" "3" "$rc"

# ── same lines, different order: not a stamp-only difference ────────────────
cat > "$TMP/reorder" <<'EOF'
<<<<<<< HEAD
alpha
beta
> verified: aaaa111
=======
beta
alpha
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/reorder"; rc=$RC; out="$OUT"
check "reordered lines refused"      "1" "$rc"
check "…and kept verbatim"           "$(cat "$TMP/reorder")" "$out"

# ── a line the other side repeats is a change too ───────────────────────────
cat > "$TMP/repeat" <<'EOF'
<<<<<<< HEAD
item
> verified: aaaa111
=======
item
item
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/repeat"; rc=$RC
check "repeated line refused" "1" "$rc"

# ── numbers are text: "10" and "10.0" are different lines ───────────────────
cat > "$TMP/numeric" <<'EOF'
<<<<<<< HEAD
10
> verified: aaaa111
=======
10.0
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/numeric"; rc=$RC
check "numeric-looking lines compared as text" "1" "$rc"

# ── identical text around the stamps, same order: still decided ────────────
cat > "$TMP/same" <<'EOF'
<<<<<<< HEAD
# Title
> verified: aaaa111
body
=======
# Title
> verified: bbbb222
body
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/same"; rc=$RC; out="$OUT"
check "stamp amid identical lines decided" "0" "$rc"
check "…keeping ours"                      "# Title
> verified: aaaa111
body" "$out"

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

# ── no labels, no loose fallback: a caller that forgets them decides nothing ─
awk -v keep_ours='^> verified: ' -f "$ROOT/rules.awk" "$TMP/stamp" > /dev/null 2>&1; rc=$?
check "labels not passed: refused"     "2" "$rc"
run '^> verified: ' "$TMP/stamp" '' 'origin/dev'; rc=$RC
check "empty ours_label refused"       "2" "$rc"
run '^> verified: ' "$TMP/stamp" 'HEAD' ''; rc=$RC
check "empty theirs_label refused"     "2" "$rc"

# ── a pattern that matches the empty string matches inside every line ──────
# It would take every line out of both sides and "decide" a hunk with a real
# change in it, dropping theirs. (BWK awk and mawk reject "a|" as a regex
# outright, which is an exit 2 as well.)
for pat in '^' '.*' 'x*' '^> verified: |' '(^> verified: )?'; do
  run "$pat" "$TMP/mixed"; rc=$RC
  check "pattern '$pat' refused"       "2" "$rc"
done

# ── marker-shaped text that is not this merge's stays content ───────────────
cat > "$TMP/example" <<'EOF'
A conflict looks like this:
<<<<<<< feature
> verified: 1111111
||||||| base
> verified: 0000000
=======
> verified: 2222222
>>>>>>> other
<<<<<<< HEAD
> verified: aaaa111
||||||| e449d7e
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev
outro
EOF
run '^> verified: ' "$TMP/example"; rc=$RC; out="$OUT"
check "foreign markers outside a hunk: real hunk decided" "0" "$rc"
check "…and the example left as written" "$(sed -n '1,8p' "$TMP/example")
> verified: aaaa111
outro" "$out"

# …and inside a hunk such a line belongs to its side
cat > "$TMP/inner" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
<<<<<<< feature
example
>>>>>>> other
||||||| e449d7e
> verified: 0000000
<<<<<<< feature
example
>>>>>>> other
=======
> verified: bbbb222
<<<<<<< feature
example
>>>>>>> other
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/inner"; rc=$RC; out="$OUT"
check "foreign markers inside a hunk are content" "0" "$rc"
check "…kept with ours"                  "> verified: aaaa111
<<<<<<< feature
example
>>>>>>> other" "$out"

# ── a file merged across a rename: git adds ":<path>" to every label ────────
# (a label that only starts like ours is still content)
cat > "$TMP/renamed" <<'EOF'
<<<<<<< HEADER
> verified: 1111111
=======
> verified: 2222222
>>>>>>> origin/develop
<<<<<<< HEAD:docs/new.md
> verified: aaaa111
||||||| 7902feb:docs/old.md
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev:docs/old.md
EOF
run '^> verified: ' "$TMP/renamed"; rc=$RC; out="$OUT"
check "rename-suffixed labels recognized" "0" "$rc"
check "…look-alike labels left as content" "$(sed -n '1,5p' "$TMP/renamed")
> verified: aaaa111" "$out"

# ── a CRLF file: git ends every marker with CR as well ──────────────────────
printf 'intro\r\n<<<<<<< HEAD\r\n> verified: aaaa111\r\n||||||| e449d7e\r\n> verified: 0000000\r\n=======\r\n> verified: bbbb222\r\n>>>>>>> origin/dev\r\noutro\r\n' > "$TMP/crlf"
run '^> verified: [0-9a-f]+$' "$TMP/crlf"; rc=$RC; out="$OUT"
check "CRLF hunk decided"                "0" "$rc"
check "…keeping ours, CRLF intact"       "$(printf 'intro\r\n> verified: aaaa111\r\noutro\r')" "$out"

# ── a criss-cross merge: the base holds the merge bases' own conflict, in
# 9-character markers, which are content ────────────────────────────────────
cat > "$TMP/crisscross" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
||||||| merged common ancestors
<<<<<<<<< Temporary merge branch 1
> verified: 2222222
||||||||| 354aaa4
> verified: 0000000
=========
> verified: 1111111
>>>>>>>>> Temporary merge branch 2
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/crisscross"; rc=$RC; out="$OUT"
check "criss-cross base decided"         "0" "$rc"
check "…keeping ours"                    "> verified: aaaa111" "$out"

# ── this merge's own markers where git never puts them: refuse the file ─────
cat > "$TMP/nested" <<'EOF'
<<<<<<< HEAD
keep me
<<<<<<< HEAD
> verified: aaaa111
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/nested"; rc=$RC
check "opener inside an open hunk refused" "2" "$rc"

cat > "$TMP/early" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
>>>>>>> origin/dev
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/early"; rc=$RC
check "closer before the separator refused" "2" "$rc"

# a closer-shaped line on theirs ends the hunk too soon: deciding that much
# would leave the rest of theirs and git's own closer in the file. What
# gives it away is a closer with no hunk open.
cat > "$TMP/stray" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
||||||| e449d7e
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev
theirs goes on
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/stray"; rc=$RC
check "closer with no hunk open refused" "2" "$rc"

# git marks every hunk of a file alike: a block with this merge's labels but
# a base line of its own is text, not a hunk
cat > "$TMP/lookalike" <<'EOF'
<<<<<<< HEAD
> verified: 1111111
||||||| base
> verified: 0000000
=======
> verified: 2222222
>>>>>>> origin/dev
<<<<<<< HEAD
> verified: aaaa111
||||||| e449d7e
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/lookalike"; rc=$RC
check "hunks marked unlike each other refused" "2" "$rc"

# ── separator or base lines that could be git's or the file's: leave as is ──
# A 7-character setext underline is a "=======" line. With two of them in a
# hunk either could be the separator, so the hunk comes back untouched.
cat > "$TMP/setext" <<'EOF'
<<<<<<< HEAD
Changes
=======
> verified: aaaa111
||||||| e449d7e
Changes
=======
> verified: 0000000
=======
Changes
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/setext"; rc=$RC; out="$OUT"
check "setext underline in a hunk: not decided" "1" "$rc"
check "…reprinted verbatim"              "$(cat "$TMP/setext")" "$out"

# a base-shaped line on ours makes two base lines; taking the first for
# git's would drop the ours lines after it
cat > "$TMP/twobase" <<'EOF'
<<<<<<< HEAD
> verified: aaaa111
||||||| how a base line looks
keep this line
||||||| e449d7e
> verified: 0000000
=======
> verified: bbbb222
>>>>>>> origin/dev
EOF
run '^> verified: ' "$TMP/twobase"; rc=$RC; out="$OUT"
check "two base lines: not decided"      "1" "$rc"
check "…reprinted verbatim"              "$(cat "$TMP/twobase")" "$out"

rm -rf "$TMP"
[ "$fails" = "0" ] && { echo "all good"; exit 0; }
echo "$fails failing case(s)"; exit 1
