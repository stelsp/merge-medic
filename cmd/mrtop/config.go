// config.env access (read + atomic write) and daemon control.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

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

// boolToConf renders a shell-style flag: config.env uses 1/0, not true/false.
func boolToConf(b bool) string {
	if b {
		return "1"
	}
	return "0"
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

// setDaemon loads or unloads this instance's scheduler job. Blocking (a
// launchctl/systemctl round-trip), so callers run it off the render loop.
func setDaemon(root string, on bool) {
	cmd := "pause"
	if on {
		cmd = "resume"
	}
	_ = exec.Command("bash", filepath.Join(root, "bin", "mrwatch"), cmd).Run()
}

func togglePause(root string) { setDaemon(root, !daemonLoaded(root)) }
