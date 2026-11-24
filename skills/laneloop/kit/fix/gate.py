"""The pre-PR gate for a branch: every step project.json "gate.steps" names (builds, linters, test suites), in order.
Run from the worktree root. It runs DETACHED (a full run outlasts a 10-minute tool call) and keeps the computer awake
until it ends (caffeinate on macOS, systemd-inhibit on Linux, SetThreadExecutionState on Windows):

  python $FIXLOOP/gate.py --start     start (or report the run already going)
  python $FIXLOOP/gate.py --status    one-line progress, then the verdict and failing tests when done

A step is a shell command (bash; Git Bash on Windows) run in the worktree with the project's env, the step's env and
the env of the services it names. Verdict rules:
- A step without a test parser passes on exit code 0. If it fails, the gate stops there (a build, a lint), unless the
  step says "continue": true.
- A step with a parser ("tests": dotnet, pytest, jest, vitest, go, cargo, rspec, maven, phpunit, or patterns of its own; see
  project.py) fails when it prints no summary, when ZERO tests ran (a stalled database or test host can report a pass
  with nothing run), or when more tests failed than loop.json KNOWN_FLAKES names matched, named or not. A non-zero exit
  with no failing test is a fail too. Tests named in KNOWN_FLAKES are reported but don't fail the gate: confirm each one
  alone before trusting that. Tests in KNOWN_PLATFORM_FAILURES fail on this platform every time and pass on CI: reported,
  not counted, not re-run alone.
- loop.json GATE_SKIP names steps left out on this machine, only on the owner's explicit decision (doctor.py says when
  one is needed); the verdict names them, with the step's "skippable" note (what checks it instead, e.g. a CI job).
Concurrency: a step with "slots": N runs at most N at once on this machine, counting every run and every project on it
(a step that uses services gets 1 unless it says). The slots are one folder for the machine (loop.json GATE_SLOTS,
default ~/.laneloop/gate-slots), shared by step name. A gate takes only slots below its own profile's N: when two
profiles give a step different counts, the larger one caps the machine and the smaller still waits for one of its N.
A gate over the limit waits, and --status (and gate.json "waiting") says for which slot and behind whom. Each instance of
a step's services gets a port no other gate on the machine holds (its port + the lowest free offset), and is removed
after (services.py). A slot or port whose gate died is freed for the next gate.
"""
import json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import project  # noqa: E402
from services import Service, ServiceError, BASH  # noqa: E402

ROOT = os.getcwd()
RUN = os.path.join(ROOT, ".fixloop")
STATE = os.path.join(RUN, "gate.json")
try:
    CONF = json.load(open(os.path.join(HERE, "loop.json"), encoding="utf8"))
except (OSError, ValueError):
    CONF = {}
LOCKS = os.path.expanduser(CONF.get("GATE_SLOTS") or "~/.laneloop/gate-slots")   # one set for the machine, every run
WHO = f"{CONF['RUN_NAME']}/{os.path.basename(ROOT)}" if CONF.get("RUN_NAME") else os.path.basename(ROOT)
POLL = int(os.environ.get("GATE_POLL_SECS", "20"))
PROJECT = project.load()
KNOWN = [k.strip() for k in CONF.get("KNOWN_FLAKES", "").split(",") if k.strip()]
PLATFORM_FAILS = [k.strip() for k in CONF.get("KNOWN_PLATFORM_FAILURES", "").split(",") if k.strip()]
SKIP = {s.strip() for s in CONF.get("GATE_SKIP", "").split(",") if s.strip()}
OWNER = CONF.get("OWNER", "the owner")
PY = CONF.get("PYTHON", "python")
WINDOWS = os.name == "nt"
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW: without it every child of the detached gate opens a console window
SPAWN = {"creationflags": NO_WINDOW} if WINDOWS else {}  # creationflags is Windows-only: POSIX raises on any value


class GateError(Exception):
    pass


def steps():
    return (PROJECT.get("gate") or {}).get("steps") or []


def save(s):
    tmp = STATE + ".tmp"
    json.dump(s, open(tmp, "w", encoding="utf8"), indent=1)
    os.replace(tmp, STATE)


def load():
    try:
        return json.load(open(STATE, encoding="utf8"))
    except (OSError, ValueError):
        return None


def pid_alive(pid):
    if not pid:
        return False
    if not WINDOWS:
        try:
            os.kill(int(pid), 0)  # signal 0 only asks whether the process exists
        except PermissionError:
            return True
        except (OSError, ValueError):
            return False
        return True
    out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True,
                         creationflags=NO_WINDOW).stdout
    return str(pid) in out


def take(p):
    """Make the lock folder p ours: None once it is, else who holds it (run/worktree). A dead gate's is freed and taken."""
    for _ in range(2):
        try:
            os.mkdir(p)
        except FileExistsError:
            try:
                lines = open(os.path.join(p, "owner"), encoding="utf8").read().splitlines()
                pid = int(lines[0].split()[0])
            except (OSError, ValueError, IndexError):
                lines, pid = [], 0
            who = lines[1] if len(lines) > 1 else "a gate starting up"
            try:  # no owner line yet: a gate between its mkdir and its write, unless that was a minute ago
                young = not pid and time.time() - os.path.getmtime(p) < 60
            except OSError:
                young = False  # released meanwhile
            if pid_alive(pid) or young:
                return who
            release(p)  # stale: its gate died
            continue
        open(os.path.join(p, "owner"), "w", encoding="utf8").write(f"{os.getpid()} {ROOT}\n{WHO}\n")
        return None
    return "a gate taking it at the same moment"


def acquire(name, n, s):
    """One of the step's n slots, shared by every gate on the machine; while all are held, gate.json says what it waits for."""
    os.makedirs(LOCKS, exist_ok=True)
    key = re.sub(r"[^\w.-]", "_", name)
    since = None
    while True:
        holders = []
        for i in range(n):
            p = os.path.join(LOCKS, f"step-{key}-{i}")
            who = take(p)
            if who is None:
                if since:
                    s.pop("waiting", None); save(s)
                return p, i
            holders.append(who)
        since = since or time.strftime("%Y-%m-%dT%H:%M:%S")
        slot = f"{'an' if name[:1].lower() in 'aeiou' else 'a'} {name} slot"
        w = {"step": name, "slot": slot, "behind": holders, "since": since,
             "text": f"waiting for {slot}, behind {', '.join(holders)} (since {since[11:16]})"}
        if s.get("waiting") != w:
            s["waiting"] = w; save(s)
        time.sleep(POLL)


def port_offset(base):
    """The lowest offset whose port (base + offset) no other gate on the machine holds, with that port's lock."""
    os.makedirs(LOCKS, exist_ok=True)
    for k in range(100):
        p = os.path.join(LOCKS, f"port-{base + k}")
        if take(p) is None:
            return k, p
    raise GateError(f"every port from {base} to {base + 99} is held by another gate")


def release(p):
    for f in (os.path.join(p, "owner"), p):
        try:
            os.remove(f) if f.endswith("owner") else os.rmdir(f)
        except OSError:
            pass


def run_step(cmd, log, env):
    with open(log, "w", encoding="utf8") as f:
        return subprocess.run([BASH, "-c", cmd], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                              env=env, **SPAWN).returncode


def with_services(names, slot, fn):
    """Start each named service on a port no other gate holds, run fn(env) with their env, and stop them, whatever happens.
    The port's offset is the machine's, not the step's slot: two steps (or projects) may name services on one port."""
    started, env, ports = [], {}, []
    try:
        for n in names:
            spec = project.service_spec(PROJECT, n)
            k = slot
            if spec.get("port"):
                k, p = port_offset(int(spec["port"]))
                ports.append(p)
            s = Service(n, spec, slot=k, state=os.path.join(RUN, "state"), logs=os.path.join(RUN, "logs"), run=HERE, root=ROOT)
            started.append(s)
            env.update(s.start())
        return fn(env)
    except ServiceError as e:
        raise GateError(str(e))
    finally:
        for s in reversed(started):
            s.stop()
        for p in ports:
            release(p)


def judge(step, r, log, rc):
    """Fill r with the step's verdict; return True when it passed."""
    if not step.get("tests"):
        r["unexpected_failures"] = [] if rc == 0 else [f"exited {rc}"]
        return rc == 0
    r.update(project.parse_tests(open(log, encoding="utf8", errors="replace").read(), step["tests"]))
    named = r.get("failed_tests") or []
    real = [t for t in named if not any(k in t for k in KNOWN + PLATFORM_FAILS)]
    known_hits = len(named) - len(real)
    if r.get("failed") is not None and r["failed"] > known_hits and not real:
        real = [f"{r['failed'] - known_hits} failure(s) the log names in a form the parser didn't match: see {log}"]
    if r.get("failed") is not None and not r["failed"] and rc != 0:
        real.append(f"exited {rc} with no failing test reported (a crash, or a build error before the tests): see {log}")
    if r.get("failed") is None:
        real.append(f"no test summary in the output: see {log}")
    elif not r.get("passed"):  # zero tests ran: never a pass
        real.append("NO TESTS RAN")
    r["unexpected_failures"] = real
    return not real


def run():
    os.makedirs(os.path.join(RUN, "logs"), exist_ok=True)  # before the first save: a plain worktree has no .fixloop yet
    if WINDOWS and keep_awake_on():  # no idle sleep while this thread holds it (macOS and Linux: start() wraps the gate)
        import ctypes
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    s = {"pid": os.getpid(), "started": time.strftime("%H:%M:%S"), "step": None, "steps": {}, "verdict": "running",
         "skipped": sorted(SKIP & {x.get("name") for x in steps()})}
    save(s)
    ok = bool(steps())
    if not steps():
        s["error"] = "project.json has no gate.steps: the gate has nothing to run (doctor.py says how to fix it)"
    base_env = dict(os.environ, **{k: str(v) for k, v in (PROJECT.get("env") or {}).items()})
    for step in steps():
        name = step["name"]
        if name in SKIP:
            s["steps"][name] = {"skipped": True, "rc": 0, "secs": 0, "log": "", "note": step.get("skippable", "")}; save(s)
            continue
        s["step"] = name; save(s)
        log = os.path.join(RUN, "logs", f"gate-{name}.log")
        svcs = step.get("services") or []
        slots = int(step.get("slots") or (1 if svcs else 0))
        lock, slot = acquire(name, slots, s) if slots else (None, 0)
        env = dict(base_env, **{k: str(v) for k, v in (step.get("env") or {}).items()})
        t0, r = time.time(), {}
        try:
            if svcs:
                def go(svc_env):
                    r["services"] = sorted(svc_env)
                    return run_step(step["run"], log, dict(env, **svc_env))
                rc = with_services(svcs, slot, go)
            else:
                rc = run_step(step["run"], log, env)
        except GateError as e:
            rc = -1
            open(log, "w", encoding="utf8").write(f"gate: {e}\n")
            r["error"] = str(e)
        finally:
            if lock:
                release(lock)
        r.update({"rc": rc, "secs": int(time.time() - t0), "log": log})
        passed = judge(step, r, log, rc)
        if r.get("error"):  # a service that wouldn't start: the step never really ran
            r["unexpected_failures"], passed = [r["error"]], False
        s["steps"][name] = r; save(s)
        if not passed:
            ok = False
            if not step.get("tests") and not step.get("continue"):
                break
    s["verdict"] = "pass" if ok else "fail"; s["step"] = None; s["finished"] = time.strftime("%H:%M:%S")
    save(s)


def status():
    s = load()
    if not s:
        print("no gate run yet"); return
    if s["verdict"] == "running":
        alive = pid_alive(s.get("pid"))
        print(f"running since {s['started']}: step {s['step']}" + ("" if alive else " (process gone: restart with --start)") +
              (f" · {s['waiting']['text']}" if alive and s.get("waiting") else ""))
        return
    skipped = s.get("skipped") or []
    print(f"gate {s['verdict'].upper()} ({s['started']}-{s.get('finished')})" +
          (f" · not checked on this machine, by {OWNER}'s decision: {', '.join(skipped)}" if skipped else ""))
    if s.get("error"):
        print(f"  {s['error']}")
    by_name = {x.get("name"): x for x in steps()}
    for name, r in s["steps"].items():
        step = by_name.get(name, {})
        if r.get("skipped"):
            print(f"  {name}: SKIPPED (GATE_SKIP)" + (f": {r['note']}" if r.get("note") else ""))
            continue
        failed = bool(r.get("unexpected_failures"))
        head = r.get("summary") if step.get("tests") else ("ok" if not failed else "FAILED")
        print(f"  {name}: {head or 'no summary line'}" + (f", see {r['log']}" if failed else "") + f" ({r['secs']}s)" +
              (f" · services: {', '.join(r['services'])}" if r.get("services") else ""))
        for t in (r.get("unexpected_failures") or [])[:15]:
            print(f"     FAILED {t}")
        known = [t for t in (r.get("failed_tests") or []) if any(k in t for k in KNOWN)]
        if known:
            print(f"     known flaky (confirm alone): {', '.join(known)}")
        plat = [t for t in (r.get("failed_tests") or []) if any(k in t for k in PLATFORM_FAILS) and t not in known]
        if plat:
            print(f"     fails on this platform every time, CI runs it (not re-run alone): {', '.join(plat)}")
        if failed and r.get("log") and os.path.exists(r["log"]):
            text = open(r["log"], encoding="utf8", errors="replace").read()
            for h in step.get("hints") or []:
                if re.search(h.get("match", r"(?!x)x"), text, re.M):
                    print(f"     {h.get('say', '')} (doctor: {PY} {HERE}/doctor.py)")


def keep_awake_on():
    return os.environ.get("LANELOOP_KEEP_AWAKE", os.environ.get("METALOOP_KEEP_AWAKE", "1")) != "0"


def awake_wrapper():
    """What the detached gate runs under to keep the computer awake until it ends (platform.sh keep_awake's tools): a gate
    is often started straight from a session or merge_base.sh, not through launch.sh, and an idle sleep stalls it
    mid-suite. macOS: caffeinate -is (system sleep held only on mains power). Linux: systemd-inhibit, when it may take the
    hold (a container or CI runner may have it and be refused: then nothing, never a gate that can't start). Windows:
    run() holds SetThreadExecutionState itself. A closed laptop lid still sleeps the computer."""
    if WINDOWS or not keep_awake_on():
        return []
    if sys.platform == "darwin":
        return ["caffeinate", "-is"] if shutil.which("caffeinate") else []
    inhibit = shutil.which("systemd-inhibit")
    hold = [inhibit, "--what=idle:sleep", "--who=LaneLoop", "--mode=block"] if inhibit else []
    try:
        if hold and subprocess.run(hold + ["--why=checking", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=10).returncode == 0:
            return hold + ["--why=a LaneLoop gate is running"]
    except (OSError, subprocess.SubprocessError):
        pass
    return []


def start():
    s = load()
    if s and s.get("verdict") == "running" and pid_alive(s.get("pid")):
        print("already running:"); status(); return
    os.makedirs(os.path.join(RUN, "logs"), exist_ok=True)
    err = open(os.path.join(RUN, "logs", "gate-runner.err"), "w")  # a crash before the first save would otherwise vanish
    # Windows: CREATE_NO_WINDOW (not DETACHED_PROCESS) gives the gate a hidden console its children share, so the desktop
    # doesn't fill with a window per step. POSIX: a session of its own, so the gate outlives the session (and its process
    # group) that started it.
    detach = {"creationflags": NO_WINDOW | 0x00000200} if WINDOWS else {"start_new_session": True}  # | CREATE_NEW_PROCESS_GROUP
    # The wrapper runs the gate as its child and lets go when it ends; gate.json records the gate's own pid.
    subprocess.Popen(awake_wrapper() + [sys.executable, os.path.abspath(__file__), "--run"], cwd=ROOT,
                     stdout=subprocess.DEVNULL, stderr=err, stdin=subprocess.DEVNULL, close_fds=True, **detach)
    time.sleep(3)
    if load() is None:
        print("gate did not start; see .fixloop/logs/gate-runner.err"); return
    print(f"gate started; poll with: {PY} $FIXLOOP/gate.py --status (and {PY} $FIXLOOP/task.py wait 300 between polls)")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")   # redirected on Windows, stdout is cp1252: its "·" breaks a UTF-8 grep
    arg = sys.argv[1] if len(sys.argv) > 1 else "--status"
    {"--start": start, "--status": status, "--run": run}.get(arg, status)()
