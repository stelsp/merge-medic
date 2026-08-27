// Small pure helpers: text measurement, wrapping, windows, formatting.
package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// windowRows fits multi-line items into capLines, keeping the selected item
// fully visible and filling around it; ↑/↓ markers show hidden rows exist.
func windowRows(items []string, selIdx, capLines int) []string {
	if capLines <= 0 || len(items) == 0 {
		return nil
	}
	if selIdx < 0 || selIdx >= len(items) {
		selIdx = 0
	}
	h := func(x string) int { return strings.Count(x, "\n") + 1 }
	total := 0
	for _, it := range items {
		total += h(it)
	}
	if total <= capLines {
		return items
	}
	budget := capLines - 1 // reserve a line for the overflow markers
	sel := items[selIdx]
	if hh := h(sel); hh > budget {
		ls := strings.Split(sel, "\n")
		keep := max(1, budget-1)
		sel = strings.Join(ls[:keep], "\n") + "\n" + dim.Render(fmt.Sprintf("      … +%d more lines", hh-keep))
	}
	out := []string{sel}
	used := h(sel)
	up, down := selIdx-1, selIdx+1
	for used < budget && (up >= 0 || down < len(items)) {
		if up >= 0 {
			if hh := h(items[up]); used+hh <= budget {
				out = append([]string{items[up]}, out...)
				used += hh
				up--
			} else {
				up = -1
			}
		}
		if down < len(items) && used < budget {
			if hh := h(items[down]); used+hh <= budget {
				out = append(out, items[down])
				used += hh
				down++
			} else {
				down = len(items)
			}
		}
	}
	marks := ""
	if up >= 0 {
		marks += fmt.Sprintf("↑ %d above", up+1)
	}
	if down < len(items) {
		if marks != "" {
			marks += " · "
		}
		marks += fmt.Sprintf("↓ %d below", len(items)-down)
	}
	if marks != "" {
		out = append(out, dim.Render("  "+marks))
	}
	return out
}

// padTo pads an ANSI-styled string to a visual width (Sprintf counts bytes).
func padTo(sv string, w int) string {
	if pad := w - lipgloss.Width(sv); pad > 0 {
		return sv + strings.Repeat(" ", pad)
	}
	return sv
}

// copyClip puts text on the system clipboard via whichever tool exists
// (macOS, Wayland, X11, WSL). Returns false when none is found.
func copyClip(text string) bool {
	for _, c := range [][]string{
		{"pbcopy"}, {"wl-copy"}, {"xclip", "-selection", "clipboard", "-in"}, {"xsel", "-ib"}, {"clip.exe"},
	} {
		if _, err := exec.LookPath(c[0]); err != nil {
			continue
		}
		cmd := exec.Command(c[0], c[1:]...)
		cmd.Stdin = strings.NewReader(text)
		if cmd.Run() == nil {
			return true
		}
	}
	return false
}

// wrapPlain word-wraps unstyled text to width w (the analysis is plain
// markdown from the model — no ANSI to worry about).
func wrapPlain(s string, w int) []string {
	if w < 8 {
		w = 8
	}
	var out []string
	for _, ln := range strings.Split(s, "\n") {
		r := []rune(ln)
		for len(r) > w {
			cut := w
			for i := w; i > w/2; i-- {
				if r[i] == ' ' {
					cut = i
					break
				}
			}
			out = append(out, string(r[:cut]))
			r = r[cut:]
			for len(r) > 0 && r[0] == ' ' {
				r = r[1:]
			}
		}
		out = append(out, string(r))
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

// nonEmpty filters blank lines in place — it reuses in's backing array, so
// callers must pass a slice they own (every call site passes a fresh Split).
func nonEmpty(in []string) []string {
	out := in[:0]
	for _, s := range in {
		if strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}
