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

type mrState struct{ iid, status, src, tgt, title string }

type snapshot struct {
	activeRows, histRows []item
	mrs                  []mrState
	budget, budgetMax    string
	daemon               bool
	ok, bad, esc         int
	tok, tbad, tesc      int
	tclean, tai          int
	feed                 []string // pre-rendered live feed lines, oldest first
	daily                []int    // DONE per day, last 14 days, oldest first
	spendToday, spend    float64  // USD, from the CLI's own accounting
	modelLine            string   // per-model tokens/cost breakdown
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
	showHelp bool
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: mrtop <merge-medic root>")
		os.Exit(2)
	}
	m := model{root: os.Args[1], width: 100, height: 40, expanded: map[string]bool{}}
	if len(os.Args) > 2 && os.Args[2] == "--once" {
		if c, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && c > 40 {
			m.width = c
		}
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
		m.snap = readSnapshot(m.root, m.width)
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
		case "?":
			m.showHelp = !m.showHelp
		case "esc":
			m.showHelp = false
			m.showLog = false
			m.expanded = map[string]bool{}
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
	case "DEFERRED":
		return dim.Render("…")
	}
	return " "
}

func (m model) renderRow(it item, idx int, now int64, aw int) string {
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
	case "DEFERRED":
		style = dim
	}
	when := time.Unix(it.t0, 0).Format("15:04")
	tag := it.mode
	if tag == "" || tag == "none" {
		tag = "  "
	}
	bw := 20
	if aw < 90 {
		bw = 12
	}
	row := fmt.Sprintf(" %s %s %s [%s] %3d%%  %s %3dm%02ds %-5s %s",
		mark, bold.Render(fmt.Sprintf("!%-4s", it.iid)), dim.Render(when),
		bar(pct, bw), pct,
		style.Render(fmt.Sprintf("%-10s", it.phase)), el/60, el%60,
		dim.Render(tag), dim.Render(trunc(it.detail, aw-(49+bw))))
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

var orbit = []rune("◐◓◑◒")

func (m model) renderBanner() string {
	return " ▄█▄\n" +
		" ▀█▀  " + bold.Render("merge-medic") + "\n"
}

func (m model) View() string {
	if m.showHelp {
		return m.helpView()
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

	// box renders a section whose TOTAL printed width (border included) is w —
	// lipgloss adds the border on top of Width, hence the -2.
	box := func(w int, title, body string) string {
		return section.Width(w - 2).Render(sectionTitle.Render(title) + "\n" + body)
	}

	// ── top strip: STATUS · RUNS · SPEND ──────────────────────────────────────
	bmax, _ := strconv.Atoi(s.budgetMax)
	bcur, _ := strconv.Atoi(s.budget)
	statusLines := []string{
		fmt.Sprintf("%s %s · daemon %s", dim.Render(string(orbit[m.frame%len(orbit)])),
			time.Now().Format("15:04:05"), d),
		fmt.Sprintf("%s %s %s/%s", dim.Render("ai-budget"), yellow.Render(gauge(bcur, bmax, 12)), s.budget, s.budgetMax),
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

	if wide {
		w1 := m.width / 3
		w2 := m.width / 3
		w3 := m.width - w1 - w2
		// same height for all three boxes — mixed heights look ragged
		h := max(len(statusLines), max(len(runLines), len(spendLines))) + 1
		boxH := func(w int, title, body string) string {
			return section.Width(w - 2).Height(h).Render(sectionTitle.Render(title) + "\n" + body)
		}
		b.WriteString(lipgloss.JoinHorizontal(lipgloss.Top,
			boxH(w1, "STATUS", strings.Join(statusLines, "\n")),
			boxH(w2, "RUNS", strings.Join(runLines, "\n")),
			boxH(w3, "SPEND", strings.Join(spendLines, "\n"))) + "\n")
	} else {
		all := append(append(statusLines, runLines...), spendLines...)
		b.WriteString(box(m.width, "STATUS", strings.Join(all, "\n")) + "\n")
	}

	// ── ACTIVE (fixers + open MRs) / HISTORY ──────────────────────────────────
	idx := 0
	lw, rw := m.width, m.width
	if wide {
		lw = m.width / 2
		rw = m.width - lw
	}
	aw := lw - 4 // content width inside border+padding
	hw := rw - 4
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
		// branch column: as wide as the widest ref actually present (capped) —
		// a single long branch name must not push every title away
		bcol := 0
		refs := make([]string, len(s.mrs))
		for i, mr := range s.mrs {
			if mr.src != "" {
				refs[i] = mr.src + "→" + mr.tgt
			}
			if n := len([]rune(refs[i])); n > bcol {
				bcol = n
			}
		}
		bcol = min(bcol, min(18, aw/3))
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
			act = append(act, fmt.Sprintf(" %s %s %s%s %s", ic,
				bold.Render(fmt.Sprintf("!%-4s", mr.iid)), gear,
				dim.Render(fmt.Sprintf("%-*s", bcol, trunc(refs[i], bcol))),
				tstyle.Render(trunc(title, aw-(13+bcol)))))
		}
	}
	if len(act) == 0 {
		act = append(act, dim.Render(" no open MRs"))
	}
	var hist []string
	if len(s.histRows) == 0 {
		hist = append(hist, dim.Render(" no runs yet"))
	}
	for _, it := range s.histRows {
		hist = append(hist, m.renderHistRow(it, idx, hw))
		idx++
	}
	actBox := box(lw, "ACTIVE", strings.Join(act, "\n"))
	histBox := box(rw, "HISTORY", strings.Join(hist, "\n"))
	if wide {
		b.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, actBox, histBox) + "\n")
	} else {
		b.WriteString(actBox + "\n" + histBox + "\n")
	}

	if m.showLog {
		b.WriteString(bold.Render("log ") + dim.Render(m.logName) + "\n")
		for _, ln := range m.logLines {
			b.WriteString(dim.Render("│ ") + trunc(ln, m.width-4) + "\n")
		}
	}

	// ── LIVE feed fills whatever height is left ───────────────────────────────
	used := lipgloss.Height(b.String())
	feedH := m.height - used - 4
	if feedH >= 3 {
		lines := s.feed
		if len(lines) > feedH {
			lines = lines[len(lines)-feedH:]
		}
		body := strings.Join(lines, "\n")
		if body == "" {
			body = dim.Render(" quiet — waiting for events")
		}
		b.WriteString(box(m.width, "LIVE", body) + "\n")
	}

	b.WriteString(dim.Render("↑↓ move · enter details · a approve · ? help · q quit"))
	return b.String()
}

func (m model) helpView() string {
	rows := [][2]string{
		{"↑↓ / j k", "move selection"},
		{"enter / e", "expand phase timeline for the selected run"},
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
	b.WriteString("\n" + dim.Render("  CLI: mrwatch status · live · mrs · agent <iid> · run · pause/resume"))
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
// chronological stream (the in-window equivalent of `mrwatch live`).
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

	s.feed = buildFeed(root, width)
	s.spendToday, s.spend, s.modelLine = readTokens(root, day0)

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
		if len(fields) > 4 {
			mr.title = strings.Join(fields[4:], " ")
		}
		s.mrs = append(s.mrs, mr)
	}
	sort.Slice(s.mrs, func(i, j int) bool {
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
