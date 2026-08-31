package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// Every line of a panel must be exactly w columns — misaligned borders are
// the most visible way a TUI can break.
func TestTitledBoxWidth(t *testing.T) {
	for _, w := range []int{30, 80, 120} {
		for _, focused := range []bool{false, true} {
			box := titledBox(w, "TITLE", "meta 12", "body line\nsecond", 0, focused)
			for i, ln := range strings.Split(box, "\n") {
				if got := lipgloss.Width(ln); got != w {
					t.Errorf("w=%d focused=%v line %d: width %d\n%q", w, focused, i, got, ln)
				}
			}
		}
	}
}

func TestTitledBoxFixedHeight(t *testing.T) {
	box := titledBox(60, "T", "", "one line", 5, false)
	// 1 top border + 5 content + 1 bottom border
	if n := strings.Count(box, "\n") + 1; n != 7 {
		t.Errorf("height 5 box has %d lines, want 7", n)
	}
}

func TestSelMark(t *testing.T) {
	got := selMark(" row text", 0)
	if !strings.HasSuffix(got, "row text") {
		t.Errorf("row text mangled: %q", got)
	}
	if lipgloss.Width(got) != lipgloss.Width(" row text") {
		t.Errorf("selMark changed visual width: %d != %d", lipgloss.Width(got), lipgloss.Width(" row text"))
	}
}

func TestSparkline(t *testing.T) {
	if got := sparkline([]int{0, 0, 0}); lipgloss.Width(got) != 3 {
		t.Errorf("flat sparkline width = %d", lipgloss.Width(got))
	}
	if got := sparkline([]int{0, 5, 10}); lipgloss.Width(got) != 3 {
		t.Errorf("sparkline width = %d", lipgloss.Width(got))
	}
}

func TestGaugeWidth(t *testing.T) {
	for _, cur := range []int{0, 3, 6, 99} {
		if got := lipgloss.Width(gauge(cur, 6, 10)); got != 10 {
			t.Errorf("gauge(%d,6,10) width = %d, want 10", cur, got)
		}
	}
}

func TestSegBarStableWidth(t *testing.T) {
	w := lipgloss.Width(segBar("START", 0))
	for _, ph := range []string{"MERGE", "AI_RESOLVE", "VERIFY", "PUSH", "DONE", "FAIL"} {
		for _, frame := range []int{0, 1, 7} {
			if got := lipgloss.Width(segBar(ph, frame)); got != w {
				t.Errorf("segBar(%q,%d) width %d != %d", ph, frame, got, w)
			}
		}
	}
}

func TestBoolSwitchWidthAndValue(t *testing.T) {
	on, off := boolSwitch(true), boolSwitch(false)
	if !strings.Contains(on, "true") || !strings.Contains(off, "false") {
		t.Errorf("switch must spell the value: %q / %q", on, off)
	}
	// both states must be short enough for the narrow STATUS column
	for _, sw := range []string{on, off} {
		if w := lipgloss.Width(sw); w > 10 {
			t.Errorf("switch too wide: %d cols (%q)", w, sw)
		}
	}
	if strings.Contains(on, "—") || strings.Contains(off, "—") {
		t.Error("switches must not carry prose — it overflows the panel")
	}
}
