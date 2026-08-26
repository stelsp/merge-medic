#!/usr/bin/env python3
"""Render docs/demo.gif — a faithful simulation of `mrwatch top`.

Draws the dashboard frames with PIL (no screen recording needed) so the demo
can be regenerated deterministically. Run from the repo root:

    python3 docs/make-demo-gif.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 860, 240
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
    "START": 5, "WORKTREE": 15, "MERGE": 30, "MERGE_CLEAN": 55,
    "AI_RESOLVE": 55, "VERIFY": 78, "PUSH": 92, "DONE": 100, "FAIL": 100,
}
COLOR = {"DONE": GRN, "FAIL": RED, "AI_RESOLVE": YLW}

# (clock, budget, [(iid, phase, elapsed, detail)])
SCRIPT = [
    ("17:44:03", 0, [("97", "START", "0m01s", "feat-74 -> dev"),
                     ("100", "START", "0m01s", "feat-101 -> dev")]),
    ("17:44:09", 0, [("97", "WORKTREE", "0m07s", "worktrees/wt-97"),
                     ("100", "WORKTREE", "0m07s", "worktrees/wt-100")]),
    ("17:44:21", 0, [("97", "MERGE", "0m19s", "origin/dev"),
                     ("100", "MERGE", "0m19s", "origin/dev")]),
    ("17:44:35", 1, [("97", "AI_RESOLVE", "0m33s", "3 file(s): map.ts acl.ts index.ts"),
                     ("100", "MERGE_CLEAN", "0m28s", "no conflict markers — AI not needed (0 tokens)")]),
    ("17:45:02", 1, [("97", "AI_RESOLVE", "1m00s", "3 file(s): map.ts acl.ts index.ts"),
                     ("100", "VERIFY", "0m55s", "pnpm typecheck && pnpm build")]),
    ("17:46:11", 1, [("97", "VERIFY", "2m09s", "pnpm typecheck && pnpm build"),
                     ("100", "VERIFY", "2m04s", "pnpm typecheck && pnpm build")]),
    ("17:47:20", 1, [("97", "VERIFY", "3m18s", "pnpm typecheck && pnpm build"),
                     ("100", "PUSH", "3m10s", "origin feat-101")]),
    ("17:47:34", 1, [("97", "PUSH", "3m32s", "origin feat-74"),
                     ("100", "DONE", "3m21s", "merged origin/dev, verify green, pushed")]),
    ("17:47:41", 1, [("97", "DONE", "3m39s", "merged origin/dev, verify green, pushed"),
                     ("100", "DONE", "3m21s", "merged origin/dev, verify green, pushed")]),
]


def bar(pct: int) -> str:
    filled = pct * BAR_W // 100
    return "█" * filled + "░" * (BAR_W - filled)


def frame(clock: str, budget: int, rows) -> Image.Image:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    x, y, lh = 18, 16, 24

    d.text((x, y), "merge-medic — live", font=FB, fill=BOLD)
    d.text((x + 240, y), clock, font=F, fill=FG)
    y += lh
    active = sum(1 for r in rows if r[1] not in ("DONE", "FAIL"))
    d.text((x, y), f"  daemon on · AI budget {budget}/6 · active fixers: {active}",
           font=F, fill=DIM)
    y += lh + 8

    for iid, phase, el, detail in rows:
        pct = PCT[phase]
        c = COLOR.get(phase, FG)
        d.text((x, y), f"!{iid:<4}", font=FB, fill=BOLD)
        d.text((x + 60, y), f"[{bar(pct)}] {pct:3d}%", font=F, fill=FG)
        d.text((x + 330, y), f"{phase:<11}", font=F, fill=c)
        d.text((x + 440, y), el, font=F, fill=FG)
        d.text((x + 510, y), detail[:44], font=F, fill=DIM)
        y += lh

    y = H - 30
    d.text((x, y), "phases: START→WORKTREE→MERGE→AI_RESOLVE|MERGE_CLEAN→VERIFY→PUSH→DONE · q quits",
           font=F, fill=DIM)
    return img


def main() -> None:
    out = Path(__file__).parent / "demo.gif"
    frames = [frame(*s) for s in SCRIPT]
    frames[0].save(
        out, save_all=True, append_images=frames[1:],
        duration=[900] * (len(frames) - 1) + [2500], loop=0,
    )
    print(f"wrote {out} ({out.stat().st_size // 1024} KiB, {len(frames)} frames)")


if __name__ == "__main__":
    main()
