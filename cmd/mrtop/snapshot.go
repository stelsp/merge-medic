// Reading watcher state from disk into one immutable snapshot per tick:
// fixer states, MR list, history ledger, token spend, hotspots, live feed.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// item is one row: a live fixer or a finished run from the ledger.
type item struct {
	iid, phase, detail string
	t0, ts             int64
	active             bool
	mode               string // clean | ai | none (history rows)
	runFile            string // per-run phase archive, "" for live rows
}

func (it item) key() string { return it.iid + "@" + strconv.FormatInt(it.t0, 10) }

type mrState struct {
	iid, status, src, tgt, ci, author, title string
	updated                                  int64
}

type radarPair struct{ a, b, srcA, srcB string }

type snapshot struct {
	activeRows, histRows []item
	mrs                  []mrState
	budget, budgetMax    string
	daemon               bool
	dryRun               bool // DRY_RUN=1: watch and report, never merge or push
	ok, bad, esc         int
	tok, tbad, tesc      int
	tclean, tai          int
	waiters              map[string]string // iid -> PLANNED|ESCALATED|DEFERRED
	radarPairs           []radarPair       // brewing MR-vs-MR conflict pairs
	feed                 []string          // pre-rendered live feed lines, oldest first
	daily                []int             // DONE per day, last 14 days, oldest first
	spendToday, spend    float64           // USD, from the CLI's own accounting
	modelLine            string            // per-model tokens/cost breakdown
	pushMode             string            // direct | mr (from config.env)
	resolver             string            // claude | aider | custom
	model                string            // active resolver model
	lastTick             int64             // mtime of watch.log (0 = unknown)
	lastErr              string            // recent ERROR line from watch.log, "" if none
	lastErrTs            int64
	hotspots             []hotspot // most-conflicted files, all time
	spendDaily           []float64 // USD per day, last 14 days, oldest first
	topRuns              []costRun // most expensive AI runs
}

type hotspot struct {
	file  string
	count int
	mrs   []string // which MRs it conflicted in
	last  int64    // most recent conflict involving this file
}

type costRun struct {
	iid, model string
	cost       float64
	ts         int64
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

// readTokens aggregates state/tokens.log (ts|iid|model|in|out|cache|cost).
func readTokens(root string, day0 int64) (today, total float64, modelLine string) {
	data, err := os.ReadFile(filepath.Join(root, "state", "tokens.log"))
	if err != nil {
		return 0, 0, ""
	}
	type agg struct {
		in, out int64
		cost    float64
	}
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
	s.dryRun = readConfigVal(root, "DRY_RUN", "1") == "1"
	s.pushMode = readConfigVal(root, "PUSH_MODE", "direct")
	s.resolver = readConfigVal(root, "RESOLVER", "claude")
	if s.resolver == "claude" {
		s.model = readConfigVal(root, "CLAUDE_MODEL", "opus")
	} else {
		s.model = readConfigVal(root, "RESOLVER_MODEL", "?")
	}

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
		// waiting states (PLANNED/ESCALATED/DEFERRED) surface on the MR row
		// in MRS; ACTIVE keeps only actually-running fixers
		if it.phase == "PLANNED" || it.phase == "ESCALATED" || it.phase == "DEFERRED" {
			if s.waiters == nil {
				s.waiters = map[string]string{}
			}
			s.waiters[it.iid] = it.phase
			continue
		}
		if terminal(it.phase) {
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
			// PLANNED/ESCALATED entries whose progress file still shows that
			// state are waiters in ACTIVE — skip the ledger duplicate here
			if it.phase == "PLANNED" {
				continue
			}
			if it.phase == "ESCALATED" && s.waiters[it.iid] == "ESCALATED" {
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
		if len(s.topRuns) > 8 {
			s.topRuns = s.topRuns[:8]
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

	// hotspots: conflicted files across all archived runs, with the MRs
	// they conflicted in and the most recent occurrence
	fileCount := map[string]int{}
	fileMRs := map[string]map[string]bool{}
	fileLast := map[string]int64{}
	if runFiles, err := filepath.Glob(filepath.Join(root, "state", "runs", "*.log")); err == nil {
		for _, rf := range runFiles {
			iid := strings.SplitN(filepath.Base(rf), "-", 2)[0]
			data, err := os.ReadFile(rf)
			if err != nil {
				continue
			}
			for _, ln := range strings.Split(string(data), "\n") {
				parts := strings.SplitN(ln, "|", 3)
				if len(parts) < 3 || (parts[1] != "AI_RESOLVE" && parts[1] != "PLAN") {
					continue
				}
				ts, _ := strconv.ParseInt(parts[0], 10, 64)
				d := parts[2]
				if i := strings.Index(d, "file(s): "); i >= 0 {
					for _, f := range strings.Fields(d[i+9:]) {
						fileCount[f]++
						if fileMRs[f] == nil {
							fileMRs[f] = map[string]bool{}
						}
						fileMRs[f][iid] = true
						if ts > fileLast[f] {
							fileLast[f] = ts
						}
					}
				}
			}
		}
	}
	for f, c := range fileCount {
		var mrs []string
		for iid := range fileMRs[f] {
			mrs = append(mrs, iid)
		}
		sort.Strings(mrs)
		s.hotspots = append(s.hotspots, hotspot{f, c, mrs, fileLast[f]})
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
	// a waiter whose MR is no longer open was resolved by hand
	openNow := map[string]bool{}
	for _, mr := range s.mrs {
		openNow[mr.iid] = true
	}
	for iid := range s.waiters {
		if !openNow[iid] {
			delete(s.waiters, iid)
		}
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
