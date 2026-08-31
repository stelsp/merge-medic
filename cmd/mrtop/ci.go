// Live pipeline progress. The watcher only records a one-word CI state per
// MR (it must stay cheap at 180s intervals); the dashboard polls the jobs of
// whatever is actually moving every few seconds, so a running pipeline fills
// up in front of the user.
package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ciJob is one pipeline job / status check, reduced to a state the UI colors.
type ciJob struct {
	name  string
	state string // pass | fail | run | wait | skip
}

// ciStatus is the latest known pipeline of one MR.
type ciStatus struct {
	jobs                  []ciJob
	pass, fail, run, wait int
	fetched               int64 // unix time of the last read attempt
	fetching              bool
}

func (c ciStatus) done() bool { return c.run == 0 && c.wait == 0 }

var (
	ciMu    sync.Mutex
	ciCache = map[string]*ciStatus{} // iid -> status
)

// ciOf returns a copy of the cached pipeline of an MR; ok is false when it
// has never been read (the row then falls back to the watcher's CI dot).
func ciOf(iid string) (ciStatus, bool) {
	ciMu.Lock()
	defer ciMu.Unlock()
	c, ok := ciCache[iid]
	if !ok || c.fetched == 0 {
		return ciStatus{}, false
	}
	return *c, true
}

// ciState normalizes GitHub and GitLab spellings into the five UI states.
func ciState(s string) string {
	switch strings.ToLower(s) {
	case "success", "passed", "neutral":
		return "pass"
	case "failure", "failed", "error", "timed_out", "canceled", "cancelled", "action_required":
		return "fail"
	case "in_progress", "running", "pending", "queued", "expected", "created", "preparing", "waiting_for_resource":
		return "run"
	case "skipped", "manual", "scheduled":
		return "skip"
	}
	return "wait"
}

// ciRunningState: watcher-level CI words that keep changing on their own.
func ciRunningState(ci string) bool {
	switch ci {
	case "running", "pending", "created", "preparing", "waiting_for_resource", "scheduled":
		return true
	}
	return false
}

// pollInterval: a moving pipeline is worth a call every few seconds; a
// finished one only needs an occasional confirmation.
func pollInterval(c *ciStatus) int64 {
	if c == nil || c.fetched == 0 {
		return 0
	}
	if c.done() {
		return 60
	}
	return 5
}

// pollCI refreshes the pipelines worth watching — everything still moving,
// plus the row the user is on or has expanded. Fetches run off the render
// loop; results land in ciCache and show up on the next frame.
func (m model) pollCI() {
	if m.screen != 0 {
		return
	}
	now := time.Now().Unix()
	sel := ""
	if m.selM < len(m.snap.mrs) {
		sel = m.snap.mrs[m.selM].iid
	}
	// the row under the cursor (and any expanded one) comes first: that is
	// the pipeline the user is actually watching
	var want []string
	for _, mr := range m.snap.mrs {
		if mr.iid == sel || m.expandedMR[mr.iid] {
			want = append(want, mr.iid)
		}
	}
	for _, mr := range m.snap.mrs {
		if !ciRunningState(mr.ci) || mr.iid == sel || m.expandedMR[mr.iid] {
			continue
		}
		want = append(want, mr.iid)
	}
	// GitLab costs two API calls per MR — keep the fan-out small, the rest
	// of the list catches up on later frames
	if len(want) > 4 {
		want = want[:4]
	}
	ciMu.Lock()
	var launch []string
	for _, iid := range want {
		c := ciCache[iid]
		if c == nil {
			c = &ciStatus{}
			ciCache[iid] = c
		}
		if c.fetching || now-c.fetched < pollInterval(c) {
			continue
		}
		c.fetching = true
		launch = append(launch, iid)
	}
	ciMu.Unlock()
	for _, iid := range launch {
		go fetchCI(m.root, iid)
	}
}

// ciSettle waits for the in-flight fetches, so a one-shot snapshot can show
// pipelines too (the live TUI never waits — it just renders the next frame).
func ciSettle(d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		ciMu.Lock()
		busy := false
		for _, c := range ciCache {
			if c.fetching {
				busy = true
				break
			}
		}
		ciMu.Unlock()
		if !busy {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// fetchCI reads one MR's jobs from the forge and stores them in the cache.
func fetchCI(root, iid string) {
	jobs, ok := readJobs(root, iid)
	ciMu.Lock()
	defer ciMu.Unlock()
	c := ciCache[iid]
	if c == nil {
		c = &ciStatus{}
		ciCache[iid] = c
	}
	c.fetching = false
	c.fetched = time.Now().Unix() // a failed read backs off like a good one
	if !ok {
		return
	}
	c.jobs = jobs
	c.pass, c.fail, c.run, c.wait = 0, 0, 0, 0
	for _, j := range jobs {
		switch j.state {
		case "pass":
			c.pass++
		case "fail":
			c.fail++
		case "run":
			c.run++
		case "wait":
			c.wait++
		}
	}
}

// ghCheck covers both shapes GitHub returns in statusCheckRollup: CheckRun
// (name/status/conclusion) and StatusContext (context/state).
type ghCheck struct {
	Name       string `json:"name"`
	Context    string `json:"context"`
	Status     string `json:"status"`
	State      string `json:"state"`
	Conclusion string `json:"conclusion"`
}

// readJobs asks the forge CLI for the MR's checks. ok is false when the call
// failed — distinct from an empty pipeline, which is a valid answer.
func readJobs(root, iid string) (jobs []ciJob, ok bool) {
	pp := readConfigVal(root, "PROJECT_PATH", "")
	if pp == "" {
		return nil, false
	}
	if readConfigVal(root, "PROVIDER", "gitlab") == "github" {
		return githubChecks(pp, iid)
	}
	return gitlabJobs(root, pp, iid)
}

func githubChecks(pp, iid string) ([]ciJob, bool) {
	out, err := exec.Command("gh", "pr", "view", iid, "--repo", pp, "--json", "statusCheckRollup").Output()
	if err != nil {
		return nil, false
	}
	var payload struct {
		Rollup []ghCheck `json:"statusCheckRollup"`
	}
	if json.Unmarshal(out, &payload) != nil {
		return nil, false
	}
	jobs := make([]ciJob, 0, len(payload.Rollup))
	for _, c := range payload.Rollup {
		name := c.Name
		if name == "" {
			name = c.Context
		}
		// a finished check reports its conclusion; a live one only a status
		raw := c.Conclusion
		if raw == "" {
			raw = c.Status
		}
		if raw == "" {
			raw = c.State
		}
		jobs = append(jobs, ciJob{name: name, state: ciState(raw)})
	}
	return jobs, true
}

// gitlabJobs resolves the MR's latest pipeline, then lists its jobs — two
// calls, because GitLab inlines the job list nowhere cheaper.
func gitlabJobs(root, pp, iid string) ([]ciJob, bool) {
	enc := strings.ReplaceAll(pp, "/", "%2F")
	env := append(os.Environ(), "GITLAB_HOST="+readConfigVal(root, "GITLAB_HOST", ""))
	api := func(path string) ([]byte, bool) {
		c := exec.Command("glab", "api", path)
		c.Env = env
		out, err := c.Output()
		return out, err == nil
	}
	raw, ok := api("projects/" + enc + "/merge_requests/" + iid + "/pipelines")
	if !ok {
		return nil, false
	}
	var pipes []struct {
		ID int `json:"id"`
	}
	if json.Unmarshal(raw, &pipes) != nil {
		return nil, false
	}
	if len(pipes) == 0 {
		return nil, true // no pipeline for this MR — a valid empty answer
	}
	rawJobs, ok := api("projects/" + enc + "/pipelines/" + strconv.Itoa(pipes[0].ID) + "/jobs?per_page=50")
	if !ok {
		return nil, false
	}
	var raws []struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	if json.Unmarshal(rawJobs, &raws) != nil {
		return nil, false
	}
	// GitLab lists newest first; the pipeline reads better in run order
	jobs := make([]ciJob, 0, len(raws))
	for i := len(raws) - 1; i >= 0; i-- {
		jobs = append(jobs, ciJob{name: raws[i].Name, state: ciState(raws[i].Status)})
	}
	return jobs, true
}
