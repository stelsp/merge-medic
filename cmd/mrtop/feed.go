// The live event rail: one chronological stream merged from the watcher's
// log and the fixers' phase events, parsed into columns and colored by
// severity so a failure is findable at a glance.
package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// severity drives color, not the source of a line: a watcher ERROR and a
// fixer FAIL must look identical, so the eye learns one failure silhouette.
const (
	sevChrome = iota // ticks, transit phases — dim, meant to be skimmed past
	sevInfo          // something happened and it went fine
	sevHuman         // waiting for a person: plans, escalations, radar, budget
	sevFail          // broken
)

// feedRow is one parsed rail line before rendering.
type feedRow struct {
	ts   int64
	src  int // 0 watch.log, 1 events.log — sort tiebreak within a second
	seq  int // arrival order inside its source
	sev  int
	iid  string // "" for watcher-global lines
	ch   string // channel (watcher) or phase (fixer)
	det  string
	tick bool // TICK lines render as a rule, not a row
	done bool // a real completion — only these earn the ✓ glyph
}

// watcher channels, written by logc() in watch.sh
var feedChannels = map[string]int{
	"TICK":     sevChrome,
	"FIX":      sevInfo,
	"CLEARED":  sevInfo,
	"ROTATE":   sevChrome,
	"SKIP":     sevChrome,
	"CONFLICT": sevHuman,
	"RADAR":    sevHuman,
	"BUDGET":   sevHuman,
	"LOCK":     sevHuman,
	"WARN":     sevHuman,
	"ERROR":    sevFail,
}

// phaseSeverity maps a fixer phase to its resting severity; the detail's
// outcome token can still raise it (a red VERIFY is a failure).
func phaseSeverity(phase string) int {
	switch phase {
	case "DONE":
		return sevInfo
	case "FAIL":
		return sevFail
	case "ESCALATED", "PLANNED":
		return sevHuman
	}
	return sevChrome
}

// outcomeSeverity reads the leading token of an event detail
// ("ok · 18s", "red · exit 1 · …", "skip · …", "policy · …").
func outcomeSeverity(det string) (int, bool) {
	tok := det
	if i := strings.Index(det, " ·"); i > 0 {
		tok = det[:i]
	}
	switch tok {
	case "ok":
		return sevInfo, true
	case "red":
		return sevFail, true
	case "policy", "warn":
		return sevHuman, true
	case "skip", "info", "run":
		return sevChrome, true
	}
	return 0, false
}

// isChannelToken: an all-caps word we know — cheap and allocation-free, so a
// prose line never gets mistaken for a structured one.
func isChannelToken(s string) bool {
	_, ok := feedChannels[s]
	return ok
}

// parseWatchLine turns "2026-08-31 14:02:11  SKIP !42 dedup · …" into a row.
// Lines that do not start with a known channel keep the legacy coloring, so
// logs written by an older watcher (and rotated files) still render.
func parseWatchLine(ln string, seq int) (feedRow, bool) {
	if len(ln) < 21 {
		return feedRow{}, false
	}
	t, err := time.ParseInLocation("2006-01-02 15:04:05", ln[:19], time.Local)
	if err != nil {
		return feedRow{}, false
	}
	msg := strings.TrimRight(ln[21:], " ")
	row := feedRow{ts: t.Unix(), src: 0, seq: seq, det: msg}

	head, rest, _ := strings.Cut(msg, " ")
	if !isChannelToken(head) {
		// legacy line (pre-channel watcher, or a rotated file): recognize the
		// old wordings only where they were actually written — matching
		// "ERROR" anywhere would paint a branch named fix/ERROR-handling red
		switch {
		case strings.HasPrefix(msg, "ERROR"), strings.HasPrefix(msg, "  ERROR"):
			row.sev = sevFail
		case strings.HasPrefix(msg, "WARN"), strings.Contains(msg, "went into CONFLICT"),
			strings.HasPrefix(msg, "RADAR:"):
			row.sev = sevHuman
		default:
			row.sev = sevChrome
		}
		return row, true
	}
	row.ch, row.sev, row.tick = head, feedChannels[head], head == "TICK"
	row.done = head == "CLEARED"
	// an optional "!42" / "#42" id follows the channel
	if id, tail, ok := strings.Cut(rest, " "); ok && len(id) > 1 && (id[0] == '!' || id[0] == '#') {
		if _, err := strconv.Atoi(id[1:]); err == nil {
			row.iid, rest = id[1:], tail
		}
	}
	row.det = rest
	return row, true
}

// parseEventLine reads "ts|iid|PHASE|detail" from events.log. It never
// assumes a fifth field: structure lives in the detail's leading token.
func parseEventLine(ln string, seq int) (feedRow, bool) {
	parts := strings.SplitN(ln, "|", 4)
	if len(parts) < 3 {
		return feedRow{}, false
	}
	ts, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return feedRow{}, false
	}
	row := feedRow{ts: ts, src: 1, seq: seq, ch: parts[2], sev: phaseSeverity(parts[2]), done: parts[2] == "DONE"}
	if parts[1] != "-" {
		row.iid = parts[1]
	}
	if len(parts) > 3 {
		row.det = stripANSI(parts[3])
	}
	if strings.HasPrefix(row.det, "ok ·") {
		row.done = true
	}
	if sev, ok := outcomeSeverity(row.det); ok && sev > row.sev {
		row.sev = sev
	} else if ok && row.ch != "FAIL" && row.ch != "ESCALATED" {
		row.sev = sev
	}
	return row, true
}

// renderFeedRow lays a row out as: time · glyph · id · channel · detail.
// The id column collapses to a dim rule when the previous row was the same
// MR, which visually groups a fixer's run without indenting it.
func renderFeedRow(r feedRow, sameAsPrev bool) string {
	ts := dim.Render(time.Unix(r.ts, 0).Format("15:04:05"))
	if r.tick {
		return ts + " " + dim.Render("──── "+r.det)
	}

	glyph := " "
	tokSt, detSt := dim, dim
	switch r.sev {
	case sevInfo:
		tokSt = green
		if r.done { // ✓ means "finished well", not merely "went fine"
			glyph = green.Render("✓")
		}
	case sevHuman:
		glyph, tokSt, detSt = yellow.Render("⚑"), yellow, lipglossPlain
	case sevFail:
		glyph, tokSt, detSt = red.Render("✗"), red, lipglossPlain
	}
	// transit phases are chrome even though they belong to a run
	if r.sev == sevChrome {
		glyph = " "
	}

	id := "     "
	switch {
	case r.iid == "":
	case sameAsPrev:
		id = dim.Render("  │  ")
	default:
		id = padTo(amberB.Render("!"+r.iid), 5)
	}

	tok := ""
	if r.ch != "" {
		tok = tokSt.Render(fmt.Sprintf("%-10s", trunc(r.ch, 10)))
	}
	return ts + " " + glyph + " " + id + " " + tok + " " + detSt.Render(r.det)
}

// buildFeed merges both logs into the rail. Both files are read from their
// tail; each source is capped before the merge so a chatty watcher cannot
// evict every fixer event.
func buildFeed(root string) []string {
	const perSource = 150
	var rows []feedRow

	watch := tailWithRotation(filepath.Join(root, "logs", "watch.log"), 32*1024)
	if len(watch) > perSource {
		watch = watch[len(watch)-perSource:]
	}
	for i, ln := range watch {
		if r, ok := parseWatchLine(ln, i); ok {
			rows = append(rows, r)
		}
	}

	events := tailWithRotation(filepath.Join(root, "logs", "events.log"), 32*1024)
	if len(events) > perSource {
		events = events[len(events)-perSource:]
	}
	for i, ln := range events {
		if r, ok := parseEventLine(ln, i); ok {
			rows = append(rows, r)
		}
	}

	sort.Slice(rows, func(i, j int) bool {
		if rows[i].ts != rows[j].ts {
			return rows[i].ts < rows[j].ts
		}
		if rows[i].src != rows[j].src {
			return rows[i].src < rows[j].src
		}
		return rows[i].seq < rows[j].seq
	})

	out := make([]string, 0, len(rows)+4)
	prevIID, prevDay := "", ""
	for _, r := range rows {
		day := time.Unix(r.ts, 0).Format("02.01")
		if prevDay != "" && day != prevDay {
			out = append(out, dim.Render("── "+day+" ──"))
			prevIID = ""
		}
		prevDay = day
		out = append(out, renderFeedRow(r, r.iid != "" && r.iid == prevIID))
		prevIID = r.iid
	}
	if len(out) > 300 {
		out = out[len(out)-300:]
	}
	return out
}

// tailWithRotation reads the tail of a log, falling back to the rotated
// <file>.1 when the live file is shorter than the window — right after a
// rotation the rail would otherwise look like a dead watcher.
func tailWithRotation(path string, window int64) []string {
	lines := tailBytes(path, window)
	if int64(len(strings.Join(lines, "\n"))) >= window/2 {
		return lines
	}
	if prev := tailBytes(path+".1", window); len(prev) > 0 {
		return append(prev, lines...)
	}
	return lines
}
