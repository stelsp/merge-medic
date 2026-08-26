# merge-medic 🩹

**Self-hosted GitLab MR conflict watcher that resolves conflicts with AI — but
polls for free.**

A launchd daemon polls your open merge requests every few minutes with plain
bash + [`glab`](https://gitlab.com/gitlab-org/cli) (zero tokens, zero cost).
When an MR flips into `conflict`, a phase-driven fixer takes over:

```
WORKTREE → MERGE → AI_RESOLVE | MERGE_CLEAN → VERIFY → PUSH
```

Claude is invoked **only** when the merge leaves real conflict markers in
files — and only to resolve those hunks. A merge that applies cleanly costs
**0 tokens**. Your MR branch is never rebased or force-pushed: the fix is
always a `chore: merge origin/<target> into <branch>` commit.

## Why this exists

There is no off-the-shelf tool for this niche (checked Aug 2026):

- **GitLab Duo** (19.3+) resolves conflicts with AI — but only on a manual
  button press, and needs Premium/Ultimate.
- **marge-bot / Renovate** keep branches fresh — by rebasing, which rewrites
  published history.
- **Mergify** has no GitLab support.
- GitLab has **no webhook** for "MR became conflicted"
  ([work item 592455](https://gitlab.com/gitlab-org/gitlab/-/work_items/592455)),
  so polling is the only reliable edge detector — it just has to be free.
- Claude-side schedulers (routines, cron agents) burn tokens on every poll.

merge-medic sits exactly in that gap: **automatic + merge-based + AI-resolved
+ token-free until the edge actually fires**.

## Live dashboard

```
merge-medic — live   17:46:24
  daemon on · AI budget 1/6 · active fixers: 1

  !100  [██████████████████████] 100%  DONE        4m12s  merged origin/dev, verify green, pushed
  !97   [████████████░░░░░░░░░░]  55%  AI_RESOLVE  1m40s  3 file(s): map.ts acl.ts index.ts
```

`mrwatch top` — redraws every second from the fixers' phase logs.

## How it stays cheap and safe

| Guard | What it does |
|---|---|
| Edge trigger | fixer starts only when an MR *transitions* into `conflict` |
| SHA-pair dedup | a failed `(source_sha, target_sha)` pair is never retried until a branch moves |
| Daily AI budget | hard cap on Claude invocations per day (`DAILY_AGENT_RUNS`) |
| Clean-merge shortcut | no conflict markers → no AI call at all |
| Verify gate | `VERIFY_CMD` (typecheck/build/tests) must pass before any push |
| Excluded branches | branches you are actively pushing to are ignored |
| Dedicated clone | fixers work in their own clone + per-MR worktrees, never in your checkout |
| Scoped AI | resolver runs headless with a minimal tool allowlist; it cannot push |
| DRY_RUN | default mode: detect and log only |

macOS notifications fire on: new conflict, fixer started, fixed ✓ / failed.

## Install

Requirements: macOS, [`glab`](https://gitlab.com/gitlab-org/cli) (authenticated),
`jq`, `git`, [Claude Code CLI](https://code.claude.com).

```bash
git clone https://github.com/YOU/merge-medic && cd merge-medic
./install.sh          # deps check, config.env, launchd job (DRY_RUN by default)
vim config.env        # project, host, verify command
mrwatch log -f        # watch a few dry ticks
# happy? set DRY_RUN=0 in config.env — that's it
```

## CLI

```
mrwatch             status: daemon, mode, budget, fixers, MR states
mrwatch top         live dashboard with progress bars (q quits)
mrwatch mrs         live mergeability of all open MRs
mrwatch log -f      follow the watcher log
mrwatch agent <iid> AI resolver log for one MR
mrwatch run         force a tick right now
mrwatch pause/resume
```

## Architecture

```
launchd (every N s)
  └─ watch.sh            bash + glab api — free polling, edge detection,
     │                   SHA dedup, budget guard, notifications
     └─ fix-mr.sh ×N     one per conflicted MR (PARALLEL_FIXERS cap)
        ├─ git worktree  isolated per MR
        ├─ git merge     clean? → done, 0 tokens
        ├─ claude -p     only on real conflict markers, resolve-only prompt
        ├─ VERIFY_CMD    typecheck/build gate
        └─ git push      merge commit, never rebase

state/progress-<iid>.log  ←  phase events  ←  mrwatch top
```

## Roadmap

- Linux support (systemd timer / cron instead of launchd, notify-send)
- GitHub flavor (`gh` + PR mergeable state)
- Server-side mode: same loop as a GitLab scheduled pipeline (survives laptop sleep)
- Auto-retire polling if GitLab ever ships the `merge_request_conflict` webhook

## License

MIT
