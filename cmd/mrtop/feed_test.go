package main

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

func TestParseWatchLineStructured(t *testing.T) {
	ln := "2026-08-31 14:02:11  SKIP !42 dedup · already tried abc:def"
	r, ok := parseWatchLine(ln, 0)
	if !ok {
		t.Fatal("structured line rejected")
	}
	if r.ch != "SKIP" || r.iid != "42" || !strings.HasPrefix(r.det, "dedup ·") {
		t.Errorf("parsed wrong: ch=%q iid=%q det=%q", r.ch, r.iid, r.det)
	}
	if r.sev != sevChrome {
		t.Errorf("SKIP severity = %d, want chrome", r.sev)
	}
}

func TestParseWatchLineGitHubSigil(t *testing.T) {
	r, _ := parseWatchLine("2026-08-31 14:02:11  CONFLICT #7 a -> b", 0)
	if r.iid != "7" || r.ch != "CONFLICT" || r.sev != sevHuman {
		t.Errorf("github sigil: iid=%q ch=%q sev=%d", r.iid, r.ch, r.sev)
	}
}

func TestParseWatchLineLegacyFallback(t *testing.T) {
	// pre-upgrade watchers (and rotated files) have no channel token
	r, ok := parseWatchLine("2026-08-31 14:02:11  ERROR: could not list MRs", 0)
	if !ok {
		t.Fatal("legacy line rejected — old logs would vanish from the rail")
	}
	if r.ch != "" {
		t.Errorf("legacy line invented a channel: %q", r.ch)
	}
	if r.sev != sevFail {
		t.Errorf("legacy ERROR severity = %d, want fail", r.sev)
	}
}

func TestParseWatchLineNoFalsePositiveChannel(t *testing.T) {
	// a branch named like a channel must not be read as one
	r, _ := parseWatchLine("2026-08-31 14:02:11  fixer -> !5 (fix/ERROR-handling)", 0)
	if r.ch != "" {
		t.Errorf("prose line parsed as channel %q", r.ch)
	}
	if r.sev == sevFail {
		t.Error("a branch named fix/ERROR-handling must not color the row red")
	}
}

func TestParseWatchLineGarbage(t *testing.T) {
	for _, ln := range []string{"", "short", "not-a-timestamp        TICK x"} {
		if _, ok := parseWatchLine(ln, 0); ok {
			t.Errorf("garbage accepted: %q", ln)
		}
	}
}

func TestParseEventLineOutcomes(t *testing.T) {
	cases := []struct {
		det  string
		sev  int
		done bool
	}{
		{"ok · 18s", sevInfo, true},
		{"red · exit 1 · boom", sevFail, false},
		{"skip · VERIFY_CMD is empty", sevChrome, false},
		{"run · pnpm test", sevChrome, false},
		{"policy · protected path", sevHuman, false},
		{"no token at all", sevChrome, false},
	}
	for _, c := range cases {
		r, ok := parseEventLine("1700000000|42|VERIFY|"+c.det, 0)
		if !ok {
			t.Fatalf("event rejected: %q", c.det)
		}
		if r.sev != c.sev {
			t.Errorf("%q severity = %d, want %d", c.det, r.sev, c.sev)
		}
		if r.done != c.done {
			t.Errorf("%q done = %v, want %v", c.det, r.done, c.done)
		}
	}
}

func TestParseEventLineTerminalPhasesKeepSeverity(t *testing.T) {
	r, _ := parseEventLine("1700000000|42|FAIL|REGRESSION red (exit 1)", 0)
	if r.sev != sevFail {
		t.Errorf("FAIL severity = %d, want fail", r.sev)
	}
	r, _ = parseEventLine("1700000000|42|ESCALATED|policy · protected path", 0)
	if r.sev != sevHuman {
		t.Errorf("ESCALATED severity = %d, want human", r.sev)
	}
	r, _ = parseEventLine("1700000000|-|ROTATE|previous: events.log.1", 0)
	if r.iid != "" {
		t.Errorf("iid '-' must render blank, got %q", r.iid)
	}
}

func TestParseEventLineNoFifthFieldAssumption(t *testing.T) {
	// details legitimately contain "|" (commands, paths)
	r, ok := parseEventLine("1700000000|42|VERIFY|run · sh -c 'a | b'", 0)
	if !ok || r.det != "run · sh -c 'a | b'" {
		t.Errorf("detail lost its pipe: ok=%v det=%q", ok, r.det)
	}
}

func TestParseEventLineStripsANSI(t *testing.T) {
	r, _ := parseEventLine("1700000000|42|REGRESSION|red · \x1b[31mFAIL\x1b[0m auth_test", 0)
	if strings.Contains(r.det, "\x1b") || strings.Contains(r.det, "31m") {
		t.Errorf("escape survived parsing: %q", r.det)
	}
	// and the rendered row must not leak a dangling sequence either
	row := renderFeedRow(r, false)
	if strings.Contains(row, "31m") {
		t.Errorf("rendered row leaked an escape body: %q", row)
	}
}

func TestRenderFeedRowGrouping(t *testing.T) {
	r, _ := parseEventLine("1700000000|42|MERGE|origin/main", 0)
	first := renderFeedRow(r, false)
	grouped := renderFeedRow(r, true)
	if !strings.Contains(first, "!42") {
		t.Errorf("first row of a run must name the MR: %q", first)
	}
	if strings.Contains(grouped, "!42") {
		t.Errorf("follow-up rows must collapse the id column: %q", grouped)
	}
	if lipgloss.Width(first) != lipgloss.Width(grouped) {
		t.Errorf("grouping changed the column width: %d vs %d",
			lipgloss.Width(first), lipgloss.Width(grouped))
	}
}

func TestRenderTickIsARule(t *testing.T) {
	r, _ := parseWatchLine("2026-08-31 14:02:11  TICK  12 open · 0 conflicted", 0)
	if !r.tick {
		t.Fatal("TICK not flagged")
	}
	if !strings.Contains(renderFeedRow(r, false), "────") {
		t.Error("a tick should render as a rule, not a row")
	}
}

func TestBuildFeedMergesAndOrders(t *testing.T) {
	root := t.TempDir()
	mkdir(t, root, "logs")
	base := time.Now().Add(-time.Hour).Truncate(time.Second)
	writeFile(t, root, "logs/watch.log",
		base.Format("2006-01-02 15:04:05")+"  CONFLICT !42 a -> b\n")
	writeFile(t, root, "logs/events.log",
		itoa(base.Add(time.Second).Unix())+"|42|START|a -> b · mode=auto\n")
	feed := buildFeed(root)
	if len(feed) != 2 {
		t.Fatalf("feed = %d lines, want 2:\n%s", len(feed), strings.Join(feed, "\n"))
	}
	if !strings.Contains(feed[0], "CONFLICT") || !strings.Contains(feed[1], "START") {
		t.Errorf("wrong chronological order:\n%s", strings.Join(feed, "\n"))
	}
}

func TestBuildFeedSurvivesMissingLogs(t *testing.T) {
	if feed := buildFeed(t.TempDir()); len(feed) != 0 {
		t.Errorf("empty instance produced %d lines", len(feed))
	}
}

func TestStripANSIHardCases(t *testing.T) {
	cases := map[string]string{
		"\x1b[31mred\x1b[0m":       "red",
		"\x1b[?25lhidden":          "hidden", // private CSI, from spinners
		"\x1b[38:2::255:0:0mtruec": "truec",  // colon-separated true color
		"x\x1b]0;my title\x07y":    "xy",     // OSC + BEL terminator
		"x\x1b]0;t\x1b\\y":         "xy",     // OSC + ST terminator
		"\x1b(Bplain":              "plain",  // two-byte escape
		"bell\a":                   "bell",   // a stray BEL beeps every repaint
		"trunc\x1b[31":             "trunc",  // escape cut at end of string
		"lone\x1b":                 "lone",
		"plain text":               "plain text",
		"кириллица\x1b[0m цела":    "кириллица цела",
	}
	for in, want := range cases {
		if got := stripANSI(in); got != want {
			t.Errorf("stripANSI(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseEventLineDropsPartialRune(t *testing.T) {
	// the shell caps details by BYTES, so the last rune can arrive halved
	r, _ := parseEventLine("1700000000|42|VERIFY|red · \xd1", 0)
	if !utf8ValidString(r.det) {
		t.Errorf("invalid UTF-8 reached the UI: %q", r.det)
	}
}

func TestParseWatchLineIDWithoutDetail(t *testing.T) {
	r, ok := parseWatchLine("2026-08-31 14:02:11  CLEARED !42", 0)
	if !ok || r.iid != "42" || r.det != "" {
		t.Errorf("bare channel+id parsed as iid=%q det=%q", r.iid, r.det)
	}
}

func TestRenderFeedRowKeepsForgeSigil(t *testing.T) {
	r, _ := parseWatchLine("2026-08-31 14:02:11  SKIP #10 excluded", 0)
	if got := renderFeedRow(r, false); !strings.Contains(got, "#10") {
		t.Errorf("GitHub PR rendered with the wrong sigil: %q", got)
	}
}

func TestRenderFeedRowKeepsLongestPhase(t *testing.T) {
	r, _ := parseEventLine("1700000000|8|MERGE_CLEAN|no conflicts", 0)
	if got := renderFeedRow(r, false); !strings.Contains(got, "MERGE_CLEAN") {
		t.Errorf("longest phase got clipped: %q", got)
	}
}
