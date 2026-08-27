package main

import "testing"

func TestTerminal(t *testing.T) {
	for _, ph := range []string{"DONE", "FAIL", "ESCALATED", "PLANNED", "DEFERRED"} {
		if !terminal(ph) {
			t.Errorf("terminal(%q) = false", ph)
		}
	}
	for _, ph := range []string{"START", "MERGE", "AI_RESOLVE", "PUSH", ""} {
		if terminal(ph) {
			t.Errorf("terminal(%q) = true", ph)
		}
	}
}

func TestPhaseSlotOrder(t *testing.T) {
	path := []string{"START", "WORKTREE", "MERGE", "AI_RESOLVE", "VERIFY", "TESTS", "REGRESSION", "PUSH", "DONE"}
	for i := 1; i < len(path); i++ {
		if phaseSlot(path[i-1]) >= phaseSlot(path[i]) {
			t.Errorf("phaseSlot not monotonic: %s(%d) >= %s(%d)",
				path[i-1], phaseSlot(path[i-1]), path[i], phaseSlot(path[i]))
		}
	}
	// the three middle resolutions share one slot
	if phaseSlot("MERGE_CLEAN") != phaseSlot("AI_RESOLVE") || phaseSlot("AI_RESOLVE") != phaseSlot("PLAN") {
		t.Error("MERGE_CLEAN/AI_RESOLVE/PLAN must share a slot")
	}
}

func TestPhasesTableSane(t *testing.T) {
	// stale detection divides by avg — a zero would panic the render loop
	for ph, p := range phases {
		if p.avg <= 0 {
			t.Errorf("phases[%q].avg = %d, must be positive", ph, p.avg)
		}
	}
	// every terminal state must be in the table (stale detection looks it up)
	for _, ph := range []string{"DONE", "FAIL", "ESCALATED", "PLANNED", "DEFERRED"} {
		if _, ok := phases[ph]; !ok {
			t.Errorf("terminal phase %q missing from phases table", ph)
		}
	}
}
