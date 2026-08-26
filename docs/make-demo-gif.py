#!/usr/bin/env python3
"""Render docs/demo.gif — a faithful simulation of the merge-medic dashboard.

Drawn with PIL (no screen recording needed) so the demo can be regenerated
deterministically whenever the dashboard changes. Run from the repo root:

    python3 docs/make-demo-gif.py

The storyline shows all three outcomes at once: a clean merge (0 tokens),
an AI resolution walking through the test gates, and an escalation.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 900, 260
BG = (13, 17, 23)        # GitHub dark
FG = (201, 209, 217)
DIM = (110, 118, 129)
BOLD = (240, 246, 252)
GRN = (63, 185, 80)
YLW = (210, 153, 34)
RED = (248, 81, 73)
BAR_W = 22

FONT = "/System/Library/Fonts/Menlo.ttc"
try:
    F = ImageFont.truetype(FONT, 15)
    FB = ImageFont.truetype(FONT, 15, index=1)  # bold face
except OSError:  # non-macOS fallback
    F = FB = ImageFont.load_default()

PCT = {
    "START": 3, "WORKTREE": 10, "MERGE": 25, "MERGE_CLEAN": 55,
    "AI_RESOLVE": 55, "VERIFY": 74, "TESTS": 83, "REGRESSION": 91,
    "PUSH": 97, "DONE": 100, "FAIL": 100, "ESCALATED": 100,
}
COLOR = {"DONE": GRN, "FAIL": RED, "AI_RESOLVE": YLW, "ESCALATED": YLW}

# (clock, budget, (ok, bad, esc, clean, ai), [(iid, phase, elapsed, detail)])
SCRIPT = [
    ("17:44:03", 0, (0, 0, 0, 0, 0), [
        ("97", "START", "0m01s", "feat-74 -> dev"),
        ("100", "START", "0m01s", "feat-101 -> dev"),
        ("84", "START", "0m01s", "feat-84 -> dev")]),
    ("17:44:12", 0, (0, 0, 0, 0, 0), [
        ("97", "MERGE", "0m10s", "origin/dev"),
        ("100", "MERGE", "0m10s", "origin/dev"),
        ("84", "MERGE", "0m10s", "origin/dev")]),
    ("17:44:35", 2, (0, 0, 0, 1, 2), [
        ("97", "AI_RESOLVE", "0m33s", "3 file(s): map.ts acl.ts index.ts"),
        ("100", "MERGE_CLEAN", "0m28s", "no conflict markers — AI not needed (0 tokens)"),
        ("84", "AI_RESOLVE", "0m33s", "1 file(s): acl-request-scope.ts")]),
    ("17:45:20", 2, (0, 0, 1, 1, 2), [
        ("97", "AI_RESOLVE", "1m18s", "3 file(s): map.ts acl.ts index.ts"),
        ("100", "VERIFY", "1m10s", "pnpm typecheck && pnpm build"),
        ("84", "ESCALATED", "1m02s", "AI declined to guess: both sides rewrote the acl guard")]),
    ("17:46:40", 2, (0, 0, 1, 1, 2), [
        ("97", "VERIFY", "2m38s", "pnpm typecheck && pnpm build"),
        ("100", "PUSH", "2m30s", "origin feat-101"),
        ("84", "ESCALATED", "1m02s", "AI declined to guess: both sides rewrote the acl guard")]),
    ("17:47:05", 2, (1, 0, 1, 1, 2), [
        ("97", "TESTS", "3m03s", "pnpm vitest related --run map.ts acl.ts index.ts"),
        ("100", "DONE", "2m41s", "merged origin/dev, gates green, pushed"),
        ("84", "ESCALATED", "1m02s", "AI declined to guess: both sides rewrote the acl guard")]),
    ("17:48:30", 2, (1, 0, 1, 1, 2), [
        ("97", "REGRESSION", "4m28s", "pnpm -r run test"),
        ("100", "DONE", "2m41s", "merged origin/dev, gates green, pushed"),
        ("84", "ESCALATED", "1m02s", "AI declined to guess: both sides rewrote the acl guard")]),
    ("17:49:55", 2, (2, 0, 1, 1, 2), [
        ("97", "DONE", "5m50s", "merged origin/dev, gates green, pushed"),
        ("100", "DONE", "2m41s", "merged origin/dev, gates green, pushed"),
        ("84", "ESCALATED", "1m02s", "AI declined to guess: both sides rewrote the acl guard")]),
]


def bar(pct: int) -> str:
    filled = pct * BAR_W // 100
    return "█" * filled + "░" * (BAR_W - filled)


def frame(clock: str, budget: int, counters, rows) -> Image.Image:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    x, y, lh = 18, 16, 24
    ok, bad, esc, clean, ai = counters

    d.text((x, y), "merge-medic — live", font=FB, fill=BOLD)
    d.text((x + 240, y), clock, font=F, fill=FG)
    y += lh
    active = sum(1 for r in rows if r[1] not in ("DONE", "FAIL", "ESCALATED"))
    d.text((x, y), "  daemon on · AI budget "
           f"{budget}/6 · active: {active} · today: ", font=F, fill=DIM)
    xx = x + 455
    d.text((xx, y), f"{ok} fixed", font=F, fill=GRN); xx += 78
    d.text((xx, y), f"/ {bad} failed", font=F, fill=RED); xx += 98
    d.text((xx, y), f"/ {esc}→human", font=F, fill=YLW); xx += 105
    d.text((xx, y), f"· {clean} clean, {ai} AI", font=F, fill=DIM)
    y += lh + 8

    for iid, phase, el, detail in rows:
        pct = PCT[phase]
        c = COLOR.get(phase, FG)
        d.text((x, y), f"!{iid:<4}", font=FB, fill=BOLD)
        d.text((x + 60, y), f"[{bar(pct)}] {pct:3d}%", font=F, fill=FG)
        d.text((x + 330, y), f"{phase:<11}", font=F, fill=c)
        d.text((x + 440, y), el, font=F, fill=FG)
        d.text((x + 510, y), detail[:46], font=F, fill=DIM)
        y += lh

    y = H - 30
    d.text((x, y), "WORKTREE→MERGE→AI|CLEAN→VERIFY→TESTS→REGRESSION→PUSH→DONE|ESCALATED · q quits",
           font=F, fill=DIM)
    return img


def main() -> None:
    out = Path(__file__).parent / "demo.gif"
    frames = [frame(*s) for s in SCRIPT]
    frames[0].save(
        out, save_all=True, append_images=frames[1:],
        duration=[1100] * (len(frames) - 1) + [3000], loop=0,
    )
    print(f"wrote {out} ({out.stat().st_size // 1024} KiB, {len(frames)} frames)")


if __name__ == "__main__":
    main()
