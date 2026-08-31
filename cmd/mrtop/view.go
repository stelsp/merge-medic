// The main dashboard screen: layout budget, panels, rows, timelines.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/reflow/truncate"
)

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
	detail := it.detail
	if stale {
		detail = "stalled? no phase progress for " + fmtAge(now-it.ts) + " — check the log (l)"
	}
	row := fmt.Sprintf(" %s %s %s %s  %s %3dm%02ds %-5s %s",
		mark, bold.Render(fmt.Sprintf("!%-4s", it.iid)), dim.Render(when),
		segBar(it.phase, m.frame),
		style.Render(fmt.Sprintf("%-10s", it.phase)), el/60, el%60,
		dim.Render(tag), dim.Render(trunc(detail, aw-52)))
	_ = idx // fixer rows are informational — no cursor
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
	if idx == m.selH && m.focus == 1 {
		row = selMark(row, aw)
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
		hub := ""
		if count[p.a] >= 3 {
			hub = p.a
		} else if count[p.b] >= 3 {
			hub = p.b
		}
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

// pipelineLines lists the jobs of an expanded MR's pipeline, wrapped into
// columns so a 20-job pipeline does not push the panel off screen.
func (m model) pipelineLines(iid string, aw int) string {
	c, ok := ciOf(iid)
	if !ok {
		return "\n" + dim.Render("      pipeline: reading…")
	}
	if len(c.jobs) == 0 {
		return "\n" + dim.Render("      pipeline: no jobs")
	}
	head := "\n      " + dim.Render("pipeline ") + ciBar(c, m.frame) + " " + ciCount(c)
	if c.fail > 0 {
		head += red.Render(fmt.Sprintf("%d failed", c.fail))
	} else if c.run > 0 {
		head += amber.Render(fmt.Sprintf("%d running", c.run))
	}
	mark := func(st string) string {
		switch st {
		case "pass":
			return green.Render("✓")
		case "fail":
			return red.Render("✗")
		case "run":
			return amber.Render(string(spinner[m.frame%len(spinner)]))
		case "skip":
			return dim.Render("–")
		}
		return dim.Render("·")
	}
	const colW = 26
	cols := max(1, (aw-8)/colW)
	var out, line strings.Builder
	for i, j := range c.jobs {
		line.WriteString(padTo(" "+mark(j.state)+" "+dim.Render(trunc(j.name, colW-4)), colW))
		if (i+1)%cols == 0 {
			out.WriteString("\n      " + strings.TrimRight(line.String(), " "))
			line.Reset()
		}
	}
	if line.Len() > 0 {
		out.WriteString("\n      " + strings.TrimRight(line.String(), " "))
	}
	return head + out.String()
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
	if m.screen == 2 {
		return m.fleetView()
	}
	if m.screen == 3 {
		return m.runsDetailView(14)
	}
	if m.screen == 5 {
		return m.hotspotsScreen()
	}
	if m.screen == 4 {
		return m.spendDetailView(14)
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
	budgetLine := fmt.Sprintf("%s %s %s/%s", dim.Render("ai-budget"), yellow.Render(gauge(bcur, bmax, 12)), s.budget, s.budgetMax)
	if bmax == 0 {
		budgetLine = fmt.Sprintf("%s %s today · %s", dim.Render("ai-budget"), s.budget, green.Render("∞ unlimited"))
	}
	modelLine2 := dim.Render("model   ") + amber.Render(s.model)
	if s.resolver != "claude" {
		modelLine2 = dim.Render("model   ") + amber.Render(s.model) + dim.Render(" ("+s.resolver+", config.env)")
	}
	pm := green.Render("direct push")
	if s.pushMode == "mr" {
		pm = yellow.Render("via resolution MR")
	}
	deliverLine := dim.Render("deliver ") + pm
	daemonLine := dim.Render("daemon  ") + d
	if !s.daemon {
		daemonLine += dim.Render(" — no ticks, no events")
	}
	fixLine := dim.Render("fixing  ") + green.Render("on") + dim.Render(" — conflicts get resolved")
	if s.dryRun {
		fixLine = dim.Render("fixing  ") + yellow.Render("off") + dim.Render(" — watch only, nothing is merged")
	}
	statusLines := []string{
		fmt.Sprintf("%s %s", amber.Render(string(orbit[m.frame%len(orbit)])),
			time.Now().Format("15:04:05")),
		daemonLine,
		fixLine,
		budgetLine,
		deliverLine,
		modelLine2,
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
			focused := (title == "STATUS" && m.focus == 3) ||
				(title == "RUNS" && m.focus == 4) || (title == "SPEND" && m.focus == 5)
			// clip (ANSI-aware) instead of letting lipgloss wrap — a wrapped
			// line would inflate one box past the shared height
			clipped := make([]string, len(lines))
			for i, ln := range lines {
				clipped[i] = truncate.String(ln, uint(max(1, w-4)))
				if title == "STATUS" && m.focus == 3 && m.screen == 0 && i == m.selS+1 {
					clipped[i] = selMark(clipped[i], w-4)
				}
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
	aw := lw - 4 // content width inside border+padding
	hw := lw - 4
	var act []string
	fixing := map[string]bool{}
	for idx, it := range s.activeRows {
		act = append(act, m.renderRow(it, idx, now, aw))
		fixing[it.iid] = true
	}
	if len(act) == 0 {
		act = append(act, dim.Render(" no active fixers"))
	}
	mrSelIdx := 0
	var mrsRows []string
	if len(s.mrs) > 0 {
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
			switch s.waiters[mr.iid] {
			case "PLANNED":
				gear = yellow.Render("▣ ")
			case "ESCALATED":
				gear = yellow.Render("⚑ ")
			case "DEFERRED":
				gear = dim.Render("… ")
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
			if i == m.selM {
				mrSelIdx = len(mrsRows)
			}
			age := fmtAge(now - mr.updated)
			if mr.updated == 0 {
				age = "  "
			}
			zap := " "
			if hot[mr.iid] {
				zap = yellow.Render("⚡")
			}
			// pipeline: the live job strip when the dashboard has read the
			// jobs, the watcher's one-word dot until then
			pipe := ciDot(mr.ci) + "      "
			if c, ok := ciOf(mr.iid); ok && len(c.jobs) > 0 {
				pipe = ciBar(c, m.frame) + " "
			}
			row := fmt.Sprintf(" %s %s %s %s%s%s %s %s %s", ic, pipe,
				bold.Render(fmt.Sprintf("!%-4s", mr.iid)), gear, zap,
				dim.Render(fmt.Sprintf("%-*s", bcol, trunc(refs[i], bcol))),
				dim.Render(fmt.Sprintf("%3s", age)),
				dim.Render(fmt.Sprintf("%-8s", trunc(mr.author, 8))),
				titleStyled(title, tstyle, aw-(37+bcol)))
			if i == m.selM && m.focus == 0 {
				row = selMark(row, aw)
			}
			if m.expandedMR[mr.iid] {
				row += "\n" + dim.Render(trunc(fmt.Sprintf("      %s → %s · by %s · updated %s ago · CI %s",
					mr.src, mr.tgt, mr.author, age, mr.ci), aw))
				row += m.pipelineLines(mr.iid, aw)
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
			mrsRows = append(mrsRows, row)
		}
	}
	mrsRows = append(mrsRows, m.mrsRadar(aw)...)
	if len(mrsRows) == 0 {
		mrsRows = append(mrsRows, dim.Render(" no open MRs"))
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
	// fixed vertical budget: panels never push the interface off-screen —
	// lists window around their cursor instead (↑/↓ markers show the rest)
	avail := m.height - 3 // banner + footer
	if m.height < 14 {
		avail = m.height - 1
	}
	topH := 6
	histH := 7
	if avail < 24 {
		histH = 5
	}
	// ACTIVE (fixers) is small and fixed; MRS takes the rest. The focused
	// panel may grow (expanded details) at the neighbors' expense — the top
	// strip never moves and nothing exceeds the terminal height.
	lines := func(items []string) int {
		n := 0
		for _, it := range items {
			n += strings.Count(it, "\n") + 1
		}
		return n
	}
	budget := avail - topH
	actWant := lines(act) + 2
	histWant := lines(hist) + 2
	mrsWant := lines(mrsRows) + 2
	const minA, minM, minH = 3, 5, 4
	actH := min(actWant, 6)
	histH = min(histWant, histH)
	if len(m.expanded) > 0 {
		// a run's timeline is open — let HISTORY grow for it
		histH = min(histWant, budget-minA-minM)
	}
	actH = max(actH, minA)
	histH = max(histH, minH)
	mrsH := budget - actH - histH
	if mrsH > mrsWant && m.focus != 0 {
		// hand unused MRS space to HISTORY (more ledger visible)
		extra := mrsH - mrsWant
		histH = min(histWant, histH+extra)
		mrsH = budget - actH - histH
	}
	if mrsH < minM {
		mrsH = minM
		if over := actH + histH + mrsH - budget; over > 0 {
			histH = max(minH, histH-over)
		}
		if over := actH + histH + mrsH - budget; over > 0 {
			actH = max(minA, actH-over)
		}
	}
	actBoxH, mrsBoxH, histBoxH := 0, 0, 0
	if wide {
		act = windowRows(act, min(m.sel, max(0, len(act)-1)), actH-2)
		mrsRows = windowRows(mrsRows, mrSelIdx, mrsH-2)
		hist = windowRows(hist, m.selH, histH-2)
		actBoxH, mrsBoxH, histBoxH = actH-2, mrsH-2, histH-2
	}
	lb.WriteString(titledBox(lw, "ACTIVE", fmt.Sprintf("%d fixers", len(s.activeRows)), strings.Join(act, "\n"), actBoxH, false) + "\n")
	lb.WriteString(titledBox(lw, "MRS", actMeta, strings.Join(mrsRows, "\n"), mrsBoxH, m.focus == 0) + "\n")
	lb.WriteString(titledBox(lw, "HISTORY", fmt.Sprintf("%d", s.tok+s.tbad+s.tesc), strings.Join(hist, "\n"), histBoxH, m.focus == 1) + "\n")

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
			if off > len(wl)-1 {
				off = max(0, len(wl)-1)
			}
			if off > 0 {
				badge = "‖ paused"
			}
			end := len(wl) - off
			start := max(0, end-feedH)
			wl = wl[start:end]
			// with LIVE focused, the cursor line sits at the bottom of the
			// window and j/k walk it line by line
			if m.focus == 2 && len(wl) > 0 {
				wl[len(wl)-1] = selMark(wl[len(wl)-1], liveW-4)
			}
			body = strings.Join(wl, "\n")
		}
		liveBox := titledBox(liveW, "LIVE", badge, body, total-2, m.focus == 2)
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

	// context-sensitive footer: only the keys that apply to the selection
	key := func(k, label string) string { return amber.Render(k) + dim.Render(" "+label) }
	sep := dim.Render(" · ")
	var fk []string
	{
		switch m.focus {
		case 0:
			if r, ok := m.selected(); ok {
				switch m.snap.waiters[r.iid()] {
				case "ESCALATED":
					fk = []string{key("c", "chat"), key("R", "retry"), key("enter", "details"), key("o", "open")}
				case "PLANNED":
					fk = []string{key("a", "approve plan"), key("enter", "details"), key("o", "open")}
				case "DEFERRED":
					fk = []string{key("R", "retry now"), key("enter", "details"), key("o", "open")}
				default:
					fk = []string{key("enter", "details"), key("o", "open"), key("l", "log")}
				}
			}
		case 1:
			fk = []string{key("enter", "timeline"), key("o", "open"), key("l", "log"), key("R", "retry")}
		case 2:
			fk = []string{key("↑↓", "scroll"), key("esc", "follow")}
		case 3:
			fk = []string{key("↑↓", "setting"), key("←→", "change"), key("r", "tick now")}
		case 4, 5:
			fk = []string{key("enter", "full breakdown")}
		}
	}
	fk = append(fk, key("tab", "panel"), key("2", "hotspots"), key("3", "fleet"), key("?", "help"), key("q", "quit"))
	b.WriteString(" " + strings.Join(fk, sep))
	return b.String()
}

func (m model) helpView() string {
	rows := [][2]string{
		{"tab", "cycle: MRS → HISTORY → LIVE → SETTINGS → RUNS → SPEND (enter opens breakdowns)"},
		{"↑↓ / j k", "move / scroll within the focused panel"},
		{"enter", "details: MR info + live pipeline jobs + clashes, or a run's phase timeline"},
		{"o", "open the selected MR/PR in the browser"},
		{"a", "approve the selected plan (▣ rows)"},
		{"c", "chat with the resolver about an escalated MR (⚑ rows) — in place"},
		{"R", "retry the selected MR (clears tried/deferred marks, ticks)"},
		{"l", "fixer/AI log panel for the selected MR"},
		{"1 / 2 / 3", "screens: dashboard / hotspots / fleet"},
		{"", "hotspots: i analyze (cached) · tab+↑↓ scroll answer · ←→ model · y copy prompt"},
		{"r / p", "force a tick / toggle the daemon (settings rows: daemon · fixing · budget · deliver · model)"},
		{"esc", "close things: settings, screens, log, expanded rows, live scroll"},
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
