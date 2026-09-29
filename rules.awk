# merge-medic deterministic conflict rules.
#
# Reads a conflicted file with zdiff3 markers and resolves the hunks a rule
# can decide without a model. Always prints a usable file: decided hunks are
# collapsed, the rest keep their markers, so whatever is left is a smaller
# job for the resolver rather than a lost one.
# Exit status: 0 = every hunk decided, 1 = some left, 2 = malformed input.
#
# Today there is one rule, KEEP_OURS: a hunk is ours when every line that
# differs between the two sides matches the KEEP_OURS pattern. That covers
# the stamp lines tools rewrite on every branch — "> verified: <sha>" and
# friends — which conflict constantly and never carry a decision.
#
# Usage: awk -v keep_ours='<ERE>' -f rules.awk <file>

function flush_hunk(  i, decided, line) {
    # a hunk is decidable when every line unique to one side matches the
    # pattern: whatever survives, no information is lost
    decided = (keep_ours != "")
    if (decided) {
        for (i = 1; i <= n_ours; i++) {
            line = ours[i]
            if (line ~ keep_ours) continue
            if (line in theirs_set) continue   # same line on both sides
            decided = 0
            break
        }
    }
    if (decided) {
        for (i = 1; i <= n_theirs; i++) {
            line = theirs[i]
            if (line ~ keep_ours) continue
            if (line in ours_set) continue
            decided = 0
            break
        }
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
    delete ours_set
    delete theirs_set
}

BEGIN { side = 0; resolved = 0; left = 0 }

/^<<<<<<< / {
    side = 1; marker_ours = $0
    n_ours = n_base = n_theirs = 0; seen_base = 0
    delete ours_set; delete theirs_set
    next
}
/^\|\|\|\|\|\|\|/  { if (side == 1) { side = 2; marker_base = $0; seen_base = 1; next } }
/^=======$/       { if (side == 1 || side == 2) { side = 3; marker_sep = $0; next } }
/^>>>>>>> /       { if (side == 3) { marker_theirs = $0; side = 0; flush_hunk(); next } }

{
    if (side == 1)      { ours[++n_ours] = $0;     ours_set[$0] = 1 }
    else if (side == 2) { base[++n_base] = $0 }
    else if (side == 3) { theirs[++n_theirs] = $0; theirs_set[$0] = 1 }
    else                  print
}

END {
    # an unterminated hunk means the file is not what we think it is
    if (side != 0) { exit 2 }
    if (left > 0) exit 1
    exit 0
}
