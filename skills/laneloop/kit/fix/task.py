"""State of ONE branch, kept in <worktree>/.fixloop/status.json. Run from the worktree root:  python $FIXLOOP/task.py ...

  show                         the task, phase, notes so far
  phase NAME "what was done"   NAME: red | green | docs | gate | security | pr | ci | design
  note "text"                  progress, decisions, gotchas (keep it short)
  pr NUMBER URL                the PR you opened. It must be this branch's (checked out, not a detached HEAD) and sit on
                               your base (.fixloop/base): one opened on another base is retargeted to it, and if gh can't
                               read or retarget it, nothing is recorded (exit 1). On a branch below (not the run's base)
                               it also joins that branch's PR in a GitHub stack (made, or added to on top); if GitHub
                               refuses the stack, the PR is still recorded, base-chained, and the note says why. A read
                               that hits a passing outage (5xx, rate limit, timeout) is tried 3 times, 5 s apart, before
                               it refuses
  review "comment (who, where, comment id)" "proposed resolution"
                               a review comment that needs action: PROPOSE only, never apply
  ask "Title" "question" "recommended answer" ["other answer" ...]
                               a question for the owner that does NOT stop the chain: it shows on the branch's live page,
                               you carry on with the recommended answer, and the pr phase waits until it is answered
  done TASK "how it was proved"  tick one of the brief's tasks (T1, T2, ...) once the test that proves it passes
  size                         this branch's changed lines (committed or not) against its size cap; exit 1 over it.
                               The pr phase and ready refuse a branch over its cap
  ready "summary"              PR open, CI read, review comments recorded (or a design page pushed) -> the owner decides
  needs "exact ask"            stuck on something only the owner can answer (chain stops)
  block "reason"               cannot proceed for a reason outside the task (chain stops)
  wait SECONDS                 sleep (max 900), e.g. while the gate or CI runs

Main session only: status · pin [BRIEF] (plan or code: the model pin the next session runs on; with BRIEF, for a branch
not started yet, so not signed off) · requeue "why" (back to todo, so the next runner picks it up) · answer Q1 "answer"
(the owner's answer from the live page; the next session reads it as an OWNER ANSWER note) · cap LINES "why" (the
owner's new size cap for this branch, over its brief's; a chain never sets its own)
"""
import contextlib, datetime, json, os, re, shutil, subprocess, sys, time

RUN = os.path.join(os.getcwd(), ".fixloop")
HERE = os.path.dirname(os.path.abspath(__file__))
try:  # the run's interpreter (python3 on macOS), so the usage below names the command the session is allowed to run
    CONF = json.load(open(os.path.join(HERE, "loop.json"), encoding="utf8"))
except (OSError, ValueError):
    CONF = {}
PY = CONF.get("PYTHON", "python")
OWNER = CONF.get("OWNER", "the owner")
USAGE = __doc__.replace("python $FIXLOOP", PY + " $FIXLOOP")
PATH = os.path.join(RUN, "status.json")
LOCK = PATH + ".lock"
FINAL = {"awaiting_owner", "needs_owner", "blocked", "done"}
# the fewest arguments each command takes
ARGS = {"phase": 1, "note": 1, "pr": 2, "review": 1, "done": 1, "answer": 2, "wait": 1, "cap": 2}


def now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def load():
    return json.load(open(PATH, encoding="utf8"))


def save(d):
    tmp = PATH + ".tmp"
    json.dump(d, open(tmp, "w", encoding="utf8"), indent=1)
    for _ in range(20):
        try:
            os.replace(tmp, PATH)
            return
        except PermissionError:  # a reader on Windows holds the file for a moment
            time.sleep(0.25)
    raise SystemExit("status.json is locked; try again")


@contextlib.contextmanager
def locked():
    """Each change reads, changes and writes status.json under this lock. The chain and the main session (an answer, a
    requeue) both change it, and two changes at once would lose one: the owner's answer or the chain's step."""
    for _ in range(240):
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except (FileExistsError, PermissionError):
            try:
                if time.time() - os.path.getmtime(LOCK) > 30:   # left by a process that was killed holding it
                    os.remove(LOCK)
            except OSError:
                pass
            time.sleep(0.25)
    else:
        raise SystemExit("status.json is locked; try again")
    try:
        yield
    finally:
        os.close(fd)
        os.remove(LOCK)


def wake(slug, line):
    """A line in the run's log that the main session's watcher (wait_chain.sh) wakes on. One line: a newline in a
    chain's text must not add a forged "chain ended" or "STOP" line."""
    one = lambda s: re.sub(r"[\r\n]+", " ", str(s))
    try:
        with open(os.path.join(HERE, "logs", "runner.log"), "a", encoding="utf8") as f:
            f.write(f"[{datetime.datetime.now():%m-%d %H:%M:%S}] [{one(slug)}] {one(line)}\n")
    except OSError:
        pass


def pin(brief, notes):
    """A design branch plans until its sign-off (record_signoff.py notes "SIGNED OFF (" and requeues it to build)."""
    design = re.search(r"^Mode: design\.", brief, re.M)
    return "plan" if design and not any(" SIGNED OFF (" in n for n in notes) else "code"


def real_gh():
    """gh itself, past the session's guard-rail shim (agent_run.py puts a gh that refuses `gh pr edit` and `gh api` first on
    PATH, beside its gh.deny): task.py's own calls below are the checked ones a chain may make."""
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and not os.path.exists(os.path.join(d, "gh.deny")):
            found = shutil.which("gh", path=d)
            if found:
                return found
    return "gh"


def gh(*args, stdin=None):
    try:
        r = subprocess.run([real_gh(), *args], input=stdin, capture_output=True, text=True, encoding="utf8", timeout=60)
        return r.returncode, r.stdout.strip(), (r.stderr or r.stdout).strip()[:300]
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


PASSING = re.compile(r"HTTP 5\d\d|rate limit|timed out|timeout|deadline exceeded", re.I)   # an outage, not an answer


def gh_retry(*args, stdin=None, again=PASSING):
    """gh, tried up to 3 times 5 s apart while it fails with what `again` matches (by default a passing outage: a 5xx, a
    rate limit, a timeout), so a PR that opened fine isn't refused for a moment's 502. Any other failure returns at once."""
    for _ in range(2):
        rc, out, err = gh(*args, stdin=stdin)
        if not rc or not again.search(err):
            return rc, out, err
        time.sleep(int(os.environ.get("GH_RETRY_SECS", "5")))
    return gh(*args, stdin=stdin)


def trunk():
    """The run's BASE, the bottom of every stack ("" when loop.json doesn't say): the one place both checks read it."""
    return CONF.get("BASE") or ""


def stacked(n):
    """`pr N URL` records a PR only once it is this branch's and sits on this branch's base in the stack (.fixloop/base, or
    the run's BASE): a session told to open it there may still open it on the base, and the owner would have to stack it
    by hand. A PR on another base is retargeted first. Returns the base and the note's tail; exits non-zero, recording
    nothing, if gh can't do either."""
    try:
        base = open(os.path.join(RUN, "base"), encoding="utf8").read().strip()
    except OSError:
        base = ""
    base = base or trunk()
    if not base:
        raise SystemExit(f"PR #{n} not recorded: no .fixloop/base and no BASE in loop.json, so its base can't be checked")
    repo = ["--repo", CONF["GH_REPO"]] if CONF.get("GH_REPO") else []
    rc, out, err = gh_retry("pr", "view", n, "--json", "baseRefName,headRefName", "--jq", '"\\(.baseRefName) \\(.headRefName)"', *repo)
    on, _, head = out.partition(" ")
    if rc or not on:
        raise SystemExit(f"PR #{n} not recorded: gh couldn't read its base ({err}). Check the number, then run task.py pr again")
    try:
        mine = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        mine = ""
    if not mine:   # a detached HEAD: whose PR this is can't be checked, so it is never retargeted
        raise SystemExit(f"PR #{n} not recorded: no branch is checked out here (a detached HEAD), so it can't be checked "
                         f"as this branch's. Check out this branch, then run task.py pr again")
    if head != mine:
        raise SystemExit(f"PR #{n} not recorded: it is {head}'s pull request, not this branch's ({mine}). Check the number")
    if on == base:
        return base, f" on {base}"
    rc, _, err = gh("pr", "edit", n, "--base", base, *repo)
    if rc:
        raise SystemExit(f"PR #{n} not recorded: it is on {on}, not this branch's base {base}, and gh couldn't retarget it "
                         f"({err}). It must sit on {base} before task.py pr records it")
    return base, f" on {base} (retargeted from {on} to {base})"


def stacks_in(doc):
    """The stacks in a GitHub stacks API answer (a list of them, or one): each holds pull_requests, bottom to top."""
    if isinstance(doc, dict):
        return [doc] if isinstance(doc.get("pull_requests"), list) else [s for v in doc.values() for s in stacks_in(v)]
    return [s for v in doc for s in stacks_in(v)] if isinstance(doc, list) else []


class NotStacked(Exception):
    """GitHub didn't put the PR in a stack: the PR is still recorded, base-chained, and the note says why."""


def github_stack(n, base):
    """A PR on a branch below (not the run's BASE) joins that branch's PR in a GitHub stack, so the owner sees and merges
    them as one, and GitHub moves the PR down itself when the one below merges. Stacks are linear: a second PR on the
    same parent stays base-chained. Returns the note's tail. Stacking is extra: if GitHub refuses it, or can't say, this
    raises NotStacked and the PR is recorded all the same (refusing it would hold back every branch stacked above it)."""
    if not trunk():
        return "; its GitHub stack wasn't checked: no BASE in loop.json to tell the bottom of a stack from a branch below"
    if base == trunk():
        return ""
    repo = ["--repo", CONF["GH_REPO"]] if CONF.get("GH_REPO") else []
    api = f"repos/{CONF.get('GH_REPO') or '{owner}/{repo}'}/stacks"

    def stack_of(pr):
        rc, out, err = gh_retry("api", f"{api}?pull_request={pr}")
        if rc and "404" in err:
            return None
        if rc:
            raise NotStacked(f"GitHub couldn't say which stack #{pr} is in ({err})")
        try:
            found = stacks_in(json.loads(out or "[]"))
        except ValueError:
            raise NotStacked(f"GitHub's stack answer for #{pr} wasn't JSON ({out[:100]})")
        if not found:
            return {}
        prs = [p if isinstance(p, int) else (p or {}).get("number") for p in found[0]["pull_requests"]]
        return {"number": found[0].get("number") or found[0].get("id"), "prs": prs}

    def post(path, prs):
        # 409: the stack is being changed (another PR joining it), so wait and try again; a write isn't retried on a 5xx
        rc, out, err = gh_retry("api", "-X", "POST", path, "--input", "-", stdin=json.dumps({"pull_requests": prs}),
                                again=re.compile("409"))
        if rc:
            raise NotStacked(f"GitHub refused to stack it ({err})")
        try:
            return (stacks_in(json.loads(out)) or [json.loads(out)])[0].get("number")
        except (ValueError, AttributeError):
            return None

    rc, below, err = gh_retry("pr", "view", base, "--json", "number,state", "--jq", '"\\(.number) \\(.state)"', *repo)
    parent, _, state = below.partition(" ")
    if rc or not parent.isdigit() or not state:
        raise NotStacked(f"gh couldn't find the PR of {base} below it ({err or below})")
    if state != "OPEN":
        return f"; not in a GitHub stack: the PR below, #{parent}, is {state.lower()}"
    mine = stack_of(n)
    if mine is None:
        return "; this repository has no GitHub stacks, so it stays base-chained"
    if mine:
        return f", already in GitHub stack #{mine['number']}"
    theirs = stack_of(parent)
    if not theirs:
        return f", in GitHub stack #{post(api, [int(parent), int(n)])} above #{parent}"
    if theirs["prs"][-1] == int(parent):
        post(f"{api}/{theirs['number']}/add", [int(n)])
        return f", added to GitHub stack #{theirs['number']} above #{parent}"
    return (f"; not in a GitHub stack: #{parent} already has #{theirs['prs'][-1]} above it in stack #{theirs['number']} "
            f"(GitHub stacks are linear), so this PR stays base-chained")


def size_refusal(d, what):
    """Why a branch can't publish at its size (the pr phase, or ready), or None. A design branch before its sign-off
    opens no pull request; a brief with no "Size cap:" line predates the cap, so the plan never sized it against one."""
    try:
        brief = open(os.path.join(RUN, "brief.md"), encoding="utf8").read()
    except OSError:
        return None
    if pin(brief, d["notes"]) == "plan":
        return None
    import pr_size
    cap = d.get("max_lines")
    if cap is None:
        cap = pr_size.brief_cap(brief)
    if not cap:
        return None
    try:
        s = pr_size.count(os.getcwd(), c=CONF)
    except RuntimeError as e:
        return f"can't measure this branch's size, so {what} waits: {e}. Run `git fetch origin`, then try again"
    if s["total"] <= cap:
        return None
    return (f"{pr_size.describe(s, cap)}\n{what} refused: {cap} changed lines is {OWNER}'s cap for this branch's pull "
            "request. Don't trim tests, docs or error handling, or pack code tighter, to get under it. Keep your commits "
            f"and finish this session with task.py needs \"over the size cap: {s['total']} of {cap} lines; split: "
            "<tasks that stay> here, <tasks that move> to a follow-up branch\"")


def main(a):
    sys.stdout.reconfigure(encoding="utf-8")   # a note or question with "→" must not crash `show` on Windows (cp1252)
    if not a:
        print(USAGE); return
    if a[0] == "pin" and len(a) > 1:  # the runner, for a queued branch with no worktree yet
        print(pin(open(a[1], encoding="utf8").read(), [])); return
    if not os.path.exists(PATH):
        raise SystemExit("no .fixloop/status.json here: run from the worktree root")
    cmd = a[0]
    if len(a) - 1 < ARGS.get(cmd, 0):
        raise SystemExit(f"{cmd} is missing an argument\n{USAGE}")
    if cmd == "show":
        d = load()
        print(f"{d['slug']} [{d['status']}] phase={d['phase']} pr={d.get('pr') or '-'}")
        for n in d["notes"][-12:]:
            print("  -", n)
        if d["reviews"]:
            print("  reviews recorded:", len(d["reviews"]))
        for q in d.get("asks", []):
            print(f"  {q['id']} [{q['status']}] {q['title']}: " +
                  (f"answered: {q['answer']}" if q["status"] == "answered" else f"carrying on with: {q['options'][0]['text']}"))
        if d.get("tasks_done"):
            print("  tasks done:", ", ".join(d["tasks_done"]))
        return
    if cmd == "wait":
        s = min(int(a[1]), 900); time.sleep(s); print(f"waited {s}s"); return
    if cmd == "status":
        print(load()["status"]); return
    if cmd == "size":
        import pr_size
        cap = pr_size.worktree_cap(os.getcwd(), CONF)
        try:
            s = pr_size.count(os.getcwd(), c=CONF)
        except RuntimeError as e:
            raise SystemExit(str(e))
        print(pr_size.describe(s, cap))
        sys.exit(1 if cap and s["total"] > cap else 0)
    if cmd == "pin":
        print(pin(open(os.path.join(RUN, "brief.md"), encoding="utf8").read(), load()["notes"])); return
    where = ""
    if cmd == "pr":   # before the lock: gh may take a while, and the main session writes status.json too
        if not a[1].isdigit():
            raise SystemExit(f"pr takes the PR's number, not {a[1]!r}\n{USAGE}")
        base, where = stacked(a[1])
        try:
            where += github_stack(a[1], base)
        except NotStacked as e:   # recorded all the same, base-chained: the owner can stack it from the PR page
            where += f"; not in a GitHub stack: {e}"
            print(f"task.py: PR #{a[1]} is recorded but not stacked: {e}. It stays base-chained; the owner can stack it "
                  f"from the PR page", file=sys.stderr)
    with locked():
        d = load()
        change(cmd, a, d, where)
        save(d)
    print("ok")


def change(cmd, a, d, where=""):
    if cmd == "phase":
        waiting = [q["id"] for q in d.get("asks", []) if q["status"] == "open"]
        if a[1] == "pr" and waiting:  # the owner may still answer differently: nothing is published on an assumption
            raise SystemExit(f"{', '.join(waiting)} still open: {OWNER} hasn't answered. Hold the pull request: finish this "
                             f"session with task.py needs \"holding the pull request until {OWNER} answers {', '.join(waiting)}\"")
        if a[1] == "pr":
            why = size_refusal(d, "the pr phase")
            if why:
                raise SystemExit(why)
        d["phase"] = a[1]; d["status"] = "in_progress"
        d["notes"].append(f"{now()} [{a[1]}] {a[2] if len(a) > 2 else ''}")
    elif cmd == "note":
        d["notes"].append(f"{now()} {a[1]}")
    elif cmd == "pr":
        d["pr"] = {"number": int(a[1]), "url": a[2]}
        d["notes"].append(f"{now()} PR #{a[1]} opened{where}")
    elif cmd == "review":
        d["reviews"].append({"comment": a[1], "proposal": a[2] if len(a) > 2 else "", "at": now()})
    elif cmd == "ask":
        if len(a) < 5:
            raise SystemExit('ask needs a title, the question, the recommended answer and at least one other answer')
        asks = d.setdefault("asks", [])
        qid = f"Q{len(asks) + 1}"
        asks.append({"id": qid, "title": a[1], "question": a[2], "recommend": "a", "at": now(), "status": "open",
                     "options": [{"key": chr(97 + i), "text": t} for i, t in enumerate(a[3:])]})
        d["notes"].append(f"{now()} asked {qid}: {a[1]} (carrying on with: {a[3]})")
        wake(d["slug"], f"chain asks: {d['slug']} {qid} · {a[1]}")
    elif cmd == "answer":
        q = next((q for q in d.get("asks", []) if q["id"] == a[1]), None)
        if not q:
            raise SystemExit(f"no question {a[1]} on this branch")
        q.update(status="answered", answer=a[2], answered=now())
        d["notes"].append(f"{now()} OWNER ANSWER {a[1]} ({OWNER}): {a[2]}. If that isn't what you carried on with, "
                          "redo that part first (test first).")
    elif cmd == "done":
        d.setdefault("tasks_done", [])
        if a[1] not in d["tasks_done"]:
            d["tasks_done"].append(a[1])
        d["notes"].append(f"{now()} task {a[1]} done: {a[2] if len(a) > 2 else ''}")
    elif cmd in ("ready", "needs", "block"):
        why = size_refusal(d, "ready") if cmd == "ready" else None
        if why:
            raise SystemExit(why)
        d["status"] = {"ready": "awaiting_owner", "needs": "needs_owner", "block": "blocked"}[cmd]
        d["summary"] = a[1] if len(a) > 1 else ""
        d["notes"].append(f"{now()} {d['status']}: {d['summary']}")
    elif cmd == "cap":
        if not a[1].isdigit():
            raise SystemExit(f"cap takes the new cap in changed lines, then why\n{USAGE}")
        d["max_lines"] = int(a[1])
        d["notes"].append(f"{now()} SIZE CAP now {int(a[1])} changed lines ({OWNER}): {a[2]}")
    elif cmd == "requeue":
        d["status"] = "todo"; d["notes"].append(f"{now()} requeued: {a[1] if len(a) > 1 else ''}")
    else:
        raise SystemExit(f"unknown command {cmd}\n{USAGE}")


if __name__ == "__main__":
    main(sys.argv[1:])
