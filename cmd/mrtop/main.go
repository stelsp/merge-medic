// mrtop — the merge-medic live dashboard (bubbletea TUI).
//
// Reads the same state/progress-<iid>.log phase events the bash fallback
// uses, so the two are interchangeable: `mrwatch top` execs this binary when
// it is built, and falls back to pure bash otherwise.
//
// Usage: mrtop <merge-medic root dir>
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	bold   = lipgloss.NewStyle().Bold(true)
	dim    = lipgloss.NewStyle().Faint(true)
	green  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	red    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	yellow = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	selRow = lipgloss.NewStyle().Background(lipgloss.Color("236"))
)

var spinner = []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

type phaseInfo struct{ base, next, avg int }

var phases = map[string]phaseInfo{
	"START":       {3, 10, 3},
	"WORKTREE":    {10, 25, 5},
	"MERGE":       {25, 45, 10},
	"MERGE_CLEAN": {45, 75, 2},
	"AI_RESOLVE":  {45, 75, 90},
	"VERIFY":      {75, 92, 150},
	"PUSH":        {92, 99, 5},
	"DONE":        {100, 100, 1},
	"FAIL":        {100, 100, 1},
}

type fixer struct {
	iid, phase, detail string
	t0, ts             int64
	active             bool
}

type mrState struct{ iid, status string }

type snapshot struct {
	fixers            []fixer
	mrs               []mrState
	budget, budgetMax string
	daemon            bool
	ok, bad, clean, ai int
}

type tickMsg time.Time

type model struct {
	root     string
	snap     snapshot
	sel      int
	showLog  bool
	logName  string
	logLines []string
	frame    int
	width    int
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: mrtop <merge-medic root>")
		os.Exit(2)
	}
	m := model{root: os.Args[1], width: 100}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func (m model) Init() tea.Cmd { return tick() }

func tick() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
	case tickMsg:
		m.snap = readSnapshot(m.root)
		if m.sel >= len(m.snap.fixers) {
			m.sel = max(0, len(m.snap.fixers)-1)
		}
		if m.showLog {
			m.logName, m.logLines = readLog(m.root, m.selectedIID())
		}
		m.frame++
		return m, tick()
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "up", "k":
			if m.sel > 0 {
				m.sel--
			}
		case "down", "j":
			if m.sel < len(m.snap.fixers)-1 {
				m.sel++
			}
		case "enter", "l":
			m.showLog = !m.showLog
			if m.showLog {
				m.logName, m.logLines = readLog(m.root, m.selectedIID())
			}
		case "r":
			c := exec.Command("bash", filepath.Join(m.root, "watch.sh"))
			_ = c.Start()
		case "p":
			go togglePause(m.root)
		}
	}
	return m, nil
}

func (m model) selectedIID() string {
	if m.sel < len(m.snap.fixers) {
		return m.snap.fixers[m.sel].iid
	}
	return ""
}

func (m model) View() string {
	var b strings.Builder
	s := m.snap
	b.WriteString(bold.Render("merge-medic — live") + "   " + time.Now().Format("15:04:05") + "\n")
	d := red.Render("off")
	if s.daemon {
		d = green.Render("on")
	}
	b.WriteString(fmt.Sprintf("  daemon %s · AI budget %s/%s · today: %s / %s · %d clean, %d AI\n\n",
		d, s.budget, s.budgetMax,
		green.Render(fmt.Sprintf("%d fixed", s.ok)), red.Render(fmt.Sprintf("%d failed", s.bad)),
		s.clean, s.ai))

	if len(s.fixers) == 0 {
		b.WriteString(dim.Render("  no active or recent fixers — no conflicts") + "\n")
	}
	now := time.Now().Unix()
	for i, f := range s.fixers {
		mark := " "
		if f.active {
			mark = string(spinner[m.frame%len(spinner)])
		}
		inPhase := int(now - f.ts)
		if !f.active {
			inPhase = 0
		}
		pct := phasePct(f.phase, inPhase)
		el := f.ts - f.t0
		if f.active {
			el = now - f.t0
		}
		style := lipgloss.NewStyle()
		switch f.phase {
		case "DONE":
			style = green
		case "FAIL":
			style = red
		case "AI_RESOLVE":
			style = yellow
		}
		row := fmt.Sprintf("  %s %s [%s] %3d%%  %s %3dm%02ds  %s",
			mark, bold.Render(fmt.Sprintf("!%-4s", f.iid)), bar(pct, 22), pct,
			style.Render(fmt.Sprintf("%-11s", f.phase)), el/60, el%60,
			dim.Render(trunc(f.detail, 56)))
		if i == m.sel {
			row = selRow.Render(row)
		}
		b.WriteString(row + "\n")
	}

	b.WriteString("\n  " + bold.Render("MRs (last tick):") + " ")
	if len(s.mrs) == 0 {
		b.WriteString(dim.Render("none"))
	}
	for _, mr := range s.mrs {
		switch mr.status {
		case "conflict":
			b.WriteString(red.Render("!"+mr.iid+"✗") + " ")
		case "mergeable":
			b.WriteString(green.Render("!"+mr.iid+"✓") + " ")
		default:
			b.WriteString(dim.Render("!"+mr.iid+"?") + " ")
		}
	}
	b.WriteString("\n")

	if m.showLog {
		b.WriteString("\n  " + bold.Render("log") + " " + dim.Render(m.logName) + "\n")
		for _, ln := range m.logLines {
			b.WriteString("  " + dim.Render("│") + " " + trunc(ln, m.width-6) + "\n")
		}
	}

	b.WriteString("\n" + dim.Render("  ↑↓ select · enter/l log · r run tick · p pause/resume · q quit"))
	return b.String()
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

func bar(pct, width int) string {
	filled := pct * width / 100
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

func trunc(s string, n int) string {
	r := []rune(s)
	if n > 0 && len(r) > n {
		return string(r[:n])
	}
	return s
}

func readSnapshot(root string) snapshot {
	var s snapshot
	now := time.Now()
	day0 := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()

	s.budget = "0"
	s.budgetMax = readConfigVal(root, "DAILY_AGENT_RUNS", "6")
	if b, err := os.ReadFile(filepath.Join(root, "state", "budget-"+now.Format("2006-01-02"))); err == nil {
		s.budget = strings.TrimSpace(string(b))
	}
	s.daemon = daemonLoaded()

	progress, _ := filepath.Glob(filepath.Join(root, "state", "progress-*.log"))
	sort.Strings(progress)
	for _, p := range progress {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		lines := nonEmpty(strings.Split(string(data), "\n"))
		if len(lines) == 0 {
			continue
		}
		iid := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(p), "progress-"), ".log")
		var f fixer
		f.iid = iid
		for _, ln := range lines {
			parts := strings.SplitN(ln, "|", 3)
			if len(parts) < 2 {
				continue
			}
			ts, _ := strconv.ParseInt(parts[0], 10, 64)
			if ts >= day0 {
				switch parts[1] {
				case "DONE":
					s.ok++
				case "FAIL":
					s.bad++
				case "MERGE_CLEAN":
					s.clean++
				case "AI_RESOLVE":
					s.ai++
				}
			}
		}
		first := strings.SplitN(lines[0], "|", 3)
		last := strings.SplitN(lines[len(lines)-1], "|", 3)
		f.t0, _ = strconv.ParseInt(first[0], 10, 64)
		f.ts, _ = strconv.ParseInt(last[0], 10, 64)
		f.phase = last[1]
		if len(last) > 2 {
			f.detail = last[2]
		}
		f.active = f.phase != "DONE" && f.phase != "FAIL"
		if !f.active && now.Unix()-f.ts > 7200 {
			continue // hide finished fixers older than 2h
		}
		s.fixers = append(s.fixers, f)
	}

	mrFiles, _ := filepath.Glob(filepath.Join(root, "state", "mr-*"))
	sort.Strings(mrFiles)
	for _, f := range mrFiles {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		st := strings.Fields(string(data))
		status := "unknown"
		if len(st) > 0 {
			status = st[0]
		}
		s.mrs = append(s.mrs, mrState{iid: strings.TrimPrefix(filepath.Base(f), "mr-"), status: status})
	}
	return s
}

func readLog(root, iid string) (string, []string) {
	if iid == "" {
		return "", nil
	}
	candidates, _ := filepath.Glob(filepath.Join(root, "logs", "ai-"+iid+"-*.log"))
	candidates = append(candidates, filepath.Join(root, "logs", "fixer-"+iid+".log"))
	var newest string
	var newestMod time.Time
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && st.ModTime().After(newestMod) {
			newest, newestMod = c, st.ModTime()
		}
	}
	if newest == "" {
		return "", nil
	}
	data, err := os.ReadFile(newest)
	if err != nil {
		return filepath.Base(newest), nil
	}
	lines := nonEmpty(strings.Split(string(data), "\n"))
	if len(lines) > 12 {
		lines = lines[len(lines)-12:]
	}
	return filepath.Base(newest), lines
}

// readConfigVal extracts a KEY=value from config.env without sourcing it.
func readConfigVal(root, key, def string) string {
	data, err := os.ReadFile(filepath.Join(root, "config.env"))
	if err != nil {
		return def
	}
	for _, ln := range strings.Split(string(data), "\n") {
		ln = strings.TrimSpace(ln)
		if v, ok := strings.CutPrefix(ln, key+"="); ok {
			return strings.Trim(v, `"'`)
		}
	}
	return def
}

func daemonLoaded() bool {
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("launchctl", "list").Output()
		return err == nil && strings.Contains(string(out), "com.merge-medic.watch")
	}
	return exec.Command("systemctl", "--user", "is-active", "--quiet", "merge-medic.timer").Run() == nil
}

func togglePause(root string) {
	mrwatch := filepath.Join(root, "bin", "mrwatch")
	if daemonLoaded() {
		_ = exec.Command("bash", mrwatch, "pause").Run()
	} else {
		_ = exec.Command("bash", mrwatch, "resume").Run()
	}
}

func nonEmpty(in []string) []string {
	out := in[:0]
	for _, s := range in {
		if strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
