// mrtop — the merge-medic live dashboard (bubbletea TUI).
//
// Entry point and program wiring; everything else lives in topical files:
// model/update/view (the Elm trio), screens (full-screen views), snapshot
// (state readers), styles, phases, config, util.
//
// Usage: mrtop <merge-medic root dir>
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type tickMsg time.Time

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: mrtop <merge-medic root>")
		os.Exit(2)
	}
	m := model{root: os.Args[1], width: 100, height: 40, expanded: map[string]bool{}, expandedMR: map[string]bool{}}
	if len(os.Args) > 2 && os.Args[2] == "--once" {
		if c, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && c > 40 {
			m.width = c
		}
		if l, err := strconv.Atoi(os.Getenv("LINES")); err == nil && l > 10 {
			m.height = l
		}
		m.frame = 100     // full banner name in snapshots
		m.typeK = 1 << 20 // no mid-typing line in snapshots
		// MRTOP_SCREEN renders a non-default screen (smoke tests, demo tapes)
		if sc, err := strconv.Atoi(os.Getenv("MRTOP_SCREEN")); err == nil {
			m.screen = sc
		}

		m.snap = readSnapshot(m.root, m.width)
		fmt.Println(m.View())
		return
	}
	// with several instances installed, boot into the fleet screen — pick
	// the project first, exactly like the old launcher but inside the TUI
	if len(readInstances()) > 1 {
		m.screen = 2
	}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func (m model) Init() tea.Cmd { return tick() }

func tick() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}
