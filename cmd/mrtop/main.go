// mrtop — the merge-medic live dashboard (bubbletea TUI).
//
// v3: Claude-GUI-style layout — bordered ACTIVE / HISTORY sections, finished
// runs stay visible as full "done loaders" (backed by the durable
// state/history.log ledger + per-run phase archives in state/runs/), and
// every run expands into its phase timeline with enter.
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
	bold    = lipgloss.NewStyle().Bold(true)
	dim     = lipgloss.NewStyle().Faint(true)
	green   = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	red     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	yellow  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	blue    = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	selRow  = lipgloss.NewStyle().Background(lipgloss.Color("236"))
	section = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("238")).
		Padding(0, 1)
	sectionTitle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
)

var spinner = []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

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
}

func terminal(phase string) bool {
	switch phase {
	case "DONE", "FAIL", "ESCALATED", "PLANNED":
		return true
	}
	return false
}

// item is one row: a live fixer or a finished run from the ledger.
type item struct {
	iid, phase, detail string
	t0, ts             int64
	active             bool
	mode               string // clean | ai | none (history rows)
	runFile            string // per-run phase archive, "" for live rows
}

func (it item) key() string { return it.iid + "@" + strconv.FormatInt(it.t0, 10) }

type mrState struct{ iid, status string }

type snapshot struct {
	activeRows, histRows []item
	mrs                  []mrState
	budget, budgetMax    string
	daemon               bool
	ok, bad, esc         int
	tok, tbad, tesc      int
	tclean, tai          int
}

type tickMsg time.Time

type model struct {
	root     string
	snap     snapshot
	sel      int
	expanded map[string]bool
	showLog  bool
	logName  string
	logLines []string
	frame    int
	width    int
	height   int
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: mrtop <merge-medic root>")
		os.Exit(2)
	}
	m := model{root: os.Args[1], width: 100, height: 40, expanded: map[string]bool{}}
	if len(os.Args) > 2 && os.Args[2] == "--once" {
		m.snap = readSnapshot(m.root)
		fmt.Println(m.View())
		return
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

func (m model) rows() []item {
	return append(append([]item{}, m.snap.activeRows...), m.snap.histRows...)
}

func (m model) selected() (item, bool) {
	rows := m.rows()
	if m.sel >= 0 && m.sel < len(rows) {
		return rows[m.sel], true
	}
	return item{}, false
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		m.snap = readSnapshot(m.root)
		if n := len(m.rows()); m.sel >= n {
			m.sel = max(0, n-1)
		}
		if m.showLog {
			if it, ok := m.selected(); ok {
				m.logName, m.logLines = readLog(m.root, it.iid)
			}
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
			if m.sel < len(m.rows())-1 {
				m.sel++
			}
		case "enter", "e":
			if it, ok := m.selected(); ok {
				m.expanded[it.key()] = !m.expanded[it.key()]
			}
		case "l":
			m.showLog = !m.showLog
			if m.showLog {
				if it, ok := m.selected(); ok {
					m.logName, m.logLines = readLog(m.root, it.iid)
				}
			}
		case "a":
			if it, ok := m.selected(); ok && it.phase == "PLANNED" {
				_ = os.Remove(filepath.Join(m.root, "state", "tried-"+it.iid))
				_ = os.Remove(filepath.Join(m.root, "state", "dry-"+it.iid))
				if f, err := os.Create(filepath.Join(m.root, "state", "approve-"+it.iid)); err == nil {
					_ = f.Close()
				}
				c := exec.Command("bash", filepath.Join(m.root, "watch.sh"))
				_ = c.Start()
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
	}
	return " "
}

func (m model) renderRow(it item, idx int, now int64) string {
	mark := outcomeMark(it.phase)
	if it.active && !terminal(it.phase) {
		mark = blue.Render(string(spinner[m.frame%len(spinner)]))
	}
	inPhase := int(now - it.ts)
	if terminal(it.phase) {
		inPhase = 0
	}
	pct := phasePct(it.phase, inPhase)
	el := it.ts - it.t0
	if it.active && !terminal(it.phase) {
		el = now - it.t0
	}
	if el < 0 {
		el = 0
	}
	style := lipgloss.NewStyle()
	switch it.phase {
	case "DONE":
		style = green
	case "FAIL":
		style = red
	case "AI_RESOLVE", "PLAN", "PLANNED", "ESCALATED":
		style = yellow
	}
	when := time.Unix(it.t0, 0).Format("15:04")
	tag := it.mode
	if tag == "" || tag == "none" {
		tag = "  "
	}
	row := fmt.Sprintf(" %s %s %s [%s] %3d%%  %s %3dm%02ds %-5s %s",
		mark, bold.Render(fmt.Sprintf("!%-4s", it.iid)), dim.Render(when),
		bar(pct, 20), pct,
		style.Render(fmt.Sprintf("%-10s", it.phase)), el/60, el%60,
		dim.Render(tag), dim.Render(trunc(it.detail, m.width-62)))
	if idx == m.sel {
		row = selRow.Render(row)
	}
	if m.expanded[it.key()] {
		row += "\n" + m.renderTimeline(it)
	}
	return row
}

// renderHistRow is a compact finished-run line: no progress bar (a static
// 100% slab is just noise), outcome mark + phase + duration + mode + detail.
func (m model) renderHistRow(it item, idx int) string {
	style := dim
	switch it.phase {
	case "DONE":
		style = green
	case "FAIL":
		style = red
	case "ESCALATED", "PLANNED":
		style = yellow
	}
	dur := "    —"
	if it.ts > it.t0 {
		d := it.ts - it.t0
		dur = fmt.Sprintf("%2dm%02ds", d/60, d%60)
	}
	tag := it.mode
	if tag == "" || tag == "none" {
		tag = "  "
	}
	detail := it.detail
	if detail == "" {
		detail = "(no run archive)"
	}
	row := fmt.Sprintf(" %s %s %s  %s %s  %-5s %s",
		outcomeMark(it.phase), bold.Render(fmt.Sprintf("!%-4s", it.iid)),
		dim.Render(time.Unix(it.t0, 0).Format("02.01 15:04")),
		style.Render(fmt.Sprintf("%-10s", it.phase)), dur,
		dim.Render(tag), dim.Render(trunc(detail, m.width-46)))
	if idx == m.sel {
		row = selRow.Render(row)
	}
	if m.expanded[it.key()] {
		row += "\n" + m.renderTimeline(it)
	}
	return row
}

// renderTimeline shows the per-phase history of one run.
func (m model) renderTimeline(it item) string {
	src := it.runFile
	if src == "" {
		src = filepath.Join(m.root, "state", "progress-"+it.iid+".log")
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return dim.Render("      (no phase archive for this run)")
	}
	lines := nonEmpty(strings.Split(string(data), "\n"))
	var b strings.Builder
	var prev int64
	for i, ln := range lines {
		parts := strings.SplitN(ln, "|", 3)
		if len(parts) < 2 {
			continue
		}
		ts, _ := strconv.ParseInt(parts[0], 10, 64)
		durStr := ""
		if i > 0 {
			durStr = fmt.Sprintf("+%ds", ts-prev)
		}
		prev = ts
		detail := ""
		if len(parts) > 2 {
			detail = parts[2]
		}
		b.WriteString(fmt.Sprintf("      %s %s %-11s %s\n",
			dim.Render(time.Unix(ts, 0).Format("15:04:05")),
			dim.Render(fmt.Sprintf("%6s", durStr)),
			parts[1], dim.Render(trunc(detail, m.width-40))))
	}
	return strings.TrimRight(b.String(), "\n")
}

func (m model) View() string {
	var b strings.Builder
	s := m.snap
	now := time.Now().Unix()

	d := red.Render("off")
	if s.daemon {
		d = green.Render("on")
	}
	b.WriteString(bold.Render("merge-medic") + dim.Render(" — live  ") + time.Now().Format("15:04:05") + "\n")
	b.WriteString(fmt.Sprintf("daemon %s · AI budget %s/%s · today %s %s %s · total %s %s %s (%d clean, %d AI)\n",
		d, s.budget, s.budgetMax,
		green.Render(fmt.Sprintf("%d✓", s.ok)), red.Render(fmt.Sprintf("%d✗", s.bad)), yellow.Render(fmt.Sprintf("%d⚑", s.esc)),
		green.Render(fmt.Sprintf("%d✓", s.tok)), red.Render(fmt.Sprintf("%d✗", s.tbad)), yellow.Render(fmt.Sprintf("%d⚑", s.tesc)),
		s.tclean, s.tai))

	idx := 0
	var act []string
	if len(s.activeRows) == 0 {
		act = append(act, dim.Render(" no active fixers — no new conflicts"))
	}
	for _, it := range s.activeRows {
		act = append(act, m.renderRow(it, idx, now))
		idx++
	}
	b.WriteString(section.Width(m.width - 2).Render(
		sectionTitle.Render("ACTIVE") + "\n" + strings.Join(act, "\n")) + "\n")

	var hist []string
	if len(s.histRows) == 0 {
		hist = append(hist, dim.Render(" no runs yet"))
	}
	for _, it := range s.histRows {
		hist = append(hist, m.renderHistRow(it, idx))
		idx++
	}
	b.WriteString(section.Width(m.width - 2).Render(
		sectionTitle.Render("HISTORY") + "\n" + strings.Join(hist, "\n")) + "\n")

	strip := " "
	for _, mr := range s.mrs {
		switch mr.status {
		case "conflict":
			strip += red.Render("!"+mr.iid+"✗") + " "
		case "mergeable":
			strip += green.Render("!"+mr.iid+"✓") + " "
		default:
			strip += dim.Render("!"+mr.iid+"?") + " "
		}
	}
	b.WriteString(bold.Render("MRs") + strip + "\n")

	if m.showLog {
		b.WriteString(bold.Render("log ") + dim.Render(m.logName) + "\n")
		for _, ln := range m.logLines {
			b.WriteString(dim.Render("│ ") + trunc(ln, m.width-4) + "\n")
		}
	}

	b.WriteString(dim.Render("↑↓ select · enter timeline · l log · a approve · r tick · p pause · q quit"))
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

	// live fixers (non-terminal) and PLANNED waiters from progress files
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
		first := strings.SplitN(lines[0], "|", 3)
		last := strings.SplitN(lines[len(lines)-1], "|", 3)
		var it item
		it.iid = iid
		it.t0, _ = strconv.ParseInt(first[0], 10, 64)
		it.ts, _ = strconv.ParseInt(last[0], 10, 64)
		it.phase = last[1]
		if len(last) > 2 {
			it.detail = last[2]
		}
		it.active = true
		// terminal runs land in HISTORY via the ledger; PLANNED still needs
		// action, so it stays in ACTIVE as a waiter
		if terminal(it.phase) && it.phase != "PLANNED" {
			continue
		}
		s.activeRows = append(s.activeRows, it)
	}

	// full run history from the durable ledger, newest first
	if data, err := os.ReadFile(filepath.Join(root, "state", "history.log")); err == nil {
		lines := nonEmpty(strings.Split(string(data), "\n"))
		for i := len(lines) - 1; i >= 0 && len(s.histRows) < 30; i-- {
			parts := strings.Split(lines[i], "|")
			if len(parts) < 3 {
				continue
			}
			ts, _ := strconv.ParseInt(parts[0], 10, 64)
			it := item{iid: parts[1], phase: parts[2], ts: ts, t0: ts}
			if len(parts) > 3 {
				it.mode = parts[3]
			}
			rf := filepath.Join(root, "state", "runs", it.iid+"-"+parts[0]+".log")
			if st, err := os.Stat(rf); err == nil && st.Size() > 0 {
				it.runFile = rf
				if data, err := os.ReadFile(rf); err == nil {
					ls := nonEmpty(strings.Split(string(data), "\n"))
					if len(ls) > 0 {
						f := strings.SplitN(ls[0], "|", 3)
						it.t0, _ = strconv.ParseInt(f[0], 10, 64)
						l := strings.SplitN(ls[len(ls)-1], "|", 3)
						if len(l) > 2 {
							it.detail = l[2]
						}
					}
				}
			}
			// PLANNED entries whose progress file is still PLANNED are shown
			// in ACTIVE as waiters — skip the duplicate here
			if it.phase == "PLANNED" {
				continue
			}
			s.histRows = append(s.histRows, it)

			switch it.phase {
			case "DONE":
				s.tok++
				if it.mode == "clean" {
					s.tclean++
				}
				if it.mode == "ai" {
					s.tai++
				}
				if ts >= day0 {
					s.ok++
				}
			case "FAIL":
				s.tbad++
				if ts >= day0 {
					s.bad++
				}
			case "ESCALATED":
				s.tesc++
				if ts >= day0 {
					s.esc++
				}
			}
		}
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
