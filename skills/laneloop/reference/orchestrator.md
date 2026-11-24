# The orchestrator's procedures

Everything the main session does, in the order it comes up. Commands run from the fix run folder unless noted.

## Watching (always)

- Every long process gets a background watcher the moment it starts, re-armed after every event: `wait_verify.sh`,
  `wait_chain.sh`, `wait_gate.sh <slug>`, `wait_ci.sh <PR>...`. Use the harness's background tasks, never `nohup ... &`
  (an untracked job never tells you it finished). One watcher per item you will act on separately: a combined watcher
  delays the first push until the slowest is done.
- Launch loops with `<run>/launch.sh` (a minimised mintty window on Windows, a detached tmux session under caffeinate
  on macOS), never a window that grabs focus: it takes the owner's keystrokes. On macOS, tell the owner how to watch it
  (`tmux attach -t <name>`, leave with Ctrl-b d).
- The computer stays awake while anything of the run is working: each loop (`launch.sh`) and each watcher holds it
  awake for as long as it runs (caffeinate on macOS, systemd-inhibit on Linux, `keep_awake.ps1` on Windows). A host
  app's own keep-awake usually lets go a few minutes after the main session goes idle, so it doesn't cover a run. A
  closed laptop lid still sleeps it: at the start, tell the owner to keep the lid open and the laptop on mains power.
- A watcher that returns with `the computer slept for <time>` means everything paused, nothing failed. Before
  re-arming it: `status.py` for every chain, `wait_ci.sh` for each PR whose checks you were waiting on, sync the live
  pages. Session time caps and `WAIT_HOURS` count awake time, and a session the computer slept through without
  progress is no strike.
- When you've been quiet a while, say in a line what you're doing.
- Every time a watcher returns, before anything else: sync the session page and post the attention lines ("Live Pages"
  below). The chat never carries a chain's question itself, only its link.

## Missing dependencies (set-up, before the first start)

`doctor.py` in the run folder checks the machine; nothing is installed without the owner's yes, and never mid-run.

1. Run it (`--json` for the details). Items: **ok**; **fallback** (the same checks another way: tell the owner in a
   line, no decision); **skipped** (already the owner's decision); **warn** (read the
   note: on battery, data in a temp folder, too many chains for the memory); **missing** (blocks the start).
2. For each missing item:
   - `who: claude`: batch them into ONE question (install all as listed, recommended / leave one out and take its
     fallback, which the question names / stop). On a yes, run exactly the listed commands, then re-run the doctor.
   - `who: owner` (a password, a first launch in a window, an Apple ID, a licence, a sign-in): give the exact commands
     in one block to run in their own terminal; never run sudo, accept a licence or sign in for them. Re-run the doctor
     when they say it's done.
   - An `ask` (`GATE_SKIP=<step>`, `START_SERVER=0`, `PLANNER=grill`): fewer checks, so only on the owner's explicit
     decision, with what it costs in the question (e.g. "CI's integration job runs that suite instead"; "the loop tests
     the app someone else runs"). Recommend installing over skipping when the install is the owner's to do once. On a yes: `init_run.py ...
     KEY=VALUE`, and a dated line in the runbook's hard rules.
3. Start only when the doctor exits 0 and `./preflight.sh` prints `ok` (a fix run with design branches: `./preflight.sh
   plan` too).
4. Mid-run, a service the run started that stops (Docker, a database server, the run's Chrome) shows as its own state
   ("postgres did not come up", "the run's Chrome is not running"), not as test failures: restart it (it is already
   installed and local) and requeue. Anything new to install goes back through step 2.

## Planning (Every Fix Run)

With `PLANNER=egm` (the default) EGM designs the work and the orchestrator fans the approved design out:
[egm.md](egm.md) has that procedure. Steps 1 to 3 below (verify, investigate, classify) come first either way and feed
EGM's brainstorm; steps 4 and 5 (grilling rounds, drawing up the plan) are the `PLANNER=grill` way; step 6 (sign-off)
applies to both.

Plan on the plan pin (`PLAN_PIN`; `crew.py` shows it): when it is this session's own agent, set this session to its model
and effort (`/model`, `/effort` in Claude Code) before triage, and switch back to the owner's choice once the plan is
signed off. When it is another agent, draft here and have the plan pin review each draft, the split and the plan page
with `consult.py plan`, and carry its findings into the next draft. A run that starts from a list of tickets instead of a verify run plans the same way: no chain starts before
`sign_plan.py`.

1. **Verify before escalating.** A defect a loop session drafted is a lead, not a finding: read the later sessions' notes
   and the code before calling it a bug, and never "restore" data on the strength of one session's guess.
2. **Investigate by area** on the research pin: one `consult.py research <area> "<question>"` per area, all at once
   (`--batch`), each answer in `consults/<area>.md` with file:line evidence. Read-only subagents of this session do as
   well when the research pin is this session's own agent and model.
3. **Classify each defect:** BUG (fix it), DECISION (the owner chooses the behaviour), GUIDE (the test plan is wrong). Give
   each a gate: none, decision, mockup (any pixel a user sees changes), schema (any stored field, collection or index
   changes; fields never stored need no page).
4. **Grill, in rounds, on the plan page** (the `grilling` skill). The decisions form a tree; a
   round is its frontier: every question whose prerequisites are settled, each a `decisions` entry with `round`, a short
   `title` (Every Word Capitalized), `context` (what happened, with real ids from the run, and where in the process it
   bites), `options` and the `recommend`ed one. Group questions by situation: one situation is one question whose
   options are whole outcomes. A choice with one sensible answer is stated as the plan, not asked. Facts are yours to
   find (dispatch a read-only agent); only decisions go to the owner.
   - `plan_page.py plan.json plan.html "<Title>"`, publish to the same URL each round, and post one line in the chat:
     "Round N is ready: <k> questions → <link>". The page's "Send This Round To Claude" wakes you.
   - Read the answers: `ArtifactData` list, collection `answers` (doc ids `d<n>`). Record each as the decision's
     `"decided"` (a note can amend the option; keep its words). Write a reply in `replies/d<n>` when an answer needs one.
   - the `domain-modeling` skill as the answers land: each decision worth keeping goes into
     the feature's decisions log as a D-numbered entry; each term the owner settled goes into `docs/glossary.md`.
   - Recompute the frontier and publish the next round, until it is empty: nothing left silently assumed.
5. **Draw up the plan** on the same page: branches by wave (wave 1 = no gate, wave 2 = mockup-gated, wave 3 =
   schema-gated; a branch that depends on another waits for it). A branch that builds on another branch's code names it,
   `"on": "<slug>"`: it is stacked on it, built on that branch and opening its PR against it. A branch with no `"on"` is
   independent: it is built from the base and runs in parallel with everything else. Each has a `title`, its binding `scope` and its
   `tasks`: every outcome the branch delivers, each with the test that proves it (a design branch's tasks are what its
   page must show), and, for a build branch, `est_lines` under the PR cap ("Sizing Branches" below). A branch with no
   tasks is not planned yet.
6. **Sign-off.** The page's Sign Off button (collection `signoff`, doc `plan`) or the owner's own words; never a bare
   "done" with nothing answered. Then `sign_plan.py plan.json "<when>" "<who>"`: it refuses while a decision is open, a
   branch has no tasks, or a build branch is unsized or over its cap, and `make_briefs.py` refuses until it has run.

## Sizing Branches

Every build branch becomes one pull request of at most `PR_MAX_LINES` changed lines (400 unless the owner chose
otherwise): added plus removed, tests included, as GitHub counts them. Lockfiles, snapshots, minified and
`linguist-generated` files, binaries and the signed-off mockup and schema pages don't count, nor does anything matching
the profile's `pr_size.exclude` ([project.md](project.md)). A reviewer reads a small PR properly and skims a big one;
the cap is how the run keeps every PR reviewable.

- **Estimate** each build branch's `est_lines` from the research, not from hope: each file's change (the design's
  Proposed Changes, the consults' file:line evidence), the callers and tests a changed signature drags in, a test per
  task (usually as many lines as the code it proves), and the docs. A defect's `size` (S, M, L) is a hint, not a count.
- **Aim for three quarters of the cap.** Estimates run low, and a chain that runs over stops mid-build for a split.
- **Split by task** when a branch won't fit: each task moves with its test, and a branch that builds on another
  depends on it (a later wave). Never split a task across branches, and never split off the tests.
- **A branch that can't be split** (one generated client, a rename across many files, a migration reviewed as one):
  give it `max_lines` with `max_lines_why`. The plan page shows both, and the owner's sign-off approves the exception.
- `pr_size.py plan plan.json` lists every branch's estimate against its cap; `sign_plan.py` (and, for an EGM plan,
  `egm_plan.py check`) refuses a build branch with no estimate, or one over its cap. Design branches need no estimate:
  the chain that builds after the sign-off keeps to the same cap, so if the signed-off page clearly needs more, split
  the build before you requeue it (below).

## Decisions After The Plan

- A question that comes up mid-run and isn't a chain's goes on the plan page as a new round, never into a pop-up.
- A follow-up that changes a branch's scope goes into that branch's brief or a note before it starts.
- Reply on each comment thread with what you recorded, then resolve it. A thread that was already answered once needs
  `acknowledge_duplicate` for a reply that adds a new decision.
- Record every decision in the plan (`"decided"`), the feature's decisions log in the repo when the branch ships, and
  memory when it is a standing rule.

## A Chain Over Its Size Cap

A chain checks its size with `task.py size` as it builds, and `task.py` refuses the pr phase, and `ready`, over its cap.
So a chain that won't fit stops with `needs`: "over the size cap: N of CAP lines; split: <tasks that stay> here, <tasks
that move> to a follow-up branch". Its commits stay on the branch. The ask is on its tab of the session page; the choice is the
owner's, because the plan changes.

- **Split** (the usual answer): add the follow-up branch to `plan.json` with the tasks that move, their tests and an
  `est_lines`, in a later wave that `depends_on` the stopped branch; take those tasks out of the stopped branch. Run
  `pr_size.py plan plan.json`, re-render and republish the plan page, and once the owner agrees, record it with
  `sign_plan.py` again. Then `task.py note "SPLIT (<owner>, <when>): this branch keeps T1, T2; T3 moved to <slug>"` in
  the stopped branch (its brief is already copied, so the note carries the change), requeue it, and run the follow-up's
  brief with its wave (`make_briefs.py plan.json --slugs <slug>` once the branch it depends on merges).
- **Raise the cap** for this branch only, when the owner says so: `task.py cap <lines> "<their reason>"` in the branch's
  worktree, and the same `max_lines` and `max_lines_why` in `plan.json`, so the plan says what was agreed. Then requeue.
- Review items that would take an open PR over its cap stop the same way: the items that fit are pushed, and the rest
  go to a follow-up branch or a ticket, as the owner decides.

## Live Pages

The orchestrator session has ONE live page: a dashboard of the whole session (the PR label every pull request of the
run carries, linked to the list of them; what is running, what needs the owner, what is ready for review, what is done;
PRs open and merged; sessions and cost; the plan page) over a tab per task, one for each chain and one for the verify
loop. Each tab is the owner's one place to see that task, answer it and ask it things. The main window carries none of
that conversation. A message there scrolls away; the tab keeps an unanswered question on top, and the tab strip marks
every tab that needs the owner.

1. **Publish once, before the first start.** `live_page.py --title "<Session Title>" <tab> ...` in the first run folder
   (a fix run's chain slugs, or `verify` in a verify run folder) records the tabs and writes `live/session.live.html`;
   it prints the capabilities. Publish it with the Artifact tool (that file, those capabilities, icon `pulse`), then
   `live_page.py --url <url>`. A later run folder of the same session (the fix run after the verify run, or the other
   way round) adds its own tabs with `live_page.py <tab> ...` and records the SAME url with `live_page.py --url <url>`:
   it never publishes a page of its own. A later wave adds its chains the same way; new tabs reach the page with the
   next sync, without a republish. `live_page.py --plan-url <url>` puts the plan page's link on the dashboard. Never copy
   the page into the repo: `*.live.html` is ignored, and the page holds run state. `verify` is the verify loop's tab id;
   a chain can't be called that.
2. **Sync whenever a watcher returns.** `live_sync.py --all` in each run folder of the session prints `{"url", "writes",
   "attention"}`; write `writes` with `ArtifactData` (action `batch`, that url, up to 50 per call, in order), then
   `live_sync.py --all --done`. Nothing reaches the page you don't write. Its collections are flat and every document
   names its `tab`: `state/<tab>` (one per tab, replaced as the task moves), `session/<run>` (the run's label,
   repository, base and plan page), and `events`, `asks`, `reviews` and `replies` keyed `<tab>~<id>`. A page holds at
   most 25,000 documents; the sync warns from 20,000.
3. **Post the attention lines.** `live_sync.py --attention` prints one line per thing a tab needs the owner for
   ("Needs you · <tab>: <one line> → <link>", "Ready · <tab>: ... → <link>"). Post exactly those, and post them again
   in every status update until each is answered.
4. **Relay what the owner does on a tab.** Only the owner can write the page's answers and approvals (the capabilities
   the script prints make every collection owner-only); anyone the page is shared with can read it and Ask Claude. A
   Send to Claude from the page wakes you (its text names the tab); otherwise read `answers` and `approvals` when you
   sync. Their ids name the tab: `answers/<tab>~Q1`, `approvals/<tab>~r2`. An answer to a chain's question: `task.py
   answer Q1 "<answer>"` in that chain's worktree, and if the chain stopped holding its PR, `task.py requeue "answered"`
   and queue it. An answer to a `needs` stop: `task.py note "OWNER ANSWER needs-<n> (<owner>): <answer>"`, requeue. A
   verify ask: requeue the test with the answer as a note. Then write `replies/<tab>~<id>` (with `tab`) saying what you
   did with it.
5. **Answer every question** sent from a tab, in its thread and in `replies` (a free question gets a `<tab>~q-<n>` doc
   with `tab`, `question`, `where`, `text`, `at`), from the task's notes, HANDOFF.md, commits and logs. Check every claim
   first.
6. **One watch.** The session's page is one artifact, so one `ArtifactComments` watch covers every task, however many
   chains run (a session can watch at most 10 artifacts: the plan page and the design pages share the rest).

## Design and schema pages

1. Read the chain's page in full (the Artifact tool requires it for files you didn't write).
2. `fix_page.py <page>`: removes a document skeleton of its own, enforces the 16px phone gutter, checks the title and the
   dark-mode tokens. Fix anything else by hand.
3. **Cross-check overlaps**: two pages that change the same row or screen must agree; add a note to both and an option
   that says it once.
4. Publish. Schema pages are markdown: `md_to_page.py <slug> <md path> "<Title>" <out.html>`, then publish the HTML.
   Pages that link each other: publish one, put its URL into the other, publish that, then republish the first.
5. `post_publish.sh <slug> <page> <url> "<choices; open>"` after the publish returns (never in parallel with it: it refuses
   anything that isn't an artifact URL). It links the README row, commits, pushes and logs the page in `design-pages.md`.
6. Send the owner every link with its open questions in one message. A session can watch only 10 artifacts; beyond that,
   read comments (`ArtifactComments read`) when the owner says they've commented.
7. **Sign-off must be explicit.** If the owner says "done" and the pages have no comments, ask: sign off all as
   recommended, or comment first. Then `record_signoff.py signoffs.json queue-build.txt <date>` (try `--dry-run` first) and
   start the build queue.

## Review Comments, On Each Chain's Tab

1. When a chain ends `awaiting_owner` with review items, read every proposal (`task.py show`, `status.json` reviews).
2. Set your own recommendation per item in `live/<slug>.recs.json`: `{"1": {"rec": "Apply", "what": "...", "proposal":
   "..."}}`, rec **Apply** (as proposed), **Reply only** (no change, with the reason) or **Owner's call** (say what you
   recommend). `what` and `proposal` restate the bot's words as what the user or the system sees: who is affected, what
   they see, the fix in one line. Wording a signed-off page doesn't settle is always Owner's call.
3. Sync: each item goes up on the chain's tab with its recommendation. Post its "Ready" line. The owner approves all as
   recommended on the tab, or adds a note to change one.
4. From the page's `approvals` for that tab (`approvals/<tab>~r<n>`, and any note), write `approvals.json` and run `approve.py approvals.json
   queue-review.txt "<how approved>"`, then start the runner on the queue. Answer the PRs whose items are all reply-only
   straight away.
5. As each chain ends:
   - `answer.py <PR> <slug> --map`; items with no comment id map to NO THREAD: match those by the thread text
     (`threads.py list <PR>`).
   - Write the replies from what the chain actually pushed (`git log` in the worktree): "Fixed in <sha> (failing test first
     in <sha>): ..." or "No change, by <owner>'s decision: <reason>". **Check every claim** (a test you say exists, a line
     you quote) before posting; if you got one wrong, post a correction on the thread.
   - `answer.py <PR> <slug> replies/<PR>.json` replies and resolves; the signature line is added.
   - Bot review summaries list findings outside the diff: read `threads.py comments` and `threads.py reviews`, and answer
     each summary with `threads.py comment`, or the owner sees unresolved comments with every thread resolved.
   - Check `gh pr view <PR> --json mergeable` and report the PR ready to merge.

## Tickets

Out-of-scope findings, "its own ticket" decisions and follow-ups go into the team's issue tracker (through the repo's
own tickets skill or CLI, if it has one): dedupe first, set the status and type, propose a priority with a one-line
reason, say the scope. Chains can't reach the tracker: file what their notes name. Keep a `followups.md` in
the run for what isn't a ticket yet.

## Merging and integrating

- The owner merges (branch protection; the auto-mode classifier blocks Claude from admin-merging, and that is not to be
  worked around). Batch merge requests: one message listing every ready PR.
- After every merge batch, first `retire.sh --apply`: each merged PR's worktree and branch go as it merges, not at the
  end of the run. A worktree is 5+ GB of builds; left to the close, they outlived their runs and filled the disk.
- A stack is merged from its PR page (or `PUT /repos/{owner}/{repo}/pulls/{n}/merge-async`): `gh pr merge` refuses a
  PR in a GitHub stack.
- After merges, for every open PR, **each stack bottom-up** (the branch below must be pushed before the one above it
  merges it):
  1. `gh pr view <n> --json mergeable,mergeStateStatus` (UNKNOWN means GitHub is still computing: ask again).
  2. `merge_base.sh <slug>` merges the branch's own base (`.fixloop/base`: the branch below it, or the base at the
     bottom). Once the branch below has merged, it moves the branch down onto what that one merged into and retargets
     its PR (`gh pr edit --base`); if the retarget fails it prints INCOMPLETE with the reason, changes nothing and exits
     4: fix that (usually gh auth) and run it again. In a GitHub stack, GitHub has already moved the PR down and rebased
     (force-pushed) its branch: `merge_base.sh` then brings the local branch to `origin/<branch>`, writes the PR's live
     base to `.fixloop/base`, merges and retargets nothing and exits 0. It tells "rebased" from "local work never
     pushed" by every tip `origin/<branch>` has had here: the one before its fetch and the reflog's (which expires), so
     a rebase is still seen with no reflog. Local commits never pushed stop it INCOMPLETE
     (exit 4) rather than lose them, as does a stacked PR GitHub hasn't rebased yet (run it again later). Never
     force-push a stacked branch. Clean: check the shared files it prints for semantic clashes and build. Conflicts:
     - Two sides added different members, rows or sections at the same spot: keep both; when the conflict sits mid-method,
       the shared closing lines must close each side's member.
     - One side moved code the other side changed (a call moved into a service, a release added on the old path): carry
       the change to the new place, and retire tests that pinned the old place with a replacement at the new one.
     - Read every auto-merged hunk in the conflicted files: an inserted line can reference a variable that doesn't exist
       in its new scope and still merge cleanly.
     - Use CRLF-agnostic matching when scripting a resolution, and write resolution scripts to a file (shell escaping of
       `\r` and `\n` inside heredocs corrupts them).
  3. `merge_base.sh <slug> --commit "<what conflicted and how it was resolved>"` starts the gate; `wait_gate.sh <slug>`;
     a known-flaky failure is confirmed by running it alone. Push, `wait_ci.sh <PR>`, report.
- A PR merged earlier may make a still-open one fail to compile without any textual conflict: re-merge and build before
  telling the owner it is ready.
- Verify after a batch merges that each merged PR's last commit is its head (nothing pushed after the merge was lost).

## Re-verify and close

- Requeue the verify tests the merged fixes cover; leave tests whose other defects are still open. Notes on each requeued
  test say what merged, what the guide now expects, and what is known-pending and how to judge it.
- New failures from the re-run go back to triage with the run's evidence.
- `retire.sh --apply` once more (state copied to `<run>/retired/`); remove the verify worktree and any base worktree
  (`git worktree remove`), which it never touches. Stop runner windows.
- PRs still open at the close merge later, with no session watching: say so in the hand-off. The next run's
  `retire.sh --all-runs --apply` retires them, and every earlier run's other late merges.
- Save to memory what changed how you or the owner work (a rule, a correction), not what the repo already records.
