// The dashboard model and row addressing: which panel has focus, which
// row is selected, and how selectable rows are enumerated.
package main

type model struct {
	root       string
	snap       snapshot
	sel        int // cursor within the focused panel
	focus      int // 0 MRS · 1 HISTORY · 2 LIVE · 3 SETTINGS · 4 RUNS · 5 SPEND
	selH       int // HISTORY cursor (kept when switching focus)
	liveOff    int // lines scrolled up from the tail of LIVE (0 = follow)
	expanded   map[string]bool
	expandedMR map[string]bool
	showLog    bool
	logName    string
	logLines   []string
	frame      int
	width      int
	height     int
	showHelp   bool
	screen     int    // 0 = main, 1 = insights, 2 = fleet
	selF       int    // fleet cursor
	lastFeed   string // newest feed line, for the typewriter effect
	typeK      int    // typed width of the newest feed line
	selS       int    // STATUS settings cursor: 0 budget · 1 deliver · 2 model
	selM       int    // MRS cursor
	selHot     int    // hotspots screen cursor
	hotFocus   int    // hotspots screen: 0 = file list, 1 = answer panel
	hotOff     int    // scroll offset inside the answer panel (0 = top)
	flash      string // transient footer notice ("prompt copied")
	flashFrame int    // frame the notice was set on (shown for ~3s)
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
	return out
}

func (m model) mrRefs() []rowRef {
	var out []rowRef
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

func (m model) selected() (rowRef, bool) {
	var rows []rowRef
	var sel int
	switch m.focus {
	case 0:
		rows, sel = m.mrRefs(), m.selM
	case 1:
		rows, sel = m.histRefs(), m.selH
	default:
		return rowRef{}, false
	}
	if sel >= 0 && sel < len(rows) {
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
