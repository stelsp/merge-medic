// Full-screen views behind the main dashboard: RUNS/SPEND breakdowns,
// the hotspot browser with cached AI analyses, and the fleet screen.
package main

import (
	"crypto/sha1"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// runsDetailView — enter on RUNS: per-day outcome table for two weeks.
func (m model) runsDetailView(nDays int) string {
	s := m.snap
	var b strings.Builder
	b.WriteString(m.renderBanner())
	type day struct{ done, fail, esc, clean, ai int }
	days := make([]day, nDays)
	now := time.Now()
	day0 := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()
	type mrAgg struct{ done, fail, esc int }
	perMR := map[string]*mrAgg{}
	var mrOrder []string
	if data, err := os.ReadFile(filepath.Join(m.root, "state", "history.log")); err == nil {
		for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
			p := strings.Split(ln, "|")
			if len(p) < 3 {
				continue
			}
			ts, _ := strconv.ParseInt(p[0], 10, 64)
			if perMR[p[1]] == nil {
				perMR[p[1]] = &mrAgg{}
				mrOrder = append(mrOrder, p[1])
			}
			switch p[2] {
			case "DONE":
				perMR[p[1]].done++
			case "FAIL":
				perMR[p[1]].fail++
			case "ESCALATED":
				perMR[p[1]].esc++
			}
			age := int((day0 + 86400 - ts) / 86400)
			if age < 0 || age >= nDays {
				continue
			}
			d := &days[nDays-1-age]
			switch p[2] {
			case "DONE":
				d.done++
				if len(p) > 3 && p[3] == "clean" {
					d.clean++
				}
				if len(p) > 3 && p[3] == "ai" {
					d.ai++
				}
			case "FAIL":
				d.fail++
			case "ESCALATED":
				d.esc++
			}
		}
	}
	sort.SliceStable(mrOrder, func(i, j int) bool {
		a, b := perMR[mrOrder[i]], perMR[mrOrder[j]]
		return a.done+a.fail+a.esc > b.done+b.fail+b.esc
	})
	titles := map[string]string{}
	for _, mr := range m.snap.mrs {
		titles[mr.iid] = mr.title
	}
	maxN := 1
	activeDays, totalRuns14 := 0, 0
	for _, d := range days {
		if n := d.done + d.fail + d.esc; n > 0 {
			activeDays++
			totalRuns14 += n
			if n > maxN {
				maxN = n
			}
		}
	}
	bw := m.width
	barW := min(48, max(18, bw-52))
	var rows []string
	rows = append(rows, dim.Render("  day    activity"+strings.Repeat(" ", barW-6)+"✓   ✗   ⚑   clean/ai"))
	for i, d := range days {
		date := time.Unix(day0+86400-int64(nDays-i)*86400, 0).Format("02.01")
		total := d.done + d.fail + d.esc
		if total == 0 {
			rows = append(rows, dim.Render("  "+date+"   ·"))
			continue
		}
		w := max(1, total*barW/maxN)
		bar := green.Render(strings.Repeat("█", w*d.done/total)) +
			red.Render(strings.Repeat("█", w*d.fail/total)) +
			yellow.Render(strings.Repeat("█", w*d.esc/total))
		rows = append(rows, fmt.Sprintf("  %s  %s%s %s %s   %s",
			dim.Render(date), padTo(bar, barW+2),
			green.Render(fmt.Sprintf("%3d", d.done)), red.Render(fmt.Sprintf("%3d", d.fail)),
			yellow.Render(fmt.Sprintf("%3d", d.esc)),
			dim.Render(fmt.Sprintf("%d/%d", d.clean, d.ai))))
	}
	rows = append(rows, "",
		fmt.Sprintf("  all time: %s %s %s · %d clean merges · %d AI resolutions",
			green.Render(fmt.Sprintf("%d✓", s.tok)), red.Render(fmt.Sprintf("%d✗", s.tbad)),
			yellow.Render(fmt.Sprintf("%d⚑", s.tesc)), s.tclean, s.tai))
	if allRuns := s.tok + s.tbad + s.tesc; allRuns > 0 {
		line := fmt.Sprintf("  success rate %d%%", s.tok*100/allRuns)
		if activeDays > 0 {
			line += fmt.Sprintf(" · %.1f runs per active day (14d)", float64(totalRuns14)/float64(activeDays))
		}
		rows = append(rows, dim.Render(line))
	}

	// what kind of work is even open right now
	kinds := map[string]int{}
	for _, mr := range m.snap.mrs {
		k := "other"
		if i := strings.IndexAny(mr.title, ":(!"); i > 0 {
			switch mr.title[:i] {
			case "feat":
				k = "feat"
			case "fix", "hotfix":
				k = "fix"
			case "docs", "chore", "refactor", "test", "ci", "build":
				k = "chore"
			}
		}
		kinds[k]++
	}
	if len(m.snap.mrs) > 0 {
		rows = append(rows, fmt.Sprintf("  open now: %s · %s · %s · %s",
			green.Render(fmt.Sprintf("%d feat", kinds["feat"])),
			yellow.Render(fmt.Sprintf("%d fix", kinds["fix"])),
			dim.Render(fmt.Sprintf("%d chore/docs", kinds["chore"])),
			dim.Render(fmt.Sprintf("%d other", kinds["other"]))))
	}

	rows = append(rows, "", dim.Render("  per MR, all time (runs: ✓ fixed · ✗ failed · ⚑ escalated):"))
	shown := 0
	for _, iid := range mrOrder {
		if shown >= 12 {
			rows = append(rows, dim.Render(fmt.Sprintf("   +%d more MRs", len(mrOrder)-shown)))
			break
		}
		a := perMR[iid]
		t := titles[iid]
		if t == "" {
			t = "(closed)"
		}
		rows = append(rows, fmt.Sprintf("   %s %s %s %s  %s",
			bold.Render(fmt.Sprintf("!%-5s", iid)),
			green.Render(fmt.Sprintf("%d✓", a.done)), red.Render(fmt.Sprintf("%d✗", a.fail)),
			yellow.Render(fmt.Sprintf("%d⚑", a.esc)), dim.Render(trunc(t, max(30, bw-28)))))
		shown++
	}
	b.WriteString(titledBox(bw, "RUNS", "last 14 days", strings.Join(rows, "\n"), 0, true) + "\n")
	b.WriteString(" " + amber.Render("esc") + dim.Render(" back · ") + amber.Render("q") + dim.Render(" quit"))
	return b.String()
}

// spendDetailView — enter on SPEND: $/day table, per-model, top runs.
func (m model) spendDetailView(nDays int) string {
	s := m.snap
	var b strings.Builder
	b.WriteString(m.renderBanner())
	maxS := 0.001
	for _, v := range s.spendDaily {
		if v > maxS {
			maxS = v
		}
	}
	now := time.Now()
	day0 := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()
	bw := m.width
	barW := min(48, max(18, bw-52))
	var rows []string
	rows = append(rows, dim.Render("  day    spend"))
	sd := s.spendDaily
	if len(sd) > nDays {
		sd = sd[len(sd)-nDays:]
	}
	week := 0.0
	for i, v := range sd {
		date := time.Unix(day0+86400-int64(len(sd)-i)*86400, 0).Format("02.01")
		if len(sd)-i <= 7 {
			week += v
		}
		if v < 0.005 {
			rows = append(rows, dim.Render("  "+date+"   ·"))
			continue
		}
		bar := amber.Render(strings.Repeat("█", max(1, int(v/maxS*float64(barW)))))
		rows = append(rows, fmt.Sprintf("  %s  %s $%.2f",
			dim.Render(date), padTo(bar, barW+2), v))
	}
	// call count + token volume, straight from the ledger
	calls, tin, tout := 0, int64(0), int64(0)
	if data, err := os.ReadFile(filepath.Join(m.root, "state", "tokens.log")); err == nil {
		for _, ln := range nonEmpty(strings.Split(string(data), "\n")) {
			p := strings.Split(ln, "|")
			if len(p) < 7 {
				continue
			}
			calls++
			in, _ := strconv.ParseInt(p[3], 10, 64)
			out, _ := strconv.ParseInt(p[4], 10, 64)
			tin += in
			tout += out
		}
	}
	rows = append(rows, "", fmt.Sprintf("  today ≈$%.2f · all time $%.2f", s.spendToday, s.spend))
	if calls > 0 {
		rows = append(rows, dim.Render(fmt.Sprintf("  %d AI calls · avg $%.2f/call · tokens %s in → %s out",
			calls, s.spend/float64(calls), fmtTok(tin), fmtTok(tout))))
	}
	if week > 0.005 {
		rows = append(rows, dim.Render(fmt.Sprintf("  ≈$%.2f/month at the last-7-days pace", week/7*30)))
	}
	if s.modelLine != "" {
		rows = append(rows, "", dim.Render("  per model:"))
		for _, part := range strings.Split(s.modelLine, " · ") {
			rows = append(rows, "   "+dim.Render(part))
		}
	}
	rows = append(rows, "", dim.Render("  most expensive runs:"))
	for _, r := range s.topRuns {
		short := r.model
		if i := strings.Index(short, "claude-"); i >= 0 {
			short = short[i+7:]
		}
		rows = append(rows, fmt.Sprintf("   %s %s %s %s",
			amber.Render(fmt.Sprintf("$%.2f", r.cost)), bold.Render(fmt.Sprintf("!%-5s", r.iid)),
			dim.Render(fmt.Sprintf("%-14s", trunc(short, 14))),
			dim.Render(time.Unix(r.ts, 0).Format("02.01 15:04"))))
	}
	b.WriteString(titledBox(bw, "SPEND", "last 14 days + top runs", strings.Join(rows, "\n"), 0, true) + "\n")
	b.WriteString(" " + amber.Render("esc") + dim.Render(" back · ") + amber.Render("q") + dim.Render(" quit"))
	return b.String()
}

// hotspotModel returns the model used for hotspot analyses — its own knob
// (HOTSPOT_MODEL), falling back to the resolver's CLAUDE_MODEL.
func hotspotModel(root string) string {
	return readConfigVal(root, "HOTSPOT_MODEL", readConfigVal(root, "CLAUDE_MODEL", "sonnet"))
}

// hotspotCache returns the analysis cache path for a hotspot — keyed by
// (file, conflict count, model) so the text stays STABLE until new conflicts
// land, while each model keeps its own answer.
func hotspotCache(root string, h hotspot, model string) string {
	sum := sha1.Sum([]byte(fmt.Sprintf("%s|%d|%s", h.file, h.count, model)))
	return filepath.Join(root, "state", fmt.Sprintf("ai-hotspot-%x.md", sum[:6]))
}

// hotspotPrompt builds the analysis prompt — also what `y` copies to the
// clipboard for pasting into any external model.
func hotspotPrompt(root string, h hotspot) string {
	repo := readConfigVal(root, "WATCH_REPO", "")
	if home, err := os.UserHomeDir(); err == nil {
		repo = strings.ReplaceAll(repo, "$HOME", home)
	}
	gitlog := ""
	if repo != "" {
		if out, err := exec.Command("git", "-C", repo, "log", "--oneline", "-15", "--", h.file).Output(); err == nil {
			gitlog = string(out)
		}
	}
	return fmt.Sprintf(`The file %s keeps causing merge conflicts in this repository: %d AI-resolved conflicts so far, in MRs %s.

Recent commits touching it:
%s

In 8-12 lines of GitHub-flavored markdown, explain: (1) WHY this file is likely a conflict magnet (structure? shared hotspot section? append-only list?), (2) 2-3 CONCRETE ways to stop the conflicts (split points, ownership, serialization), (3) which option you would pick. No preamble.`,
		h.file, h.count, "!"+strings.Join(h.mrs, " !"), gitlog)
}

// analyzeHotspot generates the explanation once and caches it (atomic write;
// a .run marker shows progress).
func analyzeHotspot(root string, h hotspot, model string) {
	cache := hotspotCache(root, h, model)
	if _, err := os.Stat(cache); err == nil {
		return
	}
	run := cache + ".run"
	if f, err := os.OpenFile(run, os.O_CREATE|os.O_EXCL, 0o644); err != nil {
		return // already running
	} else {
		f.Close()
	}
	defer os.Remove(run)
	out, err := exec.Command("claude", "-p", hotspotPrompt(root, h), "--model", model).Output()
	if err != nil || len(out) == 0 {
		return
	}
	tmp := cache + ".tmp"
	if os.WriteFile(tmp, out, 0o644) == nil {
		_ = os.Rename(tmp, cache)
	}
}

// hotspotAnswer returns the wrapped analysis lines for the selected hotspot
// plus how many the WHY panel can show — shared by the renderer and the
// scroll clamp in Update. state: ready | running | empty | none.
func (m model) hotspotAnswer() (lines []string, capL int, state string) {
	nRows := max(1, len(m.snap.hotspots))
	// banner(2) + list box(nRows+2) + WHY borders(2) + footer(1) + slack(2)
	capL = max(4, m.height-nRows-9)
	if m.selHot >= len(m.snap.hotspots) {
		return nil, capL, "none"
	}
	h := m.snap.hotspots[m.selHot]
	cache := hotspotCache(m.root, h, hotspotModel(m.root))
	if data, err := os.ReadFile(cache); err == nil {
		for _, ln := range wrapPlain(strings.TrimSpace(string(data)), m.width-6) {
			lines = append(lines, " "+ln)
		}
		return lines, capL, "ready"
	}
	if _, err := os.Stat(cache + ".run"); err == nil {
		return nil, capL, "running"
	}
	return nil, capL, "empty"
}

// hotspotsScreen — the full-screen hotspot browser with on-demand AI analysis.
// tab moves between the file list and the answer; the answer takes all the
// remaining height and scrolls.
func (m model) hotspotsScreen() string {
	s := m.snap
	bw := m.width
	var b strings.Builder
	b.WriteString(m.renderBanner())
	var rows []string
	if len(s.hotspots) == 0 {
		rows = append(rows, dim.Render(" no archived AI runs yet"))
	}
	maxC := 1
	if len(s.hotspots) > 0 {
		maxC = s.hotspots[0].count
	}
	fileW := max(20, bw-44)
	for i, h := range s.hotspots {
		row := fmt.Sprintf(" %s %s %s %s",
			amber.Render(fmt.Sprintf("%3d×", h.count)),
			yellow.Render(strings.Repeat("▪", max(1, h.count*12/maxC))),
			trunc(h.file, fileW),
			dim.Render("in !"+strings.Join(h.mrs, " !")))
		if i == m.selHot {
			row = selMark(row, bw-6)
		}
		rows = append(rows, row)
	}
	b.WriteString(titledBox(bw, "HOTSPOTS", "conflict magnets · i = AI analysis", strings.Join(rows, "\n"), 0, m.hotFocus == 0) + "\n")

	// answer panel for the selected file — fills the rest of the screen
	lines, capL, state := m.hotspotAnswer()
	body := dim.Render(" press i — the resolver explains why this file clashes and how to stop it\n" +
		" (generated once per state; the text stays stable until new conflicts land)")
	switch state {
	case "running":
		body = amber.Render(" " + string(spinner[m.frame%len(spinner)]) + " analyzing… (the answer will be cached)")
	case "ready":
		off := min(m.hotOff, max(0, len(lines)-capL))
		end := min(len(lines), off+capL)
		vis := append([]string{}, lines[off:end]...)
		if off > 0 {
			vis[0] = dim.Render(fmt.Sprintf(" ↑ %d more", off))
		}
		if rem := len(lines) - end; rem > 0 && len(vis) > 0 {
			vis[len(vis)-1] = dim.Render(fmt.Sprintf(" ↓ %d more — tab + ↑↓ to scroll", rem))
		}
		body = strings.Join(vis, "\n")
	}
	meta := trunc(s.hotspots[min(m.selHot, max(0, len(s.hotspots)-1))].file, bw-40)
	if len(s.hotspots) == 0 {
		meta = ""
	}
	meta += " · model " + hotspotModel(m.root)
	b.WriteString(titledBox(bw, "WHY", meta, body, capL, m.hotFocus == 1) + "\n")

	if m.flash != "" && m.frame-m.flashFrame < 6 {
		b.WriteString(" " + amber.Render("✔ "+m.flash))
		return b.String()
	}
	if m.hotFocus == 1 {
		b.WriteString(" " + amber.Render("↑↓") + dim.Render(" scroll · ") + amber.Render("tab") + dim.Render(" files · ") +
			amber.Render("y") + dim.Render(" copy prompt · ") + amber.Render("esc") + dim.Render(" back"))
	} else {
		b.WriteString(" " + amber.Render("↑↓") + dim.Render(" file · ") + amber.Render("tab") + dim.Render(" answer · ") +
			amber.Render("i") + dim.Render(" analyze · ") + amber.Render("←→") + dim.Render(" model · ") +
			amber.Render("y") + dim.Render(" copy prompt · ") + amber.Render("esc") + dim.Render(" back · ") + amber.Render("q") + dim.Render(" quit"))
	}
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
		// live work: non-terminal progress files younger than an hour
		working := 0
		progFiles, _ := filepath.Glob(filepath.Join(root, "state", "progress-*.log"))
		for _, pf := range progFiles {
			if fi, err := os.Stat(pf); err != nil || time.Since(fi.ModTime()) > time.Hour {
				continue
			}
			if data, err := os.ReadFile(pf); err == nil {
				ls := nonEmpty(strings.Split(string(data), "\n"))
				if len(ls) > 0 {
					lp := strings.SplitN(ls[len(ls)-1], "|", 3)
					if len(lp) > 1 && !terminal(lp[1]) {
						working++
					}
				}
			}
		}
		wk := ""
		if working > 0 {
			wk = amber.Render(fmt.Sprintf(" ⚙ %d fixing", working))
		}
		row := fmt.Sprintf(" %s%s %s %s · daemon %s · ai %s today%s%s", cur,
			bold.Render(fmt.Sprintf("%-16s", name)), dim.Render(fmt.Sprintf("%-7s", pv)),
			trunc(pp, 40), d, spent, st, wk)
		if i == m.selF {
			row = selMark(row, m.width-4)
		}
		rows = append(rows, row)
	}
	b.WriteString(titledBox(m.width, "FLEET", fmt.Sprintf("%d instances", len(insts)), strings.Join(rows, "\n"), 0, true) + "\n")
	b.WriteString(" " + amber.Render("↑↓") + dim.Render(" move · ") + amber.Render("enter") + dim.Render(" switch dashboard to instance · ") + amber.Render("1") + dim.Render(" main · ") + amber.Render("q") + dim.Render(" quit"))
	return b.String()
}
