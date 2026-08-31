// Night-shift ops console: sharp single borders, one amber accent for
// identity/keys/titles, colors otherwise reserved for state (green/red/
// yellow), terminal-transparent background. All drawing primitives.
package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var (
	bold    = lipgloss.NewStyle().Bold(true)
	dim     = lipgloss.NewStyle().Faint(true)
	green   = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	red     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	yellow  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	blue    = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	amber   = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	amberB  = lipgloss.NewStyle().Foreground(lipgloss.Color("214")).Bold(true)
	borderC = lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	// plain: the terminal's own foreground — used for details of rows that
	// already carry a state color, so they stay legible on washed-out themes
	lipglossPlain = lipgloss.NewStyle()
	// body of a panel: sharp border, no top edge — the top line is drawn by
	// titledBox with the title embedded in the border itself
	section = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, true, true, true).
		BorderForeground(lipgloss.Color("238")).
		Padding(0, 1)
)

// titledBox renders a panel of total width w with the title (and an optional
// dim meta like a count) embedded in the top border: ┌─ ACTIVE ─ 12 ──────┐
func titledBox(w int, title, meta, body string, height int, focused bool) string {
	st := section.Width(w - 2)
	bs := borderC
	if focused {
		st = st.BorderForeground(lipgloss.Color("214"))
		bs = amber
	}
	if height > 0 {
		st = st.Height(height)
	}
	inner := st.Render(body)
	label := amberB.Render(" " + title + " ")
	if meta != "" {
		label += dim.Render(meta + " ")
	}
	used := 2 + lipgloss.Width(label) // "┌─" + label
	rest := w - used - 1
	if rest < 0 {
		rest = 0
	}
	top := bs.Render("┌─") + label + bs.Render(strings.Repeat("─", rest)+"┐")
	return top + "\n" + inner
}

var spinner = []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

// segBar renders the 8-segment phase path: done green, current pulsing
// amber, future dim. Terminal phases paint the whole bar by outcome.
func segBar(ph string, frame int) string {
	switch ph {
	case "DONE", "PLANNED":
		return green.Render(strings.Repeat("█", 8))
	case "FAIL", "ESCALATED":
		return red.Render(strings.Repeat("█", 8))
	case "DEFERRED":
		return dim.Render(strings.Repeat("░", 8))
	}
	slot := phaseSlot(ph)
	cur := "█"
	if frame%2 == 1 {
		cur = "▓"
	}
	var b strings.Builder
	for i := 0; i < 8; i++ {
		switch {
		case i < slot:
			b.WriteString(green.Render("█"))
		case i == slot:
			b.WriteString(amber.Render(cur))
		default:
			b.WriteString(dim.Render("░"))
		}
	}
	return b.String()
}

// selMark marks the cursor row with an amber bar at the line start — no
// background fill, the row keeps its own colors.
func selMark(row string, _ int) string {
	return amberB.Render("▎") + strings.TrimPrefix(row, " ")
}

func outcomeMark(phase string) string {
	switch phase {
	case "DONE":
		return green.Render("✓")
	case "FAIL":
		return red.Render("✗")
	case "ESCALATED":
		return yellow.Render("⚑")
	case "PLANNED":
		return yellow.Render("▣")
	case "DEFERRED":
		return dim.Render("…")
	}
	return " "
}

var orbit = []rune("◐◓◑◒")

// known CI states (gitlab head_pipeline.status + our github rollup values)
var ciKnown = map[string]bool{
	"success": true, "failed": true, "running": true, "pending": true,
	"canceled": true, "skipped": true, "manual": true, "created": true,
	"none": true, "preparing": true, "waiting_for_resource": true, "scheduled": true,
}

// titleStyled colors the conventional-commit type prefix of an MR title:
// feat green, fix yellow, docs/chore/etc dim — the rest of the title neutral.
func titleStyled(title string, base lipgloss.Style, budget int) string {
	i := strings.Index(title, ":")
	if i > 0 && i <= 12 {
		typ := title[:i]
		root := typ
		if p := strings.IndexAny(typ, "(!"); p > 0 {
			root = typ[:p]
		}
		var st lipgloss.Style
		switch root {
		case "feat":
			st = green
		case "fix", "hotfix":
			st = yellow
		case "docs", "chore", "refactor", "test", "ci", "build", "style", "perf":
			st = dim
		default:
			return base.Render(trunc(title, budget))
		}
		rest := title[i:]
		return st.Render(typ) + base.Render(trunc(rest, max(0, budget-len([]rune(typ)))))
	}
	return base.Render(trunc(title, budget))
}

// boolSwitch renders a boolean setting as a checkbox plus its state, so the
// row stays short and unambiguous (the STATUS panel has no room for prose).
func boolSwitch(on bool) string {
	if on {
		return dim.Render("[") + green.Render("x") + dim.Render("] ") + green.Render("on")
	}
	return dim.Render("[ ] ") + yellow.Render("off")
}

// ciDot renders one colored pipeline-status dot for an open MR.
func ciDot(ci string) string {
	switch ci {
	case "success":
		return green.Render("●")
	case "failed", "canceled":
		return red.Render("●")
	case "", "none", "skipped", "manual":
		return dim.Render("·")
	}
	return yellow.Render("●")
}

// ciBar renders a pipeline as a fixed-width strip of job cells: the run
// order is preserved, so the strip fills left-to-right as jobs finish. Long
// pipelines are compressed onto the strip (one cell per bucket, worst state
// wins) — a red cell must never be hidden by a green neighbour.
func ciBar(c ciStatus, frame int) string {
	const cells = 6
	if len(c.jobs) == 0 {
		return strings.Repeat(" ", cells)
	}
	// severity order for compressed cells; "" is the empty bucket and must
	// rank below every real state, skipped included
	rank := map[string]int{"": 0, "skip": 1, "pass": 2, "wait": 3, "run": 4, "fail": 5}
	worst := func(a, b string) string {
		if rank[b] > rank[a] {
			return b
		}
		return a
	}
	// map cells -> jobs (not jobs -> cells): a short pipeline stretches over
	// the strip instead of leaving holes, a long one folds into it
	buckets := make([]string, cells)
	for k := range buckets {
		lo := k * len(c.jobs) / cells
		hi := (k + 1) * len(c.jobs) / cells
		if hi <= lo {
			hi = lo + 1 // fewer jobs than cells: this cell mirrors job lo
		}
		for i := lo; i < hi && i < len(c.jobs); i++ {
			buckets[k] = worst(buckets[k], c.jobs[i].state)
		}
	}
	var out strings.Builder
	for _, st := range buckets {
		switch st {
		case "pass":
			out.WriteString(green.Render("▰"))
		case "fail":
			out.WriteString(red.Render("▰"))
		case "run":
			// the live cell pulses so a stuck pipeline is visibly not stuck
			if frame%2 == 0 {
				out.WriteString(amberB.Render("▰"))
			} else {
				out.WriteString(amber.Render("▱"))
			}
		case "skip":
			// manual/skipped is not "unfinished" — a filled but muted cell,
			// so a green pipeline with manual jobs still reads as green
			out.WriteString(dim.Render("▰"))
		default:
			out.WriteString(dim.Render("▱"))
		}
	}
	return out.String()
}

// ciCount is the "4/7" counter next to the strip: finished jobs of total.
func ciCount(c ciStatus) string {
	if len(c.jobs) == 0 {
		return "     "
	}
	txt := fmt.Sprintf("%d/%d", c.pass+c.fail, len(c.jobs))
	st := dim
	switch {
	case c.fail > 0:
		st = red
	case c.done():
		st = green
	case c.run > 0:
		st = amber
	}
	return st.Render(fmt.Sprintf("%-5s", txt))
}

var sparkChars = []rune("▁▂▃▄▅▆▇█")

func sparkline(vals []int) string {
	maxV := 1
	for _, v := range vals {
		if v > maxV {
			maxV = v
		}
	}
	var b strings.Builder
	for _, v := range vals {
		idx := v * (len(sparkChars) - 1) / maxV
		b.WriteRune(sparkChars[idx])
	}
	return b.String()
}

func gauge(cur, maxV, width int) string {
	if maxV <= 0 {
		maxV = 1
	}
	filled := cur * width / maxV
	if filled > width {
		filled = width
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}
