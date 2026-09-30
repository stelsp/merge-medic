# merge-medic deterministic conflict rules.
#
# Reads a conflicted file with zdiff3 markers and resolves the hunks a rule
# can decide without a model. Always prints a usable file: decided hunks are
# collapsed, the rest keep their markers, so whatever is left is a smaller
# job for the resolver rather than a lost one.
# Exit status: 0 = every hunk decided, 1 = some left, 2 = malformed input,
# 3 = no conflict hunk at all. A file git reports as conflicted but wrote no
# markers into (modify/delete, binary) is not a line-level conflict, so a
# line rule has nothing to decide there: the caller leaves it to the resolver.
#
# Today there is one rule, KEEP_OURS: a hunk is ours when the two sides are
# the same text once the lines matching the KEEP_OURS pattern are taken out.
# That covers the stamp lines tools rewrite on every branch — "> verified:
# <sha>" and friends — which conflict constantly and never carry a decision.
#
# Usage: awk -v keep_ours='<ERE>' -f rules.awk <file>

function flush_hunk(  i, decided, a, b, na, nb) {
    # Decidable only when, stamps aside, both sides hold the same lines in
    # the same order and number: keeping ours then loses nothing but the
    # other side's stamps. Comparing sets instead would call a hunk decided
    # when theirs reordered or repeated a line, and silently drop that.
    decided = (keep_ours != "")
    if (decided) {
        na = nb = 0
        for (i = 1; i <= n_ours; i++)   if (ours[i] !~ keep_ours)   a[++na] = ours[i]
        for (i = 1; i <= n_theirs; i++) if (theirs[i] !~ keep_ours) b[++nb] = theirs[i]
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
        print marker_ours
        for (i = 1; i <= n_ours; i++) print ours[i]
        if (seen_base) {
            print marker_base
            for (i = 1; i <= n_base; i++) print base[i]
        }
        print marker_sep
        for (i = 1; i <= n_theirs; i++) print theirs[i]
        print marker_theirs
        left++
    }
    n_ours = n_base = n_theirs = 0
    seen_base = 0
}

BEGIN { side = 0; resolved = 0; left = 0 }

/^<<<<<<< / {
    side = 1; marker_ours = $0
    n_ours = n_base = n_theirs = 0; seen_base = 0
    next
}
/^\|\|\|\|\|\|\|/  { if (side == 1) { side = 2; marker_base = $0; seen_base = 1; next } }
/^=======$/       { if (side == 1 || side == 2) { side = 3; marker_sep = $0; next } }
/^>>>>>>> /       { if (side == 3) { marker_theirs = $0; side = 0; flush_hunk(); next } }

{
    if (side == 1)      ours[++n_ours] = $0
    else if (side == 2) base[++n_base] = $0
    else if (side == 3) theirs[++n_theirs] = $0
    else                  print
}

END {
    # an unterminated hunk means the file is not what we think it is
    if (side != 0) { exit 2 }
    if (resolved + left == 0) exit 3
    if (left > 0) exit 1
    exit 0
}
