// The fixer phase ladder: expected order, progress mapping, terminal states.
package main

type phaseInfo struct{ base, next, avg int }

var phases = map[string]phaseInfo{
	"START":       {3, 10, 3},
	"WORKTREE":    {10, 25, 5},
	"MERGE":       {25, 45, 10},
	"MERGE_CLEAN": {45, 70, 2},
	"AI_RESOLVE":  {45, 70, 90},
	"PLAN":        {45, 70, 60},
	"VERIFY":      {70, 80, 150},
	"TESTS":       {80, 88, 60},
	"REGRESSION":  {88, 95, 180},
	"PUSH":        {95, 99, 5},
	"DONE":        {100, 100, 1},
	"FAIL":        {100, 100, 1},
	"ESCALATED":   {100, 100, 1},
	"PLANNED":     {100, 100, 1},
	"DEFERRED":    {0, 0, 1},
}

func terminal(phase string) bool {
	switch phase {
	case "DONE", "FAIL", "ESCALATED", "PLANNED", "DEFERRED":
		return true
	}
	return false
}

// phaseSlot maps a phase to its position on the fixer's path.
func phaseSlot(ph string) int {
	switch ph {
	case "START":
		return 0
	case "WORKTREE":
		return 1
	case "MERGE":
		return 2
	case "MERGE_CLEAN", "AI_RESOLVE", "PLAN":
		return 3
	case "VERIFY":
		return 4
	case "TESTS":
		return 5
	case "REGRESSION":
		return 6
	case "PUSH":
		return 7
	}
	return 8
}

func phasePct(phase string, inPhase int) int {
	p, ok := phases[phase]
	if !ok {
		return 0
	}
	if p.base >= 100 {
		return 100
	}
	prog := inPhase * (p.next - p.base) / p.avg
	if prog > p.next-p.base {
		prog = p.next - p.base
	}
	return p.base + prog
}
