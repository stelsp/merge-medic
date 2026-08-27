// The fixer phase ladder: expected order, progress mapping, terminal states.
package main

// phases maps each phase to how long it typically takes (seconds) — stale
// detection flags a fixer that sits in one phase for more than 4× this.
type phaseInfo struct{ avg int }

var phases = map[string]phaseInfo{
	"START":       {3},
	"WORKTREE":    {5},
	"MERGE":       {10},
	"MERGE_CLEAN": {2},
	"AI_RESOLVE":  {90},
	"PLAN":        {60},
	"VERIFY":      {150},
	"TESTS":       {60},
	"REGRESSION":  {180},
	"PUSH":        {5},
	"DONE":        {1},
	"FAIL":        {1},
	"ESCALATED":   {1},
	"PLANNED":     {1},
	"DEFERRED":    {1},
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
