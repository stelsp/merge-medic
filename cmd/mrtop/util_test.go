package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestTrunc(t *testing.T) {
	cases := []struct {
		in   string
		n    int
		want string
	}{
		{"hello", 10, "hello"},
		{"hello", 5, "hello"},
		{"hello world", 5, "hell…"},
		{"héllo wörld", 6, "héllo…"}, // rune-aware, not byte-aware
		{"hi", 1, "h"},
		{"hello", 0, "hello"}, // 0 = no limit
	}
	for _, c := range cases {
		if got := trunc(c.in, c.n); got != c.want {
			t.Errorf("trunc(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}

func TestPadTo(t *testing.T) {
	if got := padTo("ab", 5); got != "ab   " {
		t.Errorf("padTo plain = %q", got)
	}
	// ANSI-styled input must be padded by VISUAL width, not byte length
	styled := lipgloss.NewStyle().Bold(true).Render("ab")
	if w := lipgloss.Width(padTo(styled, 5)); w != 5 {
		t.Errorf("padTo styled visual width = %d, want 5", w)
	}
	if got := padTo("abcdef", 3); got != "abcdef" {
		t.Errorf("padTo must not truncate: %q", got)
	}
}

func TestWrapPlain(t *testing.T) {
	// short text passes through
	if got := wrapPlain("hello", 40); len(got) != 1 || got[0] != "hello" {
		t.Errorf("short = %v", got)
	}
	// wraps on spaces, no line exceeds width
	long := strings.Repeat("word ", 30)
	for _, ln := range wrapPlain(long, 20) {
		if len([]rune(ln)) > 20 {
			t.Errorf("line over width: %q", ln)
		}
	}
	// a single unbreakable run is hard-cut, not looped forever
	got := wrapPlain(strings.Repeat("x", 50), 20)
	if len(got) != 3 {
		t.Errorf("unbreakable: %d lines, want 3", len(got))
	}
	// blank lines survive (markdown paragraphs)
	if got := wrapPlain("a\n\nb", 40); len(got) != 3 || got[1] != "" {
		t.Errorf("blank line lost: %v", got)
	}
}

func TestFmtAge(t *testing.T) {
	cases := map[int64]string{-5: "0m", 0: "0m", 59: "0m", 120: "2m", 3600: "1h", 7200: "2h", 86400: "1d", 200000: "2d"}
	for in, want := range cases {
		if got := fmtAge(in); got != want {
			t.Errorf("fmtAge(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestFmtTok(t *testing.T) {
	cases := map[int64]string{0: "0", 999: "999", 1000: "1k", 15500: "16k", 1_500_000: "1.5M"}
	for in, want := range cases {
		if got := fmtTok(in); got != want {
			t.Errorf("fmtTok(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestNonEmpty(t *testing.T) {
	got := nonEmpty([]string{"a", "", "  ", "b", ""})
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Errorf("nonEmpty = %v", got)
	}
}

func TestWindowRowsFitsWhole(t *testing.T) {
	items := []string{"a", "b", "c"}
	if got := windowRows(items, 1, 10); len(got) != 3 {
		t.Errorf("no clipping expected: %v", got)
	}
}

func TestWindowRowsKeepsSelection(t *testing.T) {
	items := []string{"r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"}
	got := windowRows(items, 6, 4)
	joined := strings.Join(got, "\n")
	if !strings.Contains(joined, "r6") {
		t.Fatalf("selected row clipped out: %v", got)
	}
	if n := strings.Count(joined, "\n") + 1; n > 4 {
		t.Errorf("window exceeds cap: %d lines", n)
	}
	if !strings.Contains(joined, "above") {
		t.Errorf("missing ↑ marker: %v", got)
	}
}

func TestWindowRowsClampsGiantItem(t *testing.T) {
	giant := strings.Repeat("line\n", 20) + "line"
	got := windowRows([]string{"a", giant, "b"}, 1, 6)
	joined := strings.Join(got, "\n")
	if n := strings.Count(joined, "\n") + 1; n > 6 {
		t.Errorf("giant item not clamped: %d lines", n)
	}
	if !strings.Contains(joined, "more lines") {
		t.Errorf("missing clamp marker: %v", got)
	}
}
