# Backlog: living next to coding agents (2026-09-29)

Written from a day on `w3ds/ai-viewer-proto` where merge-medic was switched OFF,
because the way that repo is developed now broke its assumptions. Every item
below comes from something that actually happened that day, not from theory.

## What the day looked like

- Five feature branches open at once, each in its own git worktree
  (`.worktrees/feat-<iid>`), each with a coding agent committing into it.
- Branches stacked: `feat-126` and `feat-137` targeted `feat-124`, which
  targeted `dev`. `feat-124` merged, and both children needed retargeting to
  `dev` plus a fresh merge.
- `dev` moved; four branches had to take it. Seven conflicts in total — **six
  of them were the same one-line `> verified: <sha>` marker in a doc**. The
  seventh was real (a branch removed a default the incoming code restored).
- CI failed three times for infrastructure reasons: runner out of disk twice,
  then a hung `resolve image config` pull. Every retry was manual.

## A. Coexistence with agents — nothing else matters until this is in

1. **Worktree-aware defer.** `USER_REPOS` assumes one checkout. Each branch now
   has its own worktree. Rule: if `<repo>/.worktrees/<branch>` exists and is
   dirty, or carries a commit younger than `QUIET_MINUTES`, defer that MR. A
   dirty worktree is a far better "someone is working here" signal than a timer.
2. **Ignore our own pushes.** Already backlog item 1; it is now a blocker, not a
   nicety, because a bot push looks exactly like an agent push.
3. **`PUSH_MODE=mr` as the default for agent-heavy repos.** The resolution goes
   to its own branch and MR; the working branch is never touched. Removes the
   conflict of interest entirely while keeping the value.

## B. Deterministic resolvers — no tokens, no risk

A `RULES` layer that runs before any AI call, with a dashboard metric for how
many conflicts it closed on its own.

| Pattern | Rule |
|---|---|
| `> verified: <sha>` doc marker | keep ours, optionally re-stamp to the new HEAD |
| `pnpm-lock.yaml` | do not merge — regenerate |
| `drizzle/meta/_journal.json` + migration numbering | renumber the tail |
| append-only tables (locator catalogs, lists) | union of lines |
| non-overlapping added blocks in tests/docs | union |

On the evidence of that day this alone would have cleared six conflicts out of
seven, at zero cost.

## C. Stack awareness — nobody else does this

1. **Retarget on parent merge.** When an MR's target branch is merged, retarget
   to the target's target and pull the new base in.
2. **Base drift warning.** If `merge-base(branch, target)` is far behind the
   target's tip — or the branch was cut from a different branch than it targets
   — say so. One branch that day was built on the wrong base and it only
   surfaced in an agent's report.
3. **`mrwatch sync-stack`.** One command: merge each open MR's target into its
   branch, run the gates, push. That is exactly the half-hour of manual work
   that day ended with.

## D. CI babysitting

1. Retry a failed job on known infrastructure signatures — `no space left on
   device`, a hung image pull, a job that dies on its timeout — with an attempt
   cap.
2. Show "failed on infrastructure" distinctly from "the code is red" in MRS.
   They look identical today and mean opposite things.

## E. Small gates

- Skip branches whose issue is not in the `Doing` column (board label).
- Skip branches with an open draft MR.

## Suggested first slice

All of A, plus the `> verified:` rule from B. That turns merge-medic from
something that fights the agents into the thing that keeps five branches in
step with `dev` while they work.
