# Pitfalls, and what fixed each one

Each entry is a failure seen in a real run. Symptom → cause → fix.

## Headless sessions

- **Four chains stopped as 'no progress' overnight.** → The account hit its usage limit: every session ended in one turn,
  $0, `api_error: usage_limit_reached`, and the stall guard counted them as strikes. → A usage-limit session is neither
  a session nor a strike: the loop waits for the reset, checking with the preflight every 30 minutes.
- **A chain couldn't read its PR's review comments.** → `pr_read.py` printed a bot comment's emoji to a cp1252 console
  and crashed. → It writes UTF-8 whatever the console.
- **The guard crashed every session.** → The session ran with `--no-session-persistence`, so there was no transcript to
  measure. → Never use that flag for a loop session (the preflight's one-line call is the only place it's fine). The
  guard fails closed: a guard that can't measure stops the session.
- **The wrapper couldn't parse a session's output.** → The prompt was passed as an argument and the CLI printed a
  "no stdin data" warning into stdout. → Feed the prompt on stdin.
- **Context was never metered.** → A status line doesn't run in `-p` mode. → Meter in a PostToolUse hook from the
  transcript's last `usage`, plus the tool results returned since (summed across parallel calls under a lock, x1.25 + 300
  for framing, 1600 per image).
- **Background calls ran on another model.** → Helper calls use the small/fast model. → Set
  `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` to the pinned model; the preflight fails if a second
  model shows up. (`fixloop.sh` sets them per session, to the plan or code pin that session runs on.)
- **A session tried to end with nothing recorded.** → Nothing required the hand-off. → A Stop hook blocks once until the
  state file and the hand-off are newer than the session's start. (Agents without hooks: `agent_run.py` resumes the
  session once with the same ask.)
- **A guard-rail shim ran itself forever.** → To find the real `gh` it skipped its own folder on PATH by comparing path
  strings, and the folder was spelled two ways (`T//x` on PATH, `T/x` from `pwd`), so it found itself. → Compare the
  files (`-ef`), never the spellings.

## Windows

- **Dozens of console windows opened.** → Every build, test and `tasklist` child of the detached gate got its own console.
  → `CREATE_NO_WINDOW` on the gate and on every child.
- **The owner's keystrokes went into a new runner window.** → A new mintty window takes focus. → Launch runners and loops
  with `mintty -w min`.
- **Closing those windows killed builds.** → They were the builds. → Don't close loop windows; stop a run through its
  own controls.
- **Scripts that edit files broke.** → Shell escaping turned `\r\n` inside a heredoc into real line breaks; files had CRLF
  endings. → Write edit scripts to a file and run them; match with `\r?\n`; read and write with `newline=""`.
- **`UnicodeEncodeError` printing bot comments.** → cp1252 console, emoji in comments. → `PYTHONIOENCODING=utf-8`.
- **Paths too long.** → Deep worktree paths pass MAX_PATH in build output folders. → Keep the worktree root short (`C:/w/...`).
- **The disk filled with merged worktrees (85 of them, ~360 GB).** → `retire.sh` ran once, at the close, before the owner
  merged the last PRs; some runs never ran it; and `git worktree remove` stopped at the first path past MAX_PATH, leaving
  the builds behind. → Retire after every merge batch, `--all-runs` at a new run's start, and remove with
  `core.longpaths=true` (retire.sh does).

## macOS

- **Nothing started: the preflight refused with a blank reason.** → macOS has no `python`; every script, hook and
  allow-list entry called it (and with the hooks missing, the context guard would not have run at all). → loop.conf
  `PYTHON` (`python3` on macOS), rendered into everything; `init_run.py` picks it.
- **`./preflight.sh: Permission denied`.** → `init_run.py` wrote scripts without the exec bit (Windows never needs one).
  → It sets 0755 on every `.sh` and `.py` it writes.
- **The runner died at once.** → `mapfile` and `declare -A` are bash 4; macOS ships bash 3.2, and a login shell's
  path_helper puts Homebrew's bash behind it anyway. → `runner.sh` is plain bash 3.2; launch with `bash`, not `bash -l`.
- **Every gate failed.** → `creationflags` is Windows-only (Python raises on any value elsewhere) and `tasklist` doesn't
  exist. → Windows-only flags; `os.kill(pid, 0)` and `start_new_session` on POSIX.
- **A verify run could test a stale server.** → BSD `netstat` has no `-o`, so the port always looked free; a server
  already on the app's port kept answering the health check while the loop's own failed to bind. → `lsof -sTCP:LISTEN`.
- **Two preflights at once shared one file.** → BSD `mktemp` randomises only trailing X's: `preflight.XXXXXX.json`
  was a literal name. → No suffix after the X's.
- **A document-rendering test failed only on one Mac.** → The runtime formatted dates and numbers by the process
  locale, and the Mac's region wasn't the one CI uses. → Pin the locale in the profile's `env` (the .NET preset does).
- **PostgreSQL wouldn't start on macOS: "postmaster became multithreaded during startup".** → The shell's locale
  wasn't one Postgres accepts. → The native preset runs `initdb` and `postgres` with `LC_ALL=C`; a start command that
  dies fails at once with the end of its log, rather than waiting out the timeout.
- **One test failed every macOS gate and passed on CI.** → It used a platform API that behaves differently on macOS, so
  it can never pass there; and its known-flake entry never matched, because the runner prints a failure by its bare
  name. → `KNOWN_PLATFORM_FAILURES`, apart from flakes: a flake must pass alone, this one can't. Name each as the runner
  prints it.
- **Two integration runs on one database server clobbered each other.** → The suite uses fixed database names. → One
  fresh service instance per gate slot, on a port no other gate on the machine holds (`services.py`); a port already
  in use by another program is an error, never shared.
- **The verify database's data sat in a session's scratchpad under /tmp.** → macOS clears temp folders, and the seeded
  test accounts go with them. → The verify loop's services keep their data in a `persist` folder under `~/.laneloop/`.
- **An unattended run stopped overnight.** → The Mac slept. → `launch.sh` runs loops under `caffeinate -is` and refuses
  on battery, where caffeinate can't hold the Mac awake. A closed lid still sleeps it.
- **Three gates stalled mid-suite while the owner was away.** → They were started straight from the orchestrator and
  `merge_base.sh --commit`, not through `launch.sh`, so nothing held the Mac awake; only the display being on did. →
  `gate.py --start` runs the gate under `caffeinate -is` (systemd-inhibit on Linux, `SetThreadExecutionState` on
  Windows), and `runner.sh` keeps the computer awake for as long as it lives (`keep_awake`), however either was started.
- **Chains and PR checks went unwatched once the loops ended, and the computer slept.** → Only the loops held it awake;
  the orchestrator's watchers didn't, and the desktop app's own keep-awake lets go once the session goes idle. On
  waking, wall-clock timeouts fired at once: a session killed as a runaway, a watcher reporting TIMEOUT. → Every watcher
  holds the computer awake while it waits (`keep_awake` in `platform.sh`, on macOS, Linux and Windows), session caps and
  `WAIT_HOURS` count awake time, a watcher returns with `the computer slept for <time>` so the orchestrator re-checks,
  and a session slept through without progress is no strike.

## The verify stack

- **Every webhook event was refused (400).** → The framework's launch profile set its own webhook secret, which
  overrode the one the provider's CLI listener signs with. → Export the app's settings explicitly (`verify.env`, the
  services' env) and start it the way that skips the launch profile.
- **The owner signed in, but the loop still saw the sign-in page.** → They signed in in their own browser. → Check the
  run's Chrome over its debug port; raise that window on the right tab; let `resume_on_signin.sh` resume the loop.
- **A pause sat for three and a half hours.** → Nobody was watching the loop's log. → Arm `wait_verify.sh` whenever the
  loop runs and re-arm it after every event.
- **The pause rule was read too narrowly, then too widely.** → "Don't pause" was taken to mean nothing ever pauses. → The
  rule is in the ledger: `pause` needs `--signin`, everything else is `needs`.
- **A reset didn't take.** → The code read a settings copy of a stamp while the reset cleared the config copy; later the
  app stamped it again by itself. → Check which copy the code reads before writing; expect the app to re-stamp after a
  run through the flow, and check again before a requeue.
- **A loop-drafted defect was escalated as a production risk and was wrong.** → One session misread a confirm step. →
  Read later sessions' notes and the code before escalating; never "restore" data on one session's word.
- **An unmatched route looked like broken auth.** → It redirected to the sign-in page and signed the session out. → The
  runbook names where routes are defined; sessions resolve a URL there instead of guessing.

## Fix chains and CI

- **The gate passed with zero integration tests.** → A stalled test-database host reported a pass with nothing run. → A
  suite that ran zero tests fails the gate (every parser counts what ran).
- **Timing tests failed only under load.** → Several gates share the machine. → `KNOWN_FLAKES`, and confirm each one alone.
- **Every gate crawled with several runs going.** → The gate slots lived in each run's own folder, so a step's count held
  per run: with four or five runs at once a 24-thread machine ran up to 8 integration and 12 unit suites together, and
  the integration suite took 2,000-6,800 s (1,100-1,350 s alone), unit up to 3,400 s (350-560 s). Two runs holding
  slot 0 of a step also started its service on the same port. → One set of slots for the machine (`GATE_SLOTS`,
  `~/.laneloop/gate-slots`), shared by every run and project; each service instance on a port no other gate holds. A
  gate over the limit waits, and `gate.py --status` says for which slot and behind whom.
- **Brief line numbers were off.** → The investigation read an older base. → Say which commit the notes came from.
- **A chain couldn't file a ticket or run a migration script.** → The tracker and script runners aren't allowed in chains. → The chain
  notes what to file; the orchestrator files it; a migration script runs first as a dry run on dev.
- **CI "passed" but nothing reviewed the new commits.** → The review bot skips plain pushes; security review runs on the
  first commit only; Codex hit its usage limit. → The chain says so in its summary; ask for a re-review when it matters.
- **Every check failed in 2 to 3 seconds with zero steps.** → The GitHub Actions budget, not the code.
- **Commits pushed after a merge never reached the base.** → The PR was already merged; only push-triggered jobs ran. →
  After a merge batch, compare each merged PR's head with its branch tip.
- **One feature's parallel PRs kept conflicting with each other and with the base.** → Branches that built on each
  other were ordinary PRs off the base, so every merge reopened conflicts in the others. → A branch that builds on
  another is stacked on it (`"on"` in the plan, `Stacked on:` in its brief, `.fixloop/base` in its worktree), while
  independent branches still run in parallel; the runner starts a stacked branch once the one below has a PR; `merge_base.sh` updates a stack bottom-up and moves a branch
  down, retargeting its PR, once the branch below merges.
- **Stacked PRs got no review, security or size checks.** → The repository's workflows ran only on PRs whose base is the
  default branch (`pull_request: branches: [main]`). → Every such filter also takes the run's branch prefix
  (`ai-work/**`), or drops the filter.
- **A design branch stacked on a design branch never started.** → The runner waited for the parent's PR, and a design
  chain opens none: it pushes its page and ends awaiting the owner. → A design branch on a design branch starts once
  that one ends awaiting the owner; a build branch on it still waits for a PR.
- **A branch whose parent merged before it started got no worktree.** → `fixloop.sh` fetched the parent's branch, which
  had been deleted after the merge. → It builds on what the parent merged into, as `merge_base.sh` does.
- **`merge_base.sh` moved a branch down while its PR still targeted the merged branch.** → It wrote `.fixloop/base`
  before `gh pr edit` and ignored a failure. → The new base is kept only once the retarget succeeds; otherwise it prints
  INCOMPLETE with gh's reason, merges nothing and exits 4.
- **Chains made base-chained PRs, never a GitHub stack, and the owner stacked them by hand.** → `task.py pr` only
  checked the base. → It also makes or extends the GitHub stack with the PR below. Two things change once PRs are
  stacked: `gh pr merge` refuses a stacked PR (merge from the PR page, or `merge-async`), and when a PR below merges
  GitHub retargets the next PR and rebases (force-pushes) its branch, so a merge on top of the old local branch can't
  be pushed. → `merge_base.sh` takes GitHub's rebase instead (stopping on unpushed local commits); nobody force-pushes a
  stacked branch.
- **A GitHub rebase could read as "not rebased yet" forever.** → `merge_base.sh` knew the remote branch's old tips only
  from the reflog of `origin/<branch>`, which expires. → It also counts that ref's tip before the fetch, the way
  `push --force-with-lease` tells a rewrite. In the same review: `task.py pr` retries a read that hits a passing outage
  (5xx, rate limit, timeout) 3 times before refusing, and with no `BASE` in loop.json it makes no stack call (noted)
  rather than take the trunk for a branch below.

## The orchestrator

- **Changing a running loop's script.** → bash reads a script as it runs, so editing `runner.sh` or `qa-loop.sh` under a
  live run can break it mid-loop. → Leave running scripts alone: start a second runner on its own queue
  (`start.sh <queue>`; runners share the log, and every run on the machine shares the gate slots), or change the runbook, which every new session reads.
- **A placeholder step ran for real.** → A "no-op" tool call was sent in parallel with a publish and executed
  (`post_publish.sh` with `PLACEHOLDER`, then `PENDING`). → Never put a placeholder call next to a real one;
  `post_publish.sh` refuses anything that isn't an artifact URL.
- **A reply claimed a test that didn't exist.** → The proposal said "add a pinning test"; the item was approved as
  reply-only, so no test was written. → Check every claim against the branch before posting; post a correction when wrong.
- **Replies were signed in a home-made format.** → Every reply needs the same signature line. → `threads.py` appends it.
- **A watcher never reported.** → It was started with `nohup ... &`, outside the harness. → Use background tasks.
- **A watcher would have waited forever.** → It waited for PASS or FAIL, and the gate had crashed before writing any
  state (it was started on a plain worktree with no `.fixloop/`). → Every watcher matches every terminal state ("no gate
  run", "process gone", timeouts), and `gate.py --start` now says when the gate didn't start.
- **A CI watcher returned while a job was still pending.** → GitHub's API was briefly unreachable, and the watcher read gh's error as "nothing pending". → `wait_ci.sh` counts any gh failure other than "checks pending" as not done yet.
- **A push waited on unrelated work.** → One watcher waited for three gates. → One watcher per item you act on separately.
- **New pages weren't watched for comments.** → A session can watch only 10 artifacts. → Read comments when told.
- **A reply on a decided thread was refused as a duplicate.** → The thread already had a Claude reply. → Send it with
  `acknowledge_duplicate` when it records something new.
- **Two signed-off pages said the same thing on the same row.** → Different chains drew the same screen. → Cross-check
  pages that touch one screen before publishing; give the owner an option that says it once.
- **"Done" was not a sign-off.** → No page had a comment. → Ask before recording a sign-off.
- **The admin merge was refused.** → The auto-mode classifier blocks "merge without review". → The owner merges; don't
  work around it.
- **An auto-merged line didn't compile.** → A line one PR added landed in a method moved by another, referencing a
  variable that doesn't exist there. → Read every auto-merged hunk in conflicted files and build before committing.
- **A PR with no conflict no longer compiled.** → A dependency merged after it was tested. → Re-merge the base and
  build before calling it ready.
- **A read-only allow could post.** → `Bash(gh api repos/.../pulls/*)` also matches `--method POST` or `-f body=...`. →
  Chains get no `gh api` at all; they read PR comments through `pr_read.py` (GET only).
- **Bot summaries kept PRs "unresolved".** → Summary comments list findings outside the diff. → Answer each summary.
- **A schema page was asked for on an in-memory field.** → The protocol covers stored data only. →
  DTO and projection fields need no schema page.
- **Requeued tests failed again on known gaps.** → Some of their defects were still in unbuilt branches. → Requeue only
  tests whose every defect is fixed; note anything still pending and how to judge it.

- **The verify run reported linked records twice and made twin parts.** → A merged PR's migration (a deploy gate)
  had never run on the verify database. → Before every verify run, apply every new migration to it (dry run, apply, its
  read-only check), or make migrating part of the profile's `verify.build`.
- **A read-only check script merged that could never run.** → The database shell that runs it treats a file as a
  script, not a module, so its top-level `await` was a syntax error, and chains can't run that shell to find out. → Run
  any new script once (a syntax check at least) before its PR is called done.
