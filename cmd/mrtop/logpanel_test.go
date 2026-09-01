package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestLogWindowTailWhenClean(t *testing.T) {
	lines := []string{"a", "b", "c", "d", "e", "f"}
	got := logWindow(lines, 3)
	if strings.Join(got, "") != "def" {
		t.Errorf("a clean log should show its tail, got %v", got)
	}
}

func TestLogWindowAnchorsOnFailure(t *testing.T) {
	// the diagnostic is in the middle; the resolver's summary trails it
	lines := []string{
		"starting", "reading files", "thinking",
		"FAIL src/auth_test.ts > rotates the secret",
		"more output", "summary line 1", "summary line 2",
		"summary line 3", "summary line 4", "summary line 5",
	}
	got := strings.Join(logWindow(lines, 4), "\n")
	if !strings.Contains(got, "FAIL src/auth_test.ts") {
		t.Errorf("window missed the failure it exists to show:\n%s", got)
	}
}

func TestLogWindowKeepsRequestedSize(t *testing.T) {
	lines := make([]string, 50)
	for i := range lines {
		lines[i] = "line"
	}
	lines[3] = "Error: boom" // near the top, so the window must clamp
	for _, w := range []int{4, 10, 25} {
		if got := len(logWindow(lines, w)); got != w {
			t.Errorf("window %d returned %d lines", w, got)
		}
	}
}

func TestLogWindowShortLogUntouched(t *testing.T) {
	lines := []string{"one", "two"}
	if got := logWindow(lines, 10); len(got) != 2 {
		t.Errorf("a log shorter than the window must pass through, got %v", got)
	}
}

func TestLooksLikeFailure(t *testing.T) {
	yes := []string{"Error: boom", "FAIL tests/x", "  Traceback (most recent call last):",
		"exit status 1", "panic: nil map", "✗ regression"}
	no := []string{"all good", "resolving conflicts in src/error_handler.ts",
		"branch fix/ERROR-handling", "12 files changed"}
	for _, ln := range yes {
		if !looksLikeFailure(ln) {
			t.Errorf("missed a failure line: %q", ln)
		}
	}
	for _, ln := range no {
		if looksLikeFailure(ln) {
			t.Errorf("false positive: %q", ln)
		}
	}
}

func TestReadLogPicksNewestAndNamesTheOther(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, filepath.Join("logs", "fixer-42.log"), "older\n")
	writeFile(t, root, filepath.Join("logs", "ai-42-1700000000.log"), "newer\nlines\n")
	name, other, lines := readLog(root, "42", 10)
	if name != "ai-42-1700000000.log" {
		t.Errorf("newest log = %q", name)
	}
	if other != "fixer-42.log" {
		t.Errorf("other candidate = %q", other)
	}
	if len(lines) != 2 {
		t.Errorf("lines = %v", lines)
	}
}

func TestReadLogStripsANSI(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, filepath.Join("logs", "fixer-42.log"), "\x1b[31mFAILED auth\x1b[0m\n")
	_, _, lines := readLog(root, "42", 10)
	if len(lines) != 1 || strings.Contains(lines[0], "\x1b") || strings.Contains(lines[0], "31m") {
		t.Errorf("escapes survived: %q", lines)
	}
}

func TestReadLogMissing(t *testing.T) {
	name, _, lines := readLog(t.TempDir(), "42", 10)
	if name != "" || lines != nil {
		t.Errorf("a missing log must be empty, got %q %v", name, lines)
	}
	if name, _, _ := readLog(t.TempDir(), "", 10); name != "" {
		t.Error("no selection must read nothing")
	}
}

func TestRefreshLogClearsWithoutSelection(t *testing.T) {
	// the panel used to keep a merged MR's log under a live MR's header
	m := model{root: t.TempDir(), height: 40, logName: "stale.log", logLines: []string{"old"}}
	m.refreshLog()
	if m.logName != "" || m.logLines != nil {
		t.Errorf("panel kept stale content: %q %v", m.logName, m.logLines)
	}
}

func TestLogPanelHeightBounds(t *testing.T) {
	for _, h := range []int{0, 10, 40, 200} {
		m := model{height: h}
		got := m.logPanelHeight()
		if got < 6 || got > 20 {
			t.Errorf("terminal height %d gave a panel of %d lines", h, got)
		}
	}
}
