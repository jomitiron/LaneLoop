# Loop kit

Scripts for [laneloop](../SKILL.md). `init_run.py` copies them into a run folder and renders the templates with
the run's settings; you never run them from here. Nothing in the kit assumes a language, framework or database: the
project's own commands, services and tools come from its profile, `.laneloop/project.json`
([reference/project.md](../reference/project.md)), which `init_project.py` writes from the presets in `presets/`.

`<kit>` below is this folder. Installed as a plugin, it is in Claude Code's plugin cache and the skill gives Claude its
path (`${CLAUDE_SKILL_DIR}/kit`); installed for another agent (`install.sh`), it is the `kit` folder beside the skill's
`SKILL.md`; in a clone of the LaneLoop repository it is `skills/laneloop/kit`.

## The crew

Every session runs on its role's pin, `agent/model[:effort]`: research, plan, code, verify, each on any agent the kit
drives (Claude Code, Codex, Antigravity, Gemini CLI, Grok Build, OpenCode, Cursor). Pick a ready-made crew from
`crews/` and override single roles; [reference/crew.md](../reference/crew.md) has the presets, the benchmarks behind
them and what each agent supports.

```bash
python3 <kit>/common/crew.py presets                 # the ready-made crews, role by role, with why
python3 <kit>/common/crew.py use mixed               # this repository's crew (.laneloop/crew.json; commit it)
python3 <kit>/common/crew.py set plan=codex/gpt-6-astra:xhigh
python3 <kit>/common/crew.py check                   # agents installed, pins answering
```

## The project profile

```bash
# from inside the project's repository; --list shows every preset
python3 <kit>/init_project.py --stack <node|python|ruby|go|rust|java-maven|java-gradle|dotnet|php|custom> \
    [--db <postgres|mysql|mongodb|redis|sqlite>]... [--via docker|native]
```

It writes `.laneloop/project.json`: the gate's steps (with the right test-output parser), the services those steps need
(a fresh instance per gate slot, in Docker or native), how the verify loop builds, starts and health-checks the app (its
own services, data kept and seeded once), the tools the machine needs, and the commands sessions may run. Fill in what it
marks `FILL IN`, check the commands against the repo, commit it.

## Prerequisites

`doctor.py` (in every run folder) checks all of these on the machine it runs on, and says for each missing one what the
run does without it and who installs it. The orchestrator runs it at set-up and asks the owner before installing
anything (see [reference/orchestrator.md](../reference/orchestrator.md), "Missing dependencies").

- **Every run:** `claude` CLI signed in · `gh` signed in · Python 3 (`python` on Windows, `python3` on macOS: loop.conf
  `PYTHON`) · `pip install markdown` (for schema pages) · the project profile, and every tool it `requires` (its
  toolchain; Docker, or each native database server, for the services its checks use).
- **Fix runs planned with EGM** (`PLANNER=egm`, the default): Google's EGM plugin in the orchestrator's Claude Code
  (`claude plugin marketplace add google/elephant-goldfish-model`, `claude plugin install egm@egm`, a new session).
  `PLANNER=grill` plans without it.
- **Verify runs:** Chrome · Node (for `npx chrome-devtools-mcp`) · curl · the profile's `verify.start` (or
  `START_SERVER=0` against an app someone runs elsewhere).
- **Windows:** Git Bash with `mintty` and `cygpath`; PowerShell keeps the computer awake (`keep_awake.ps1`).
- **macOS:** `tmux` (or the `screen` macOS ships) for detached runs; mains power and an open lid for unattended runs
  (`launch.sh`, `runner.sh` and the gate run under `caffeinate` themselves; `launch.sh` refuses on battery). Nothing
  else: no Homebrew bash, no `python` shim.
- **Linux:** `tmux` or `screen`; `systemd-inhibit` (systemd) keeps the computer awake.
- **Every platform:** loops and the orchestrator's watchers hold the computer awake while they run. A closed laptop lid
  still sleeps it; if it sleeps anyway, the watchers say so on waking and nothing counts the lost time.

## Start a run

```bash
# from inside the repo (Windows: Git Bash, with a short root like /c/w; macOS: python3, e.g. ~/w)
python <kit>/init_run.py fix    /c/w/<name>  OWNER=<you> SLUG_PREFIX=<area>-fix-
python <kit>/init_run.py verify /c/w/<name>  OWNER=<you> "PAUSE_FOR=<the one sign-in that may pause the run>"
cd /c/w/<name> && python doctor.py && ./preflight.sh  # doctor exits 0, preflight prints ok
./launch.sh "<what>" ./start.sh [queue-file MAX_PAR]  # detached: mintty (Windows) or tmux (macOS)
```

Settings live in `loop.conf` / `loop.json` (re-run `init_run.py` with `KEY=VALUE` to change them: every other setting,
hand edits to `loop.conf` included, and the run's state are kept, and a rendered `runbook.md` or `settings.json` you
edited by hand is kept too, with the new render beside it as `<name>.new`).
Defaults: the repository's crew (`.laneloop/crew.json`), else the `claude` crew: research and code on Opus 5.5 1M at
high, plan (a design branch's sessions until its sign-off) and verify at xhigh (`CREW`, `RESEARCH_PIN`, `PLAN_PIN`,
`CODE_PIN`, `VERIFY_PIN`; the old `MODEL_ARG`/`EFFORT` and `PLAN_MODEL_ARG`/`PLAN_EFFORT` still set the main and plan
pins), hand-off at 65%, stop at 72%, $150 per session (Claude Code), 300 minutes per session (any agent,
`SESSION_TIMEOUT_MIN`), Codex in its workspace sandbox (`CODEX_SANDBOX`), 10 sessions per chain, 5 chains at once
(on macOS and Linux, one per 8 GB of memory, at most 5), base: the repository's default branch, branches
`ai-work/<SLUG_PREFIX><slug>`,
worktrees in `<run>-wt/`, the session page synced at least every 10 minutes (`LIVE_SYNC_MIN`).

Machine fallbacks (doctor.py says when each applies):

| Key | Default | What |
|---|---|---|
| `PYTHON` | `python` (Windows), `python3` | The interpreter every script, hook, allow-list entry and runbook names. |
| `PROJECT` | `.laneloop/project.json` | The project profile (relative to the repo, or absolute). |
| `PR_LABEL` | `laneloop:<run name>` | The label on every pull request the run opens (at most 50 characters); the session page links all of them. Empty: no label. |
| `GATE_SKIP` | empty | **The owner's decision only:** gate steps (by name) left out on this machine, e.g. one whose service this machine can't run; CI runs it instead. The gate's verdict and every PR body name it. |
| `GATE_SLOTS` | `~/.laneloop/gate-slots` | The gate's slots and service ports: one folder for the machine, shared by every run of every project, so a step's `slots` count caps it machine-wide. |
| `START_SERVER` | `1` | `0`: the verify loop tests an app already running on `APP_URL` (the profile's `verify.url`). |
| `KNOWN_FLAKES` | empty | Tests that fail only under shared load: reported, not counted; each must pass when run alone. |
| `KNOWN_PLATFORM_FAILURES` | empty | Tests that fail on this platform every time and pass on CI: reported, not counted, never re-run alone. |
| `HAVE_CAPS` | empty | Capabilities this machine has beyond what the loop detects (and the profile's `verify.provides`), for tests with a `Requires:` line. |
| `MOCKUPS_DIR`, `SCHEMA_DIR` | `docs/mockups`, `docs/schema-changes` | Where design chains put pages for sign-off (or the profile's `docs`). |

## Shared (`kit/common`)

| File | What |
|---|---|
| `doctor.py [--json]` | Every dependency: ok, fallback, skipped, warn or missing; what the run does without it; the install and who runs it. Installs nothing. |
| `preflight.sh [role]` | Prints `ok` when a one-line call on the role's pin answers as that pin (default: code for a fix run, verify for a verify run). On Claude Code: only the pinned model, on its window, background calls included. |
| `crew.py` | The crew: `presets`, `use <preset>`, `set <role>=<pin>`, `models`, `check`; in a repository it writes `.laneloop/crew.json`, in a run folder `loop.conf`. |
| `agent_run.py session\|preflight\|argv\|pin` | Runs one session on a role's pin, on any agent: its command line, the runbook, the context guard (the hook on Claude Code, the event stream elsewhere), the guard-rail shims for git and gh, the end gate, the result line. `argv` shows the command without running it. |
| `consult.py <role> <name> "<question>"` | A read-only question to a role's pin (research, or plan for reviews), answered in `consults/<name>.md`; `--batch` runs many at once. |
| `agents.json` | The agents the kit drives and the models it knows: windows, efforts, prices, dated benchmark notes. |
| `launch.sh <name> <start.sh> [args]` | Starts a loop without taking focus and keeps the computer awake under it: minimised mintty (Windows), detached tmux or screen (macOS under caffeinate, Linux under systemd-inhibit). |
| `platform.sh` | Sourced by every shell script: the Windows calls (cygpath, toasts, netstat, taskkill, PowerShell) and their macOS / Linux equivalents, and `keep_awake`, `nap` and `slept_since`, which keep the computer awake and notice when it slept (on Windows, with no readable Windows pid for the process, `keep_awake` holds nothing and says so on stderr and in a toast). |
| `ctx_guard.py`, `session_result.py`, `notify.ps1`, `keep_awake.ps1` | Claude Code's context and model guard (a hook); a Claude Code session log's result line; the Windows toast; the Windows keep-awake hold. |
| `live_page.py`, `live_page.html` | The orchestrator session's one live page: a dashboard (the run's PR label linked to its pull requests, what is running, what needs the owner, PRs open and merged, cost) over a tab per task. `live_page.py <tab>...` adds this run's tabs (chain slugs, or `verify`) and writes `live/session.live.html` in the run folder, never committed (the repo ignores `*.live.html`); `--url` records where the session's page is published (a later run of the same session records the same url, and never publishes its own); `--plan-url` links the plan page. It draws itself from its own database. |
| `live_sync.py` | The writes that keep this run's tabs current (state, lines, questions, review items) and its dashboard entry, for the main session's ArtifactData batch; `--done` once written; `--attention` prints the main window's one line per thing a tab needs, with the page's link. |
| `two_way.js` | Shared by the session page and the plan page: Ask Claude (Send to Claude), and Claude's answers from the page's `replies`. |
| `project.py` | Reads the project profile: `check`, `get <key>`, `exports <section>`; the test-output parsers the gate uses. |
| `services.py up\|env\|down` | The project's background services (databases, caches, queues, listeners): a fresh one per gate slot, or the verify loop's own (kept, seeded once, reused). |

## Verify run (`kit/verify`)

| File | What |
|---|---|
| `qa-loop.sh` | The wrapper: the profile's verify services, its build and start commands until its health URL answers, the shared Chrome, the preflight, then sessions until done. |
| `start.sh` | Runs the loop and keeps its window: start it with `launch.sh "verify-<name>" <run>/start.sh`. |
| `ledger.py` / `init_ledger.py` | The run's state, and building it from `tests/*.md` (see `kit/examples/test.example.md`; an optional `Requires: <capability>` line names what the machine must have). |
| `runbook.md` | Rendered from the template; fill its FILL IN parts (what is verified, P0, approved writes, how sessions sign in, routes, sandboxes). |
| `settings.json`, `mcp.json` | Session permissions and hooks; the Chrome DevTools MCP on the run's debug port. |
| `end_gate.py` | Stop hook: no ending before the ledger and HANDOFF.md are written. |
| `wait_verify.sh` | Watcher: returns on PAUSED, the end, or a STOP, every `LIVE_SYNC_MIN` minutes when the ledger changed, and on waking from a sleep. Keeps the computer awake while it waits. |
| `raise_chrome.sh` (`raise_chrome.ps1`), `resume_on_signin.sh` | Put the run's Chrome in front on the right tab; resume the loop when the sign-in lands. |

## Fix run (`kit/fix`)

| File | What |
|---|---|
| `plan.example.json` → `plan.json` | Defects, decisions, branches by wave; `"on": "<slug>"` stacks a branch on the one it builds on, and a branch without it runs in parallel. |
| `egm_plan.py import\|check\|render\|boundary` | The hand-off from EGM ([reference/egm.md](../reference/egm.md)): imports an approved EGM design doc into `plan.json` (goals, journeys, files, verification); checks the branches drawn from it (design on the base, every file owned once per wave, every journey delivered, dependencies in earlier waves); renders the split as `fanout.md` for the Goldfish review; lists what a chain changed outside its files (a stacked branch: on top of the branch below it). |
| `plan.egm.example.json` | A plan imported from an EGM design, with its branches drawn up (`files`, `cujs`, `depends_on`). |
| `fanout_readiness.md`, `fanout-readiness-standard.md` | The Goldfish reviewer and standard `/egm:egm-review-loop` uses on `fanout.md`: hidden coupling within a wave, unowned work, missing dependencies, boundaries too narrow for their tests. |
| `plan_page.py`, `plan_page.html` | The plan page: the owner answers each grilling round on it, reads the plan (branches by wave, each broken into tasks with its proving test) and signs it off. Answers and sign-off live in the page's database. |
| `sign_plan.py` | Records the owner's sign-off in `plan.json`; refuses while a decision is open, a branch has no tasks, or a build branch is unsized (`est_lines`) or over its PR size cap. |
| `make_briefs.py` | `briefs/<slug>.md` (with the branch's title, tasks, a `Plan signed off:` line and its `Size cap:`) and a queue file, from a signed-off plan only. The runner starts no branch whose brief lacks that line. |
| `pr_size.py` | A pull request's size: `count` measures a branch (added plus removed lines, tests included; lockfiles, generated files and signed-off pages left out; a stacked branch against the branch below it) against its cap, `plan` lists every branch's estimate against `PR_MAX_LINES`. `sign_plan.py`, `egm_plan.py check` and `task.py` use it. |
| `start.sh <queue> [MAX_PAR]`, `runner.sh`, `fixloop.sh` | Run a queue of chains in parallel; one chain of sessions per branch. The runner makes the run's PR label (`PR_LABEL`) before the first chain starts, and stops if it can't, and keeps the computer awake while it lives. A stacked branch starts once the one below has opened its PR (a design branch on a design branch: once that one has pushed its page); one whose parent already merged is built from what the parent merged into. |
| `task.py`, `gate.py` | A branch's state (`task.py pin`: the plan or code pin its next session runs on; `ask` / `answer`: a question for the owner that doesn't stop the chain, and the answer from its tab of the session page; `done`: a task ticked; `size`: the branch against its PR size cap, which the pr phase and `ready` enforce; `cap`: a cap the owner raised mid-run; `pr`: the PR, recorded only once it sits on the branch's base in its stack, retargeted there if it doesn't, and put in a GitHub stack with the PR below; a read that hits a passing GitHub outage is tried 3 times); the pre-PR gate (the profile's gate steps, detached and kept awake, slot-limited by slots every run on the machine shares, each slot with its own services; `--status` names the slot a gate waits for and who holds it). |
| `pr_read.py <PR> comments\|reviews\|issue` | The chains' only way to read PR comments: GET only (chains may not call `gh api`). |
| `runbook.md`, `settings.json`, `end_gate.py` | What every chain session is told and allowed; its stop hook. |
| `status.py [queue]` | Every branch's state, phase, PR and last note. |
| `wait_chain.sh`, `wait_gate.sh <slug>`, `wait_ci.sh <PR>...` | Watchers; each keeps the computer awake while it waits, times out after `WAIT_HOURS` of awake time and prints the state it saw. `wait_chain.sh` also returns on a chain's question, every `LIVE_SYNC_MIN` minutes when a chain's state changed, and on waking from a sleep. |
| `fix_page.py`, `md_to_page.py`, `post_publish.sh` | Make a design page publishable; render a schema page; link the published artifact in its README row. |
| `record_signoff.py` | Record a sign-off on design branches and queue their builds (`--dry-run` first). |
| `approve.py` | Record the owner's review-item approvals (from each chain's tab) and queue the chains that apply them. |
| `threads.py`, `answer.py` | List, reply to and resolve PR threads; answer summaries (the signature line added). |
| `merge_base.sh <slug>` | Bring a branch up to date with its own base (the branch below it in its stack, or the base) after merges, moving it down and retargeting its PR once the branch below merges (a retarget that fails changes nothing: INCOMPLETE, exit 4). In a GitHub stack, GitHub has moved and rebased it already: the local branch takes `origin/<branch>` (unpushed local commits: INCOMPLETE). `--commit` after resolving starts the gate. |
| `retire.sh [--all-runs] [--apply]` | Remove worktrees and branches of merged PRs, keeping their state. After every merge batch; `--all-runs` covers earlier runs' late merges. |

## Changing the kit

`bash <kit>/selftest.sh` renders both kinds of run from a test profile and runs the scripts against stubs
(claude, pmset, stand-in test runners and services), every test-output parser against sample output, and the native
PostgreSQL and MongoDB presets for real where those servers are installed. Run it on every platform a change touches
(macOS: it runs under the system's bash 3.2; `SELFTEST_BASH=<bash>` picks another). Windows branches stay as they were
unless the change is for Windows.
