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
	"github.com/muesli/reflow/truncate"
)

// Night-shift ops console: sharp single borders, one amber accent for
// identity/keys/titles, colors otherwise reserved for state (green/red/
// yellow), terminal-transparent background.
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
	selRow  = lipgloss.NewStyle().Background(lipgloss.Color("236"))
	// body of a panel: sharp border, no top edge — the top line is drawn by
	// titledBox with the title embedded in the border itself
	section = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, true, true, true).
		BorderForeground(lipgloss.Color("238")).
		Padding(0, 1)
	sectionTitle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
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
		label += dim.Render(meta+" ")
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

// item is one row: a live fixer or a finished run from the ledger.
type item struct {
	iid, phase, detail string
	t0, ts             int64
	active             bool
	mode               string // clean | ai | none (history rows)
	runFile            string // per-run phase archive, "" for live rows
}

func (it item) key() string { return it.iid + "@" + strconv.FormatInt(it.t0, 10) }

type mrState struct{ iid, status, src, tgt, ci, author, title string
	updated int64 }

type radarPair struct{ a, b, srcA, srcB string }

type snapshot struct {
	activeRows, histRows []item
	mrs                  []mrState
	budget, budgetMax    string
	daemon               bool
	ok, bad, esc         int
	tok, tbad, tesc      int
	tclean, tai          int
	radarPairs           []radarPair // brewing MR-vs-MR conflict pairs
	feed                 []string // pre-rendered live feed lines, oldest first
	daily                []int    // DONE per day, last 14 days, oldest first
	spendToday, spend    float64  // USD, from the CLI's own accounting
	modelLine            string   // per-model tokens/cost breakdown
	pushMode             string   // direct | mr (from config.env)
	lastTick             int64    // mtime of watch.log (0 = unknown)
	lastErr              string   // recent ERROR line from watch.log, "" if none
	lastErrTs            int64
	hotspots             []hotspot   // most-conflicted files, all time
	spendDaily           []float64   // USD per day, last 14 days, oldest first
	topRuns              []costRun   // most expensive AI runs
}

type hotspot struct {
	file  string
	count int
}

type costRun struct {
	iid, model string
	cost       float64
	ts         int64
}

type tickMsg time.Time

type model struct {
	root       string
	snap       snapshot
	sel        int // cursor within the focused panel
	focus      int // 0 = STATUS, 1 = ACTIVE, 2 = HISTORY, 3 = LIVE
	selH       int // HISTORY cursor (kept when switching focus)
	liveOff    int // lines scrolled up from the tail of LIVE (0 = follow)
	expanded   map[string]bool
	expandedMR map[string]bool
	showLog  bool
	logName  string
	logLines []string
	frame    int
	width    int
	height   int
	showHelp bool
	screen   int // 0 = main, 1 = insights, 2 = fleet
	selF     int // fleet cursor
	lastFeed string // newest feed line, for the typewriter effect
	typeK    int    // typed width of the newest feed line
}

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
		m.frame = 100  // full banner name in snapshots
		m.typeK = 1 << 20 // no mid-typing line in snapshots

		m.snap = readSnapshot(m.root, m.width)
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

// rowRef is one selectable dashboard row: a live fixer, an open MR, or a
// finished run — in exactly the order the ACTIVE/HISTORY boxes render them.
type rowRef struct {
	kind string // fixer | mr | hist
	it   item
	mr   mrState
}

func (m model) activeRefs() []rowRef {
	var out []rowRef
	for _, it := range m.snap.activeRows {
		out = append(out, rowRef{kind: "fixer", it: it})
	}
	for _, mr := range m.snap.mrs {
		out = append(out, rowRef{kind: "mr", mr: mr})
	}
	return out
}

func (m model) histRefs() []rowRef {
	var out []rowRef
	for _, it := range m.snap.histRows {
		out = append(out, rowRef{kind: "hist", it: it})
	}
	return out
}

// focusedRows returns the row list of the panel that owns the cursor.
func (m model) focusedRows() []rowRef {
	if m.focus == 2 {
		return m.histRefs()
	}
	return m.activeRefs()
}

func (m model) selected() (rowRef, bool) {
	rows := m.focusedRows()
	sel := m.sel
	if m.focus == 2 {
		sel = m.selH
	}
	if (m.focus == 1 || m.focus == 2) && sel >= 0 && sel < len(rows) {
		return rows[sel], true
	}
	return rowRef{}, false
}

func (r rowRef) iid() string {
	if r.kind == "mr" {
		return r.mr.iid
	}
	return r.it.iid
}

// webURL builds the MR/PR web address for this row from config.env values.
func webURL(root, iid string) string {
	pp := readConfigVal(root, "PROJECT_PATH", "")
	if pp == "" {
		return ""
	}
	if readConfigVal(root, "PROVIDER", "gitlab") == "github" {
		return "https://github.com/" + pp + "/pull/" + iid
	}
	host := readConfigVal(root, "GITLAB_HOST", "gitlab.com")
	return "https://" + host + "/" + pp + "/-/merge_requests/" + iid
}

func openInBrowser(url string) {
	if url == "" {
		return
	}
	cmd := "xdg-open"
	if runtime.GOOS == "darwin" {
		cmd = "open"
	}
	_ = exec.Command(cmd, url).Start()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		m.snap = readSnapshot(m.root, m.width)
		if n := len(m.activeRefs()); m.sel >= n {
			m.sel = max(0, n-1)
		}
		if n := len(m.histRefs()); m.selH >= n {
			m.selH = max(0, n-1)
		}
		if m.showLog {
			if r, ok := m.selected(); ok {
				m.logName, m.logLines = readLog(m.root, r.iid())
			}
		}
		if n := len(m.snap.feed); n > 0 {
			if m.snap.feed[n-1] != m.lastFeed {
				m.lastFeed = m.snap.feed[n-1]
				m.typeK = 0 // a fresh line starts typing itself
			} else {
				m.typeK += 8
			}
		}
		m.frame++
		return m, tick()
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.showHelp = !m.showHelp
		case "1":
			m.screen = 0
		case "2":
			m.screen = 1
		case "3":
			m.screen = 2
		case "esc":
			m.showHelp = false
			m.showLog = false
			m.liveOff = 0
			m.expanded = map[string]bool{}
			m.expandedMR = map[string]bool{}
		case "tab":
			m.focus = (m.focus + 1) % 4
		case "up", "k":
			if m.screen == 2 {
				if m.selF > 0 {
					m.selF--
				}
				break
			}
			switch m.focus {
			case 1:
				if m.sel > 0 {
					m.sel--
				}
			case 2:
				if m.selH > 0 {
					m.selH--
				}
			case 3:
				m.liveOff += 3
			}
		case "down", "j":
			if m.screen == 2 {
				if m.selF < len(readInstances())-1 {
					m.selF++
				}
				break
			}
			switch m.focus {
			case 1:
				if m.sel < len(m.activeRefs())-1 {
					m.sel++
				}
			case 2:
				if m.selH < len(m.histRefs())-1 {
					m.selH++
				}
			case 3:
				m.liveOff = max(0, m.liveOff-3)
			}
		case "enter", "e":
			if m.screen == 2 {
				insts := readInstances()
				if m.selF >= 0 && m.selF < len(insts) {
					m.root = insts[m.selF]
					m.snap = readSnapshot(m.root, m.width)
					m.screen = 0
					m.sel, m.selH, m.liveOff = 0, 0, 0
				}
				break
			}
			if r, ok := m.selected(); ok {
				if r.kind == "mr" {
					m.expandedMR[r.mr.iid] = !m.expandedMR[r.mr.iid]
				} else {
					m.expanded[r.it.key()] = !m.expanded[r.it.key()]
				}
			}
		case "o":
			if r, ok := m.selected(); ok {
				openInBrowser(webURL(m.root, r.iid()))
			}
		case "l":
			m.showLog = !m.showLog
			if m.showLog {
				if r, ok := m.selected(); ok {
					m.logName, m.logLines = readLog(m.root, r.iid())
				}
			}
		case "a":
			if r, ok := m.selected(); ok && r.kind != "mr" && r.it.phase == "PLANNED" {
				it := r.it
				_ = os.Remove(filepath.Join(m.root, "state", "tried-"+it.iid))
				_ = os.Remove(filepath.Join(m.root, "state", "dry-"+it.iid))
				if f, err := os.Create(filepath.Join(m.root, "state", "approve-"+it.iid)); err == nil {
					_ = f.Close()
				}
				c := exec.Command("bash", filepath.Join(m.root, "watch.sh"))
				_ = c.Start()
			}
		case "+", "=":
			if m.focus != 0 {
				break
			}
			cur, _ := strconv.Atoi(m.snap.budgetMax)
			cur++
			setConfigVal(m.root, "DAILY_AGENT_RUNS", strconv.Itoa(cur))
			m.snap.budgetMax = strconv.Itoa(cur)
		case "-":
			if m.focus != 0 {
				break
			}
			cur, _ := strconv.Atoi(m.snap.budgetMax)
			cur--
			if cur < 0 {
				cur = 0 // 0 = unlimited
			}
			setConfigVal(m.root, "DAILY_AGENT_RUNS", strconv.Itoa(cur))
			m.snap.budgetMax = strconv.Itoa(cur)
		case "m":
			if m.focus != 0 {
				break
			}
			mode := "mr"
			if m.snap.pushMode == "mr" {
				mode = "direct"
			}
			setConfigVal(m.root, "PUSH_MODE", "\""+mode+"\"")
			m.snap.pushMode = mode
		case "r":
			c := exec.Command("bash", filepath.Join(m.root, "watch.sh"))
			_ = c.Start()
		case "p":
			go togglePause(m.root)
		}
	}
	return m, nil
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

func (m model) renderRow(it item, idx int, now int64, aw int) string {
	mark := outcomeMark(it.phase)
	stale := false
	if it.active && !terminal(it.phase) {
		mark = amber.Render(string(spinner[m.frame%len(spinner)]))
		if p, ok := phases[it.phase]; ok && now-it.ts > int64(4*max(p.avg, 30)) {
			stale = true
			mark = red.Render("⏱")
		}
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
	case "DEFERRED":
		style = dim
	}
	when := time.Unix(it.t0, 0).Format("15:04")
	tag := it.mode
	if tag == "" || tag == "none" {
		tag = "  "
	}
	_ = pct
	detail := it.detail
	if stale {
		detail = "stalled? no phase progress for " + fmtAge(now-it.ts) + " — check the log (l)"
	}
	row := fmt.Sprintf(" %s %s %s %s  %s %3dm%02ds %-5s %s",
		mark, bold.Render(fmt.Sprintf("!%-4s", it.iid)), dim.Render(when),
		segBar(it.phase, m.frame),
		style.Render(fmt.Sprintf("%-10s", it.phase)), el/60, el%60,
		dim.Render(tag), dim.Render(trunc(detail, aw-48)))
	if idx == m.sel && m.focus == 1 {
		row = selRow.Render(row)
	}
	if m.expanded[it.key()] {
		row += "\n" + m.renderTimeline(it)
	}
	return row
}

// renderHistRow is a compact finished-run line: no progress bar (a static
// 100% slab is just noise), outcome mark + phase + duration + mode + detail.
func (m model) renderHistRow(it item, idx int, aw int) string {
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
		dim.Render(tag), dim.Render(trunc(detail, aw-48)))
	if idx == m.selH && m.focus == 2 {
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

var orbit = []rune("◐◓◑◒")

// mrsRadar renders the brewing-conflict warnings for the ACTIVE box.
// An MR clashing with 3+ others (a "hub" — usually one wide branch) is
// collapsed into a single line instead of one line per pair.
func (m model) mrsRadar(aw int) []string {
	count := map[string]int{}
	branch := map[string]string{}
	for _, p := range m.snap.radarPairs {
		count[p.a]++
		count[p.b]++
		branch[p.a], branch[p.b] = p.srcA, p.srcB
	}
	var out []string
	seenHub := map[string]bool{}
	for _, p := range m.snap.radarPairs {
		hub, other := "", ""
		if count[p.a] >= 3 {
			hub, other = p.a, p.b
		} else if count[p.b] >= 3 {
			hub, other = p.b, p.a
		}
		_ = other
		if hub != "" {
			if !seenHub[hub] {
				seenHub[hub] = true
				out = append(out, yellow.Render(trunc(fmt.Sprintf(" ⚡ !%s (%s) clashes with %d open MRs — first to merge wins", hub, branch[hub], count[hub]), aw-2)))
			}
			continue
		}
		out = append(out, yellow.Render(trunc(fmt.Sprintf(" ⚡ !%s × !%s  %s ↔ %s", p.a, p.b, p.srcA, p.srcB), aw-2)))
	}
	return out
}

func (m model) renderBanner() string {
	// one line: a tiny wrench at work (sparks fly) + the name typing itself
	const name = "merge-medic"
	cycle := len(name) + 8 // typing + hold with the full name
	k := m.frame % cycle
	if k > len(name) {
		k = len(name)
	}
	cur := dim.Render("▌")
	if m.frame%2 == 1 {
		cur = " "
	}
	sparks := []string{" ", "·", "✦", "·"}
	spark := amber.Render(sparks[m.frame%len(sparks)])
	// pixel wrench: a corner pixel orbiting the cell — reads as spinning
	wrench := []string{"▘", "▝", "▗", "▖"}
	w := amberB.Render(wrench[m.frame%len(wrench)])
	return " " + w + spark + " " + bold.Render(name[:k]) + cur + "\n\n"
}

func (m model) View() string {
	if m.showHelp {
		return m.helpView()
	}
	if m.screen == 1 {
		return m.insightsView()
	}
	if m.screen == 2 {
		return m.fleetView()
	}
	s := m.snap
	now := time.Now().Unix()
	wide := m.width >= 110

	d := red.Render("off")
	if s.daemon {
		d = green.Render("on")
	}

	var b strings.Builder
	if m.height >= 14 {
		b.WriteString(m.renderBanner())
	}

	box := func(w int, title, body string) string {
		return titledBox(w, title, "", body, 0, false)
	}

	// ── layout: left column (status strip, ACTIVE, HISTORY) + LIVE at right ──
	lw := m.width
	liveW := 0
	if wide {
		liveW = m.width * 2 / 5
		if liveW > 100 {
			liveW = 100
		}
		lw = m.width - liveW
	}

	bmax, _ := strconv.Atoi(s.budgetMax)
	bcur, _ := strconv.Atoi(s.budget)
	budgetLine := fmt.Sprintf("%s %s %s/%s %s", dim.Render("ai-budget"), yellow.Render(gauge(bcur, bmax, 12)), s.budget, s.budgetMax, dim.Render("+/-"))
	if bmax == 0 {
		budgetLine = fmt.Sprintf("%s %s today · %s %s", dim.Render("ai-budget"), s.budget, green.Render("∞ unlimited"), dim.Render("+/-"))
	}
	pm := green.Render("direct push")
	if s.pushMode == "mr" {
		pm = yellow.Render("via resolution MR")
	}
	statusLines := []string{
		fmt.Sprintf("%s %s · daemon %s", amber.Render(string(orbit[m.frame%len(orbit)])),
			time.Now().Format("15:04:05"), d),
		budgetLine,
		dim.Render("deliver ") + pm + " " + dim.Render("m"),
	}
	if s.lastErr != "" {
		statusLines = append(statusLines, red.Render("⚠ "+s.lastErr))
	}
	runLines := []string{
		fmt.Sprintf("today  %s %s %s", green.Render(fmt.Sprintf("%d✓", s.ok)),
			red.Render(fmt.Sprintf("%d✗", s.bad)), yellow.Render(fmt.Sprintf("%d⚑", s.esc))),
		fmt.Sprintf("total  %s %s %s · %dc/%dai", green.Render(fmt.Sprintf("%d✓", s.tok)),
			red.Render(fmt.Sprintf("%d✗", s.tbad)), yellow.Render(fmt.Sprintf("%d⚑", s.tesc)),
			s.tclean, s.tai),
		fmt.Sprintf("%s %s 14d", dim.Render("activity"), green.Render(sparkline(s.daily))),
	}
	spendLines := []string{
		fmt.Sprintf("≈$%.2f today · $%.2f all", s.spendToday, s.spend),
	}
	if s.modelLine != "" {
		spendLines = append(spendLines, dim.Render(s.modelLine))
	}

	var lb strings.Builder
	if lw >= 72 {
		w1 := lw * 2 / 5
		w2 := (lw - w1) / 2
		w3 := lw - w1 - w2
		h := max(len(statusLines), max(len(runLines), len(spendLines)))
		boxH := func(w int, title string, lines []string) string {
			focused := title == "STATUS" && m.focus == 0
			// clip (ANSI-aware) instead of letting lipgloss wrap — a wrapped
			// line would inflate one box past the shared height
			clipped := make([]string, len(lines))
			for i, ln := range lines {
				clipped[i] = truncate.String(ln, uint(max(1, w-4)))
			}
			return titledBox(w, title, "", strings.Join(clipped, "\n"), h, focused)
		}
		lb.WriteString(lipgloss.JoinHorizontal(lipgloss.Top,
			boxH(w1, "STATUS", statusLines),
			boxH(w2, "RUNS", runLines),
			boxH(w3, "SPEND", spendLines)) + "\n")
	} else {
		all := append(append(statusLines, runLines...), spendLines...)
		lb.WriteString(box(lw, "STATUS", strings.Join(all, "\n")) + "\n")
	}

	// ── ACTIVE (fixers + open MRs + radar), then HISTORY, stacked ─────────────
	idx := 0
	aw := lw - 4 // content width inside border+padding
	hw := lw - 4
	var act []string
	fixing := map[string]bool{}
	for _, it := range s.activeRows {
		act = append(act, m.renderRow(it, idx, now, aw))
		fixing[it.iid] = true
		idx++
	}
	if len(s.mrs) > 0 {
		if len(act) > 0 {
			act = append(act, dim.Render(strings.Repeat("─", max(1, aw-1))))
		}
		// when every MR targets the same branch, drop the "→target" noise
		// (the shared target moves into the panel title meta)
		commonTgt := ""
		uniform := true
		for _, mr := range s.mrs {
			if mr.tgt == "" {
				continue
			}
			if commonTgt == "" {
				commonTgt = mr.tgt
			} else if mr.tgt != commonTgt {
				uniform = false
			}
		}
		// branch column: as wide as the widest ref actually present (capped) —
		// a single long branch name must not push every title away
		bcol := 0
		refs := make([]string, len(s.mrs))
		for i, mr := range s.mrs {
			if mr.src != "" {
				refs[i] = mr.src
				if !uniform && mr.tgt != "" {
					refs[i] += "→" + mr.tgt
				}
			}
			if n := len([]rune(refs[i])); n > bcol {
				bcol = n
			}
		}
		// ⚡ marks only peer-to-peer clashes; hub members are covered by the
		// collapsed "clashes with N MRs" line and would just be noise here
		rcount := map[string]int{}
		for _, pr := range s.radarPairs {
			rcount[pr.a]++
			rcount[pr.b]++
		}
		hot := map[string]bool{}
		for _, pr := range s.radarPairs {
			if rcount[pr.a] < 3 && rcount[pr.b] < 3 {
				hot[pr.a], hot[pr.b] = true, true
			}
		}
		bcol = min(bcol, min(24, aw/3))
		for i, mr := range s.mrs {
			ic := dim.Render("?")
			switch mr.status {
			case "conflict":
				ic = red.Render("✗")
			case "mergeable":
				ic = green.Render("✓")
			}
			gear := "  "
			if fixing[mr.iid] {
				gear = blue.Render("⚙ ")
			}
			title := mr.title
			tstyle := lipgloss.NewStyle()
			if d, ok := strings.CutPrefix(title, "Draft: "); ok {
				title = d
				tstyle = dim
				if gear == "  " {
					gear = dim.Render("d ")
				}
			}
			age := fmtAge(now - mr.updated)
			if mr.updated == 0 {
				age = "  "
			}
			zap := " "
			if hot[mr.iid] {
				zap = yellow.Render("⚡")
			}
			row := fmt.Sprintf(" %s %s %s %s%s%s %s %s %s", ic, ciDot(mr.ci),
				bold.Render(fmt.Sprintf("!%-4s", mr.iid)), gear, zap,
				dim.Render(fmt.Sprintf("%-*s", bcol, trunc(refs[i], bcol))),
				dim.Render(fmt.Sprintf("%3s", age)),
				dim.Render(fmt.Sprintf("%-8s", trunc(mr.author, 8))),
				titleStyled(title, tstyle, aw-(31+bcol)))
			if idx == m.sel && m.focus == 1 {
				row = selRow.Render(row)
			}
			if m.expandedMR[mr.iid] {
				row += "\n" + dim.Render(trunc(fmt.Sprintf("      %s → %s · by %s · updated %s ago · CI %s",
					mr.src, mr.tgt, mr.author, age, mr.ci), aw))
				var clashes []string
				for _, p := range s.radarPairs {
					if p.a == mr.iid {
						clashes = append(clashes, "!"+p.b)
					}
					if p.b == mr.iid {
						clashes = append(clashes, "!"+p.a)
					}
				}
				if len(clashes) > 0 {
					row += "\n      " + yellow.Render(trunc("⚡ clashes with "+strings.Join(clashes, " "), aw-6))
				}
			}
			act = append(act, row)
			idx++
		}
	}
	act = append(act, m.mrsRadar(aw)...)
	if len(act) == 0 {
		act = append(act, dim.Render(" no open MRs"))
	}
	var hist []string
	if len(s.histRows) == 0 {
		hist = append(hist, dim.Render(" no runs yet"))
	}
	for hIdx, it := range s.histRows {
		hist = append(hist, m.renderHistRow(it, hIdx, hw))
	}
	nConf := 0
	tgtMeta := ""
	for _, mr := range s.mrs {
		if mr.status == "conflict" {
			nConf++
		}
	}
	if len(s.mrs) > 0 {
		t := s.mrs[0].tgt
		same := t != ""
		for _, mr := range s.mrs {
			if mr.tgt != t {
				same = false
			}
		}
		if same {
			tgtMeta = " → " + t
		}
	}
	actMeta := fmt.Sprintf("%d MRs%s", len(s.mrs), tgtMeta)
	if nConf > 0 {
		actMeta = fmt.Sprintf("%d MRs · %d✗%s", len(s.mrs), nConf, tgtMeta)
	}
	lb.WriteString(titledBox(lw, "ACTIVE", actMeta, strings.Join(act, "\n"), 0, m.focus == 1) + "\n")
	lb.WriteString(titledBox(lw, "HISTORY", fmt.Sprintf("%d", s.tok+s.tbad+s.tesc), strings.Join(hist, "\n"), 0, m.focus == 2) + "\n")

	if m.showLog {
		lb.WriteString(bold.Render("log ") + dim.Render(m.logName) + "\n")
		for _, ln := range m.logLines {
			lb.WriteString(dim.Render("│ ") + trunc(ln, lw-4) + "\n")
		}
	}

	// ── LIVE: full-height right column (wide) or bottom box (narrow) ──────────
	if wide {
		left := strings.TrimRight(lb.String(), "\n")
		total := m.height - lipgloss.Height(m.renderBanner()) - 2
		if h := lipgloss.Height(left); h > total {
			total = h
		}
		feedH := total - 3
		badge := "▼ follow"
		ival, _ := strconv.Atoi(readConfigVal(m.root, "POLL_INTERVAL", "180"))
		if ival <= 0 {
			ival = 180
		}
		if s.lastTick > 0 {
			left := s.lastTick + int64(ival) - now
			switch {
			case left >= 0:
				badge += fmt.Sprintf(" · next tick %02d:%02d", left/60, left%60)
			case -left > int64(ival):
				badge += " · " + "LATE " + fmtAge(-left)
			default:
				badge += " · tick due…"
			}
		}
		feed := s.feed
		if len(feed) > 0 && m.liveOff == 0 {
			last := feed[len(feed)-1]
			if lw := lipgloss.Width(last); m.typeK < lw {
				feed = append(append([]string{}, feed[:len(feed)-1]...),
					truncate.String(last, uint(max(0, m.typeK)))+amber.Render("▌"))
			}
		}
		body := strings.Join(feed, "\n")
		if body == "" {
			body = dim.Render(" quiet — waiting for events")
		} else {
			// wrap (ANSI-aware), then show the window liveOff above the tail
			wl := strings.Split(lipgloss.NewStyle().Width(liveW-4).Render(body), "\n")
			off := m.liveOff
			if off > len(wl)-feedH {
				off = max(0, len(wl)-feedH)
			}
			if off > 0 {
				badge = "‖ paused"
			}
			end := len(wl) - off
			if end > feedH {
				wl = wl[end-feedH : end]
			} else if len(wl) > end {
				wl = wl[:end]
			}
			body = strings.Join(wl, "\n")
		}
		liveBox := titledBox(liveW, "LIVE", badge, body, total-2, m.focus == 3)
		b.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, left, liveBox) + "\n")
	} else {
		b.WriteString(lb.String())
		used := lipgloss.Height(b.String())
		feedH := m.height - used - 4
		if feedH >= 3 {
			feed := s.feed
			if len(feed) > 0 && m.liveOff == 0 {
				last := feed[len(feed)-1]
				if lw := lipgloss.Width(last); m.typeK < lw {
					feed = append(append([]string{}, feed[:len(feed)-1]...),
						truncate.String(last, uint(max(0, m.typeK)))+amber.Render("▌"))
				}
			}
			body := strings.Join(feed, "\n")
			if body == "" {
				body = dim.Render(" quiet — waiting for events")
			} else {
				wl := strings.Split(lipgloss.NewStyle().Width(m.width-4).Render(body), "\n")
				if len(wl) > feedH {
					wl = wl[len(wl)-feedH:]
				}
				body = strings.Join(wl, "\n")
			}
			b.WriteString(box(m.width, "LIVE", body) + "\n")
		}
	}

	key := func(k, label string) string { return amber.Render(k) + dim.Render(" "+label) }
	sep := dim.Render(" · ")
	b.WriteString(" " + key("tab", "focus") + sep + key("↑↓", "move") + sep + key("enter", "details") + sep +
		key("o", "open") + sep + key("a", "approve") + sep + key("2", "insights") + sep + key("3", "fleet") + sep +
		key("?", "help") + sep + key("q", "quit"))
	return b.String()
}

// readInstances lists installed merge-medic roots from the registry.
func readInstances() []string {
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".config", "merge-medic", "instances"))
	if err != nil {
		return nil
	}
	var out []string
	for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
		if st, err := os.Stat(ln); err == nil && st.IsDir() {
			out = append(out, ln)
		}
	}
	return out
}

// insightsView — screen 2: conflict hotspots + spend analytics.
func (m model) insightsView() string {
	s := m.snap
	var b strings.Builder
	b.WriteString(m.renderBanner())
	w := m.width

	var hs []string
	if len(s.hotspots) == 0 {
		hs = append(hs, dim.Render(" no archived AI runs yet"))
	}
	maxC := 1
	for _, h := range s.hotspots {
		if h.count > maxC {
			maxC = h.count
		}
	}
	for _, h := range s.hotspots {
		barW := h.count * 20 / maxC
		hs = append(hs, fmt.Sprintf(" %s %s %s",
			amber.Render(fmt.Sprintf("%3d×", h.count)),
			yellow.Render(strings.Repeat("▪", barW)),
			dim.Render(trunc(h.file, w-32))))
	}
	b.WriteString(titledBox(w, "HOTSPOTS", "most-conflicted files, all runs", strings.Join(hs, "\n"), 0, false) + "\n")

	maxS := 0.01
	for _, v := range s.spendDaily {
		if v > maxS {
			maxS = v
		}
	}
	var spark strings.Builder
	for _, v := range s.spendDaily {
		idx := int(v / maxS * float64(len(sparkChars)-1))
		spark.WriteRune(sparkChars[idx])
	}
	sp := []string{
		fmt.Sprintf(" %s %s  %s", dim.Render("14d"), green.Render(spark.String()),
			dim.Render(fmt.Sprintf("today ≈$%.2f · all $%.2f", s.spendToday, s.spend))),
		"",
		dim.Render(" most expensive runs:"),
	}
	if len(s.topRuns) == 0 {
		sp = append(sp, dim.Render("  none yet"))
	}
	for _, r := range s.topRuns {
		short := r.model
		if i := strings.Index(short, "claude-"); i >= 0 {
			short = short[i+7:]
		}
		sp = append(sp, fmt.Sprintf("  %s %s %s %s",
			amber.Render(fmt.Sprintf("$%.2f", r.cost)),
			bold.Render(fmt.Sprintf("!%-5s", r.iid)),
			dim.Render(fmt.Sprintf("%-14s", trunc(short, 14))),
			dim.Render(time.Unix(r.ts, 0).Format("02.01 15:04"))))
	}
	b.WriteString(titledBox(w, "SPEND", "$ per day + top runs", strings.Join(sp, "\n"), 0, false) + "\n")
	b.WriteString(" " + amber.Render("1") + dim.Render(" main · ") + amber.Render("3") + dim.Render(" fleet · ") + amber.Render("q") + dim.Render(" quit"))
	return b.String()
}

// fleetView — screen 3: every installed instance at a glance.
func (m model) fleetView() string {
	var b strings.Builder
	b.WriteString(m.renderBanner())
	insts := readInstances()
	var rows []string
	if len(insts) == 0 {
		rows = append(rows, dim.Render(" no registered instances (~/.config/merge-medic/instances)"))
	}
	today := time.Now().Format("2006-01-02")
	for i, root := range insts {
		name := strings.TrimPrefix(filepath.Base(root), ".")
		pp := readConfigVal(root, "PROJECT_PATH", "?")
		pv := readConfigVal(root, "PROVIDER", "gitlab")
		spent := "0"
		if bts, err := os.ReadFile(filepath.Join(root, "state", "budget-"+today)); err == nil {
			spent = strings.TrimSpace(string(bts))
		}
		conf := 0
		mrFiles, _ := filepath.Glob(filepath.Join(root, "state", "mr-*"))
		for _, f := range mrFiles {
			if data, err := os.ReadFile(f); err == nil && strings.HasPrefix(string(data), "conflict") {
				conf++
			}
		}
		d := red.Render("off")
		if daemonLoaded(root) {
			d = green.Render("on")
		}
		cur := "  "
		if root == m.root {
			cur = amber.Render("▸ ")
		}
		st := ""
		if conf > 0 {
			st = red.Render(fmt.Sprintf(" %d✗", conf))
		}
		row := fmt.Sprintf(" %s%s %s %s · daemon %s · ai %s today%s", cur,
			bold.Render(fmt.Sprintf("%-16s", name)), dim.Render(fmt.Sprintf("%-7s", pv)),
			trunc(pp, 40), d, spent, st)
		if i == m.selF {
			row = selRow.Render(row)
		}
		rows = append(rows, row)
	}
	b.WriteString(titledBox(m.width, "FLEET", fmt.Sprintf("%d instances", len(insts)), strings.Join(rows, "\n"), 0, true) + "\n")
	b.WriteString(" " + amber.Render("↑↓") + dim.Render(" move · ") + amber.Render("enter") + dim.Render(" switch dashboard to instance · ") + amber.Render("1") + dim.Render(" main · ") + amber.Render("2") + dim.Render(" insights · ") + amber.Render("q") + dim.Render(" quit"))
	return b.String()
}

func (m model) helpView() string {
	rows := [][2]string{
		{"↑↓ / j k", "move selection"},
		{"enter / e", "details: phase timeline (runs) / MR info + clashes (MRs)"},
		{"o", "open the selected MR/PR in the browser"},
		{"tab", "cycle focus: ACTIVE → HISTORY → LIVE (j/k scrolls the log)"},
		{"+ / -", "raise / lower the daily AI budget when STATUS is focused (0 = unlimited)"},
		{"m", "toggle delivery when STATUS is focused: direct push ↔ resolution MR"},
		{"1 / 2 / 3", "screens: main dashboard / insights (hotspots, spend) / fleet (instances)"},
		{"l", "toggle AI/fixer log panel for the selected MR"},
		{"a", "approve the selected PLANNED plan (semi-auto branches)"},
		{"r", "force a watcher tick now"},
		{"p", "pause / resume the daemon"},
		{"esc", "close panels / collapse everything"},
		{"?", "this help"},
		{"q", "quit"},
	}
	var b strings.Builder
	b.WriteString(m.renderBanner() + "\n")
	for _, r := range rows {
		b.WriteString(fmt.Sprintf("  %s  %s\n", bold.Render(fmt.Sprintf("%-9s", r[0])), r[1]))
	}
	b.WriteString("\n" + amberB.Render("  legend") + "\n")
	leg := [][2]string{
		{green.Render("✓") + " / " + red.Render("✗") + " / " + dim.Render("?"), "MR mergeable / conflicted / unknown"},
		{green.Render("●") + red.Render("●") + yellow.Render("●") + dim.Render("·"), "CI pipeline: passed / failed / running / none"},
		{blue.Render("⚙"), "a fixer is working on this MR right now"},
		{dim.Render("d"), "draft MR (never auto-fixed)"},
		{yellow.Render("⚡"), "clashes with another OPEN MR (radar) — first to merge wins"},
		{green.Render("████") + amber.Render("▓") + dim.Render("░░░"), "fixer phase path: done / current / ahead"},
		{red.Render("⏱"), "stalled? phase frozen for 4× its usual time — check the log"},
		{yellow.Render("▣"), "plan posted, waiting for your approve (a)"},
		{yellow.Render("⚑") + " / " + dim.Render("…"), "escalated to a human / deferred (branch is hot)"},
	}
	for _, r := range leg {
		pad := 12 - lipgloss.Width(r[0])
		if pad < 0 {
			pad = 0
		}
		b.WriteString("  " + r[0] + strings.Repeat(" ", pad) + "  " + dim.Render(r[1]) + "\n")
	}
	b.WriteString("\n" + dim.Render("  CLI: mrwatch setup · log -f · agent <iid> · run · pause/resume"))
	b.WriteString("\n\n" + dim.Render("  press ? or esc to return"))
	return b.String()
}

// tailBytes reads at most max bytes from the end of a file, split into lines.
func tailBytes(path string, max int64) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil
	}
	off := int64(0)
	if st.Size() > max {
		off = st.Size() - max
	}
	buf := make([]byte, st.Size()-off)
	if _, err := f.ReadAt(buf, off); err != nil && len(buf) == 0 {
		return nil
	}
	lines := nonEmpty(strings.Split(string(buf), "\n"))
	if off > 0 && len(lines) > 0 {
		lines = lines[1:] // first line likely cut mid-way
	}
	return lines
}

type feedLine struct {
	ts   int64
	text string
}

// buildFeed merges watcher lines and fixer phase events into one colored,
// chronological stream shown in the LIVE panel.
func buildFeed(root string, width int) []string {
	var fl []feedLine
	for _, ln := range tailBytes(filepath.Join(root, "logs", "watch.log"), 32*1024) {
		if len(ln) < 21 {
			continue
		}
		t, err := time.ParseInLocation("2006-01-02 15:04:05", ln[:19], time.Local)
		if err != nil {
			continue
		}
		msg := strings.TrimRight(ln[21:], " ")
		style := dim
		switch {
		case strings.Contains(msg, "ERROR"):
			style = red
		case strings.Contains(msg, "CONFLICT"):
			style = yellow
		case strings.Contains(msg, "fixer ->"):
			style = green
		}
		fl = append(fl, feedLine{t.Unix(),
			dim.Render(ln[11:19]) + " " + style.Render(trunc(msg, width-12))})
	}
	for _, ln := range tailBytes(filepath.Join(root, "logs", "events.log"), 32*1024) {
		parts := strings.SplitN(ln, "|", 4)
		if len(parts) < 3 {
			continue
		}
		ts, _ := strconv.ParseInt(parts[0], 10, 64)
		phase := parts[2]
		detail := ""
		if len(parts) > 3 {
			detail = parts[3]
		}
		style := lipgloss.NewStyle()
		switch phase {
		case "DONE":
			style = green
		case "FAIL":
			style = red
		case "AI_RESOLVE", "PLAN", "PLANNED", "ESCALATED":
			style = yellow
		}
		fl = append(fl, feedLine{ts,
			dim.Render(time.Unix(ts, 0).Format("15:04:05")) + " " +
				bold.Render("!"+parts[1]) + " " + style.Render(fmt.Sprintf("%-11s", phase)) +
				" " + dim.Render(trunc(detail, width-30))})
	}
	sort.SliceStable(fl, func(i, j int) bool { return fl[i].ts < fl[j].ts })
	out := make([]string, 0, len(fl))
	for _, l := range fl {
		out = append(out, l.text)
	}
	if len(out) > 300 {
		out = out[len(out)-300:]
	}
	return out
}

// fmtAge renders a compact age: 42m, 3h, 2d.
func fmtAge(sec int64) string {
	switch {
	case sec < 0:
		return "0m"
	case sec < 3600:
		return fmt.Sprintf("%dm", sec/60)
	case sec < 86400:
		return fmt.Sprintf("%dh", sec/3600)
	}
	return fmt.Sprintf("%dd", sec/86400)
}

func fmtTok(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1_000:
		return fmt.Sprintf("%.0fk", float64(n)/1e3)
	}
	return strconv.FormatInt(n, 10)
}

// readTokens aggregates state/tokens.log (ts|iid|model|in|out|cache|cost).
func readTokens(root string, day0 int64) (today, total float64, modelLine string) {
	data, err := os.ReadFile(filepath.Join(root, "state", "tokens.log"))
	if err != nil {
		return 0, 0, ""
	}
	type agg struct{ in, out int64; cost float64 }
	models := map[string]*agg{}
	var order []string
	for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
		p := strings.Split(ln, "|")
		if len(p) < 7 {
			continue
		}
		ts, _ := strconv.ParseInt(p[0], 10, 64)
		in, _ := strconv.ParseInt(p[3], 10, 64)
		out, _ := strconv.ParseInt(p[4], 10, 64)
		cost, _ := strconv.ParseFloat(p[6], 64)
		total += cost
		if ts >= day0 {
			today += cost
		}
		m := p[2]
		if models[m] == nil {
			models[m] = &agg{}
			order = append(order, m)
		}
		models[m].in += in
		models[m].out += out
		models[m].cost += cost
	}
	var parts []string
	for _, m := range order {
		a := models[m]
		short := m
		if i := strings.Index(short, "claude-"); i >= 0 {
			short = short[i+7:]
		}
		if len(short) > 12 {
			short = short[:12]
		}
		parts = append(parts, fmt.Sprintf("%s %s→%s $%.2f", short, fmtTok(a.in), fmtTok(a.out), a.cost))
	}
	return today, total, strings.Join(parts, " · ")
}

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
		if n > 1 {
			return string(r[:n-1]) + "…"
		}
		return string(r[:n])
	}
	return s
}

func readSnapshot(root string, width int) snapshot {
	var s snapshot
	now := time.Now()
	day0 := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()

	s.budget = "0"
	s.budgetMax = readConfigVal(root, "DAILY_AGENT_RUNS", "6")
	if b, err := os.ReadFile(filepath.Join(root, "state", "budget-"+now.Format("2006-01-02"))); err == nil {
		s.budget = strings.TrimSpace(string(b))
	}
	s.daemon = daemonLoaded(root)
	s.pushMode = readConfigVal(root, "PUSH_MODE", "direct")

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
		if terminal(it.phase) && it.phase != "PLANNED" && it.phase != "DEFERRED" {
			continue
		}
		s.activeRows = append(s.activeRows, it)
	}

	// full run history from the durable ledger, newest first
	if data, err := os.ReadFile(filepath.Join(root, "state", "history.log")); err == nil {
		lines := nonEmpty(strings.Split(string(data), "\n"))
		for i := len(lines) - 1; i >= 0 && len(s.histRows) < 8; i-- {
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

	s.feed = buildFeed(root, 4000)
	s.spendToday, s.spend, s.modelLine = readTokens(root, day0)
	s.spendDaily = make([]float64, 14)
	if data, err := os.ReadFile(filepath.Join(root, "state", "tokens.log")); err == nil {
		for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
			p := strings.Split(ln, "|")
			if len(p) < 7 {
				continue
			}
			ts, _ := strconv.ParseInt(p[0], 10, 64)
			cost, _ := strconv.ParseFloat(p[6], 64)
			age := int((day0 + 86400 - ts) / 86400)
			if age >= 0 && age < 14 {
				s.spendDaily[13-age] += cost
			}
			s.topRuns = append(s.topRuns, costRun{iid: p[1], model: p[2], cost: cost, ts: ts})
		}
		sort.Slice(s.topRuns, func(i, j int) bool { return s.topRuns[i].cost > s.topRuns[j].cost })
		if len(s.topRuns) > 5 {
			s.topRuns = s.topRuns[:5]
		}
	}

	// DONE per day for the last 14 days (activity sparkline)
	s.daily = make([]int, 14)
	if data, err := os.ReadFile(filepath.Join(root, "state", "history.log")); err == nil {
		for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
			parts := strings.Split(ln, "|")
			if len(parts) < 3 || parts[2] != "DONE" {
				continue
			}
			ts, _ := strconv.ParseInt(parts[0], 10, 64)
			age := int((day0 + 86400 - ts) / 86400) // 0 = today
			if age >= 0 && age < 14 {
				s.daily[13-age]++
			}
		}
	}

	// watcher health: heartbeat written by every tick (watch.log only gets
	// lines when something happens, so its mtime is not a liveness signal)
	if b, err := os.ReadFile(filepath.Join(root, "state", ".lastpoll")); err == nil {
		s.lastTick, _ = strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	} else if st, err := os.Stat(filepath.Join(root, "logs", "watch.log")); err == nil {
		s.lastTick = st.ModTime().Unix() // pre-heartbeat fallback
	}
	for _, ln := range tailBytes(filepath.Join(root, "logs", "watch.log"), 8*1024) {
		if i := strings.Index(ln, "ERROR:"); i >= 0 && len(ln) > 21 {
			if t, err := time.ParseInLocation("2006-01-02 15:04:05", ln[:19], time.Local); err == nil {
				s.lastErr = strings.TrimSpace(ln[i+6:])
				s.lastErrTs = t.Unix()
			}
		}
	}
	if s.lastErrTs > 0 && now.Unix()-s.lastErrTs > 1800 {
		s.lastErr = "" // old news
	}

	// hotspots: conflicted files across all archived runs
	fileCount := map[string]int{}
	if runFiles, err := filepath.Glob(filepath.Join(root, "state", "runs", "*.log")); err == nil {
		for _, rf := range runFiles {
			data, err := os.ReadFile(rf)
			if err != nil {
				continue
			}
			for _, ln := range strings.Split(string(data), "\n") {
				parts := strings.SplitN(ln, "|", 3)
				if len(parts) < 3 || (parts[1] != "AI_RESOLVE" && parts[1] != "PLAN") {
					continue
				}
				d := parts[2]
				if i := strings.Index(d, "file(s): "); i >= 0 {
					for _, f := range strings.Fields(d[i+9:]) {
						fileCount[f]++
					}
				}
			}
		}
	}
	for f, c := range fileCount {
		s.hotspots = append(s.hotspots, hotspot{f, c})
	}
	sort.Slice(s.hotspots, func(i, j int) bool {
		if s.hotspots[i].count != s.hotspots[j].count {
			return s.hotspots[i].count > s.hotspots[j].count
		}
		return s.hotspots[i].file < s.hotspots[j].file
	})
	if len(s.hotspots) > 10 {
		s.hotspots = s.hotspots[:10]
	}

	// brewing conflicts between open MRs (state/radar: a|b|srcA|srcB)
	if st, err := os.Stat(filepath.Join(root, "state", "radar")); err == nil && now.Sub(st.ModTime()) > 15*time.Minute {
		// stale radar (watcher quiet) — don't show orphan warnings when the
		// MR list itself has already aged out
	} else if data, err := os.ReadFile(filepath.Join(root, "state", "radar")); err == nil {
		for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
			p := strings.Split(ln, "|")
			if len(p) >= 4 {
				s.radarPairs = append(s.radarPairs, radarPair{p[0], p[1], p[2], p[3]})
			}
		}
	}

	// open MRs — mr-* files fresher than 15 min (stale ones are closed MRs
	// or a stopped daemon; either way not "current")
	mrFiles, _ := filepath.Glob(filepath.Join(root, "state", "mr-*"))
	for _, f := range mrFiles {
		if st, err := os.Stat(f); err != nil || now.Sub(st.ModTime()) > 15*time.Minute {
			continue
		}
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		fields := strings.Fields(string(data))
		mr := mrState{iid: strings.TrimPrefix(filepath.Base(f), "mr-"), status: "unknown"}
		if len(fields) > 0 {
			mr.status = fields[0]
		}
		if len(fields) > 3 {
			mr.src, mr.tgt = fields[2], fields[3]
		}
		// field 5 is the CI status when it matches a known value (older state
		// files put the title there — they age out within the 15min TTL)
		if len(fields) > 4 {
			rest := fields[4:]
			if ciKnown[rest[0]] {
				mr.ci = rest[0]
				rest = rest[1:]
			}
			// author + RFC3339 updated timestamp (newer state files)
			if len(rest) >= 2 {
				if t, err := time.Parse(time.RFC3339, rest[1]); err == nil {
					mr.author = rest[0]
					mr.updated = t.Unix()
					rest = rest[2:]
				}
			}
			mr.title = strings.Join(rest, " ")
		}
		s.mrs = append(s.mrs, mr)
	}
	sort.Slice(s.mrs, func(i, j int) bool {
		ci := s.mrs[i].status == "conflict"
		cj := s.mrs[j].status == "conflict"
		if ci != cj {
			return ci // conflicted first — that's what the tool is about
		}
		a, _ := strconv.Atoi(s.mrs[i].iid)
		b, _ := strconv.Atoi(s.mrs[j].iid)
		return a > b
	})
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

// setConfigVal rewrites (or appends) KEY=value in config.env, atomically.
func setConfigVal(root, key, val string) {
	path := filepath.Join(root, "config.env")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	lines := strings.Split(string(data), "\n")
	found := false
	for i, ln := range lines {
		if strings.HasPrefix(strings.TrimSpace(ln), key+"=") {
			lines[i] = key + "=" + val
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, key+"="+val)
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, []byte(strings.Join(lines, "\n")), 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
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

// daemonLoaded checks this instance's scheduler job — the job name is derived
// from the install dir basename (multi-instance: one clone per watched repo).
func daemonLoaded(root string) bool {
	// test/demo hook: synthetic state dirs have no real scheduler job
	if os.Getenv("MRTOP_FAKE_DAEMON") == "1" {
		return true
	}
	inst := strings.TrimPrefix(filepath.Base(root), ".")
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("launchctl", "list").Output()
		return err == nil && strings.Contains(string(out), "com."+inst+".watch")
	}
	return exec.Command("systemctl", "--user", "is-active", "--quiet", inst+".timer").Run() == nil
}

func togglePause(root string) {
	mrwatch := filepath.Join(root, "bin", "mrwatch")
	if daemonLoaded(root) {
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

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
