package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestCIStateMapping(t *testing.T) {
	cases := map[string]string{
		"SUCCESS": "pass", "success": "pass", "passed": "pass", "NEUTRAL": "pass",
		"FAILURE": "fail", "failed": "fail", "TIMED_OUT": "fail", "canceled": "fail",
		"IN_PROGRESS": "run", "running": "run", "pending": "run", "created": "run",
		"skipped": "skip", "manual": "skip",
		"weird": "wait", "": "wait",
	}
	for in, want := range cases {
		if got := ciState(in); got != want {
			t.Errorf("ciState(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCIBarFixedWidthAndWorstWins(t *testing.T) {
	mk := func(states ...string) ciStatus {
		var c ciStatus
		for _, s := range states {
			c.jobs = append(c.jobs, ciJob{name: "j", state: s})
		}
		return c
	}
	for _, c := range []ciStatus{{}, mk("pass"), mk("pass", "fail", "run"), mk(make([]string, 40)...)} {
		if got := lipgloss.Width(ciBar(c, 0)); got != 6 {
			t.Errorf("ciBar width = %d, want 6 (jobs=%d)", got, len(c.jobs))
		}
	}
	// 12 jobs, one failed: the failure must survive the compression into 6 cells
	states := make([]string, 12)
	for i := range states {
		states[i] = "pass"
	}
	states[5] = "fail"
	if got := ciBar(mk(states...), 0); !strings.Contains(got, red.Render("▰")) {
		t.Error("a failed job disappeared when compressed into the strip")
	}
}

func TestCIBarSkippedIsFilled(t *testing.T) {
	// a pipeline of skipped/manual jobs has finished — it must not look like
	// one that has not started (the empty bucket used to win over "skip")
	c := ciStatus{jobs: []ciJob{{state: "skip"}, {state: "skip"}, {state: "pass"}}}
	if got := ciBar(c, 0); strings.Contains(got, "▱") {
		t.Errorf("skipped jobs render as unstarted cells: %q", got)
	}
}

func TestCIDoneAndCounts(t *testing.T) {
	c := ciStatus{jobs: []ciJob{{state: "pass"}, {state: "run"}}, pass: 1, run: 1}
	if c.done() {
		t.Error("a running pipeline must not report done")
	}
	if !(ciStatus{jobs: []ciJob{{state: "pass"}}, pass: 1}).done() {
		t.Error("an all-finished pipeline must report done")
	}
}

func TestPollIntervalBackoff(t *testing.T) {
	if pollInterval(nil) != 0 {
		t.Error("never-read pipeline must poll immediately")
	}
	running := &ciStatus{fetched: 1, run: 1}
	finished := &ciStatus{fetched: 1}
	if pollInterval(running) >= pollInterval(finished) {
		t.Error("a running pipeline must poll more often than a finished one")
	}
}
