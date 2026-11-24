# Fix chains

One branch per task, in its own git worktree, worked by a chain of fresh headless sessions until the task reaches a
state where the owner decides. Each session runs on the crew's code pin (a design branch on its plan pin until its
sign-off), on whichever agent that pin names: `agent_run.py` starts it ([crew.md](crew.md)). Many chains run at once under one runner.

## Pieces

| File | Role |
|---|---|
| `briefs/<slug>.md` | The task. `make_briefs.py` writes it from `plan.json`; copied into the worktree as `.fixloop/brief.md` on first start, so later changes go in as `task.py note`. |
| `fixloop.sh <slug>` | One chain: creates the worktree and branch from `origin/<base>` (or reuses them), then runs sessions until a final state, `MAX_SESSIONS`, two sessions in a row without progress (status, HEAD, working tree and notes unchanged), or four in a row that only added notes. |
| `runner.sh` | Runs a queue file's chains, `MAX_PAR` at a time, starting the next as one ends; logs every start and end to `logs/runner.log` and raises a toast. Several runners can share the log. |
| `task.py` | The branch's state (`.fixloop/status.json`): phase, notes, PR, review proposals, questions for the owner, tasks done, final state. Sessions change state only through it. |
| `live_page.py`, `live_sync.py` | The branch's tab on the orchestrator session's one live page (`live/session.live.html`, never committed) and the writes that keep it current from `status.json`. The main session publishes and syncs it; chains never touch it. |
| `pr_size.py` | The branch's pull request size against its cap (`PR_MAX_LINES`, 400 by default): added plus removed lines, tests included, lockfiles, generated files and signed-off pages left out. `task.py size` runs it; `task.py` refuses the pr phase and `ready` over the cap. |
| `gate.py` | The pre-PR gate: every step the project profile names (builds, linters, test suites), detached, with lock slots per step shared by every run on the machine (`--status` says which slot a gate waits for, behind whom), and each slot's own instances of the services a step needs. A suite fails on more failures than known-flake names matched, named or not, and on zero tests run. |
| `runbook.md` | Appended to every session's system prompt: the standing overrides, the phases, each mode's rules, the hand-off format. |
| `settings.json` | Permissions (allow and deny lists) and the hooks: `ctx_guard.py` after every tool call, `end_gate.py` on stop. |

Final states: `awaiting_owner` (ready for the owner: a PR with CI read, or a design page), `needs_owner` (a question only
the owner can answer; the summary is the exact ask), `blocked` (outside the task, or the chain made no progress), `done`.

## Questions, Tasks And The Branch's Tab

- **A question that doesn't stop the chain:** `task.py ask "<Title>" "<question>" "<recommended answer>" "<other>" ...`
  records Q1, Q2, ... on the branch, shows it on the branch's tab of the session page and writes a `chain asks` line that wakes the main
  session. The chain carries on with the recommended answer; `task.py phase pr` refuses while a question is open, so the
  chain then holds its PR with `task.py needs "holding the pull request until <owner> answers Q1"`. For questions whose
  answer can't change what users see or what is stored, and where redoing the part is cheap. Anything else is `needs`.
- **The owner's answer** comes back from the tab as `task.py answer Q1 "<answer>"` (main session): an `OWNER ANSWER` note
  the next session reads first, redoing the part if the answer differs from what it carried on with.
- **Tasks:** the brief lists the branch's tasks, each with the test that proves it; `task.py done T1 "<how>"` ticks one,
  and every task is ticked before the pr phase. The branch's tab shows them.
- **Size:** the brief's `Size cap:` line is the most lines the branch's pull request may change. The chain checks with
  `task.py size` after green and before the pr phase; over the cap it stops with `needs` and a proposed split by task,
  never trims tests or packs code to fit. Only the owner raises a cap (`task.py cap`, main session).
- **Plain words:** the branch's tab shows the chain's phase lines, notes and questions as written, so the runbook asks for
  plain words (what changed for the user or the system) and keeps file:line for commits and HANDOFF.md.

## Modes (one runbook, triggered by the brief and by notes)

1. **Build** (default). Phases: **red** (failing tests that reproduce each defect, committed) → **green** (the fix; build
   the server and touched test projects; update every test that `new`s a changed constructor) → **docs** → **gate**
   (start, poll with `task.py wait 300`) → **security** (`security-review` skill over the diff) → **pr** (merge the base,
   push, open the PR with a self-contained body, add the workstream file) → **ci** (poll checks; read inline comments,
   review bodies and summaries; record each comment needing action as `task.py review "<who> #<comment id>: ..." "<proposal>"`)
   → `task.py ready`.
2. **Design** (`Mode: design` in the brief). Draft a delta mockup and/or a schema-change page on the branch, add the
   README registry row as PROPOSED, push, `ready`. No code, no gate, no PR. The page rules are in the runbook (Artifact
   contract, numbered choices with recommendations, open questions on top, absolute code links to a commit).
3. **Build after sign-off** (a `SIGNED OFF ...` note). The signed-off page on the branch is the spec, word for word; the
   chain builds it through the usual phases and changes the README row to "Built in PR #N". Anything the page doesn't
   settle stops the chain with `needs`.
4. **Apply approved review items** (an `APPROVED REVIEW ITEMS ...` note). Apply exactly the listed items (test first where
   behaviour changes), merge the base if it moved, gate, push to the same PR, poll CI, record new comments, `ready`. Never
   reply to or resolve threads.

## What a session may and may not do

Allowed (see `kit/fix/settings.json.template`): read and edit the worktree, `task.py`, `gate.py`, the project's own
build and test commands (the profile's `chain_allow`),
local git (status, diff, log, add, commit, fetch, merge of its base: the branch below it in its stack, or the base), push to its own branch prefix, `gh pr create/view/checks/diff`,
`pr_read.py` (read-only PR comments and reviews), read-only shell tools.

Denied: subagents, questions, artifacts, web, scheduling, worktree tools, force push, reset, rebase, checking out the base,
deleting branches, `gh pr merge/close/comment/review/edit/ready`, every `gh api` call (it can write: a method or field flag
after the path turns a read into a post), `rm -rf`, docker, curl, and installing anything (brew, sudo, pip install).
A chain that needs something outside this says so in a note; the orchestrator does it.

The lists are a guardrail against a chain's mistakes, not a sandbox: a chain edits code and runs the project's build
and tests, so it can run whatever it writes. What actually protects the base is branch protection (a PR and an
approval) and the owner merging. Never give a chain's account more rights than that needs.

## The gate

- The steps, their commands and their test-output parsers come from the project profile
  ([project.md](project.md), "The gate"): any language, any test runner.
- Verdict: a build or check that exits non-zero fails and stops the gate; a suite with an unexpected failure fails;
  **a suite that ran zero tests fails** (a stalled database or test host can report a pass with nothing run); a suite
  that exits non-zero with no failing test fails (it crashed before the tests).
- `KNOWN_FLAKES` (loop.conf) lists tests that fail only under shared load or on this platform's checkout. They are
  reported, not counted, and each one must pass when run alone before anyone trusts the gate.
  `KNOWN_PLATFORM_FAILURES` lists tests that fail on this platform every time and pass on CI: reported, not counted,
  never re-run alone. Name each as the test runner prints a failure (usually the bare method name).
- On Windows, child processes start with `CREATE_NO_WINDOW`: without it every child of the gate opens a console window.
  Elsewhere the gate runs in a session of its own. The profile's `env` reaches every step (pin a locale there if the
  project's tests format dates or numbers).
- Slots: a step's `slots` count caps it on the whole machine, across every run and every project (one folder,
  `GATE_SLOTS`, default `~/.laneloop/gate-slots`, by step name). A gate takes only slots below its own profile's count,
  so when two profiles give a step different counts the larger caps the machine and the smaller still waits for one of
  its own. While a gate waits, `gate.py --status`, its `gate.json` ("waiting") and the chain's tab say for which slot,
  behind which run and worktree, and since when. A slot whose gate died is freed for the next one.
- Services: a step that names services gets its own fresh instance of each (a database, a cache, a queue) on its port
  plus the lowest offset no other gate on the machine holds, removed after: two chains never share one, even from two
  runs, or two steps or projects that name the same port, so suites with fixed database names can't clobber each other.
  Docker or native, as the profile says.
- `GATE_SKIP` leaves a step out on a machine that can't run it, only on the owner's decision (e.g. a step whose service
  this machine can't run). The chain then waits for the CI check that runs it before `ready`; the verdict line names it
  and the PR body says so, with the step's `skippable` note.
- Several worktrees can build at once (each has its own build output); the slots keep heavy suites from starving each other.

## Briefs

Every brief carries `Stacked on: <slug>` (or `-` for the bottom of a stack): the chain's worktree is built from that
branch, its base is kept in `.fixloop/base`, and its PR targets it. `task.py pr` retargets a PR opened elsewhere and puts
it in a GitHub stack with the PR below (a second child of one parent stays base-chained: stacks are linear). Stacking
is extra: if GitHub refuses it, the PR is still recorded, base-chained, and the note says why. It refuses a PR it can't
check is this branch's (another branch's, or no branch checked out), and never retargets one. If that
branch has already merged, the chain is built from what it merged into. The runner starts the chain once that branch has
opened its PR, or, for a design branch on a design branch, once that one has pushed its page (ended awaiting the owner).
`task.py size` and `egm_plan.py boundary` measure a stacked branch against the branch below it.

A good brief has: the binding scope in plain words (what to change, what not to touch, which decisions apply and how),
the defects with their why (file:line) and fix, the investigation notes, the tests that re-verify it after merge, its
size cap with the plan's estimate, and what "done" means for its mode. Say where line numbers came from (they drift).
Put a decision the owner made into the scope in their words. Keep anything that needs a design or schema sign-off out of
a build brief, or make it a design brief.

## Watching and finishing

- `wait_chain.sh` returns on the next chain end or question with every `chain stops: <state> · <summary>` and `chain asks`
  line since, and every `LIVE_SYNC_MIN` minutes (default 10) when a chain's state changed; re-arm it every time. It
  keeps the computer awake while it waits, and returns with `the computer slept for <time>` if it slept anyway.
  `status.py [queue]` lists every branch's state.
- Each time: sync the session page and post the attention lines (orchestrator reference, "Live Pages").
- On `awaiting_owner`: read the summary and the notes (look for "HEADS-UP", "Out of scope, seen", known gaps the chain
  flagged), then act per the orchestrator reference. On `needs_owner`: the ask is on the chain's tab; post the page's link. On
  `blocked`: read the last session's log and decide whether to requeue with a note.

## Typical costs

Build chains: $3 to $15 per PR including CI waits. Design chains: $1 to $5 per page. Review-item chains: $1 to $5.
A wave of 14 build chains runs to about $100.
