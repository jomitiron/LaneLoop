# LaneLoop

LaneLoop is a skill for running large engineering work as loops of fresh, headless coding-agent sessions. The spec is
engineered up front, branches run in parallel in isolated worktrees, every session stays well inside its context
window, and the owner decides at fixed gates. Each kind of work can run on a different agent and model: research on
Gemini, planning on Codex, coding on Claude, or any mix you choose.

## Contents

- [Key Features](#key-features)
- [Crews](#crews)
- [Models and Benchmarks](#models-and-benchmarks)
- [Planning with EGM](#planning-with-egm)
- [Installation](#installation)
- [Supported Stacks and Services](#supported-stacks-and-services)
- [Repository Layout](#repository-layout)
- [Development](#development)
- [License](#license)

## Key Features

- **Spec first.** Nothing is built before the owner signs off a plan: every branch broken into tasks, each with the
  test that proves it.
- **Small pull requests.** Every PR changes at most 400 lines by default, tests included, so a reviewer can read it
  properly. The plan sizes each branch under that cap before sign-off, and a chain that won't fit stops and proposes a
  split instead of opening an oversized PR. Lockfiles, generated files and signed-off design pages don't count, and the
  owner sets the cap per run (`PR_MAX_LINES`).
- **Any agent, per role.** A run's crew pins an agent, model and effort for each role: research, plan, code and
  verify. Claude Code, Codex, Antigravity, Gemini CLI, Grok Build, OpenCode (any provider's model) and Cursor are all
  driven the same way. The ready-made crews are chosen from current benchmarks, SlopCodeBench among them.
- **PR stacks where work depends.** A branch that builds on another is stacked on it (built on it, its PR against it,
  in a GitHub stack the owner merges as one), so dependent PRs stop conflicting with each other. Independent branches
  run in parallel beside the stacks.
- **Parallel.** Each branch is its own chain of headless sessions in its own git worktree, five at a time by default,
  each with a tab on the session's one live page, where the owner follows its progress and answers its questions,
  under a dashboard of the whole run and every pull request it opened (they all carry the run's label).
- **Context-efficient.** A guard hands a session off at 65% of its context window and stops it at 72%, on every agent:
  through a hook in Claude Code and through the session's event stream elsewhere. Sessions hand over through files,
  never memory, so every session starts sharp.
- **Any stack.** Nothing in LaneLoop is tied to a language, framework or database. A project describes itself in one
  file, `.laneloop/project.json`: how it builds and tests, which services its checks need and how its app is served.

## Crews

### Roles

| Role | Responsibility | Run By |
|---|---|---|
| Research | Answers questions read-only, many at once, each in its own file. | `consult.py research` |
| Plan | Runs design branches (mockups, schema pages) and reviews plans. | Design chains, `consult.py plan` |
| Code | Runs the fix chains: failing test, fix, docs, gate, security review, pull request and CI. | `fixloop.sh` |
| Verify | Runs the live-verify loop against the running app. | `qa-loop.sh` |

### Choosing a Crew

Pick a ready-made crew, then change any role you want. Each role is set by a pin of the form
`agent/model[:effort][@window]`, for example `codex/gpt-6-astra:xhigh`. The window is needed only for a model the
skill doesn't already know.

| Command | Purpose |
|---|---|
| `crew.py presets` | Lists every crew role by role, with the reasons, and marks which are ready on this machine. |
| `crew.py use auto` | Selects the first recommended crew this machine can run. |
| `crew.py use <crew>` | Selects a crew and writes `.laneloop/crew.json`, which you commit. |
| `crew.py set <role>=<pin>` | Changes one or more roles, for example `plan=codex/gpt-6-astra:xhigh`. |
| `crew.py check` | Confirms that each agent is installed and each pin answers. |

Run each command as `python3 <kit>/common/crew.py`, where `<kit>` is the kit folder of the installed skill.

### Agents and Effort Levels

| Agent | Pin Prefix | Effort Levels |
|---|---|---|
| Claude Code | `claude` | low, medium, **high**, xhigh, max |
| Codex CLI | `codex` | low, medium, **high**, xhigh, max, ultra |
| Antigravity CLI | `agy` | low, medium, **high**, xhigh, max |
| OpenCode | `opencode` | minimal, low, medium, high, xhigh, max |
| Gemini CLI | `gemini` | Not configurable |
| Grok Build | `grok` | Not configurable |
| Cursor CLI | `cursor` | Not configurable |

Bold marks the default. OpenCode has no default: without an effort in the pin, the model's own setting applies.

### Recommended Crews

Each cell gives the model and, below it, its effort level.

| Crew | Research | Plan | Code | Verify |
|---|---|---|---|---|
| `frontier` | Opus 5.5<br>`high` | Fable 5.2<br>`high` | Opus 5.5<br>`high` | Opus 5.5<br>`xhigh` |
| `mixed` | Gemini 4 Carbon<br>`high` | GPT-6 Astra<br>`xhigh` | Opus 5.5<br>`high` | Opus 5.5<br>`xhigh` |
| `clean-code` | Opus 5.5<br>`high` | Fable 5.2<br>`high` | GPT-6 Astra<br>`xhigh` | Opus 5.5<br>`xhigh` |
| `budget` | Gemini 4 Carbon<br>`medium` | GPT-6.1 Sol<br>`high` | GPT-6.1 Sol<br>`medium` | Sonnet 5.5<br>`high` |

- **`frontier`** puts the best measured model in each role; today every role goes to Claude Code.
- **`mixed`** gives each role to the vendor that measured well in it, so the design is reviewed by a model that will
  not write the code.
- **`clean-code`** codes with GPT-6 Astra at xhigh, which has SlopCodeBench's best strict solve rate and its least
  verbose code.
- **`budget`** keeps most of the quality at a fraction of the cost.

### Single-Agent Crews

| Crew | Research | Plan | Code | Verify |
|---|---|---|---|---|
| `claude` (default) | Opus 5.5<br>`high` | Opus 5.5<br>`xhigh` | Opus 5.5<br>`high` | Opus 5.5<br>`xhigh` |
| `codex` | GPT-6.1 Sol<br>`high` | GPT-6 Astra<br>`xhigh` | GPT-6 Astra<br>`xhigh` | GPT-6 Astra<br>`high` |
| `gemini` | Gemini 4 Carbon<br>`high` | Gemini 4 Carbon<br>`xhigh` | Gemini 4 Carbon<br>`high` | Gemini 4 Carbon<br>`xhigh` |
| `grok` | Grok 4.7 | Grok 4.7 | Grok 4.7 | Grok 4.7 |

Each runs every role on one agent: Claude Code, the Codex CLI, the Antigravity CLI or Grok Build. Grok Build takes no
effort level.

## Models and Benchmarks

The models and benchmark results below are built into the skill
([agents.json](skills/laneloop/kit/common/agents.json), as of 16 November 2026).
[reference/crew.md](skills/laneloop/reference/crew.md) gives the full evidence and its sources.

### Models

| Model | Pin | Context Window | Suited To |
|---|---|---|---|
| Opus 5.5 | `claude/claude-opus-5-5[1m]` | 1M | Code, research, verify |
| Fable 5.2 | `claude/claude-fable-5-2[1m]` | 1M | Plan, research |
| Sonnet 5.5 | `claude/claude-sonnet-5-5[1m]` | 1M | Research, verify |
| Haiku 5.5 | `claude/claude-haiku-5-5[1m]` | 1M | Quick research only |
| GPT-6 Astra | `codex/gpt-6-astra` | 256K\* | Code, plan |
| GPT-6.1 Sol | `codex/gpt-6.1-sol` | 500K | Code, plan, research |
| Gemini 4 Carbon | `agy/gemini-4-carbon` | 1M\* | Research, code |
| Grok 4.7 | `grok/grok-4.7` | 256K\* | None recommended |

The pin prefix names the agent that runs the model (see [Agents and Effort Levels](#agents-and-effort-levels)); add
`:<effort>` to choose an effort level.

\* Not yet verified. If the agent reports a different window, give it in the pin, for example
`codex/gpt-6-astra:xhigh@400k`.

### SlopCodeBench

[SlopCodeBench](https://www.scbench.ai/leaderboard) (v1.0, 26 October 2026) has an agent extend its own code through
196 checkpoints as the spec changes. It scores the solve rate, **erosion** (complexity piling into a few functions) and
**verbosity** (redundant code). Entries are named by model and effort; a dash means the skill records no figure:

| Model | Effort | Isolated Solve | Cost per Checkpoint |
|---|---|---|---|
| GPT 5.6 Sol | xhigh | 32.1% | $3.84 |
| GPT-6 Astra | xhigh | 31.6% | – |
| Opus 5.5 | medium | 29.6% | $0.99 |
| GPT-6.1 Sol | medium | 29.1% | $0.91 |
| Opus 5.5 | xhigh | 27.6% | – |

- **GPT 5.6 Sol** at xhigh has the highest isolated solve rate, at nearly four times Opus 5.5's cost per checkpoint.
- **GPT-6 Astra** at xhigh has the best strict solve rate (16.3%) and the least verbose code of any entry (0.158).
- **Opus 5.5** at medium is the best value of the top ten; at xhigh it has the third-lowest erosion of the top ten
  (0.495).
- **GPT-6.1 Sol** at medium has the lowest recorded cost per checkpoint.

No agent solves a problem end to end, and agent code is 2.3 times as verbose and 2.0 times as eroded as human code.
Gemini 4 Carbon, Grok 4.7 and Fable 5.2 have no entry yet.

### Other Benchmarks

Effort is in brackets where the leaderboard states it; a dash means the model has no entry.

| Model | Terminal-Bench 4.1 | FrontierCode 2.0 | SWE-Atlas-QnA |
|---|---|---|---|
| Opus 5.5 | 65.8% (max) | 44.0 (max) | 65.9 (max) |
| Fable 5.2 | 65.8% (max) | 49.2 (xhigh) | 62.1 |
| Sonnet 5.5 | 63.9% (max) | – | 64.2 |
| Haiku 5.5 | 40.0% | – | – |
| GPT-6 Astra | 60.3% (max) | 42.6 | 59.1 |
| GPT-6.1 Sol | 60.9% (max) | 42.5 | – |
| Gemini 4 Carbon | 64.6% (high) | – | 63.7 |
| Grok 4.7 | 38.8% | – | – |

- **[Terminal-Bench 4.1](https://www.tbench.ai/leaderboard/terminal-bench/4.1)**: hard tasks in a real terminal, end
  to end. The main basis for the code role.
- **[FrontierCode 2.0](https://artificialanalysis.ai/agents/coding-agents)**: whether a change is mergeable with no
  human edits, with out-of-scope changes penalised. The nearest public measure of planning.
- **[SWE-Atlas-QnA](https://artificialanalysis.ai/agents/coding-agents)**: answering questions about real codebases.
  The nearest measure of research.

## Planning with EGM

Planning uses Google's [Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model) (EGM). The main
session is EGM's **Elephant**: it designs the work with the owner. EGM's **Goldfish**, fresh subagents with none of the
conversation, review the design. LaneLoop then splits the approved design into branches, has the Goldfish review that
split, and orchestrates the chains that build it.

| Stage | Steps |
|---|---|
| Design (EGM) | `/egm:egm-brainstorm` → `/egm:egm-draft` → `/egm:egm-review` and `/egm:egm-resolve` → the owner approves and the design is merged |
| Hand-off | `egm_plan.py import` → branches drawn up, each sized for one PR under the cap → `egm_plan.py check` → fan-out Goldfish review → the owner signs off |
| Build (LaneLoop) | `make_briefs.py` → parallel chains, dependent ones stacked (red, green, docs, gate, security, PR, CI) → review items → the owner merges |
| After merge | `/egm:egm-drift-report` → the owner updates the design doc or the code → re-verify |

The full procedure is in [reference/egm.md](skills/laneloop/reference/egm.md). `PLANNER=grill` plans the original way,
with grilling rounds on the plan page, and uses the `grilling` and `domain-modeling` companion skills where the
repository or the user has them.

## Installation

### Claude Code

LaneLoop installs as a Claude Code plugin, once per machine, and works in any repository:

```bash
claude plugin install laneloop --marketplace jomitiron/LaneLoop
```

This adds the repository as the `laneloop` marketplace and installs `laneloop@laneloop`. In a new session, Claude picks
the skill up when the work fits, or you can run `/laneloop:laneloop`.

To plan with EGM, install Google's plugin as well:

```bash
claude plugin install egm --marketplace google/elephant-goldfish-model
```

### Other Agents

Any agent that loads Agent Skills can orchestrate a run. From a clone of this repository, link the skill into the
agent's skills folder; a `git pull` in the clone then updates it:

```bash
./install.sh codex
```

| Argument | Installs Into | Read By |
|---|---|---|
| `codex` | `~/.agents/skills` | Codex CLI, Grok Build |
| `agy` or `gemini` | `~/.gemini/skills` | Antigravity CLI, Gemini CLI |
| `grok` | `~/.grok/skills` | Grok Build (which also reads Claude Code plugins) |
| `all` | All three folders above | All of the above |
| `--project <repo>` | `<repo>/.agents/skills` | Codex CLI, Antigravity CLI, Gemini CLI, OpenCode, Cursor |

Add `--copy` to copy the skill instead of linking it, for example to commit it to a repository for the whole team.

The agents in a run's crew only need to be installed and signed in; `crew.py check` and the run's `doctor.py` report
any that are missing. When the orchestrator is an agent other than Claude Code, the session page is a file the owner opens
in a browser and answers in the chat, and planning uses the grilling rounds, since EGM is a Claude Code plugin. See
[reference/crew.md](skills/laneloop/reference/crew.md).

### Updates

Turn on auto-update once: in Claude Code, open `/plugin` → **Marketplaces** → `laneloop` → **Enable auto-update**.
Claude Code then checks in the background during a session and installs any newer LaneLoop, which loads at the next
start or after `/reload-plugins`. Auto-update is off by default for marketplaces outside Anthropic's own. Without it,
update by hand:

```bash
claude plugin update laneloop@laneloop
```

A run already under way keeps the copy of the kit it was created with. Running `init_run.py` on it again brings in the
new kit and keeps the run's settings and any runbook or settings file you edited; the new render is written beside them
with a `.new` suffix.

### Coming From MetaLoop

LaneLoop was called MetaLoop. An existing install moves over by itself: the marketplace's `renames` entry tells Claude
Code that `metaloop` is now `laneloop`, so it rewrites `metaloop@metaloop` to `laneloop@metaloop` in your settings at
the next update and loads the new name. The marketplace keeps the local name you added it under (`metaloop`), which
is fine; `claude plugin update laneloop@metaloop` updates it by hand. The old repository address redirects to this one.

In the repositories you use it on, rename the folder, then commit it:

```bash
git mv .metaloop .laneloop
```

Until you do, the kit reads `.metaloop/` and says so. `METALOOP_BIN_*`, `METALOOP_ARGS_*` and `METALOOP_KEEP_AWAKE`
still work as well; their new names start with `LANELOOP_`. The verify loop keeps its database between runs in
`~/.laneloop/<project>/` now, so the first verify run after the rename seeds a fresh copy (`~/.metaloop/` can then go).

### Team Repositories

To give everyone who works in a repository LaneLoop and EGM, with LaneLoop updating itself, commit the following to
the repository's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "laneloop": {
      "source": { "source": "github", "repo": "jomitiron/LaneLoop" },
      "autoUpdate": true
    },
    "egm": {
      "source": { "source": "github", "repo": "google/elephant-goldfish-model" }
    }
  },
  "enabledPlugins": {
    "laneloop@laneloop": true,
    "egm@egm": true
  }
}
```

Claude Code registers both marketplaces for each person once they trust the folder. Enabling a plugin there does not
install it, so each person runs these commands once in the repository:

```bash
claude plugin install laneloop@laneloop --scope project
claude plugin install egm@egm --scope project
```

### Pinned Versions From npm

The GitHub install above follows every merge to `main`. To hold a team on numbered releases instead, list LaneLoop's
npm package in your own marketplace (an entry in your marketplace's `.claude-plugin/marketplace.json`) with the
versions you accept:

```json
{
  "name": "laneloop",
  "source": { "source": "npm", "package": "laneloop", "version": "^0.1.0" }
}
```

Claude Code fetches the package from npm, runs none of its scripts, and updates only when a newer release within that
range is published. Each release is also a [GitHub release](https://github.com/jomitiron/LaneLoop/releases) with its
notes.

### Project Setup

Describe the project once from the presets and commit the file this writes, `.laneloop/project.json`. Ask Claude to
set LaneLoop up for the repository and it runs this from the installed kit (`--list` shows every preset):

```bash
python3 <kit>/init_project.py --stack node --db postgres
```

Claude then starts a run (`init_run.py fix|verify <run folder> OWNER=<you>`) and uses the run's `doctor.py` to report
anything else the machine needs. `<kit>` is the kit folder inside the installed plugin; Claude knows its path. Every
session follows the repository's own instructions (`CLAUDE.md`, `AGENTS.md`).

## Supported Stacks and Services

### Stacks

| Stack | Preset (`--stack`) | Toolchain and Tests |
|---|---|---|
| Node.js | `node` | npm; Jest by default, or Vitest |
| Python | `python` | A `.venv` virtualenv; pytest |
| Ruby on Rails | `ruby` | Bundler; RSpec by default, or Minitest |
| Go | `go` | Go modules; `go vet` and `go test` |
| Rust | `rust` | Cargo; Clippy and `cargo test` |
| Java (Maven) | `java-maven` | Maven, using `./mvnw` when present; JUnit through Surefire |
| Java or Kotlin (Gradle) | `java-gradle` | Gradle; the gate goes by the exit code |
| .NET | `dotnet` | The dotnet CLI |
| PHP | `php` | Composer; PHPUnit |
| Anything else | `custom` | Every command filled in by hand |

### Databases and Services

| Service | Preset (`--db`) | Details | Exports |
|---|---|---|---|
| PostgreSQL | `postgres` | Version 16 | `DATABASE_URL` |
| MySQL | `mysql` | Version 8.4 | `DATABASE_URL` |
| MongoDB | `mongodb` | Version 7, as a single-node replica set so transactions work | `MONGO_URL` |
| Redis | `redis` | Version 7 | `REDIS_URL` |
| SQLite | `sqlite` | No server; a fresh database file per gate slot | `DATABASE_URL` |

Services run in Docker by default, or natively with `--via native`.

A preset fills in the gate's steps with the right test-output parser, the services those steps need (a fresh instance
per gate slot, on its own port, removed afterwards), how the verify loop builds, starts and health-checks the app (with
its own services, and data kept between runs and seeded once), the tools the machine needs, and the commands sessions
may run. Whatever a preset cannot know, such as how this particular app starts, it marks `FILL IN`, and the run will
not start until each one is filled in. Anything the presets do not cover takes a few lines of JSON: any command, any
test runner (given a summary pattern) and any service with a start command and a ready check.
[reference/project.md](skills/laneloop/reference/project.md) documents every field.

## Repository Layout

This repository is a Claude Code plugin, the marketplace that lists it, and a plain Agent Skill folder that any other
agent can load through `install.sh`.

| Path | Contents |
|---|---|
| [.claude-plugin/](.claude-plugin/) | `plugin.json` (the plugin) and `marketplace.json` (the catalog Claude Code installs it from). |
| [skills/laneloop/SKILL.md](skills/laneloop/SKILL.md) | The skill: when to offer a loop, the roles, the non-negotiables and the lifecycle. |
| [skills/laneloop/reference/](skills/laneloop/reference/) | The orchestrator's procedures, the project profile, the fix and verify loops, the EGM hand-off, and pitfalls met in practice. |
| [skills/laneloop/kit/](skills/laneloop/kit/) | The scripts `init_run.py` copies into a run folder (see the [kit README](skills/laneloop/kit/README.md)). |
| [skills/laneloop/kit/presets/](skills/laneloop/kit/presets/) | Ready-made project profiles: stacks, and the databases and services their checks need. |
| [skills/laneloop/kit/crews/](skills/laneloop/kit/crews/) | Ready-made crews: which agent and model researches, plans, codes and verifies. |
| [skills/laneloop/kit/common/agents.json](skills/laneloop/kit/common/agents.json) | The agents the kit drives and the models it knows, with dated benchmark notes. |
| [install.sh](install.sh) | Installs the skill for Codex, Antigravity, Gemini CLI, Grok Build, OpenCode or Cursor. |
| [evals/](evals/) | Behaviour evals for the skill (`claude plugin eval .`). |
| [.github/workflows/check.yml](.github/workflows/check.yml) | Validates the plugin and runs the kit's self-test on every pull request. |
| [package.json](package.json), [scripts/npm-release.mjs](scripts/npm-release.mjs), [.github/workflows/publish-npm.yml](.github/workflows/publish-npm.yml) | The npm package (the plugin, the skill, `install.sh`, LICENSE and NOTICE; no evals or CI), the version stamp for a release, and the workflow that publishes each GitHub release to npm. |
| [LICENSE](LICENSE), [NOTICE](NOTICE) | The Apache License 2.0, and the copyright and attribution notices that go with it. |

## Development

### Releasing Changes

Every commit on `main` is a release. `plugin.json` has no `version`, so Claude Code versions LaneLoop by commit: people
with auto-update on receive a merged change at their next session, and everyone else on `claude plugin update`.

- **Merge only what is ready.** [check.yml](.github/workflows/check.yml) validates the plugin and runs the kit's
  self-test on every pull request. Run the [evals](#evals) before merging a change to `SKILL.md` or the references.
- **Try a change before it ships.** From a clone, `claude --plugin-dir .` loads the working copy for that session
  instead of the installed plugin.
- **npm releases.** Publishing a GitHub release tagged `v<semver>` (e.g. `v0.1.0`) publishes that commit to npm as
  `laneloop@<version>` ([publish-npm.yml](.github/workflows/publish-npm.yml)). The workflow stamps the version into
  `package.json` and `plugin.json` in its own checkout only (`scripts/npm-release.mjs`), so `main` keeps versioning the
  GitHub install by commit; an npm copy with no version would read as `unknown` and never update. `npm publish` refuses
  a copy that wasn't stamped. It authenticates with npm trusted publishing, so no token is stored: on npmjs.com, in the
  package's settings, the trusted publisher is GitHub Actions, `jomitiron/LaneLoop`, workflow `publish-npm.yml`.
  Version 0.1.0 was published by hand; the next release tag is `v0.1.1` or later, since npm never accepts a version twice.
  To publish by hand: the npm account needs two-factor authentication for writes; then `npm login`,
  `node scripts/npm-release.mjs <version>`, `npm publish --provenance=false` (provenance can only be signed inside
  GitHub Actions), approve it in the browser, then `git checkout -- package.json .claude-plugin/plugin.json`.
- **Numbered releases for everyone.** To hold GitHub installs on numbered releases too, add `"version": "1.0.0"` to
  `.claude-plugin/plugin.json` on `main` and raise it for each release (`claude plugin tag --push` tags it). Users then
  receive nothing new until the version changes.

### Evals

[evals/](evals/) checks that the skill steers Claude as intended, across nine cases: from offering a loop only for wide
work, to planning with EGM before any chain starts, to giving each role the agent the owner names, to leaving merges
and sign-offs to the owner. Each case runs with and without the skill, so the report shows the difference it makes.

```bash
claude plugin eval . --judge-model sonnet
```

### Self-Test

From a clone of this repository:

```bash
bash skills/laneloop/kit/selftest.sh
```

The self-test renders a fix run and a verify run in a temporary folder from a test profile and runs the scripts against
stand-ins (a stub toolchain and a stub service), every test-output parser against sample output, and every stack
preset. Where PostgreSQL or MongoDB is installed, it also starts the native presets for real. Nothing outside the
temporary folder is touched.

## License

LaneLoop is licensed under the [Apache License, Version 2.0](LICENSE). You may use, change and redistribute it,
commercially or not, provided you keep the license and the [NOTICE](NOTICE) file with it and mark the files you change.
The license grants no rights to the LaneLoop name.

The fan-out readiness reviewer and its standard (`skills/laneloop/kit/fix/fanout_readiness.md` and
`fanout-readiness-standard.md`) are adapted from Google's [Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model),
also licensed under Apache 2.0; [NOTICE](NOTICE) lists what was taken.
