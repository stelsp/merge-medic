// Key handling and the actions keys trigger (config writes, approve,
// retry, chat, clipboard).
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

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

// adjustSetting changes the selected STATUS row by dir (-1 / +1) and writes
// it straight to config.env — arrows are the whole interaction.
func (m *model) adjustSetting(dir int) {
	switch m.selS {
	case 0: // daemon: → starts the scheduler, ← stops it (same job as `p`)
		on := dir > 0
		if on == m.snap.daemon {
			return
		}
		m.snap.daemon = on
		m.daemonWant, m.daemonWantTicks = on, 20 // ~10s of grace
		go setDaemon(m.root, on)
	case 1: // fixing: DRY_RUN inverted — off keeps every event, skips the merge
		dry := !m.snap.dryRun
		setConfigVal(m.root, "DRY_RUN", boolToConf(dry))
		m.snap.dryRun = dry
	case 2: // ai budget; 0 = unlimited
		cur, _ := strconv.Atoi(m.snap.budgetMax)
		cur += dir
		if cur < 0 {
			cur = 0
		}
		setConfigVal(m.root, "DAILY_AGENT_RUNS", strconv.Itoa(cur))
		m.snap.budgetMax = strconv.Itoa(cur)
	case 3: // delivery
		mode := "mr"
		if m.snap.pushMode == "mr" {
			mode = "direct"
		}
		setConfigVal(m.root, "PUSH_MODE", "\""+mode+"\"")
		m.snap.pushMode = mode
	case 4: // model (claude only)
		if m.snap.resolver != "claude" {
			return
		}
		order := []string{"opus", "sonnet", "haiku"}
		i := 0
		for j, o := range order {
			if o == m.snap.model {
				i = j
			}
		}
		i = (i + dir + len(order)) % len(order)
		setConfigVal(m.root, "CLAUDE_MODEL", "\""+order[i]+"\"")
		m.snap.model = order[i]
	}
}

// logPanelHeight is how many lines the log panel shows — a slice of the
// frame, never more than a third of it.
func (m model) logPanelHeight() int {
	h := m.height/3 - 2
	if h < 6 {
		h = 6
	}
	if h > 20 {
		h = 20
	}
	return h
}

// refreshLog reloads the panel for the current selection. With nothing
// selected it clears: the panel used to keep a merged MR's log under a live
// MR's header.
func (m *model) refreshLog() {
	r, ok := m.selected()
	if !ok {
		m.logName, m.logOther, m.logLines = "", "", nil
		return
	}
	m.logName, m.logOther, m.logLines = readLog(m.root, r.iid(), m.logPanelHeight()+m.logOff)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tickMsg:
		m.snap = readSnapshot(m.root)
		if m.daemonWantTicks > 0 {
			m.daemonWantTicks--
			if m.snap.daemon == m.daemonWant {
				m.daemonWantTicks = 0 // the scheduler caught up
			} else {
				m.snap.daemon = m.daemonWant
			}
		}
		if n := len(m.activeRefs()); m.sel >= n {
			m.sel = max(0, n-1)
		}
		if n := len(m.histRefs()); m.selH >= n {
			m.selH = max(0, n-1)
		}
		if n := len(m.mrRefs()); m.selM >= n {
			m.selM = max(0, n-1)
		}
		if n := len(m.snap.hotspots); m.selHot >= n {
			m.selHot = max(0, n-1)
		}
		if m.showLog {
			m.refreshLog()
		}
		if n := len(m.snap.feed); n > 0 {
			if m.snap.feed[n-1] != m.lastFeed {
				m.lastFeed = m.snap.feed[n-1]
				m.typeK = 0 // a fresh line starts typing itself
			} else {
				m.typeK += 16
			}
		}
		m.frame++
		m.pollCI()
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
			m.screen = 5
		case "3":
			m.screen = 2
		case "esc":
			if m.screen != 0 {
				m.screen = 0
				m.hotFocus, m.hotOff = 0, 0
				break
			}
			m.showHelp = false
			m.showLog = false
			m.liveOff = 0
			m.expanded = map[string]bool{}
			m.expandedMR = map[string]bool{}
		case "tab":
			if m.screen == 5 {
				m.hotFocus = 1 - m.hotFocus
				break
			}
			m.focus = (m.focus + 1) % 6
		case "up", "k":
			if m.showLog && m.screen == 0 {
				m.logOff++
				m.refreshLog()
				break
			}
			if m.screen == 2 {
				if m.selF > 0 {
					m.selF--
				}
				break
			}
			if m.screen == 5 {
				if m.hotFocus == 1 {
					if m.hotOff > 0 {
						m.hotOff--
					}
				} else if m.selHot > 0 {
					m.selHot--
					m.hotOff = 0
				}
				break
			}
			if m.focus == 3 {
				if m.selS > 0 {
					m.selS--
				}
				break
			}
			switch m.focus {
			case 0:
				if m.selM > 0 {
					m.selM--
				}
			case 1:
				if m.selH > 0 {
					m.selH--
				}
			case 2:
				m.liveOff++
			}
		case "down", "j":
			if m.showLog && m.screen == 0 {
				m.logOff = max(0, m.logOff-1)
				m.refreshLog()
				break
			}
			if m.screen == 2 {
				if m.selF < len(readInstances())-1 {
					m.selF++
				}
				break
			}
			if m.screen == 5 {
				if m.hotFocus == 1 {
					if lines, capL, _ := m.hotspotAnswer(); m.hotOff < len(lines)-capL {
						m.hotOff++
					}
				} else if m.selHot < len(m.snap.hotspots)-1 {
					m.selHot++
					m.hotOff = 0
				}
				break
			}
			if m.focus == 3 {
				if m.selS < 4 {
					m.selS++
				}
				break
			}
			switch m.focus {
			case 0:
				if m.selM < len(m.mrRefs())-1 {
					m.selM++
				}
			case 1:
				if m.selH < len(m.histRefs())-1 {
					m.selH++
				}
			case 2:
				m.liveOff = max(0, m.liveOff-1)
			}
		case "enter", "e":
			if m.screen == 0 && m.focus == 4 {
				m.screen = 3
				break
			}
			if m.screen == 0 && m.focus == 5 {
				m.screen = 4
				break
			}
			if m.screen == 2 {
				insts := readInstances()
				if m.selF >= 0 && m.selF < len(insts) {
					m.root = insts[m.selF]
					m.snap = readSnapshot(m.root)
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
			m.logOff = 0
			if m.showLog {
				m.refreshLog()
			}
		case "a":
			if r, ok := m.selected(); ok && m.snap.waiters[r.iid()] == "PLANNED" {
				iid := r.iid()
				_ = os.Remove(filepath.Join(m.root, "state", "tried-"+iid))
				_ = os.Remove(filepath.Join(m.root, "state", "dry-"+iid))
				if f, err := os.Create(filepath.Join(m.root, "state", "approve-"+iid)); err == nil {
					_ = f.Close()
				}
				c := exec.Command("bash", filepath.Join(m.root, "watch.sh"))
				_ = c.Start()
			}
		case "i":
			if m.screen == 5 && m.selHot < len(m.snap.hotspots) {
				go analyzeHotspot(m.root, m.snap.hotspots[m.selHot], hotspotModel(m.root))
				m.hotOff = 0
			}
		case "y":
			if m.screen == 5 && m.selHot < len(m.snap.hotspots) {
				if copyClip(hotspotPrompt(m.root, m.snap.hotspots[m.selHot])) {
					m.flash, m.flashFrame = "prompt copied to clipboard", m.frame
				} else {
					m.flash, m.flashFrame = "no clipboard tool found", m.frame
				}
			}
		case "left", "h":
			if m.screen == 5 {
				m.cycleHotspotModel(-1)
				break
			}
			if m.focus == 3 && m.screen == 0 {
				m.adjustSetting(-1)
			}
		case "right":
			if m.screen == 5 {
				m.cycleHotspotModel(1)
				break
			}
			if m.focus == 3 && m.screen == 0 {
				m.adjustSetting(1)
			}
		case "c":
			if r, ok := m.selected(); ok {
				iid := r.iid()
				// the chat runs IN THIS terminal: the TUI suspends, the
				// resolver session takes over, and the dashboard returns on
				// exit. cwd is pinned to the instance root so the folder-trust
				// prompt happens once, ever.
				cmd := exec.Command("bash", filepath.Join(m.root, "bin", "mrwatch"), "chat", iid)
				cmd.Dir = m.root
				return m, tea.ExecProcess(cmd, func(error) tea.Msg { return tickMsg(time.Now()) })
			}
		case "R":
			if r, ok := m.selected(); ok {
				iid := r.iid()
				_ = os.Remove(filepath.Join(m.root, "state", "tried-"+iid))
				_ = os.Remove(filepath.Join(m.root, "state", "dry-"+iid))
				_ = os.Remove(filepath.Join(m.root, "state", "deferred-"+iid))
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

// cycleHotspotModel steps HOTSPOT_MODEL through the claude tiers.
func (m *model) cycleHotspotModel(dir int) {
	order := []string{"opus", "sonnet", "haiku"}
	i := 0
	for j, o := range order {
		if o == hotspotModel(m.root) {
			i = j
		}
	}
	i = (i + dir + len(order)) % len(order)
	setConfigVal(m.root, "HOTSPOT_MODEL", "\""+order[i]+"\"")
	m.hotOff = 0 // a different model means a different cached answer
}
