package main

import (
	"path/filepath"
	"testing"
	"time"
)

// parseMRState is exercised through readSnapshot, which only accepts state
// files younger than its 15-minute TTL — so the fixtures are written fresh.
func snapWithMR(t *testing.T, line string) mrState {
	t.Helper()
	root := t.TempDir()
	writeFile(t, root, filepath.Join("state", "mr-42"), line+"\n")
	s := readSnapshot(root)
	if len(s.mrs) != 1 {
		t.Fatalf("expected one MR, got %d", len(s.mrs))
	}
	return s.mrs[0]
}

func TestMRStateDraftFlag(t *testing.T) {
	now := time.Now().Format(time.RFC3339)
	got := snapWithMR(t, "conflict a1b2:c3d4 feat-x main success stelsp "+now+" draft feat: work in progress")
	if !got.draft {
		t.Error("draft flag not parsed")
	}
	if got.title != "feat: work in progress" {
		t.Errorf("title = %q — the flag leaked into it", got.title)
	}
	if got.src != "feat-x" || got.tgt != "main" || got.ci != "success" || got.author != "stelsp" {
		t.Errorf("neighbouring fields damaged: %+v", got)
	}
}

func TestMRStateNotDraft(t *testing.T) {
	now := time.Now().Format(time.RFC3339)
	got := snapWithMR(t, "mergeable a1b2:c3d4 feat-x main success stelsp "+now+" - fix: real title")
	if got.draft {
		t.Error("'-' must mean not-a-draft")
	}
	if got.title != "fix: real title" {
		t.Errorf("title = %q", got.title)
	}
}

func TestMRStateLegacyLineWithoutFlag(t *testing.T) {
	// state files written before the flag existed must still parse
	now := time.Now().Format(time.RFC3339)
	got := snapWithMR(t, "conflict a1b2:c3d4 feat-x main success stelsp "+now+" feat: older format")
	if got.draft {
		t.Error("a legacy line must not read as a draft")
	}
	if got.title != "feat: older format" {
		t.Errorf("legacy title = %q", got.title)
	}
}

func TestMRStateDraftDoesNotShiftFields(t *testing.T) {
	// the radar and the watcher read src/tgt positionally out of the same
	// file — the flag must sit after the timestamp, never before them
	now := time.Now().Format(time.RFC3339)
	got := snapWithMR(t, "conflict a1:b2 feat-x main running stelsp "+now+" draft Draft: feat: x")
	if got.src != "feat-x" || got.tgt != "main" || got.ci != "running" {
		t.Errorf("positional fields moved: %+v", got)
	}
	if got.title != "Draft: feat: x" {
		t.Errorf("parser must keep the raw title, got %q", got.title)
	}
}
