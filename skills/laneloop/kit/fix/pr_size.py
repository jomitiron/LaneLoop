"""How big a branch's pull request is, against the run's cap (PR_MAX_LINES in loop.conf, 400 by default; 0 turns it
off). The plan sizes every build branch under the cap, and a chain checks its branch before it opens or updates its PR.

  python pr_size.py count [WORKTREE]   this branch's changed lines (default: the current directory) against its cap
  python pr_size.py plan plan.json     each build branch's estimate against its cap

A pull request's size is the lines it adds plus the lines it removes, tests included, as GitHub counts them, against the
merge base with origin/<base> (for a stacked branch, the branch below it: .fixloop/base). Uncommitted and untracked work counts too, so a chain sees the size before it commits. A
moved file counts only the lines that changed in it. Not counted: lockfiles, snapshots and minified files, files that
.gitattributes marks linguist-generated or linguist-vendored, binary files, the signed-off mockup and schema pages
(MOCKUPS_DIR, SCHEMA_DIR: the owner reviewed those on their own page), and the project profile's pr_size.exclude globs.

In plan.json every build branch has "est_lines": the lines its pull request is expected to change, tests included. A
branch may carry its own cap, "max_lines", with "max_lines_why": the owner sees both on the plan page and signs them off
with the plan. make_briefs.py writes the branch's cap into its brief ("Size cap: N changed lines"), and task.py refuses
the pr phase, and `ready`, for a branch over it. A cap the owner raises mid-run goes in with `task.py cap`.
"""
import fnmatch, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CAP = 400
LOCKFILES = {
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "deno.lock",
    "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock", "Cargo.lock", "go.sum", "Gemfile.lock", "composer.lock",
    "packages.lock.json", "gradle.lockfile", "mix.lock", "pubspec.lock", "Podfile.lock", "Package.resolved",
}
GENERATED = ["*.snap", "__snapshots__/*", "*/__snapshots__/*", "*.min.js", "*.min.mjs", "*.min.css", "*.js.map",
             "*.css.map"]


def conf():
    try:
        return json.load(open(os.path.join(HERE, "loop.json"), encoding="utf8"))
    except (OSError, ValueError):
        return {}


def run_cap(c=None):
    """The run's cap: PR_MAX_LINES, 400 when it's unset, 0 for none."""
    v = str((conf() if c is None else c).get("PR_MAX_LINES", DEFAULT_CAP)).strip()
    try:
        return max(0, int(v)) if v else DEFAULT_CAP
    except ValueError:
        return DEFAULT_CAP


def branch_cap(b, c=None):
    """A branch's cap: its own max_lines (signed off with the plan), else the run's."""
    if b.get("max_lines") is not None:
        return int(b["max_lines"])
    return run_cap(c)


def plan_problems(plan, c=None):
    """What keeps the plan's sizing from being signed off; [] when every build branch fits its cap."""
    c = conf() if c is None else c
    if run_cap(c) == 0:
        return []
    out = []
    for b in plan.get("branches", []):
        if b.get("mode", "build") != "build":
            continue
        cap, est = branch_cap(b, c), b.get("est_lines")
        if b.get("max_lines") is not None and not str(b.get("max_lines_why") or "").strip():
            out.append(f"branch {b['slug']} has its own cap ({b['max_lines']} lines) with no max_lines_why: say why, "
                       "so the owner signs the exception off with the plan")
        if not isinstance(est, int) or isinstance(est, bool) or est <= 0:
            out.append(f"branch {b['slug']} has no est_lines: estimate the lines its pull request changes, tests "
                       f"included (the cap is {cap})")
        elif cap and est > cap:
            out.append(f"branch {b['slug']} is estimated at {est} changed lines, over its cap of {cap}: split it by "
                       "task (a later branch depends on an earlier one when it builds on it)")
    return out


# ------------------------------------------------------------------------------------------------------------- counting

def git(wt, *args, stdin=None):
    r = subprocess.run(["git", "-C", wt] + list(args), capture_output=True, input=stdin)
    return r.returncode, r.stdout, r.stderr.decode("utf8", "replace").strip()


def numstat(wt, ref):
    """[(path, added, removed, binary)] for the working tree (committed or not) against ref, renames followed."""
    code, out, err = git(wt, "diff", "--numstat", "-z", "-M", ref)
    if code != 0:
        raise RuntimeError(err or f"git diff {ref} failed")
    toks, rows, i = out.decode("utf8", "replace").split("\0"), [], 0
    while i < len(toks):
        parts = toks[i].split("\t")
        i += 1
        if len(parts) < 3:
            continue
        path = parts[2]
        if path == "":  # a rename: the old path, then the new one
            path = toks[i + 1] if i + 1 < len(toks) else ""
            i += 2
        binary = parts[0] == "-"
        rows.append((path, 0 if binary else int(parts[0]), 0 if binary else int(parts[1]), binary))
    return rows


def untracked(wt):
    """[(path, lines, binary)] for new files git doesn't track yet (and doesn't ignore)."""
    code, out, _ = git(wt, "ls-files", "--others", "--exclude-standard", "-z")
    rows = []
    for p in out.decode("utf8", "replace").split("\0") if code == 0 else []:
        if not p:
            continue
        try:
            data = open(os.path.join(wt, p), "rb").read()
        except OSError:
            continue
        if b"\0" in data[:8000]:
            rows.append((p, 0, True))
        else:
            rows.append((p, data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0), False))
    return rows


def generated(wt, paths):
    """The paths .gitattributes marks linguist-generated or linguist-vendored."""
    if not paths:
        return set()
    code, out, _ = git(wt, "check-attr", "-z", "--stdin", "linguist-generated", "linguist-vendored",
                       stdin="\0".join(paths).encode("utf8") + b"\0")
    toks = out.decode("utf8", "replace").split("\0") if code == 0 else []
    return {toks[i] for i in range(0, len(toks) - 2, 3) if toks[i + 2] in ("set", "true")}


def why_not_counted(path, extra, c, marked):
    name = path.rsplit("/", 1)[-1]
    if path.startswith(".fixloop/"):
        return "the chain's own state"
    if name in LOCKFILES:
        return "lockfile"
    if any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(name, g) for g in GENERATED):
        return "generated"
    if path in marked:
        return "marked generated or vendored in .gitattributes"
    for d in (c.get("MOCKUPS_DIR"), c.get("SCHEMA_DIR")):
        d = (d or "").strip().strip("/")
        if d and path.startswith(d + "/"):
            return "signed-off page"
    if any(fnmatch.fnmatch(path, g) for g in extra):
        return "the profile's pr_size.exclude"
    return None


def count(wt, base=None, c=None, profile=None):
    """This branch's size: {added, removed, total, files [(path, added, removed)], skipped [(path, why)], base}."""
    c = conf() if c is None else c
    if not base:   # a stacked branch's PR shows only its own diff against the branch below it (.fixloop/base)
        try:
            base = open(os.path.join(wt, ".fixloop", "base"), encoding="utf8").read().strip()
        except OSError:
            pass
    base = base or c.get("BASE") or "develop"
    if profile is None:
        try:
            profile = json.load(open(os.path.join(HERE, "project.json"), encoding="utf8"))
        except (OSError, ValueError):
            profile = {}
    extra = (profile.get("pr_size") or {}).get("exclude") or []
    code, mb, err = git(wt, "merge-base", f"origin/{base}", "HEAD")
    if code != 0:
        raise RuntimeError(f"can't find where this branch left origin/{base}: {err or 'no merge base'}")
    rows = [(p, a, r, b) for p, a, r, b in numstat(wt, mb.decode().strip())]
    rows += [(p, n, 0, b) for p, n, b in untracked(wt)]
    marked = generated(wt, [p for p, *_ in rows])
    files, skipped = [], []
    for p, a, r, b in rows:
        why = "binary" if b else why_not_counted(p, extra, c, marked)
        if why:
            skipped.append((p, why))
        elif a or r:
            files.append((p, a, r))
    added, removed = sum(f[1] for f in files), sum(f[2] for f in files)
    return {"added": added, "removed": removed, "total": added + removed, "base": base,
            "files": sorted(files, key=lambda f: -(f[1] + f[2])), "skipped": skipped}


def describe(s, cap):
    """The size in words: the first line says whether it fits."""
    head = (f"{s['total']}{f' of {cap}' if cap else ''} changed lines (+{s['added']} -{s['removed']}) against "
            f"origin/{s['base']}, tests included")
    if not cap:
        head += ": no size cap for this branch"
    elif s["total"] > cap:
        head += f": OVER the cap by {s['total'] - cap}"
    else:
        head += f": within the cap ({cap - s['total']} to spare)"
    out = [head]
    if s["files"]:
        out.append("  largest: " + " · ".join(f"{p} {a + r}" for p, a, r in s["files"][:8]))
    if s["skipped"]:
        out.append("  not counted: " + " · ".join(f"{p} ({w})" for p, w in s["skipped"][:8]) +
                   (f" and {len(s['skipped']) - 8} more" if len(s["skipped"]) > 8 else ""))
    return "\n".join(out)


def brief_cap(brief):
    """The cap make_briefs.py wrote into a brief, or None for a brief written before there was one."""
    m = re.search(r"^Size cap: (\d+) changed lines", brief, re.M)
    return int(m.group(1)) if m else None


def worktree_cap(wt, c=None, fallback=True):
    """A chain's cap: one the owner raised mid-run (task.py cap), else its brief's, else (with fallback) the run's.
    None without fallback: the brief predates the cap, so the plan never sized the branch against one."""
    try:
        st = json.load(open(os.path.join(wt, ".fixloop", "status.json"), encoding="utf8"))
    except (OSError, ValueError):
        st = {}
    if st.get("max_lines") is not None:
        return int(st["max_lines"])
    try:
        cap = brief_cap(open(os.path.join(wt, ".fixloop", "brief.md"), encoding="utf8").read())
    except OSError:
        cap = None
    if cap is not None:
        return cap
    return run_cap(c) if fallback else None


# ---------------------------------------------------------------------------------------------------------------- CLI

def main(a):
    if not a or a[0] not in ("count", "plan"):
        print(__doc__); sys.exit(2)
    c = conf()
    if a[0] == "plan":
        if len(a) < 2:
            print(__doc__); sys.exit(2)
        plan = json.load(open(a[1], encoding="utf8"))
        for b in plan.get("branches", []):
            if b.get("mode", "build") != "build":
                continue
            cap, est = branch_cap(b, c), b.get("est_lines")
            flag = "no estimate" if not est else ("OVER" if cap and est > cap else "ok")
            own = f" (own cap: {b.get('max_lines_why') or 'no reason given'})" if b.get("max_lines") is not None else ""
            print(f"{b['slug']}: about {est or '?'} of {cap or 'no cap'} lines · {flag}{own}")
        probs = plan_problems(plan, c)
        for p in probs:
            print(f"  - {p}")
        sys.exit(1 if probs else 0)
    wt = a[1] if len(a) > 1 else os.getcwd()
    try:
        s = count(wt, c=c)
    except RuntimeError as e:
        raise SystemExit(str(e))
    cap = worktree_cap(wt, c)
    print(describe(s, cap))
    sys.exit(1 if cap and s["total"] > cap else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
