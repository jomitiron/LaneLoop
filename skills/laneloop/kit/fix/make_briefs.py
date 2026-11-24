"""Write briefs/<slug>.md for branches in plan.json and a queue file the runner can take.

  python make_briefs.py plan.json --wave 1                  every wave-1 branch -> queue-wave1.txt
  python make_briefs.py plan.json --slugs a,b --queue q.txt  just these

A brief is the chain's whole task: binding scope, the defects with their why and fix, its tasks (each with the test that
proves it), the investigation notes, the tests that re-verify it, and what "done" means for its mode (build or design).
Refuses a plan the owner hasn't signed off (sign_plan.py); every brief carries a "Plan signed off:" line, and the runner
starts no branch without one. Each brief also carries the branch's "Size cap:" (PR_MAX_LINES, or the branch's own
max_lines) with the plan's estimate: task.py refuses to open or hand over a pull request over it (pr_size.py). Never
overwrites a brief a chain already copied: a running branch reads .fixloop/brief.md, so change scope through a task.py
note instead.

Dependent branches ship as PR stacks; independent ones run in parallel. A branch that builds on another branch's code
names it: "on": "<slug>". It is built on that branch, opens its PR against it, and the runner starts it once that branch
has opened its PR. A branch with no "on" (or "on": null) depends on nothing: it is built from the base and starts at once,
beside any stack. Every brief says "Stacked on: <slug>" (or "-" for the base).

A plan imported from an EGM design (egm_plan.py import) adds to each brief: the design as the spec (path and hash), the
files the branch may create or change (its boundary), the journeys it delivers, and the design's verification steps.
"""
import argparse, fnmatch, json, os

import pr_size

HERE = os.path.dirname(os.path.abspath(__file__))
DONE = {
    "build": "PR open against the base with failing-then-passing tests for every defect and task above, docs updated, the "
             "gate passing, the security review run, CI read and review comments recorded as proposals (`task.py ready`).",
    "design": "The page(s) committed and pushed on this branch, the README row added, and `task.py ready` naming the paths, "
              "the numbered choices with recommendations, and any open questions.",
}


def design_section(plan, b, design):
    """The EGM design as this branch's spec: its boundary, its journeys and how the design says to verify them."""
    files = {f["path"]: f for f in plan.get("files", [])}
    cujs = {j["id"]: j for j in plan.get("cujs", [])}
    out = ["## The design (binding)",
           f"`{design['path']}` is the spec, approved by {plan.get('owner', 'the owner')}. Before red, read its Goals, "
           "Non-Goals and Technical Plan, and its entries for the files below. Where this brief and the design disagree, "
           "or the design doesn't settle something you need, stop with `task.py needs`: other branches are building "
           "the rest of it at the same time, from the same design.", ""]
    if b.get("files"):
        out += ["### Files this branch creates or changes (its boundary)",
                "New tests for these are fine. Any other file belongs to another branch or isn't in the design: "
                "`task.py needs \"<file> and why\"`, never an edit."]
        for p in b["files"]:
            f = files.get(p) or next((x for x in files.values() if "*" in x["path"] and fnmatch.fnmatch(p, x["path"])), {})
            line = f"- `{p}` ({f.get('action', 'Modify')})"
            if f.get("scope"):
                line += f" · {f['scope']}"
            if f.get("changes"):
                line += f" · {f['changes']}"
            out.append(line)
        out.append("")
    if b.get("cujs"):
        out += ["### Journeys this branch delivers (each is proved by a test)"]
        for j in b["cujs"]:
            c = cujs.get(j, {})
            out.append(f"- {j} · {c.get('title', '')}: given {c.get('given', '?')}; when {c.get('when', '?')}; "
                       f"then {c.get('then', '?')}")
        out.append("")
    if plan.get("verify"):
        out += ["### Verification (from the design; the gate still runs everything)"] + [f"- {v}" for v in plan["verify"]] + [""]
    return out


def stack_parents(plan):
    """slug -> the slug it is stacked on (None: independent, on the base). Only an explicit "on" stacks a branch.
    Refuses a parent the plan doesn't have, and a loop."""
    slugs = [b["slug"] for b in plan["branches"]]
    parents = {}
    for b in plan["branches"]:
        on = b.get("on")
        if on is not None and (on not in slugs or on == b["slug"]):
            raise SystemExit(f"{b['slug']} is stacked on {on}, which isn't another branch in the plan")
        parents[b["slug"]] = on
    for s in slugs:
        seen, p = [], s
        while p is not None:
            if p in seen:
                raise SystemExit(f"the stack loops: {' -> '.join(seen + [p])}")
            seen.append(p)
            p = parents[p]
    return parents


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan")
    ap.add_argument("--wave", type=int)
    ap.add_argument("--slugs")
    ap.add_argument("--queue")
    a = ap.parse_args()
    plan = json.load(open(a.plan, encoding="utf8"))
    signed = plan.get("signed_off") or {}
    if not (signed.get("at") and signed.get("by")):
        raise SystemExit(f"{a.plan} is not signed off: grill it onto the plan page (plan_page.py), and once "
                         f"{plan.get('owner', 'the owner')} signs the page off, record it with sign_plan.py")
    defects = {d["id"]: d for d in plan.get("defects", [])}
    design = plan.get("design")
    parents = stack_parents(plan)
    want = set(a.slugs.split(",")) if a.slugs else None
    picked = [b for b in plan["branches"] if (want is None or b["slug"] in want) and (a.wave is None or b.get("wave") == a.wave)]
    if not picked:
        raise SystemExit("no branches matched")
    os.makedirs(os.path.join(HERE, "briefs"), exist_ok=True)
    for b in picked:
        mode = b.get("mode", "build")
        out = [f"# {'Design' if mode == 'design' else 'Fix'} branch `{b['slug']}`", ""]
        if mode == "design":
            out.append(f"Mode: design. Deliver: {' and '.join(b.get('deliver', ['mockup']))} for {plan.get('owner', 'the owner')}'s "
                       "sign-off (see the runbook's design-only section). No code.")
        if b.get("title"):
            out.append(f"Title: {b['title']}")
        out += [f"Plan signed off: {signed['at']} by {signed['by']}", f"Stacked on: {parents[b['slug']] or '-'}",
                f"Defects: {', '.join(b.get('defects', [])) or 'none'} · tests to re-verify after merge: {', '.join(b.get('tests', [])) or 'none named'}",
                f"Plan: {plan.get('plan_url', '-')} · results: {plan.get('results_url', '-')}"]
        if design:
            out.append(f"Design: `{design['path']}` (EGM, {design.get('status', 'Approved')}, sha256 {design['sha256'][:12]}), "
                       "on the base, so it is in your worktree")
        cap = pr_size.branch_cap(b)
        if cap:
            line = f"Size cap: {cap} changed lines, tests included"
            if mode == "design":
                line += ", once it builds after the sign-off"
            elif b.get("est_lines"):
                line += f" (planned at about {b['est_lines']})"
            if b.get("max_lines") is not None and b.get("max_lines_why"):
                line += f"; {plan.get('owner', 'the owner')} set this branch's own cap: {b['max_lines_why']}"
            out.append(line + ". See the runbook's size rule; `task.py size` measures it")
        if b.get("depends_on"):
            out.append(f"Builds on: {', '.join(b['depends_on'])} (on the base, or below this branch in its stack, before it starts)")
        if plan.get("base_note"):
            out.append(plan["base_note"])
        out += ["", "## Scope and constraints (binding)", b.get("scope", ""), ""]
        if design:
            out += design_section(plan, b, design)
        if b.get("tasks"):
            out += ["## Tasks (tick each with `task.py done <id> \"how it was proved\"` once its test passes)"]
            out += [f"- {t['id']} · {t['text']} · proved by: {t.get('test') or ('the page' if mode == 'design' else '?')}"
                    for t in b["tasks"]] + [""]
        for did in b.get("defects", []):
            d = defects.get(did)
            if d:
                out += [f"## {did} · {d['title']} (test {d.get('test', '-')}, {d.get('type', 'BUG')})",
                        f"- **Why:** {d.get('why', '')}", f"- **Fix:** {d.get('fix', '')}", f"- **Size:** {d.get('size', '?')}", ""]
        if b.get("notes"):
            out += ["## Investigation notes"] + [f"- {n}" for n in b["notes"]] + [""]
        out += ["## Done means", DONE[mode]]
        path = os.path.join(HERE, "briefs", f"{b['slug']}.md")
        open(path, "w", encoding="utf8").write("\n".join(out) + "\n")
    queue = a.queue or (f"queue-wave{a.wave}.txt" if a.wave is not None else "queue.txt")
    open(os.path.join(HERE, queue), "w", encoding="utf8").write("\n".join(b["slug"] for b in picked) + "\n")
    print(f"{len(picked)} briefs -> briefs/; queue {queue}: {', '.join(b['slug'] for b in picked)}")


if __name__ == "__main__":
    main()
