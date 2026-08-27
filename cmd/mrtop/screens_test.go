package main

import "testing"

func TestHotspotCacheStable(t *testing.T) {
	h := hotspot{file: "a/b.go", count: 3, mrs: []string{"1", "2"}}
	if hotspotCache("/root", h, "sonnet") != hotspotCache("/root", h, "sonnet") {
		t.Error("cache path must be deterministic")
	}
}

func TestHotspotCacheKeyedByStateAndModel(t *testing.T) {
	h := hotspot{file: "a/b.go", count: 3}
	base := hotspotCache("/root", h, "sonnet")
	if hotspotCache("/root", hotspot{file: "a/b.go", count: 4}, "sonnet") == base {
		t.Error("new conflicts must invalidate the cache")
	}
	if hotspotCache("/root", h, "haiku") == base {
		t.Error("each model must keep its own answer")
	}
	if hotspotCache("/root", hotspot{file: "a/c.go", count: 3}, "sonnet") == base {
		t.Error("different files must not collide")
	}
}
