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

func TestPhasePctBounds(t *testing.T) {
	for ph := range phases {
		for _, sec := range []int{0, 1, 100, 100000} {
			pct := phasePct(ph, sec)
			if pct < 0 || pct > 100 {
				t.Errorf("phasePct(%q, %d) = %d out of [0,100]", ph, sec, pct)
			}
		}
	}
	if phasePct("NO_SUCH_PHASE", 5) != 0 {
		t.Error("unknown phase must map to 0")
	}
	if phasePct("DONE", 0) != 100 {
		t.Error("DONE must map to 100")
	}
	// progress within a phase never spills past the phase's ceiling
	if got := phasePct("AI_RESOLVE", 1<<20); got > 70 {
		t.Errorf("AI_RESOLVE overflow: %d > 70", got)
	}
}
