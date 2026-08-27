# merge-medic 🩹

[![CI](https://github.com/stelsp/merge-medic/actions/workflows/ci.yml/badge.svg)](https://github.com/stelsp/merge-medic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/macOS%20%7C%20Linux%20%7C%20Windows%20(WSL2)-launchd%20%2F%20systemd-lightgrey)
![Forges](https://img.shields.io/badge/GitLab%20%7C%20GitHub-glab%20%2F%20gh-orange)

**Self-hosted MR/PR conflict watcher that resolves merge conflicts with AI —
but polls for free and refuses to guess.**

![merge-medic live dashboard](docs/demo.gif)

A launchd / systemd-timer daemon polls your open merge requests every few
minutes with plain bash + your forge CLI — **zero tokens, zero cost**. When an
MR flips into `conflict`, a phase-driven fixer takes over:

```
WORKTREE → MERGE → AI_RESOLVE | MERGE_CLEAN → VERIFY → TESTS → REGRESSION → PUSH
                        ↓
                   ESCALATED (needs human)
```

Three possible outcomes, all visible above: a merge that applies cleanly costs
**0 tokens**; real conflict markers get an AI resolution that must survive the
test gates; and anything the bot shouldn't decide is **escalated to a human**
instead of guessed. Your branch is never rebased or force-pushed — the fix is
always a `chore: merge origin/<target> into <branch>` commit.

## Why this exists

There was no off-the-shelf tool in this niche (checked Aug 2026):

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

## How it decides

Mechanics first: git merges everything it can — the AI only ever sees files
with real conflict markers, rendered in **zdiff3** style, so the
common-ancestor version sits inside every hunk and the resolver knows what
each side actually changed. The prompt also carries **intent context**: each
side's commit history over the conflicted files and the MR title.

The default policy: preserve both sides' intent; when in doubt the **source
branch wins for its own feature code, the target for everything else**;
nothing outside the conflicted hunks is touched; the agent stages files but
cannot commit or push. `RESOLVE_POLICY_FILE` appends your project rules
(e.g. *"in `migrations/` keep both sides"*).

When guessing would be dangerous, the bot **doesn't**: conflicts under
`ESCALATE_PATTERNS`, and cases the AI itself judges incompatible, end as
`ESCALATED (needs human)`. With `POST_RESOLUTION_NOTE=1` the resolver's
per-file reasoning — or the escalation reason — is posted to the MR, so the
reviewer always sees what the bot did and why.

**Semi-auto for sensitive branches.** Only `AUTO_BRANCHES` sources (default
`feat-*`) are fixed hands-off. A conflicted MR from any other source — e.g. a
release MR `dev → main` — gets a read-only **resolution plan** posted as an MR
comment instead of a fix. A human reviews it, optionally leaves correcting
comments right on the MR, and presses `a` in the dashboard; the approved run
executes the plan with those comments as overriding instructions. The bot
never pushes to a non-auto branch without that approve.

**Conflict radar.** Conflicts are detected *between open MRs* before anyone
merges: every poll runs free in-memory `git merge-tree` checks across MRs
sharing a target and warns — in the dashboard (⚡) and as a notification —
that "!104 and !107 conflict with each other; first to merge wins". No other
tool does this; here it costs zero tokens and zero API calls.

## How it stays cheap and safe

| Guard | What it does |
|---|---|
| Edge trigger | fixer starts only when an MR *transitions* into `conflict` |
| SHA-pair dedup | a failed `(source_sha, target_sha)` pair is never retried until a branch moves |
| Daily AI budget | hard cap on Claude invocations per day (`DAILY_AGENT_RUNS`) |
| Clean-merge shortcut | no conflict markers → no AI call at all |
| Verify gate | `VERIFY_CMD` (typecheck/build) must pass before any push |
| Test gates | `TEST_CMD_TEMPLATE` runs tests focused on the conflicted files; `REGRESSION_CMD` runs the full suite after AI resolutions |
| Escalation | `ESCALATE_PATTERNS` paths are never resolved by the bot; incompatible substantive changes are refused, not guessed |
| Defer while hot | a branch pushed less than `QUIET_MINUTES` ago (or with uncommitted work in `USER_REPOS`) is DEFERRED, not raced — retried every tick for free until it goes quiet |
| Excluded branches | branches you are actively pushing to are ignored |
| Dedicated clone | fixers work in their own clone + per-MR worktrees, never in your checkout |
| Scoped AI | resolver runs headless with a minimal tool allowlist; it cannot commit or push |
| DRY_RUN | default mode: detect and log only |

Desktop notifications (macOS `osascript` / Linux `notify-send` / Windows
toast from WSL) fire on: new conflict, fixer started, fixed ✓ / failed /
escalated.

## Install

Requirements: macOS (launchd), Linux (systemd user timer) or Windows via
WSL2 (see below), `jq`, `git`, your forge CLI —
[`glab`](https://gitlab.com/gitlab-org/cli) for GitLab (default) or
[`gh`](https://cli.github.com) for GitHub — and a resolver agent:
[Claude Code CLI](https://code.claude.com) by default, or
[aider](https://aider.chat) to use **any model** (OpenAI / Gemini / DeepSeek /
OpenRouter / local Ollama — bring your API key), or your own command
(`RESOLVER=custom`).

One command (clones + interactive wizard: offers to install missing deps,
starts the forge/resolver logins, fills the config, sets up the scheduler):

```bash
curl -fsSL https://raw.githubusercontent.com/stelsp/merge-medic/main/get.sh | bash
```

Prefer not to pipe curl into bash? Same thing by hand:

```bash
git clone https://github.com/stelsp/merge-medic && cd merge-medic
bin/mrwatch setup     # the same wizard — deps, logins, config, scheduler
```

Or fully manual: `./install.sh` (checks deps, seeds config.env, sets up the
scheduler), then edit `config.env` yourself. Either way it starts in
`DRY_RUN=1`: watch a few dry ticks with `mrwatch log -f`, then set `DRY_RUN=0`
— that's it.

### Windows (WSL2)

merge-medic runs on Windows inside [WSL2](https://learn.microsoft.com/windows/wsl/)
exactly as on Linux — same installer, same systemd timer. Two extras:

1. **Enable systemd** in your distro (once):
   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
   ```
   then `wsl --shutdown` from Windows and reopen the distro. `install.sh`
   detects the missing systemd and prints these exact steps.
2. **Notifications** need nothing: inside WSL, `mm_notify` bridges to native
   Windows toast notifications via `powershell.exe` automatically.

Caveat: WSL pauses when no WSL process is running, so keep a distro terminal
open (or set a Windows Task Scheduler job running `wsl -e true` periodically)
if you want ticks while you're not working inside WSL.

Updating later: `git pull && make build` (mrtop) — config/state are local and
gitignored.

**Multiple repos:** one clone = one instance. Clone again under a different
name (`~/.merge-medic-gh`, `~/.merge-medic-work`, …), give each its own
`config.env` and run its `install.sh` — every instance gets its own scheduler
job and its own suffixed CLI (`mrwatch-gh top`), fully independent state and
dashboards.

## CLI

```
mrwatch             the dashboard (plain-text status when piped)
mrwatch setup       interactive helper: deps, logins, config, scheduler
mrwatch log -f      follow the watcher log
mrwatch agent <iid> AI resolver log for one MR
mrwatch run         force a tick right now
mrwatch pause/resume
```

Everything live (event feed, open MRs, history, logs) is inside the
dashboard — one window. With several instances installed, plain `mrwatch`
asks which project to open first; suffixed commands (`mrwatch-gh …`) go
straight to theirs.

`mrwatch top` is **`mrtop`** — a Go /
[bubbletea](https://github.com/charmbracelet/bubbletea) dashboard built by
`install.sh` when Go is present (a pure-bash fallback reads the same phase
logs; `MRWATCH_PLAIN=1` forces it). The grid: **STATUS / RUNS / SPEND**
(budget gauge, day counters, 14-day activity sparkline, per-model token
spend in $), **ACTIVE** (live fixers with interpolated progress bars, plus
every open MR with its state), **HISTORY** (all-time ledger) and a full-width
**LIVE** event feed. Keys: `↑↓/jk` move, `enter` per-phase timeline of any
run, `a` approve a plan, `l` AI/fixer log panel, `r` force tick, `p`
pause/resume, `?` help, `esc` close, `q` quit.

## Configuration

Everything lives in `config.env` (gitignored; seeded from
[config.example.env](config.example.env)). The essentials:

| Key | Meaning |
|---|---|
| `PROVIDER` | `gitlab` (glab) or `github` (gh) |
| `PROJECT_PATH` / `GITLAB_HOST` / `GIT_REMOTE_URL` | the project to watch |
| `DRY_RUN` | `1` = detect & log only (default), `0` = live |
| `VERIFY_CMD` | build/typecheck gate before push |
| `TEST_CMD_TEMPLATE` | focused tests, `{files}` = conflicted paths |
| `REGRESSION_CMD` / `REGRESSION_WHEN` | full suite gate: `ai` (default) / `always` / `never` |
| `RESOLVER` | `claude` (default) / `aider` (any model via API keys: `RESOLVER_MODEL`) / `custom` (`RESOLVER_CMD`) |
| `PUSH_MODE` | `direct` (default: merge commit pushed into the source branch) / `mr` (your branch is never touched — the resolution is opened as its own MR/PR into it, you review and merge) |
| `TRUSTED_AUTHORS` | usernames whose plan comments the approved run obeys (default: the MR author only) |
| `RESOLVE_POLICY_FILE` | project-specific resolution rules appended to the prompt |
| `AUTO_BRANCHES` | source-branch globs fixed fully automatically (default `feat-*`); any other source gets the semi-auto flow: plan → MR comment → human approve (`a` in the dashboard) → fix that reads your comments |
| `ESCALATE_PATTERNS` | glob paths the bot must never resolve |
| `POST_RESOLUTION_NOTE` | `1` = comment the resolver's reasoning on the MR/PR |
| `QUIET_MINUTES` | defer the fix while the source branch had a push this recently (retried every tick; `0` disables) |
| `USER_REPOS` | local checkouts to inspect — uncommitted work on the branch there also defers the fix |
| `INCLUDE_BRANCHES` | allowlist of source-branch globs — when set, everything else is ignored entirely |
| `RADAR` | `1` (default) — warn when two open MRs conflict with each other (free merge-tree checks) |
| `EXCLUDE_BRANCHES` | branches to ignore (your active work) |
| `DAILY_AGENT_RUNS` | daily cap on AI invocations |
| `PARALLEL_FIXERS` | concurrent fixers (`1` = sequential) |
| `NOTIFY` / `NOTIFY_SOUND` | desktop notifications |

## Architecture

```
launchd / systemd user timer (every N s)
  └─ watch.sh            bash + glab/gh — free polling, edge detection,
     │                   SHA dedup, budget guard, notifications
     └─ fix-mr.sh ×N     one per conflicted MR (PARALLEL_FIXERS cap)
        ├─ defer         branch pushed < QUIET_MINUTES ago? → retry when quiet
        ├─ git worktree  isolated per MR
        ├─ git merge     zdiff3 markers; clean? → done, 0 tokens
        ├─ escalation    protected paths / incompatible changes → human
        ├─ claude -p     resolve-only prompt + intent context + policy file
        ├─ gates         VERIFY_CMD → TEST_CMD_TEMPLATE → REGRESSION_CMD
        ├─ git push      merge commit, never rebase
        └─ MR comment    per-file reasoning (POST_RESOLUTION_NOTE)

state/progress-<iid>.log  ←  phase events  ←  mrtop / mrwatch top
```

## Roadmap

- Baseline "no new failures" diffing (run the suite on the branch tip, compare
  failure sets) — deferred until chronically red branches make it worth it
- Server-side mode: same loop as a GitLab scheduled pipeline (survives laptop
  sleep)
- Auto-retire polling if GitLab ever ships the `merge_request_conflict` webhook

## License

MIT
