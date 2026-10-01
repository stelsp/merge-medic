# merge-medic deterministic conflict rules.
#
# Reads a conflicted file with zdiff3 markers and resolves the hunks a rule
# can decide without a model. Always prints a usable file: decided hunks are
# collapsed, the rest keep their markers, so whatever is left is a smaller
# job for the resolver rather than a lost one.
# Exit status: 0 = every hunk decided, 1 = some left, 2 = malformed input or
# a refused call, 3 = no conflict hunk at all. A file git reports as
# conflicted but wrote no markers into (modify/delete, binary) is not a
# line-level conflict, so a line rule has nothing to decide there: the
# caller leaves it to the resolver.
#
# Today there is one rule, KEEP_OURS: a hunk is ours when the two sides are
# the same text once the lines matching the KEEP_OURS pattern are taken out.
# That covers the stamp lines tools rewrite on every branch — "> verified:
# <sha>" and friends — which conflict constantly and never carry a decision.
#
# Usage: awk -v keep_ours='<ERE>' -v ours_label=HEAD \
#            -v theirs_label=origin/<target> -f rules.awk <file>
#
# Markers. A file can hold marker-shaped text of its own (a test fixture, a
# docs example), so only the lines git writes for this merge are markers:
#   <<<<<<< <ours_label>[:<path>]      opens a hunk
#   ||||||| <base label>               base, before the separator
#   =======                            separator
#   >>>>>>> <theirs_label>[:<path>]    closes it
# git adds ":<path>" to the labels of a file it merged across a rename, and
# ends every marker with CR in a CRLF file. Any other marker-shaped line is
# content of the section it is in. Where git's line and a content line look
# alike, nothing is decided:
#  - an opener inside an open hunk, a closer outside one or before its
#    separator, a hunk still open at the end: the hunk boundaries are not
#    known, so the whole file is refused (exit 2);
#  - hunks of one file with different markers: git marks every hunk of a
#    file alike, so some of them are content and the file is refused;
#  - a second "=======" in a hunk (a 7-character setext underline), or a
#    second base line before the separator: either could be git's, so that
#    hunk is reprinted exactly as it was and left to the resolver.
# Known limits: a whole marker-shaped block reads as a hunk when it copies
# the markers of the file's real hunks, base line included, or when the file
# has no real hunk to compare it with (the kept side of a modify/delete);
# and in 2-way output, which has no base lines (the fixer always asks for
# zdiff3), a base-shaped line on ours would be taken for the base line.

function refuse(why) {
    printf "rules.awk: %s\n", why > "/dev/stderr"
    refused = 1
    exit 2
}

# the line without the CR a CRLF file ends it with
function text(s) {
    return (substr(s, length(s)) == "\r") ? substr(s, 1, length(s) - 1) : s
}

# t is the marker `head` as git writes it: bare, or with ":<path>"
function is_marker(t, head) {
    return t == head || (substr(t, 1, length(head) + 1) == (head ":") && length(t) > length(head) + 1)
}

function flush_hunk(  i, decided, a, b, na, nb, sig) {
    sig = open_t SUBSEP base_t SUBSEP close_t
    if (resolved + left == 0) file_sig = sig
    else if (sig != file_sig) refuse("hunk markers differ from the first hunk's, line " NR)

    # Decidable only when, stamps aside, both sides hold the same lines in
    # the same order and number: keeping ours then loses nothing but the
    # other side's stamps. Comparing sets instead would call a hunk decided
    # when theirs reordered or repeated a line, and silently drop that.
    decided = (keep_ours != "" && n_sep == 1 && n_bar <= 1)
    if (decided) {
        na = nb = 0
        for (i = 1; i <= n_ours; i++)   if (text(ours[i]) !~ keep_ours)   a[++na] = ours[i]
        for (i = 1; i <= n_theirs; i++) if (text(theirs[i]) !~ keep_ours) b[++nb] = theirs[i]
        if (na != nb) decided = 0
        # ("" forces a string comparison: awk would call "10" and "10.0" equal)
        for (i = 1; decided && i <= na; i++) if ((a[i] "") != (b[i] "")) decided = 0
    }
    # nothing differs at all, or every difference is a stamp: keep ours
    if (decided) {
        for (i = 1; i <= n_ours; i++) print ours[i]
        resolved++
    } else {
        # reprint the hunk exactly as it was, so the file stays mergeable
        for (i = 1; i <= n_raw; i++) print raw[i]
        left++
    }
}

BEGIN {
    side = 0; resolved = 0; left = 0
    # without the labels nothing tells git's markers from marker-shaped
    # content, and there is no loose fallback
    if (ours_label == "" || theirs_label == "")
        refuse("ours_label and theirs_label are required")
    # A pattern that matches the empty string (^, .*, x*, "a|") matches
    # inside every line: both sides would always compare equal and every
    # hunk would be "decided" as ours, dropping theirs.
    if (keep_ours != "" && "" ~ keep_ours)
        refuse("keep_ours matches the empty string, so every line: " keep_ours)
    opener = "<<<<<<< " ours_label
    closer = ">>>>>>> " theirs_label
}

{
    t = text($0)
    if (is_marker(t, opener)) {
        if (side) refuse("conflict opener inside an open hunk, line " NR)
        side = 1; open_t = t; base_t = ""
        n_raw = n_ours = n_theirs = n_sep = n_bar = 0
        raw[++n_raw] = $0
        next
    }
    if (!side) {
        # a closer with nothing open: if it is git's, a closer-shaped line
        # on theirs ended its hunk too early, and that hunk was misread
        if (is_marker(t, closer)) refuse("conflict closer outside a hunk, line " NR)
        print
        next
    }
    raw[++n_raw] = $0
    if (is_marker(t, closer)) {
        if (side != 3) refuse("conflict closer before the separator, line " NR)
        close_t = t; side = 0
        flush_hunk()
        next
    }
    if (t == "=======") {
        if (++n_sep == 1) { side = 3; next }
    } else if (side != 3 && (t == "|||||||" || substr(t, 1, 8) == "||||||| ")) {
        if (++n_bar == 1) { side = 2; base_t = t; next }
    }
    # content, including a second separator or base line (n_sep, n_bar > 1
    # keep that hunk from being decided); base lines live only in raw
    if (side == 1)      ours[++n_ours] = $0
    else if (side == 3) theirs[++n_theirs] = $0
}

END {
    if (refused) exit 2
    # an unterminated hunk means the file is not what we think it is
    if (side) exit 2
    if (resolved + left == 0) exit 3
    if (left > 0) exit 1
    exit 0
}
