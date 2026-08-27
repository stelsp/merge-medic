package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func seedConfig(t *testing.T, content string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "config.env"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestReadConfigVal(t *testing.T) {
	root := seedConfig(t, "# comment\nPLAIN=abc\nQUOTED=\"def\"\nSINGLE='ghi'\n  INDENTED=jkl\n")
	cases := map[string]string{"PLAIN": "abc", "QUOTED": "def", "SINGLE": "ghi", "INDENTED": "jkl"}
	for k, want := range cases {
		if got := readConfigVal(root, k, "fallback"); got != want {
			t.Errorf("readConfigVal(%s) = %q, want %q", k, got, want)
		}
	}
	if got := readConfigVal(root, "MISSING", "fallback"); got != "fallback" {
		t.Errorf("missing key = %q, want fallback", got)
	}
	if got := readConfigVal(t.TempDir(), "ANY", "fallback"); got != "fallback" {
		t.Errorf("missing file = %q, want fallback", got)
	}
}

func TestSetConfigValUpdatesInPlace(t *testing.T) {
	root := seedConfig(t, "A=1\nB=2\nC=3\n")
	setConfigVal(root, "B", "\"22\"")
	if got := readConfigVal(root, "B", ""); got != "22" {
		t.Errorf("B = %q, want 22", got)
	}
	// neighbours untouched, no duplicate lines
	data, _ := os.ReadFile(filepath.Join(root, "config.env"))
	if strings.Count(string(data), "B=") != 1 {
		t.Errorf("duplicate B lines:\n%s", data)
	}
	if readConfigVal(root, "A", "") != "1" || readConfigVal(root, "C", "") != "3" {
		t.Error("neighbouring keys damaged")
	}
}

func TestSetConfigValAppendsNewKey(t *testing.T) {
	root := seedConfig(t, "A=1\n")
	setConfigVal(root, "NEW", "x")
	if got := readConfigVal(root, "NEW", ""); got != "x" {
		t.Errorf("NEW = %q, want x", got)
	}
}

func TestSetConfigValPrefixNoFalseMatch(t *testing.T) {
	// MODEL must not overwrite HOTSPOT_MODEL (or vice versa)
	root := seedConfig(t, "HOTSPOT_MODEL=haiku\nMODEL=opus\n")
	setConfigVal(root, "MODEL", "sonnet")
	if got := readConfigVal(root, "HOTSPOT_MODEL", ""); got != "haiku" {
		t.Errorf("HOTSPOT_MODEL clobbered: %q", got)
	}
	if got := readConfigVal(root, "MODEL", ""); got != "sonnet" {
		t.Errorf("MODEL = %q, want sonnet", got)
	}
}
