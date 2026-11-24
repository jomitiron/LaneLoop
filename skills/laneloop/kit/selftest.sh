#!/usr/bin/env bash
# Self-test of the laneloop kit on THIS machine. It renders a fix run and a verify run from a test project profile, runs
# the scripts against stubs (claude, pmset, a stand-in toolchain `st-run`, a stand-in web service `st_serve.py`), every
# test-output parser against sample output, every stack preset, and the native PostgreSQL and MongoDB presets for real
# where those servers are installed (plus Chrome and tmux).
# No real session, build or push; nothing outside a temp folder is touched.
#   bash skills/laneloop/kit/selftest.sh   (macOS, Linux or Windows Git Bash; from a clone of the LaneLoop repository,
#   or as bash <kit>/selftest.sh from an installed copy, where a scratch repository stands in for the project)
# Run it after any change to the kit, on every platform you changed it for. Exit 0 = every check passed.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)"
T="$(mktemp -d "${TMPDIR:-/tmp}/laneloop-selftest.XXXXXX")"
# Outside a git checkout (an installed plugin): a scratch repository with one commit stands in for the project.
CLONE=1
if [ -z "$REPO" ]; then
    CLONE=0; REPO="$T/project-repo"
    git init -q -b main "$REPO" && git -C "$REPO" -c user.name=selftest -c user.email=selftest@example.invalid \
        commit -q --allow-empty -m init || { echo "could not make a scratch repository in $REPO"; exit 1; }
fi
STUBS="$T/stubs"; mkdir -p "$STUBS"
PY="$(command -v python3 || command -v python)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; *) WIN=0 ;; esac
pass=0; fail=0; skipped=0
ok() { pass=$((pass + 1)); echo "  ok    $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $*"; }
skip() { skipped=$((skipped + 1)); echo "  skip  $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
TMUX_NAME="laneloop-selftest-$$"
cleanup() {
    tmux kill-session -t "=$TMUX_NAME" >/dev/null 2>&1
    [ -f "$T/ver/state/services.json" ] && (cd "$T/ver" && "$PY" services.py down --state state) >/dev/null 2>&1
    pkill -f "sleep 611" >/dev/null 2>&1   # the stand-in service that never answers
    rm -rf "$T"
}
trap cleanup EXIT
free_port() { "$PY" -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])"; }
wait_for() { local n="$1"; shift; for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# Stubs. claude: a preflight-shaped reply from the model it was given (or SELFTEST_ANSWER_AS). st-run: a stand-in build and test command
# passing build or suite (or a missing-workload build failure). bash: the bash under test (on macOS /bin/bash is 3.2).
cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; sleep 1
m=none; while [ $# -gt 0 ]; do [ "$1" = --model ] && m="${2%"[1m]"}"; shift; done
m="${SELFTEST_ANSWER_AS:-$m}"
echo '{"type":"result","result":"READY","modelUsage":{"'"$m"'":{"canonicalModel":"'"$m"'","contextWindow":1000000}}}'
EOF
cat > "$STUBS/st-run" <<'EOF'
#!/usr/bin/env bash
# a stand-in toolchain: logs each call with the env the gate gave it; `test` answers like jest
echo "st-run $* | LC_ALL=${LC_ALL:-} | SVC=${SVC_URL:-}" >> "$SELFTEST_LOG"
case "$1" in
  build) if [ -n "${SELFTEST_BUILD_FAIL:-}" ]; then echo "error: missing toolchain component xyz"; exit 1; fi
         [ -z "${SELFTEST_SLOW_SECS:-}" ] || sleep "$SELFTEST_SLOW_SECS"
         echo "built" ;;
  test)  if [ -n "${SVC_URL:-}" ]; then echo "svc=$(curl -s "$SVC_URL/ping.txt")" >> "$SELFTEST_LOG"; fi
         if [ "$2" = unit ] && [ -n "${SELFTEST_ZERO:-}" ]; then echo "Tests:       0 total"; exit 0; fi
         if [ "$2" = unit ] && [ -n "${SELFTEST_UNIT_FAIL:-}" ]; then
             echo "  ● $SELFTEST_UNIT_FAIL"; echo "Tests:       1 failed, 2 passed, 3 total"; exit 1
         fi
         echo "Tests:       3 passed, 3 total" ;;
esac
EOF
# st_serve.py <port> [dir]: a stand-in web service. Not `python -m http.server`: its server looks up the name of the
# address it binds (socket.getfqdn) before it listens, which takes over 20 seconds where reverse DNS is slow (GitHub's
# macOS runners), longer than a service may take to come up.
cat > "$STUBS/st_serve.py" <<'EOF'
import functools, http.server, socketserver, sys

class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):  # no name lookup
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

port, folder = int(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else ".")
with Server(("127.0.0.1", port), functools.partial(http.server.SimpleHTTPRequestHandler, directory=folder)) as s:
    print(f"serving {folder} on 127.0.0.1:{port}", flush=True)
    s.serve_forever()
EOF
# gh: `label create` is logged (SELFTEST_GH_LABEL_FAIL makes it fail as a token without access would); anything else goes
# to the real gh when there is one.
REAL_GH="$(command -v gh || true)"
cat > "$STUBS/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = label ] && [ "\$2" = create ]; then
    echo "gh \$*" >> "\$SELFTEST_LOG.gh"
    [ -n "\${SELFTEST_GH_LABEL_FAIL:-}" ] && { echo "HTTP 403: Resource not accessible by integration"; exit 1; }
    exit 0
fi
[ -n "$REAL_GH" ] && exec "$REAL_GH" "\$@"
echo "gh: command not found" >&2; exit 127
EOF
# awake_for <pid>: how many no-sleep assertions pmset reports held on behalf of process <pid>, in either form macOS prints
# the owner ("on behalf of Process ID N", "on behalf of 'name' (pid N)")
cat > "$STUBS/awake_for" <<'EOF'
#!/usr/bin/env bash
pmset -g assertions 2>/dev/null | grep -cE "on behalf of ('[^']*' \(pid $1\)|Process ID $1\$)"
EOF
chmod +x "$STUBS/claude" "$STUBS/st-run" "$STUBS/gh" "$STUBS/awake_for"
ln -s "${SELFTEST_BASH:-$(command -v bash)}" "$STUBS/bash"
export PATH="$STUBS:$PATH" SELFTEST_LOG="$T/steps.log"

# The test profile: the stand-in toolchain and a stand-in service, so every stack-neutral path runs with no real stack.
SVC_PORT=$(free_port); VSVC_PORT=$(free_port); APP_PORT=$(free_port)
write_profile() {  # <out> [python that edits p]
    "$PY" - "$1" "${2:-pass}" <<EOF
import json, sys
p = {
 "requires": [{"tool": "st-run", "for": "the stand-in build and tests", "install": "a selftest stub", "who": "claude"}],
 "env": {"LC_ALL": "en_US.UTF-8"},
 "gate": {"steps": [
  {"name": "build", "run": "st-run build", "hints": [{"match": "missing toolchain component", "say": "the toolchain is incomplete"}]},
  {"name": "unit", "run": "st-run test unit", "tests": "jest", "slots": 3},
  {"name": "integration", "run": "st-run test integration", "tests": "jest", "services": ["web"],
   "skippable": "CI's integration job runs it"}]},
 "services": {"web": {"port": $SVC_PORT, "start": "exec '$PY' -u '$STUBS/st_serve.py' {port} {dir}",
                      "up": "curl -s -o /dev/null http://127.0.0.1:{port}/", "init": "echo pong > {dir}/ping.txt",
                      "ready": "curl -sf http://127.0.0.1:{port}/ping.txt >/dev/null", "timeout": 20,
                      "env": {"SVC_URL": "http://127.0.0.1:{port}"}}},
 "verify": {"url": "http://127.0.0.1:$APP_PORT", "health": "/", "start": "exec '$PY' -u '$STUBS/st_serve.py' {app_port}",
            "services": {"web": {"port": $VSVC_PORT, "persist": "$T/persist-web", "reuse": True,
                                 "seed": "echo seeded >> '$T/seed.log'"}},
            "provides": ["webhooks"]},
 "chain_allow": ["st-run *"], "verify_allow": ["curl *localhost*"],
 "caps": {"payments": "start the payment provider's sandbox listener as a verify service, then requeue the test"},
}
exec(sys.argv[2])
json.dump(p, open(sys.argv[1], "w"), indent=1)
EOF
}
write_profile "$T/project.json"
echo "laneloop kit self-test: $(uname -s), bash $("$STUBS/bash" -c 'echo $BASH_VERSION'), $("$PY" --version 2>&1)"

cd "$REPO" || exit 1
# every run here shares one temp folder of gate slots, never the machine's own
init() { "$PY" "$KIT/init_run.py" "$1" "$2" OWNER=Selftest GH_REPO=o/r GH_LOGIN=selftest PROJECT="$T/project.json" GATE_SLOTS="$T/slots" "${@:3}" > "$T/init.log" 2>&1; }

echo "== init_run renders runs whose every command exists on this machine"
init fix "$T/fix" || { cat "$T/init.log"; exit 1; }
init verify "$T/ver" || { cat "$T/init.log"; exit 1; }
for run in fix ver; do
    noexec=$(cd "$T/$run" && for f in *.sh *.py; do [ -x "$f" ] || echo "$f"; done)
    check "$run: every script is executable${noexec:+ (not: $(echo $noexec))}" test -z "$noexec"
    py=$(sed -n 's/^PYTHON=//p' "$T/$run/loop.conf" | tr -d "'")
    check "$run: loop.conf PYTHON ('$py') runs here" command -v "${py:-none}"
    missing=$("$PY" - "$T/$run/settings.json" <<'EOF'
import json, shutil, sys
d = json.load(open(sys.argv[1], encoding="utf8"))
cmds = [h["command"] for ev in d["hooks"].values() for m in ev for h in m["hooks"]]
cmds += [a[5:-1] for a in d["permissions"]["allow"] if a.startswith("Bash(") and ".py" in a]
print(" ".join(sorted({c.split()[0] for c in cmds if not shutil.which(c.split()[0])})))
EOF
)
    check "$run: hooks and allow-listed scripts start with a command that exists${missing:+ (missing: $missing)}" test -z "$missing"
    check "$run: the runbook names the run's python, not a bare 'python' this machine lacks" \
        sh -c "[ '$py' = python ] || ! grep -qE '(^|[\` ])python [^-]' '$T/$run/runbook.md'"
done
check "the project profile is copied into both runs" sh -c "cmp -s '$T/project.json' '$T/fix/project.json' && cmp -s '$T/project.json' '$T/ver/project.json'"
check "fix sessions may run the profile's chain_allow commands" grep -q '"Bash(st-run \*)"' "$T/fix/settings.json"
check "verify sessions may run its verify_allow commands, and not the chains'" \
    sh -c "grep -q '\"Bash(curl \*localhost\*)\"' '$T/ver/settings.json' && ! grep -q 'st-run' '$T/ver/settings.json'"
check "APP_URL comes from the profile's verify.url" grep -qx "APP_URL=http://127.0.0.1:$APP_PORT" "$T/ver/loop.conf"
check "BASE is the repository's default branch, not a fixed name" sh -c "b=\$(sed -n 's/^BASE=//p' '$T/fix/loop.conf'); [ -n \"\$b\" ] && git -C '$REPO' rev-parse -q --verify \"origin/\$b\" >/dev/null || git -C '$REPO' rev-parse -q --verify \"\$b\" >/dev/null"
check "the next-step hint names the run's python, not a bare 'python'" \
    sh -c "[ '$py' = python ] || ! grep -q 'run python ' '$T/init.log'"
init fix "$T/keep" SLUG_PREFIX=x-
sed -i.bak 's/^MAX_SESSIONS=.*/MAX_SESSIONS=7/' "$T/keep/loop.conf"       # a hand edit, as loop.conf's header invites
"$PY" "$KIT/init_run.py" fix "$T/keep" MAX_PAR=2 > "$T/init-keep.log" 2>&1
for kv in OWNER=Selftest SLUG_PREFIX=x- MAX_SESSIONS=7 MAX_PAR=2; do
    check "a re-run with one KEY=VALUE keeps the run's other settings: $kv" grep -qx "$kv" "$T/keep/loop.conf"
done
check "and loop.json says the same as loop.conf" "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['MAX_SESSIONS']=='7' and d['OWNER']=='Selftest', d" "$T/keep/loop.json"
mcp_cmd=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['mcpServers']['chrome-devtools']['command'])" "$T/ver/mcp.json")
check "verify: the Chrome MCP command ('$mcp_cmd') exists" command -v "$mcp_cmd"
chrome=$(sed -n 's/^CHROME=//p' "$T/ver/loop.conf" | tr -d "'")
if [ -e "$chrome" ] || [ "$WIN" = 1 ]; then check "verify: CHROME points at an installed Chrome" test -e "$chrome"
else skip "verify: CHROME ($chrome): no Chrome installed"; fi

echo "== model pins: the default crew, code on Opus 5.5 high, plan on Opus 5.5 xhigh, the verify loop at xhigh"
for kv in CREW=claude "CODE_PIN='claude/claude-opus-5-5[1m]:high'" "PLAN_PIN='claude/claude-opus-5-5[1m]:xhigh'" \
          "VERIFY_PIN='claude/claude-opus-5-5[1m]:xhigh'" "RESEARCH_PIN='claude/claude-opus-5-5[1m]:high'" CODE_AGENT=claude \
          MODEL=claude-opus-5-5 "MODEL_ARG='claude-opus-5-5[1m]'" EFFORT=high CTX_WINDOW=1000000 \
          PLAN_MODEL=claude-opus-5-5 "PLAN_MODEL_ARG='claude-opus-5-5[1m]'" PLAN_EFFORT=xhigh; do
    check "fix: loop.conf has $kv" grep -qxF "$kv" "$T/fix/loop.conf"
done
check "verify: loop.conf has EFFORT=xhigh (the verify pin's)" grep -qx EFFORT=xhigh "$T/ver/loop.conf"
check "fix: the runbook signs PRs and commits as the code pin's agent and model" \
    sh -c "grep -qF 'Generated with [Claude Code]' '$T/fix/runbook.md' && grep -qF 'Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>' '$T/fix/runbook.md'"

echo "== preflight: two at once in one run both pass, and the plan pin"
( cd "$T/fix" && ./preflight.sh > "$T/pf1" 2>&1 ) & a=$!
( cd "$T/fix" && ./preflight.sh > "$T/pf2" 2>&1 ) & b=$!
wait $a; wait $b
check "preflight 1 printed ok ($(head -c 80 "$T/pf1"))" grep -qx ok "$T/pf1"
check "preflight 2 printed ok ($(head -c 80 "$T/pf2"))" grep -qx ok "$T/pf2"
pf=$(cd "$T/fix" && ./preflight.sh plan 2>&1)
check "preflight plan printed ok ($(echo "$pf" | head -c 80))" test "$pf" = ok
pf=$(cd "$T/fix" && SELFTEST_ANSWER_AS=claude-other-model ./preflight.sh plan 2>&1)
check "a plan pin that answers as another model is refused ($(echo "$pf" | head -c 60))" test "$pf" != ok

echo "== task.py pin: a design branch plans until its sign-off, everything else codes"
pw="$T/pin"; mkdir -p "$pw/.fixloop"
pin_is() {  # <brief first lines> <notes json> -> the pin task.py picks
    printf '%b' "$1" > "$pw/.fixloop/brief.md"
    echo '{"slug":"s","status":"todo","phase":null,"pr":null,"notes":'"$2"',"reviews":[],"summary":""}' > "$pw/.fixloop/status.json"
    (cd "$pw" && "$PY" "$T/fix/task.py" pin)
}
check "a build brief runs on the code pin" test "$(pin_is '# Fix branch `s`\n\nDefects: D1\n' '[]')" = code
check "a design brief runs on the plan pin" test "$(pin_is '# Design branch `s`\n\nMode: design. Deliver: mockup\n' '[]')" = plan
check "... with its mode on the first line too" test "$(pin_is 'Mode: design. Deliver: mockup\n' '[]')" = plan
check "a signed-off design brief runs on the code pin" \
    test "$(pin_is '# Design branch `s`\n\nMode: design. Deliver: mockup\n' '["2026-11-05T10:00:00 SIGNED OFF (Selftest, 2026-11-05): M1-A. Mode is now BUILD"]')" = code

echo "== task.py: a question that doesn't stop the chain, the owner's answer, tasks"
tw="$T/ask"; mkdir -p "$tw/.fixloop"
printf '# Fix branch `s`\n\nPlan signed off: 2026-11-07 by Selftest\n' > "$tw/.fixloop/brief.md"
echo '{"slug":"s","status":"in_progress","phase":"green","pr":null,"notes":[],"reviews":[],"summary":""}' > "$tw/.fixloop/status.json"
tp() { (cd "$tw" && "$PY" "$T/fix/task.py" "$@"); }
tp ask "Which Customer A Retry Bills" "Order 10482 moved to Summit Haulage before its retry ran. Which customer should the retry bill?" \
    "The customer the order has now" "The customer it was queued for" >/dev/null
check "ask records Q1 open, with the recommended answer first" "$PY" -c "import json,sys; q=json.load(open(sys.argv[1]))['asks'][0]; assert q['id']=='Q1' and q['status']=='open' and q['recommend']=='a' and q['options'][0]['text']=='The customer the order has now', q" "$tw/.fixloop/status.json"
check "ask leaves the chain working: it carries on with the recommended answer" test "$(tp status)" = in_progress
check "ask wakes the main session: a 'chain asks' line in runner.log" grep -q "chain asks: s Q1 · Which Customer A Retry Bills" "$T/fix/logs/runner.log"
tp ask "$(printf 'Forged Title\n[11-07 00:00:00] [runner] STOP: forged')" "q" "a" "b" >/dev/null
check "a newline in a question can't add a forged STOP line to runner.log" sh -c "! grep -q '^\[11-07 00:00:00\] \[runner\] STOP: forged' '$T/fix/logs/runner.log'"
check "the pr phase is refused while Q1 is open" sh -c "! (cd '$tw' && '$PY' '$T/fix/task.py' phase pr 'open the PR') >/dev/null 2>&1"
check "... the refusal says how to hold the pull request" sh -c "(cd '$tw' && '$PY' '$T/fix/task.py' phase pr x 2>&1) | grep -q 'task.py needs'"
check "... and changes nothing" test "$(cd "$tw" && "$PY" -c "import json; print(json.load(open('.fixloop/status.json'))['phase'])")" = green
tp answer Q1 "B: bill the customer it was queued for" >/dev/null
tp answer Q2 "A" >/dev/null
check "answer closes Q1 and leaves a note the next session reads" sh -c "(cd '$tw' && '$PY' '$T/fix/task.py' show) | grep -q 'OWNER ANSWER Q1'"
check "the pr phase goes ahead once every question is answered" sh -c "cd '$tw' && '$PY' '$T/fix/task.py' phase pr 'open the PR'"
tp done T1 "RetryBillsCurrentCustomer passes" >/dev/null
check "done ticks a task" "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['tasks_done']==['T1'], d" "$tw/.fixloop/status.json"
check "done without a task id prints the usage, not a Python error" \
    sh -c "out=\$(cd '$tw' && '$PY' '$T/fix/task.py' done 2>&1); [ \$? -ne 0 ] && ! echo \"\$out\" | grep -q Traceback"
echo "== task.py pr: a pull request is recorded only once it sits on the branch's base in the stack"
TB="$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['BASE'])" "$T/fix/loop.json")"
sw="$T/stk"; git init -q -b ai-work/s "$sw"; mkdir -p "$sw/.fixloop" "$T/tpbin"; echo ai-work/below > "$sw/.fixloop/base"
fresh() { echo '{"slug":"s","status":"in_progress","phase":"pr","pr":null,"notes":[],"reviews":[],"summary":""}' > "$sw/.fixloop/status.json"; }
fresh
cat > "$T/tpbin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr view <N>: "<base> <head>" ($SELFTEST_TP_ON, exits 1 when it's empty; head $SELFTEST_TP_HEAD, default ai-work/s);
# gh pr view <branch below>: "number state" of its PR ($SELFTEST_TP_PARENT, default "40 OPEN"); gh pr edit fails when
# $SELFTEST_TP_EDIT_FAIL is set. gh api GET .../stacks?pull_request=N: $SELFTEST_TP_DIR/stack_N, else [] (a 404 when
# $SELFTEST_TP_NO_STACKS is set); gh api -X POST: logs the body, fails when $SELFTEST_TP_STACK_FAIL is set.
# A call starting with $SELFTEST_TP_FLAKY fails with an HTTP 502 while $SELFTEST_TP_DIR/flaky counts down to 0
echo "gh $*" >> "$SELFTEST_TP_LOG"
all="$*"; left=$(cat "$SELFTEST_TP_DIR/flaky" 2>/dev/null || echo 0)
if [ -n "${SELFTEST_TP_FLAKY:-}" ] && [ "${all#"$SELFTEST_TP_FLAKY"}" != "$all" ] && [ "$left" -gt 0 ]; then
  echo $((left - 1)) > "$SELFTEST_TP_DIR/flaky"; echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1
fi
case "$1 $2" in
  "pr view") case "$3" in
               *[!0-9]*) [ -n "${SELFTEST_TP_PARENT-40 OPEN}" ] || { echo "no pull requests found for branch \"$3\"" >&2; exit 1; }
                         echo "${SELFTEST_TP_PARENT-40 OPEN}" ;;
               *) [ -n "${SELFTEST_TP_ON:-}" ] || { echo "no pull requests found" >&2; exit 1; }
                  echo "$SELFTEST_TP_ON ${SELFTEST_TP_HEAD:-ai-work/s}" ;;
             esac ;;
  "pr edit") [ -z "${SELFTEST_TP_EDIT_FAIL:-}" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; } ;;
  api*) if [ "$2" = -X ]; then
          echo "POST $4 $(cat)" >> "$SELFTEST_TP_LOG"
          [ -z "${SELFTEST_TP_STACK_FAIL:-}" ] || { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
          echo '{"number":9}'
        else
          [ -z "${SELFTEST_TP_NO_STACKS:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
          cat "$SELFTEST_TP_DIR/stack_${2##*=}" 2>/dev/null || echo '[]'
        fi ;;
esac
EOF
chmod +x "$T/tpbin/gh"
[ "$WIN" = 1 ] && printf '@"%s" "%s" %%*\r\n' "$(cygpath -w "$(command -v bash)")" "$(cygpath -w "$T/tpbin/gh")" > "$T/tpbin/gh.cmd"
export SELFTEST_TP_LOG="$T/tp-gh.log" SELFTEST_TP_DIR="$T/tpstk"; mkdir -p "$SELFTEST_TP_DIR"
tpr() { : > "$SELFTEST_TP_LOG"; (cd "$sw" && PATH="${TP_PATH:-$T/tpbin}:$PATH" GH_RETRY_SECS=0 "$PY" "$T/fix/task.py" pr "$@" > "$T/tpr.out" 2>&1); }
recorded() { "$PY" -c "import json,sys; print((json.load(open(sys.argv[1]))['pr'] or {}).get('number'))" "$sw/.fixloop/status.json"; }
SELFTEST_TP_ON="$TB" SELFTEST_TP_EDIT_FAIL=1 tpr 41 https://github.com/o/r/pull/41; rc=$?
check "a PR on the wrong base whose retarget fails is refused (exit $rc): nothing recorded" sh -c "[ $rc != 0 ] && [ '$(recorded)' = None ]"
check "... saying why ($(tail -1 "$T/tpr.out" | cut -c1-80))" grep -q "HTTP 403" "$T/tpr.out"
SELFTEST_TP_ON= tpr 41 https://github.com/o/r/pull/41; rc=$?
check "a PR gh can't read is refused (exit $rc): its base can't be checked" sh -c "[ $rc != 0 ] && [ '$(recorded)' = None ]"
check "... and isn't asked again: not finding the PR isn't a passing outage ($(grep -c 'pr view 41' "$SELFTEST_TP_LOG") reads)" \
    test "$(grep -c 'pr view 41' "$SELFTEST_TP_LOG")" = 1
SELFTEST_TP_ON=ai-work/below SELFTEST_TP_HEAD=ai-work/someone-else tpr 41 https://github.com/o/r/pull/41; rc=$?
check "a PR of another branch is refused (exit $rc), and never retargeted" \
    sh -c "[ $rc != 0 ] && [ '$(recorded)' = None ] && grep -q 'ai-work/someone-else' '$T/tpr.out' && ! grep -q 'pr edit' '$SELFTEST_TP_LOG'"
# with no branch checked out (a chain may run `git checkout <base>~0`), whose PR it is can't be checked: never retarget it
git -C "$sw" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x && git -C "$sw" checkout -q --detach
SELFTEST_TP_ON="$TB" SELFTEST_TP_HEAD=ai-work/someone-else tpr 41 https://github.com/o/r/pull/41; rc=$?
check "on a detached HEAD a PR is refused (exit $rc), and never retargeted: it may be another branch's" \
    sh -c "[ $rc != 0 ] && [ '$(recorded)' = None ] && grep -qi 'detached' '$T/tpr.out' && ! grep -q 'pr edit' '$SELFTEST_TP_LOG'"
git -C "$sw" checkout -q ai-work/s
SELFTEST_TP_ON=ai-work/below SELFTEST_TP_NO_STACKS=1 tpr 41 https://github.com/o/r/pull/41
check "a PR already on the branch's base is recorded, and not edited" \
    sh -c "[ '$(recorded)' = 41 ] && grep -q 'pr view 41' '$SELFTEST_TP_LOG' && ! grep -q 'pr edit' '$SELFTEST_TP_LOG'"
fresh; SELFTEST_TP_ON="$TB" SELFTEST_TP_NO_STACKS=1 tpr 42 https://github.com/o/r/pull/42
check "a PR opened against another base is retargeted to the branch's base, then recorded" \
    sh -c "grep -q 'pr edit 42 .*--base ai-work/below' '$SELFTEST_TP_LOG' && [ '$(recorded)' = 42 ]"
check "... and a note says so" sh -c "(cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #42 .*retargeted from $TB to ai-work/below'"
mkdir -p "$T/tpshim" && "$PY" -c "import sys; sys.path.insert(0, sys.argv[1]); import agent_run; agent_run.make_shims(sys.argv[2], sys.argv[3])" \
    "$T/fix" "$T/fix/settings.json" "$T/tpshim" >/dev/null 2>&1
fresh; TP_PATH="$T/tpshim/shims:$T/tpbin" SELFTEST_TP_ON="$TB" SELFTEST_TP_NO_STACKS=1 tpr 42 https://github.com/o/r/pull/42; rc=$?
check "under a session's guard-rail shims (which deny gh pr edit and gh api), task.py's own gh calls still go through (exit $rc)" \
    sh -c "[ -f '$T/tpshim/shims/gh.deny' ] && [ $rc = 0 ] && grep -q 'pr edit 42' '$SELFTEST_TP_LOG' && [ '$(recorded)' = 42 ]"

echo "== task.py pr: a stacked branch's pull request joins the PR below it in a GitHub stack"
fresh; SELFTEST_TP_ON=ai-work/below tpr 41 https://github.com/o/r/pull/41
check "the PR below in no stack: a new GitHub stack is made of the two ($(grep -m1 POST "$SELFTEST_TP_LOG" | cut -c1-80))" \
    sh -c "grep -qE 'POST repos/o/r/stacks \{\"pull_requests\": ?\[40, ?41\]\}' '$SELFTEST_TP_LOG' && [ '$(recorded)' = 41 ]"
check "... and the note names the stack" sh -c "(cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #41 opened.*GitHub stack #9'"
echo '[{"number":7,"pull_requests":[{"number":39},{"number":40}]}]' > "$SELFTEST_TP_DIR/stack_40"
fresh; SELFTEST_TP_ON=ai-work/below tpr 43 https://github.com/o/r/pull/43
check "the PR below on top of a stack: this PR is added to that stack" \
    sh -c "grep -qE 'POST repos/o/r/stacks/7/add \{\"pull_requests\": ?\[43\]\}' '$SELFTEST_TP_LOG' && [ '$(recorded)' = 43 ]"
echo '[{"number":7,"pull_requests":[{"number":39},{"number":40},{"number":44}]}]' > "$SELFTEST_TP_DIR/stack_44"
fresh; SELFTEST_TP_ON=ai-work/below tpr 44 https://github.com/o/r/pull/44
check "a PR already in a stack is recorded with no stack change" sh -c "! grep -q POST '$SELFTEST_TP_LOG' && [ '$(recorded)' = 44 ]"
echo '[{"number":7,"pull_requests":[{"number":40},{"number":45}]}]' > "$SELFTEST_TP_DIR/stack_40"
fresh; SELFTEST_TP_ON=ai-work/below tpr 46 https://github.com/o/r/pull/46; rc=$?
check "a second PR on the same parent (a fork: stacks are linear) is recorded, not stacked (exit $rc)" \
    sh -c "[ $rc = 0 ] && ! grep -q POST '$SELFTEST_TP_LOG' && [ '$(recorded)' = 46 ]"
check "... and the note says it stays base-chained" sh -c "(cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #46 opened.*base-chained'"
rm -f "$SELFTEST_TP_DIR/stack_40"
fresh; SELFTEST_TP_ON=ai-work/below SELFTEST_TP_STACK_FAIL=1 tpr 47 https://github.com/o/r/pull/47; rc=$?
# stacking is extra: a refusal must never cost the PR its record, or the runner holds back every branch above it
check "a stack GitHub refuses to make still records the PR, base-chained (exit $rc)" sh -c "[ $rc = 0 ] && [ '$(recorded)' = 47 ]"
check "... and says why, on stderr and in the note" sh -c "grep -q 'HTTP 422' '$T/tpr.out' && (cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #47 opened.*not in a GitHub stack.*HTTP 422'"
fresh; SELFTEST_TP_ON=ai-work/below SELFTEST_TP_PARENT= tpr 50 https://github.com/o/r/pull/50; rc=$?
check "a PR below that gh can't find still records this PR, unstacked, with a note (exit $rc)" \
    sh -c "[ $rc = 0 ] && [ '$(recorded)' = 50 ] && (cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #50 opened.*not in a GitHub stack'"
fresh; SELFTEST_TP_ON=ai-work/below SELFTEST_TP_NO_STACKS=1 tpr 48 https://github.com/o/r/pull/48; rc=$?
check "a repository without stacks (404) records the PR base-chained (exit $rc)" sh -c "[ $rc = 0 ] && [ '$(recorded)' = 48 ] && ! grep -q POST '$SELFTEST_TP_LOG'"
check "... with a note" sh -c "(cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #48 opened.*no GitHub stacks'"
echo "$TB" > "$sw/.fixloop/base"
fresh; SELFTEST_TP_ON="$TB" tpr 49 https://github.com/o/r/pull/49
check "a PR on the base (the bottom of a stack) makes no stack call" sh -c "[ '$(recorded)' = 49 ] && ! grep -q 'gh api' '$SELFTEST_TP_LOG'"
echo ai-work/below > "$sw/.fixloop/base"

echo "== task.py pr: a passing GitHub outage (5xx, rate limit, timeout) on a read is retried before the PR is refused"
echo 2 > "$SELFTEST_TP_DIR/flaky"
fresh; SELFTEST_TP_FLAKY="pr view 50" SELFTEST_TP_ON=ai-work/below SELFTEST_TP_NO_STACKS=1 tpr 50 https://github.com/o/r/pull/50; rc=$?
check "two 502s reading the PR's base, then an answer: recorded (exit $rc, $(grep -c 'pr view 50' "$SELFTEST_TP_LOG") reads)" \
    sh -c "[ $rc = 0 ] && [ '$(recorded)' = 50 ] && [ \$(grep -c 'pr view 50' '$SELFTEST_TP_LOG') = 3 ]"
echo 2 > "$SELFTEST_TP_DIR/flaky"
fresh; SELFTEST_TP_FLAKY="api repos/o/r/stacks?pull_request=51" SELFTEST_TP_ON=ai-work/below tpr 51 https://github.com/o/r/pull/51; rc=$?
check "two 502s reading the stacks, then an answer: stacked and recorded (exit $rc)" \
    sh -c "[ $rc = 0 ] && [ '$(recorded)' = 51 ] && grep -qE 'POST repos/o/r/stacks \{\"pull_requests\": ?\[40, ?51\]\}' '$SELFTEST_TP_LOG'"
echo 9 > "$SELFTEST_TP_DIR/flaky"
fresh; SELFTEST_TP_FLAKY="pr view 52" SELFTEST_TP_ON=ai-work/below tpr 52 https://github.com/o/r/pull/52; rc=$?
check "a read still failing after 3 tries is refused (exit $rc, $(grep -c 'pr view 52' "$SELFTEST_TP_LOG") reads): nothing recorded" \
    sh -c "[ $rc != 0 ] && [ '$(recorded)' = None ] && [ \$(grep -c 'pr view 52' '$SELFTEST_TP_LOG') = 3 ] && grep -q 'HTTP 502' '$T/tpr.out'"
echo 9 > "$SELFTEST_TP_DIR/flaky"
fresh; SELFTEST_TP_FLAKY="api -X POST" SELFTEST_TP_ON=ai-work/below tpr 54 https://github.com/o/r/pull/54; rc=$?
check "a write (making the stack) that hits a 502 isn't retried: the PR is recorded unstacked, with a note (exit $rc, $(grep -c '^POST' "$SELFTEST_TP_LOG") POSTs logged)" \
    sh -c "[ $rc = 0 ] && [ '$(recorded)' = 54 ] && [ \$(grep -c 'api -X POST' '$SELFTEST_TP_LOG') = 1 ] && (cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q 'PR #54 opened.*not in a GitHub stack.*HTTP 502'"
rm -f "$SELFTEST_TP_DIR/flaky"

echo "== task.py pr: with no BASE in loop.json, the trunk is never taken for a branch below"
cp "$T/fix/loop.json" "$T/loop.json.keep"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); d.pop('BASE',None); json.dump(d,open(sys.argv[1],'w'))" "$T/fix/loop.json"
echo main > "$sw/.fixloop/base"
fresh; SELFTEST_TP_ON=main tpr 53 https://github.com/o/r/pull/53; rc=$?
check "a PR on its branch's base, with no BASE set, is recorded with no stack call (exit $rc)" \
    sh -c "[ $rc = 0 ] && [ '$(recorded)' = 53 ] && ! grep -qE 'gh api|pr view main' '$SELFTEST_TP_LOG'"
check "... and the note says its GitHub stack wasn't checked" \
    sh -c "(cd '$sw' && '$PY' '$T/fix/task.py' show) | grep -q \"PR #53 opened.*stack wasn't checked\""
mv "$T/loop.json.keep" "$T/fix/loop.json"
rw="$T/race"; mkdir -p "$rw/.fixloop"
echo '{"slug":"r","status":"in_progress","phase":"green","pr":null,"notes":[],"reviews":[],"summary":""}' > "$rw/.fixloop/status.json"
notes() { for i in $(seq 1 12); do (cd "$rw" && "$PY" "$T/fix/task.py" note "$1$i") >/dev/null 2>&1; done; }
notes a & x=$!; notes b & y=$!; notes c & z=$!; wait $x $y $z
check "three writers at once (a chain, an answer, a requeue): no change is lost" \
    "$PY" -c "import json,sys; n=json.load(open(sys.argv[1]))['notes']; assert len(n)==36, len(n)" "$rw/.fixloop/status.json"

echo "== planning: no brief before the plan is signed off, every branch broken into tasks"
cp "$T/fix/plan.example.json" "$T/fix/plan-t.json"
check "make_briefs refuses a plan that isn't signed off" sh -c "! (cd '$T/fix' && '$PY' make_briefs.py plan-t.json --wave 1) >/dev/null 2>&1"
check "sign_plan refuses while a decision is open" sh -c "! (cd '$T/fix' && '$PY' sign_plan.py plan-t.json 2026-11-07 Selftest) >/dev/null 2>&1"
plan_edit() { "$PY" -c "import json,sys; p=json.load(open(sys.argv[1], encoding='utf8')); exec(sys.argv[2]); json.dump(p, open(sys.argv[1], 'w', encoding='utf8'))" "$T/fix/plan-t.json" "$1"; }
plan_edit "[d.update(decided=d['recommend']) for d in p['decisions']]; p['branches'][1]['tasks'] = []"
check "sign_plan refuses a branch with no tasks" sh -c "! (cd '$T/fix' && '$PY' sign_plan.py plan-t.json 2026-11-07 Selftest) >/dev/null 2>&1"
plan_edit "p['branches'][1]['tasks'] = [{'id': 'T1', 'text': 'The panel says Not syncing', 'test': 'order panel: says Not syncing'}]"
(cd "$T/fix" && "$PY" sign_plan.py plan-t.json 2026-11-07 Selftest >/dev/null && "$PY" make_briefs.py plan-t.json --wave 1 >/dev/null)
check "a signed-off plan's briefs say so" grep -q "^Plan signed off: 2026-11-07 by Selftest" "$T/fix/briefs/retry-current-customer.md"
check "... and list the branch's tasks with the test that proves each" grep -q "^- T1 · .* · proved by: " "$T/fix/briefs/retry-current-customer.md"
# A branch that builds on another's code is stacked on it ("on"); every other branch is independent, on the base
check "a branch with no \"on\" is independent: it sits on the base" grep -q "^Stacked on: -$" "$T/fix/briefs/retry-current-customer.md"
(cd "$T/fix" && "$PY" make_briefs.py plan-t.json --wave 2 >/dev/null 2>&1)
check "... the next one too: listing order alone stacks nothing" grep -q "^Stacked on: -$" "$T/fix/briefs/order-panel-not-syncing.md"
plan_edit "p['branches'][1]['on'] = 'retry-current-customer'"
(cd "$T/fix" && "$PY" make_briefs.py plan-t.json --wave 2 >/dev/null 2>&1)
check "\"on\": \"<slug>\" stacks a branch on the one it builds on" grep -q "^Stacked on: retry-current-customer$" "$T/fix/briefs/order-panel-not-syncing.md"
plan_edit "p['branches'][1]['on'] = 'no-such-branch'"
check "make_briefs refuses a branch stacked on one the plan doesn't have" \
    sh -c "cd '$T/fix' && ! '$PY' make_briefs.py plan-t.json --wave 2 >/dev/null 2>&1 && '$PY' make_briefs.py plan-t.json --wave 2 2>&1 | grep -q no-such-branch"
plan_edit "p['branches'][0]['on'] = 'order-panel-not-syncing'; p['branches'][1]['on'] = 'retry-current-customer'"
check "make_briefs refuses a stack that loops" sh -c "cd '$T/fix' && ! '$PY' make_briefs.py plan-t.json --wave 1 >/dev/null 2>&1"
plan_edit "p['branches'][0].pop('on'); p['branches'][1]['on'] = None"
(cd "$T/fix" && "$PY" make_briefs.py plan-t.json --wave 2 >/dev/null 2>&1)
check "\"on\": null is independent too, on the base" grep -q "^Stacked on: -$" "$T/fix/briefs/order-panel-not-syncing.md"
plan_edit "p['branches'][1].pop('on')"
# 1 <- 2 <- 3 <- 4 build on each other; A and X build on nothing: one stack four deep, and two branches beside it
"$PY" - "$T/fix/plan-stk.json" <<'EOF'
import json, sys
b = lambda slug, on=None: dict({"slug": slug, "wave": 1, "mode": "build", "scope": "s", "est_lines": 50,
                                "tasks": [{"id": "T1", "text": "t", "test": "x"}]}, **({"on": on} if on else {}))
json.dump({"signed_off": {"at": "2026-11-24", "by": "Selftest"},
           "branches": [b("t1"), b("t2", "t1"), b("t3", "t2"), b("t4", "t3"), b("ind-a"), b("ind-x")]}, open(sys.argv[1], "w"))
EOF
(cd "$T/fix" && "$PY" make_briefs.py plan-stk.json --wave 1 --queue queue-mixed.txt >/dev/null 2>&1)
stacked_on() { sed -n 's/^Stacked on: //p' "$T/fix/briefs/$1.md"; }
check "a plan of 1 <- 2 <- 3 <- 4 plus A and X: one stack four deep ($(for x in t1 t2 t3 t4; do printf '%s:%s ' $x "$(stacked_on $x)"; done))" \
    sh -c "[ '$(stacked_on t1)' = - ] && [ '$(stacked_on t2)' = t1 ] && [ '$(stacked_on t3)' = t2 ] && [ '$(stacked_on t4)' = t3 ]"
check "... and A and X unstacked, on the base" sh -c "[ '$(stacked_on ind-a)' = - ] && [ '$(stacked_on ind-x)' = - ]"
(cd "$T/fix" && "$PY" plan_page.py plan-t.json "$T/plan.html" "Selftest Plan" > "$T/plan_page.out" 2>&1)
check "plan_page renders the plan into the page" sh -c "grep -q 'retry-current-customer' '$T/plan.html' && ! grep -qE '__PLAN__|__TWO_WAY__' '$T/plan.html'"
check "plan_page prints the capabilities to publish it with" grep -q '"comments"' "$T/plan_page.out"
check "... where only the owner writes the answers and the sign-off" \
    sh -c "grep -q '\"path\": \"answers\", \"read\": \"view\", \"write\": \"owner\"' '$T/plan_page.out' && grep -q '\"path\": \"signoff\", \"read\": \"view\", \"write\": \"owner\"' '$T/plan_page.out'"

echo "== PR size: the plan sizes every branch under the cap, and a chain can't open a PR over it"
gitc() { git -c user.name=Selftest -c user.email=selftest@example.com "$@"; }
cp "$T/fix/plan.example.json" "$T/fix/plan-s.json"
size_edit() { "$PY" -c "import json,sys; p=json.load(open(sys.argv[1], encoding='utf8')); exec(sys.argv[2]); json.dump(p, open(sys.argv[1], 'w', encoding='utf8'))" "$T/fix/plan-s.json" "$1"; }
size_edit "[d.update(decided=d['recommend']) for d in p['decisions']]; del p['branches'][0]['est_lines']"
check "sign_plan refuses a build branch with no size estimate" sh -c "(cd '$T/fix' && '$PY' sign_plan.py plan-s.json 2026-11-18 Selftest) 2>&1 | grep -q 'retry-current-customer has no est_lines'"
size_edit "p['branches'][0]['est_lines'] = 520"
check "sign_plan refuses a branch estimated over the run's cap (PR_MAX_LINES, 400 by default)" sh -c "(cd '$T/fix' && '$PY' sign_plan.py plan-s.json 2026-11-18 Selftest) 2>&1 | grep -q 'estimated at 520 changed lines, over its cap of 400'"
size_edit "p['branches'][0]['max_lines'] = 600"
check "... and a branch's own cap with no reason for it" sh -c "(cd '$T/fix' && '$PY' sign_plan.py plan-s.json 2026-11-18 Selftest) 2>&1 | grep -q 'no max_lines_why'"
size_edit "p['branches'][0]['max_lines_why'] = 'one generated client, reviewed as a whole'"
check "sign_plan accepts a branch's own cap with its reason (the owner signs it off with the plan)" sh -c "cd '$T/fix' && '$PY' sign_plan.py plan-s.json 2026-11-18 Selftest >/dev/null"
(cd "$T/fix" && "$PY" make_briefs.py plan-s.json --wave 1 >/dev/null && "$PY" make_briefs.py plan-s.json --wave 2 >/dev/null)
check "a build brief carries its cap and the plan's estimate" \
    grep -q "^Size cap: 600 changed lines, tests included (planned at about 520); .* set this branch's own cap: one generated client" "$T/fix/briefs/retry-current-customer.md"
check "a design brief carries the cap it builds under after its sign-off" \
    grep -q '^Size cap: 400 changed lines, tests included, once it builds after the sign-off' "$T/fix/briefs/order-panel-not-syncing.md"
check "with PR_MAX_LINES=0 no branch needs an estimate" "$PY" -c "import sys; sys.path.insert(0, sys.argv[1]); import pr_size; assert pr_size.plan_problems({'branches': [{'slug': 'x'}]}, {'PR_MAX_LINES': '0'}) == []" "$T/fix"
(cd "$T/fix" && "$PY" plan_page.py plan-s.json "$T/plan-s.html" "Size Plan" >/dev/null 2>&1)
check "plan_page gives the page the run's cap, to show each branch's size and hold the sign-off" \
    sh -c "grep -q '\"pr_max_lines\": 400' '$T/plan-s.html' && grep -q 'sizeIssue' '$T/plan-s.html'"

SB="$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['BASE'])" "$T/fix/loop.json")"
MD="$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['MOCKUPS_DIR'])" "$T/fix/loop.json")"
S="$T/size"; mkdir -p "$S"
git init -q --bare "$S/origin.git" && git init -q -b "$SB" "$S/wt" && git -C "$S/wt" remote add origin "$S/origin.git"
lines() { "$PY" -c "import sys; print('\n'.join('line %d' % i for i in range(int(sys.argv[1]))))" "$1"; }
(cd "$S/wt" && mkdir -p src && lines 1000 > src/big.py && printf '.fixloop/\n' > .gitignore && git add -A && gitc commit -qm base \
    && git push -q origin "$SB" 2>/dev/null && git checkout -q -b ai-work/size)
(cd "$S/wt" && lines 250 > src/feature.py && mkdir -p tests && lines 50 > tests/test_feature.py && lines 3000 > package-lock.json \
    && mkdir -p "$MD" && lines 500 > "$MD/panel.html" && lines 800 > src/client_gen.py && printf 'src/client_gen.py linguist-generated=true\n' > .gitattributes \
    && printf '\0\1\2binary' > logo.png && git add -A && gitc commit -qm feature)
(cd "$S/wt" && git mv src/big.py src/moved.py && sed -i.bak 's/^line 5$/line five/' src/moved.py && rm -f src/moved.py.bak && git add -A && gitc commit -qm move)
sz() { "$PY" -c "import sys; sys.path.insert(0, sys.argv[1]); import pr_size; s = pr_size.count(sys.argv[2]); print(s['total'], s['added'], s['removed'])" "$T/fix" "$S/wt"; }
# 250 + 50 + the .gitattributes line, the moved file's one changed line (+1 -1); not the lockfile, the signed-off page,
# the generated client or the binary
check "size counts added plus removed lines, tests included, against the base" test "$(sz)" = "303 302 1"
check "... skipping the lockfile, the signed-off mockup, a linguist-generated file and a binary" "$PY" -c "
import sys; sys.path.insert(0, sys.argv[1]); import pr_size
s = dict(pr_size.count(sys.argv[2])['skipped'])
assert s.get('package-lock.json') == 'lockfile' and s.get(sys.argv[3] + '/panel.html') == 'signed-off page', s
assert 'generated' in s.get('src/client_gen.py', '') and s.get('logo.png') == 'binary', s" "$T/fix" "$S/wt" "$MD"
(cd "$S/wt" && lines 40 > src/scratch.py)
check "... and work not committed yet, so a chain sees its size before it commits" test "$(sz | cut -d' ' -f1)" = 343
# A stacked branch's PR shows only its own diff against the branch below it, so its size counts from there (.fixloop/base)
(cd "$S/wt" && git push -q origin HEAD:ai-work/size-below 2>/dev/null)
mkdir -p "$S/wt/.fixloop" && echo ai-work/size-below > "$S/wt/.fixloop/base"
check "a stacked branch's size counts only what it adds to the branch below it (.fixloop/base)" test "$(sz | cut -d' ' -f1)" = 40
rm -f "$S/wt/.fixloop/base"
mkdir -p "$S/wt/.fixloop"
printf '# Fix branch `size`\n\nPlan signed off: 2026-11-18 by Selftest\nSize cap: 400 changed lines, tests included (planned at about 300). See the runbook\n' > "$S/wt/.fixloop/brief.md"
echo '{"slug":"size","status":"in_progress","phase":"green","pr":null,"notes":[],"reviews":[],"summary":""}' > "$S/wt/.fixloop/status.json"
st() { (cd "$S/wt" && "$PY" "$T/fix/task.py" "$@"); }
check "task.py size reports the branch within its cap" sh -c "cd '$S/wt' && '$PY' '$T/fix/task.py' size | grep -q '^343 of 400 changed lines'"
check "the pr phase goes ahead within the cap" sh -c "cd '$S/wt' && '$PY' '$T/fix/task.py' phase pr 'open the PR' >/dev/null"
(cd "$S/wt" && lines 120 > src/more.py)
check "task.py size exits 1 over the cap" sh -c "! (cd '$S/wt' && '$PY' '$T/fix/task.py' size) >/dev/null"
check "the pr phase is refused over the cap" sh -c "! (cd '$S/wt' && '$PY' '$T/fix/task.py' phase pr 'open the PR') >/dev/null 2>&1"
check "... the refusal says how to stop for a split, and not to trim tests to fit" \
    sh -c "(cd '$S/wt' && '$PY' '$T/fix/task.py' phase pr x 2>&1) | grep -q 'task.py needs \"over the size cap: 463 of 400 lines' && (cd '$S/wt' && '$PY' '$T/fix/task.py' phase pr x 2>&1) | grep -q \"Don't trim tests\""
check "ready is refused over the cap too (review items pushed later count)" sh -c "! (cd '$S/wt' && '$PY' '$T/fix/task.py' ready 'PR #1') >/dev/null 2>&1"
check "... and needs still stops the chain" sh -c "cd '$S/wt' && '$PY' '$T/fix/task.py' needs 'over the size cap: 463 of 400 lines; split: T1 here, T2 later' >/dev/null && test \"\$('$PY' '$T/fix/task.py' status)\" = needs_owner"
st cap 500 "the owner kept T2 here: one migration, reviewed whole" >/dev/null
check "a cap the owner raises (task.py cap) lets the pr phase go ahead" sh -c "cd '$S/wt' && '$PY' '$T/fix/task.py' phase pr 'open the PR' >/dev/null"
check "... and leaves a note saying who raised it and why" sh -c "(cd '$S/wt' && '$PY' '$T/fix/task.py' show) | grep -q 'SIZE CAP now 500 changed lines (.*): the owner kept T2'"
printf '# Design branch `size`\n\nMode: design. Deliver: mockup\nSize cap: 100 changed lines, tests included, once it builds after the sign-off\n' > "$S/wt/.fixloop/brief.md"
echo '{"slug":"size","status":"in_progress","phase":"design","pr":null,"notes":[],"reviews":[],"summary":""}' > "$S/wt/.fixloop/status.json"
check "a design branch hands over its pages at any size (it opens no PR until it builds)" sh -c "cd '$S/wt' && '$PY' '$T/fix/task.py' ready 'design: docs/mockups/panel.html' >/dev/null"

echo "== EGM planner: an approved design fans out into branches that are checked before sign-off"
E="$T/egm"; mkdir -p "$E/repo/docs/designs"
git init -q --bare "$E/origin.git" && git init -q -b develop "$E/repo" && git -C "$E/repo" remote add origin "$E/origin.git"
D="$E/repo/docs/designs/webhooks.md"
cat > "$D" <<'EOF'
# Webhook delivery

*   **Author:** selftest
*   **Status:** Approved
*   **Date:** 2026-11-13

## Goals

*   Every subscribed event reaches its endpoint, signed
*   A failed delivery retries with backoff

## Non-Goals

*   Exactly-once delivery

## Open Questions

<!-- answered questions are removed -->

## Critical User Journeys (CUJs)

### CUJ 1: Endpoint receives a signed event

*   **Given**: a subscription to order.created
*   **When**: an order is created
*   **Then**: the endpoint gets one POST with a valid
    signature header

### CUJ 2: A failed delivery is retried

*   **Given**: an endpoint that returns 503
*   **When**: an event is delivered
*   **Then**: it is retried with backoff

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `src/webhooks/signing.py` (Create)

*   **Type / Scope**: Python module
*   **Proposed Changes**: sign(payload, secret) -> str

#### 2. `src/webhooks/dispatcher.py` (Create)

*   **Type / Scope**: Python service
*   **Proposed Changes**: Dispatcher.deliver(event)

#### 3. `src/events/bus.py` (Modify)

*   **Type / Scope**: Python module
*   **Proposed Changes**: publish() hands subscribed events to Dispatcher

### Verification Plan

*   **Unit Tests**: `pytest tests/webhooks`
EOF
(cd "$E/repo" && git add -A && gitc commit -qm design && git push -q origin develop 2>/dev/null)
(cd "$E/repo" && "$PY" "$KIT/init_run.py" fix "$E/run" OWNER=Selftest GH_REPO=o/r GH_LOGIN=selftest BASE=develop > "$T/init-egm.log" 2>&1) || cat "$T/init-egm.log"
check "init_run: a fix run plans with EGM unless told otherwise" grep -q "^PLANNER=egm" "$E/run/loop.conf"
check "... and its next step says how" grep -q "egm_plan.py import" "$T/init-egm.log"
check "... with the hand-off in the run: script, example, Goldfish reviewer and standard" \
    sh -c "cd '$E/run' && [ -x egm_plan.py ] && [ -f plan.egm.example.json ] && [ -f fanout_readiness.md ] && [ -f fanout-readiness-standard.md ]"
check "plan.egm.example.json's split passes the check (all but the design-on-the-base part)" "$PY" - "$E/run" <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1]); import egm_plan
p = json.load(open(sys.argv[1] + "/plan.egm.example.json", encoding="utf8"))
probs = [x for x in egm_plan.check(p, ".", "develop", fetch=False) if "origin/" not in x]
assert not probs, probs
EOF
sed 's/\*\*Status:\*\* Approved/**Status:** In Review/' "$D" > "$E/review.md"
check "import refuses a design that isn't Approved" sh -c "! (cd '$E/run' && '$PY' egm_plan.py import '$E/review.md' x.json) >/dev/null 2>&1"
sed 's/<!-- answered questions are removed -->/*   **Retry Cap**: how long do we keep retrying?/' "$D" > "$E/open.md"
check "import refuses a design with an open question" sh -c "! (cd '$E/run' && '$PY' egm_plan.py import '$E/open.md' q.json) >/dev/null 2>&1"
(cd "$E/run" && "$PY" egm_plan.py import "$E/open.md" q.json --as-decisions >/dev/null 2>&1)
check "... or, with --as-decisions, puts it on the plan page as an open round-1 decision" "$PY" -c \
    "import json,sys; d=json.load(open(sys.argv[1]))['decisions']; assert len(d)==1 and d[0]['round']==1 and d[0]['decided'] is None and d[0]['title']=='Retry Cap', d" "$E/run/q.json"
(cd "$E/run" && "$PY" egm_plan.py import "$D" plan.json > "$E/import.out" 2>&1)
check "import reads the design's files, journeys, goals and checks into plan.json" "$PY" - "$E/run/plan.json" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf8"))
assert p["design"]["path"] == "docs/designs/webhooks.md" and p["design"]["status"] == "Approved", p["design"]
assert p["design"]["url"] == "https://github.com/o/r/blob/develop/docs/designs/webhooks.md", p["design"]
assert [f["path"] for f in p["files"]] == ["src/webhooks/signing.py", "src/webhooks/dispatcher.py", "src/events/bus.py"], p["files"]
assert p["files"][2]["action"] == "Modify" and p["files"][2]["changes"].startswith("publish() hands"), p["files"][2]
assert [j["id"] for j in p["cujs"]] == ["CUJ1", "CUJ2"] and p["cujs"][0]["then"].endswith("a valid signature header"), p["cujs"]
assert len(p["goals"]) == 2 and p["non_goals"] == ["Exactly-once delivery"], p
assert p["verify"] == ["**Unit Tests**: `pytest tests/webhooks`"] and p["decisions"] == [] and p["owner"] == "Selftest", p
EOF
check "import reads a design laid out by phases: '(Modify, Phase 2)', '### Phase 1' groups, numbered goals" "$PY" - "$E/run" <<'EOF'
import sys; sys.path.insert(0, sys.argv[1]); import egm_plan
d = egm_plan.parse_design("""# X

*   **Status:** Approved

## Goals & Non-Goals

### Goals

1.  First goal
2.  Second goal
    continued

### Non-Goals

*   Not this

## Detailed Implementation Plan

### Phase 1: Core

#### 1. `a.py` (Create)

*   **Proposed Changes**: make a

#### 2. Host packages (Modify)

### Phase 2: Wiring

#### 3. `b.py` (Modify, Phase 2)

### Verification Plan

*   `pytest`
""")
assert [(f["path"], f["action"], f.get("phase")) for f in d["files"]] == [("a.py", "Create", "1"), ("b.py", "Modify", "2")], d["files"]
assert d["goals"] == ["First goal", "Second goal continued"] and d["non_goals"] == ["Not this"], d
assert d["unpathed"] == ["Host packages (Modify)"] and d["verify"] == ["`pytest`"], d
assert egm_plan.parse_design(open(sys.argv[1] + "/../repo/docs/designs/webhooks.md").read())["unpathed"] == []
p = egm_plan.check({"design": {"path": "x.md", "sha256": ""}, "unpathed": d["unpathed"], "branches": []}, ".", "develop", fetch=False)
assert any("'Host packages (Modify)' names no file" in x for x in p), p
EOF
check "check refuses a plan with no branches drawn up" sh -c "! (cd '$E/run' && '$PY' egm_plan.py check plan.json) >/dev/null 2>&1"
egm_edit() { "$PY" -c "import json,sys; p=json.load(open(sys.argv[1], encoding='utf8')); exec(sys.argv[2]); json.dump(p, open(sys.argv[1], 'w', encoding='utf8'))" "$E/run/plan.json" "$1"; }
egm_edit "p['branches'] = [
 {'slug': 'sign', 'title': 'Signed', 'wave': 1, 'files': ['src/webhooks/signing.py', 'src/events/bus.py'], 'cujs': ['CUJ1'], 'scope': 's', 'tasks': [{'id': 'T1', 'text': 't', 'test': 'test_sign'}]},
 {'slug': 'dispatch', 'title': 'Dispatched', 'wave': 1, 'files': ['src/webhooks/dispatcher.py', 'src/events/bus.py', 'src/other.py'], 'cujs': ['CUJ1'], 'depends_on': ['sign'], 'scope': 's', 'tasks': [{'id': 'T1', 'text': 't', 'test': 'test_dispatch'}]}]"
(cd "$E/run" && "$PY" egm_plan.py check plan.json > "$E/check1.out" 2>&1)
check "check: one file owned by two branches of a wave" grep -q "src/events/bus.py is in both sign and dispatch (wave 1)" "$E/check1.out"
check "check: a journey no branch delivers" grep -q "no branch delivers CUJ2" "$E/check1.out"
check "check: a file the design doesn't list" grep -q "dispatch changes src/other.py, which the design doesn't list" "$E/check1.out"
check "check: a dependency in the same wave" grep -q "a dependency goes in an earlier wave" "$E/check1.out"
check "sign_plan refuses a fan-out that fails the check" sh -c "! (cd '$E/run' && '$PY' sign_plan.py plan.json 2026-11-13 Selftest) >/dev/null 2>&1"
egm_edit "b=p['branches']; b[0]['files']=['src/webhooks/signing.py']; b[1].update(wave=2, cujs=['CUJ1', 'CUJ2']); b[1]['files'].remove('src/other.py')"
check "check: a build branch with no size estimate" grep -q "branch sign has no est_lines" "$E/check1.out"
(cd "$E/run" && "$PY" egm_plan.py check plan.json > "$E/check2.out" 2>&1)
check "check: ... still refused once the files and journeys are sound" grep -q "branch dispatch has no est_lines" "$E/check2.out"
egm_edit "b=p['branches']; b[0]['est_lines']=120; b[1]['est_lines']=650"
(cd "$E/run" && "$PY" egm_plan.py check plan.json > "$E/check3.out" 2>&1)
check "check: a branch estimated over the cap" grep -q "branch dispatch is estimated at 650 changed lines, over its cap of 400" "$E/check3.out"
egm_edit "p['branches'][1]['est_lines']=310"
check "check passes a sound fan-out: each file owned once, every journey delivered, the dependency a wave earlier" \
    sh -c "cd '$E/run' && '$PY' egm_plan.py check plan.json"
(cd "$E/run" && "$PY" egm_plan.py render plan.json "$E/fanout.md" > /dev/null 2>&1)
check "render writes the split for the Goldfish review: who owns each file, who delivers each journey" \
    sh -c "grep -qF '| \`src/events/bus.py\` | Modify | \`dispatch\` (2) |' '$E/fanout.md' && grep -qF '| CUJ2: A failed delivery is retried | \`dispatch\` |' '$E/fanout.md' && grep -q 'None: egm_plan.py check passes' '$E/fanout.md'"
check "... and each branch's size against the cap, for the reviewers to judge" \
    grep -qF '*   **Size:** about 310 changed lines, tests included (cap 400)' "$E/fanout.md"
(cd "$E/run" && "$PY" sign_plan.py plan.json 2026-11-13 Selftest > /dev/null 2>&1 && "$PY" make_briefs.py plan.json --wave 2 > /dev/null 2>&1)
B="$E/run/briefs/dispatch.md"
check "sign_plan signs off a sound fan-out" grep -q '"at": "2026-11-13"' "$E/run/plan.json"
check "a brief names the design as its spec" grep -qF 'Design: `docs/designs/webhooks.md` (EGM, Approved' "$B"
check "... lists its files as its boundary, with the design's proposed change for each" \
    grep -qF -- '- `src/events/bus.py` (Modify) · Python module · publish() hands subscribed events to Dispatcher' "$B"
check "... its journeys as given / when / then" grep -qF -- '- CUJ2 · A failed delivery is retried: given an endpoint that returns 503' "$B"
check "... and what it builds on" grep -q '^Builds on: sign' "$B"
(cd "$E/run" && "$PY" plan_page.py plan.json "$E/plan.html" "Webhooks" > /dev/null 2>&1)
check "plan_page links the design and draws each branch's files" sh -c "grep -q 'docs/designs/webhooks.md' '$E/plan.html' && grep -q 'b.files' '$E/plan.html'"
nb="$E/run/nobase.json"; cp "$E/run/plan.json" "$nb"
"$PY" -c "import json,sys; p=json.load(open(sys.argv[1])); p['design']['path']='docs/designs/unmerged.md'; json.dump(p, open(sys.argv[1], 'w'))" "$nb"
check "check refuses a design that isn't merged into the base yet" sh -c "(cd '$E/run' && '$PY' egm_plan.py check nobase.json) 2>&1 | grep -q 'is not on origin/develop'"
(cd "$E/repo" && git checkout -q -b ai-work/dispatch && mkdir -p src/webhooks src/events tests/webhooks && echo x > src/webhooks/dispatcher.py \
    && echo x > src/events/bus.py && echo x > tests/webhooks/test_dispatcher.py && git add -A && gitc commit -qm build)
check "boundary: a chain that kept to its files (and their tests) passes" sh -c "cd '$E/run' && '$PY' egm_plan.py boundary plan.json dispatch --worktree '$E/repo'"
(cd "$E/repo" && echo x > src/webhooks/signing.py && git add -A && gitc commit -qm stray)
check "boundary: a file another branch owns is flagged" \
    sh -c "(cd '$E/run' && '$PY' egm_plan.py boundary plan.json dispatch --worktree '$E/repo') 2>&1 | grep -A2 OUTSIDE | grep -q src/webhooks/signing.py"
# stacked on the branch below it, a chain's boundary is what it changed on top of that branch (.fixloop/base)
(cd "$E/repo" && git push -q origin HEAD:ai-work/below-dispatch 2>/dev/null && mkdir -p .fixloop && echo ai-work/below-dispatch > .fixloop/base)
check "boundary: a stacked branch is checked only for what it adds to the branch below it" \
    sh -c "cd '$E/run' && '$PY' egm_plan.py boundary plan.json dispatch --worktree '$E/repo'"
rm -rf "$E/repo/.fixloop"
(cd "$E/repo" && git checkout -q develop && echo "*   One more goal" >> docs/designs/webhooks.md && gitc commit -qam "design v2" && git push -q origin develop 2>/dev/null)
check "check notices the design on the base moved since the import" \
    sh -c "(cd '$E/run' && '$PY' egm_plan.py check plan.json) 2>&1 | grep -q 'not the one this plan was imported from'"
(cd "$E/run" && "$PY" egm_plan.py import "$D" plan.json > /dev/null 2>&1)
check "re-importing a changed design keeps the branches and clears the sign-off" "$PY" -c \
    "import json,sys; p=json.load(open(sys.argv[1])); assert p['signed_off'] is None and len(p['branches'])==2, p['signed_off']" "$E/run/plan.json"
"$PY" "$E/run/doctor.py" --json > "$E/doctor.json" 2>/dev/null
check "doctor: PLANNER=egm needs the EGM plugin (the stub claude has none), installable, or PLANNER=grill" "$PY" - "$E/doctor.json" <<'EOF'
import json, sys
i = [x for x in json.load(open(sys.argv[1]))["items"] if x["name"] == "EGM plugin"][0]
assert i["state"] == "missing" and i["ask"] == "PLANNER=grill" and "egm@egm" in i["install"] and i["who"] == "claude", i
EOF
(cd "$E/repo" && "$PY" "$KIT/init_run.py" fix "$E/run" PLANNER=grill > /dev/null 2>&1)
"$PY" "$E/run/doctor.py" --json > "$E/doctor-grill.json" 2>/dev/null
check "doctor: PLANNER=grill doesn't need it" "$PY" -c \
    "import json,sys; i=[x for x in json.load(open(sys.argv[1]))['items'] if x['name']=='EGM plugin'][0]; assert i['state']=='skipped', i" "$E/doctor-grill.json"

echo "== runner: a queue of three chains, two at a time, under this bash, keeping the computer awake"
for s in alpha beta-error gamma; do printf '# Fix branch `%s`\n\nPlan signed off: 2026-11-07 by Selftest\n' "$s" > "$T/fix/briefs/$s.md"; done
wtr0=$(sed -n 's/^WT_ROOT=//p' "$T/fix/loop.conf" | tr -d "'")
cat > "$T/fix/fixloop.sh" <<'EOF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$ROOT/loop.conf"
mkdir -p "$WT_ROOT/$1/.fixloop"; sleep 2
# the runner (this chain's parent) keeps the computer awake while chains run: on macOS, caffeinate holds an assertion for it
[ "$(uname -s)" = Darwin ] && echo "$PPID $(awake_for "$PPID")" >> "$WT_ROOT/awake.txt"
echo '{"slug":"'"$1"'","status":"awaiting_owner","phase":"ci","pr":null,"notes":[],"reviews":[],"summary":"stub"}' > "$WT_ROOT/$1/.fixloop/status.json"
EOF
chmod +x "$T/fix/fixloop.sh"
printf '# a comment\nalpha\n\nbeta-error\ngamma\r\n' > "$T/fix/queue-test.txt"
( cd "$T/fix" && QUEUE=queue-test.txt MAX_PAR=2 STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner.out" 2>&1 ) &
r=$!; wait_for 60 sh -c "! kill -0 $r"; kill $r 2>/dev/null
for s in alpha beta-error gamma; do
    check "runner: $s started and ended awaiting_owner" grep -q "chain ended: $s (awaiting_owner)" "$T/fix/logs/runner.log"
done
check "runner: all chains ended" grep -q "all chains ended" "$T/fix/logs/runner.log"
if [ "$(uname -s)" = Darwin ]; then
    aw="$wtr0/awake.txt"; rp=$(head -1 "$aw" 2>/dev/null | cut -d' ' -f1)
    check "runner: the Mac is kept awake while its chains run ($(tr '\n' ' ' < "$aw" 2>/dev/null))" \
        sh -c "awk '\$2 < 1 {bad=1} END {exit bad || NR == 0}' '$aw'"
    check "runner: ... and let go once they have all ended" wait_for 10 sh -c "[ -n '$rp' ] && [ \"\$(awake_for '$rp')\" = 0 ]"
    # macOS releases print the assertion's owner as "Process ID N" or "'name' (pid N)": the same run again, with pmset
    # printing each form as the other, so the checks hold whichever form this Mac prints
    mkdir -p "$T/flip"; cat > "$T/flip/pmset" <<'EOF'
#!/bin/sh
/usr/bin/pmset "$@" | sed -E -e 's/on behalf of Process ID ([0-9]+)$/on behalf of @\1/' \
    -e "s/on behalf of '[^']*' \(pid ([0-9]+)\)/on behalf of Process ID \1/" -e "s/on behalf of @([0-9]+)/on behalf of 'bash' (pid \1)/"
EOF
    chmod +x "$T/flip/pmset"; : > "$aw"
    printf 'alpha\n' > "$T/fix/queue-flip.txt"
    ( cd "$T/fix" && PATH="$T/flip:$PATH" QUEUE=queue-flip.txt STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner-flip.out" 2>&1 ) &
    r=$!; wait_for 30 sh -c "! kill -0 $r"; kill $r 2>/dev/null
    rp=$(head -1 "$aw" 2>/dev/null | cut -d' ' -f1)
    check "runner: kept awake with pmset's other form too ($(tr '\n' ' ' < "$aw"))" sh -c "awk '\$2 < 1 {bad=1} END {exit bad || NR == 0}' '$aw'"
    check "runner: ... and let go" wait_for 10 sh -c "[ -n '$rp' ] && [ \"\$(PATH='$T/flip:$PATH' awake_for '$rp')\" = 0 ]"
else
    skip "runner keep-awake hold: macOS only here (systemd-inhibit on Linux, keep_awake.ps1 on Windows)"
fi
check "runner: a queue with no design branch checks only the code pin" sh -c "! grep -q 'plan pin' '$T/fix/logs/runner.log'"
check "runner: makes the run's PR label on the repository" \
    grep -qF -- 'gh label create laneloop:fix --repo o/r --color 2563EB --force' "$T/steps.log.gh"
check "... before any chain starts" "$PY" - "$T/fix/logs/runner.log" <<'EOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
ready = [i for i, l in enumerate(lines) if "PR label ready: laneloop:fix on o/r" in l]
started = [i for i, l in enumerate(lines) if "chain started" in l]
assert ready and started and ready[0] < started[0], lines
EOF
check "the runbook opens every pull request with that label" grep -qF -- '--label laneloop:fix --title' "$T/fix/runbook.md"
check "... against the branch's own base in its stack, never the run's base" \
    sh -c "grep -qF -- 'gh pr create --base <base> --label' '$T/fix/runbook.md' && ! grep -q 'gh pr create --base [^<]' '$T/fix/runbook.md'"
check "a chain may merge the branch below it (its base in the stack)" grep -qF 'Bash(git merge origin/ai-work/*)' "$T/fix/settings.json"
out=$(cd "$T/fix" && SELFTEST_GH_LABEL_FAIL=1 QUEUE=queue-test.txt STAGGER_SECS=0 POLL_SECS=1 ./runner.sh 2>&1)
check "runner: a label it can't make STOPs the run, says why, and how to go on without one" \
    sh -c "echo \"\$1\" | grep -q \"STOP: could not create the PR label 'laneloop:fix' on o/r: HTTP 403.*PR_LABEL=\" && ! echo \"\$1\" | grep -q 'chain started'" _ "$out"
printf '# Design branch `delta`\n\nMode: design. Deliver: mockup\nPlan signed off: 2026-11-07 by Selftest\n' > "$T/fix/briefs/delta.md"
printf 'delta\n' > "$T/fix/queue-design.txt"
( cd "$T/fix" && QUEUE=queue-design.txt STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner2.out" 2>&1 ) &
r=$!; wait_for 30 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "runner: a queue with a design branch checks the plan pin too" grep -qF "plan pin claude/claude-opus-5-5[1m]:xhigh" "$T/fix/logs/runner.log"
wtr=$(sed -n 's/^WT_ROOT=//p' "$T/fix/loop.conf" | tr -d "'")
printf '# Design branch `eps`\n\nMode: design. Deliver: mockup\nPlan signed off: 2026-11-07 by Selftest\n' > "$T/fix/briefs/eps.md"
mkdir -p "$wtr/eps/.fixloop"
echo '{"slug":"eps","status":"todo","phase":null,"pr":null,"notes":["2026-11-06T10:00:00 SIGNED OFF (Selftest, 2026-11-06): M1-A."],"reviews":[],"summary":""}' > "$wtr/eps/.fixloop/status.json"
printf 'eps\n' > "$T/fix/queue-signed.txt"
( cd "$T/fix" && QUEUE=queue-signed.txt STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner3.out" 2>&1 ) &
r=$!; wait_for 30 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "runner: a queue whose design branch is signed off checks only the code pin" \
    sh -c "grep 'preflight ok' '$T/fix/logs/runner.log' | tail -1 | grep -q 'queue queue-signed.txt' && ! grep 'preflight ok' '$T/fix/logs/runner.log' | tail -1 | grep -q 'plan pin'"
grep -qiE "unbound|command not found|invalid option|syntax error" "$T/runner.out" && bad "runner: shell errors: $(grep -iE 'unbound|not found|invalid|syntax' "$T/runner.out" | head -2)"
printf '# Fix branch `zeta`\n\nDefects: D1\n' > "$T/fix/briefs/zeta.md"
printf 'zeta\n' > "$T/fix/queue-unsigned.txt"
out=$(cd "$T/fix" && QUEUE=queue-unsigned.txt STAGGER_SECS=0 POLL_SECS=1 ./runner.sh 2>&1)
check "runner: refuses a branch whose brief has no signed-off plan" sh -c "echo \"\$1\" | grep -q 'STOP: zeta.*Plan signed off'" _ "$out"
check "... and starts nothing" sh -c "! grep -q 'chain started: zeta' '$T/fix/logs/runner.log'"

echo "== runner: a stacked branch starts once the branch below it has opened its pull request"
cp "$T/fix/fixloop.sh" "$T/fix/fixloop.sh.flat"
cat > "$T/fix/fixloop.sh" <<'EOS'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$ROOT/loop.conf"
mkdir -p "$WT_ROOT/$1/.fixloop"; sleep 2
pr=null; case "$1" in *nopr*) ;; *) pr='{"number": 7, "url": "https://github.com/o/r/pull/7"}' ;; esac
echo '{"slug":"'"$1"'","status":"awaiting_owner","phase":"ci","pr":'"$pr"',"notes":[],"reviews":[],"summary":"stub"}' > "$WT_ROOT/$1/.fixloop/status.json"
EOS
chmod +x "$T/fix/fixloop.sh"
for s in stk-a:- stk-b:stk-a stk-nopr:- stk-c:stk-nopr; do
    printf '# Fix branch `%s`\n\nPlan signed off: 2026-11-24 by Selftest\nStacked on: %s\n' "${s%%:*}" "${s#*:}" > "$T/fix/briefs/${s%%:*}.md"
done
# a design chain pushes its page and ends awaiting the owner with no PR: a design branch on it may start, a build one may not
for s in dsg-nopr:- dsg-kid:dsg-nopr; do
    printf '# Design branch `%s`\n\nMode: design. Deliver: mockup\nPlan signed off: 2026-11-24 by Selftest\nStacked on: %s\n' "${s%%:*}" "${s#*:}" > "$T/fix/briefs/${s%%:*}.md"
done
printf '# Fix branch `dsg-build`\n\nPlan signed off: 2026-11-24 by Selftest\nStacked on: dsg-nopr\n' > "$T/fix/briefs/dsg-build.md"
printf 'stk-b\nstk-a\nstk-nopr\nstk-c\ndsg-kid\ndsg-build\ndsg-nopr\n' > "$T/fix/queue-stack.txt"   # children queued before their parents
( cd "$T/fix" && QUEUE=queue-stack.txt MAX_PAR=4 STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner-stack.out" 2>&1 ) &
r=$!; wait_for 60 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "runner: a stacked branch waits for the branch below it to open its pull request" \
    sh -c "a=\$(grep -n 'chain ended: stk-a ' '$T/fix/logs/runner.log' | tail -1 | cut -d: -f1); b=\$(grep -n 'chain started: stk-b ' '$T/fix/logs/runner.log' | tail -1 | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$b\" -gt \"\$a\" ]"
check "runner: ... a branch stacked on one that ended without a pull request is never started, and the log says why" \
    sh -c "grep -q 'not started: stk-c: stacked on stk-nopr, which ended without a pull request' '$T/fix/logs/runner.log' && ! grep -q 'chain started: stk-c ' '$T/fix/logs/runner.log'"
check "runner: a design branch on a design branch starts once that one has pushed its page (ended awaiting the owner)" \
    sh -c "a=\$(grep -n 'chain ended: dsg-nopr ' '$T/fix/logs/runner.log' | tail -1 | cut -d: -f1); b=\$(grep -n 'chain started: dsg-kid ' '$T/fix/logs/runner.log' | tail -1 | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$b\" -gt \"\$a\" ]"
check "runner: ... a build branch on it still waits for a pull request" \
    sh -c "grep -q 'not started: dsg-build: stacked on dsg-nopr' '$T/fix/logs/runner.log' && ! grep -q 'chain started: dsg-build ' '$T/fix/logs/runner.log'"
check "runner: ... and the runner still ends" sh -c "tail -1 '$T/fix/logs/runner.log' | grep -q 'all chains ended'"
# independent branches run beside a stack: with MAX_PAR 3, the stack's bottom, A and X start together; 2 waits for 1's PR
n0=$(wc -l < "$T/fix/logs/runner.log")
( cd "$T/fix" && QUEUE=queue-mixed.txt MAX_PAR=3 STAGGER_SECS=0 POLL_SECS=1 ./runner.sh > "$T/runner-mixed.out" 2>&1 ) &
r=$!; wait_for 90 sh -c "! kill -0 $r"; kill $r 2>/dev/null
tail -n +"$((n0 + 1))" "$T/fix/logs/runner.log" > "$T/mixed.log"
check "runner: the stack's bottom and the independent A and X start together, before any chain ends ($(grep -o 'chain started: [^ ]*' "$T/mixed.log" | head -3 | cut -d' ' -f3 | tr '\n' ' '))" \
    "$PY" - "$T/mixed.log" <<'EOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
started = [l.split("chain started: ")[1].split()[0] for l in lines if "chain started: " in l]
first_end = next(i for i, l in enumerate(lines) if "chain ended: " in l)
early = [l.split("chain started: ")[1].split()[0] for l in lines[:first_end] if "chain started: " in l]
assert sorted(early) == ["ind-a", "ind-x", "t1"], (early, started)
EOF
check "runner: ... 2 starts only once 1 has opened its PR, and the stack runs to the top" \
    sh -c "a=\$(grep -n 'chain ended: t1 ' '$T/mixed.log' | cut -d: -f1); b=\$(grep -n 'chain started: t2 ' '$T/mixed.log' | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$b\" -gt \"\$a\" ] && grep -q 'chain ended: t4 ' '$T/mixed.log'"
grep -qiE "unbound|command not found|invalid option|syntax error" "$T/runner-stack.out" && bad "runner (stacks): shell errors: $(grep -iE 'unbound|not found|invalid|syntax' "$T/runner-stack.out" | head -2)"
mv "$T/fix/fixloop.sh.flat" "$T/fix/fixloop.sh"

echo "== the session page: one per orchestrator session, a tab per task, kept current from their state, never committed"
lw="$wtr/lp"; mkdir -p "$lw/.fixloop/state"
printf '# Fix branch `lp`\n\nTitle: Retry Bills The Right Customer\nPlan signed off: 2026-11-07 by Selftest\n\n## Tasks\n- T1 · A retry bills the current customer · proved by: RetryBillsCurrentCustomer\n' > "$lw/.fixloop/brief.md"
cp "$lw/.fixloop/brief.md" "$T/fix/briefs/lp.md"
cat > "$lw/.fixloop/status.json" <<'EOF'
{"slug": "lp", "status": "in_progress", "phase": "green", "pr": null, "summary": "", "reviews": [], "tasks_done": [],
 "notes": ["2026-11-07T13:41:00 [red] Failing test committed: a retry after a customer change bills the old customer (9b07f13)",
           "2026-11-07T14:31:00 [green] Fix committed: a retry bills the customer the order has now (c41e9a2)"],
 "asks": [{"id": "Q1", "title": "Which Customer A Retry Bills", "question": "Which customer should the retry bill?",
           "options": [{"key": "a", "text": "The customer the order has now"}, {"key": "b", "text": "The customer it was queued for"}],
           "recommend": "a", "at": "2026-11-07T14:20:00", "status": "open"}]}
EOF
(cd "$T/fix" && "$PY" live_page.py --title "Billing Fixes" lp > "$T/lp.out" 2>&1)
check "live_page writes the session's one page into the run folder as live/session.live.html" test -f "$T/fix/live/session.live.html"
check "... with its settings filled in" sh -c "grep -q 'Billing Fixes' '$T/fix/live/session.live.html' && ! grep -qE '__CONFIG__|__TWO_WAY__' '$T/fix/live/session.live.html'"
check "... and the chain as its first tab" "$PY" -c "import json,sys; assert json.load(open(sys.argv[1])) == ['lp']" "$T/fix/live/tabs.json"
check "... and prints the capabilities to publish it with" grep -q '"db"' "$T/lp.out"
check "... where only the owner writes, on every collection the page has" "$PY" - "$T/lp.out" <<'EOF'
import json, sys
caps = json.loads([l for l in open(sys.argv[1]) if l.startswith("{")][-1])
rules = {r["path"]: (r["read"], r["write"]) for r in caps["db"]["rules"]}
want = {"state", "session", "events", "asks", "reviews", "replies", "answers", "approvals"}
assert set(rules) == want and set(rules.values()) == {("view", "owner")}, rules
EOF
check "a chain can't take the verify loop's tab id" sh -c "! (cd '$T/fix' && '$PY' live_page.py verify) >/dev/null 2>&1"
if [ "$CLONE" = 1 ]; then
    check "the repo ignores *.live.html, so a live page can never be committed" git -C "$REPO" check-ignore -q skills/laneloop/x.live.html
else
    skip "the LaneLoop repository ignores *.live.html (not a clone of it)"
fi
check "--url without the URL prints the usage, not a Python error" \
    sh -c "out=\$(cd '$T/fix' && '$PY' live_page.py --url 2>&1); [ \$? -ne 0 ] && ! echo \"\$out\" | grep -q Traceback"
(cd "$T/fix" && "$PY" live_page.py --url https://claude.ai/artifact/S1 >/dev/null)
(cd "$T/fix" && "$PY" live_sync.py lp > "$T/sync1.json" 2>&1)
check "first sync: the run's dashboard entry, the tab's state, both progress lines and the open question" "$PY" - "$T/sync1.json" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1]))
w = o["writes"]; cols = [x["collection"] for x in w]
assert o["url"] == "https://claude.ai/artifact/S1", o
assert cols.count("session") == 1 and cols.count("state") == 1 and cols.count("events") == 2 and cols.count("asks") == 1, cols
assert all(x["op"] == "set" and "if_version" not in x for x in w), w
assert all(x["data"]["tab"] == "lp" for x in w if x["collection"] != "session"), w   # every document names its tab
ids = {x["collection"]: x["doc_id"] for x in w}
assert ids["state"] == "lp" and ids["asks"] == "lp~Q1" and ids["events"].startswith("lp~e"), ids
sess = [x["data"] for x in w if x["collection"] == "session"][0]
assert sess["label"] == "laneloop:fix" and sess["repo"] == "o/r", sess
assert sess["labelUrl"] == "https://github.com/o/r/pulls?q=is%3Apr+label%3A%22laneloop%3Afix%22", sess["labelUrl"]
st = [x for x in w if x["collection"] == "state"][0]["data"]
assert st["badge"]["tone"] == "warn" and st["tasks"][0]["id"] == "T1" and "peers" not in st, st
EOF
(cd "$T/fix" && "$PY" live_sync.py lp > "$T/sync1b.json" 2>&1)
check "until --done, the same writes are offered again" cmp -s "$T/sync1.json" "$T/sync1b.json"
(cd "$T/fix" && "$PY" live_sync.py lp --done >/dev/null && "$PY" live_sync.py lp > "$T/sync2.json" 2>&1)
check "after --done, an unchanged chain needs no writes" "$PY" -c "import json,sys; o=json.load(open(sys.argv[1])); assert not o['writes'], o" "$T/sync2.json"
printf '# Fix branch `lq`\n\nTitle: A Chain Still In The Queue\nPlan signed off: 2026-11-07 by Selftest\n' > "$T/fix/briefs/lq.md"
(cd "$T/fix" && "$PY" live_page.py lq > "$T/lq.out" 2>&1 && "$PY" live_sync.py --all > "$T/syncq.json" 2>&1)
check "a tab added later needs no republish: the page is already up" grep -q "nothing to republish" "$T/lq.out"
check "a chain that hasn't started yet: its own tab, after the first, Queued, and no step done" "$PY" - "$T/syncq.json" <<'EOF'
import json, sys
w = json.load(open(sys.argv[1]))["writes"]
assert [x["doc_id"] for x in w if x["collection"] == "state"] == ["lq"], w   # lp is unchanged: nothing sent for it
st = [x["data"] for x in w if x["collection"] == "state"][0]
assert st["order"] == 1 and st["badge"]["text"] == "Queued" and all(s["state"] == "todo" for s in st["steps"]), st
EOF
(cd "$T/fix" && "$PY" live_sync.py --all --done >/dev/null)
(cd "$lw" && "$PY" "$T/fix/task.py" phase docs "Docs updated: the sync retry section" >/dev/null)
(cd "$T/fix" && "$PY" live_sync.py lp > "$T/sync3.json" 2>&1)
check "a new step: one new line and the tab's state replaced, nothing sent twice" "$PY" - "$T/sync3.json" <<'EOF'
import json, sys
w = json.load(open(sys.argv[1]))["writes"]
assert sorted((x["collection"], x["doc_id"]) for x in w) == [("events", "lp~e000003"), ("state", "lp")], w
EOF
(cd "$T/fix" && "$PY" live_sync.py lp --done >/dev/null)
att=$(cd "$T/fix" && "$PY" live_sync.py --attention 2>&1)
check "--attention prints the main window's line for the open question, with the page's link" \
    sh -c "echo \"\$1\" | grep -q 'Needs you · lp: Which Customer A Retry Bills → https://claude.ai/artifact/S1'" _ "$att"
(cd "$lw" && "$PY" "$T/fix/task.py" review "CodeRabbit #101: a deleted order crashes the retry, Retry.cs:40" "Skip the retry and log it" >/dev/null)
(cd "$T/fix" && "$PY" live_sync.py lp > "$T/sync4.json" 2>&1)
check "a review item waits for the main session's recommendation" "$PY" -c "import json,sys; w=json.load(open(sys.argv[1]))['writes']; assert not [x for x in w if x['collection']=='reviews'], w" "$T/sync4.json"
echo '{"1": "Apply"}' > "$T/fix/live/lp.recs.json"
(cd "$T/fix" && "$PY" live_sync.py lp > "$T/sync5.json" 2>&1)
check "... and goes up with it, keyed by its tab" "$PY" -c "import json,sys; r=[x for x in json.load(open(sys.argv[1]))['writes'] if x['collection']=='reviews']; assert len(r)==1 and r[0]['doc_id']=='lp~r1' and r[0]['data']['rec']=='Apply', r" "$T/sync5.json"
check "an unknown tab is refused, saying how to add it" sh -c "out=\$(cd '$T/fix' && '$PY' live_sync.py nosuch 2>&1); [ \$? -ne 0 ] && echo \"\$out\" | grep -q 'live_page.py nosuch'"
mkdir -p "$T/fix/retired/lr"   # what retire.sh keeps of a merged chain once its worktree is gone
echo '{"slug":"lr","status":"done","phase":"ci","pr":{"number":7,"url":"https://github.com/o/r/pull/7"},"summary":"merged","notes":["2026-11-07T15:00:00 [ci] CI passed"],"reviews":[]}' > "$T/fix/retired/lr/status.json"
(cd "$T/fix" && "$PY" live_page.py lr >/dev/null && "$PY" live_sync.py lr > "$T/syncr.json" 2>/dev/null)
check "after its worktree is retired, a chain's tab keeps its state: Done, merged, with its PR" "$PY" - "$T/syncr.json" <<'EOF'
import json, sys
st = [x["data"] for x in json.load(open(sys.argv[1]))["writes"] if x["collection"] == "state"][0]
assert st["badge"]["text"] == "Done" and st["merged"] is True and st["pr"]["number"] == 7, st
EOF
(cd "$T/fix" && "$PY" live_sync.py --all --done >/dev/null)
init fix "$T/fix" PR_LABEL=
(cd "$T/fix" && "$PY" live_sync.py --all > "$T/syncnl.json" 2>&1)
check "PR_LABEL= turns the label off: the runbook opens PRs without one, and the dashboard shows none" "$PY" - "$T/syncnl.json" "$T/fix/runbook.md" <<'EOF'
import json, sys
s = [x["data"] for x in json.load(open(sys.argv[1]))["writes"] if x["collection"] == "session"][0]
assert s["label"] == "" and s["labelUrl"] == "", s
assert "--label" not in open(sys.argv[2]).read()
EOF
(cd "$T/fix" && "$PY" live_sync.py --all --done >/dev/null)
init fix "$T/fix" PR_LABEL=laneloop:fix

echo "== wait_chain: wakes for a question as well as a chain end, and for progress to sync"
n0=$(wc -l < "$T/fix/logs/runner.log")
echo "[11-07 14:20:00] [lp] chain asks: lp Q2 · Another Question" >> "$T/fix/logs/runner.log"
( cd "$T/fix" && WAIT_POLL_SECS=1 LIVE_SYNC_SECS=0 ./wait_chain.sh "$n0" > "$T/wc1.out" 2>&1 ) & r=$!
wait_for 20 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "a 'chain asks' line returns at once" grep -q "chain asks: lp Q2" "$T/wc1.out"
n1=$(wc -l < "$T/fix/logs/runner.log")
( cd "$T/fix" && WAIT_POLL_SECS=1 LIVE_SYNC_SECS=3 ./wait_chain.sh "$n1" > "$T/wc2.out" 2>&1 ) & r=$!
sleep 2; echo "[11-07 14:21:00] [runner] chain started: lq" >> "$T/fix/logs/runner.log"; touch "$lw/.fixloop/status.json"
wait_for 30 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "no chain event, but a chain's state changed: it returns after LIVE_SYNC_SECS naming the chain" \
    sh -c "grep -q 'progress' '$T/wc2.out' && grep -q 'lp' '$T/wc2.out'"
check "... handing back the same from-line, so a stop logged meanwhile is still read next time" grep -qx "== next from-line: $n1" "$T/wc2.out"

echo "== sleep: watchers keep the computer awake, and say so when it slept anyway"
# A stand-in date whose wall clock jumps by the seconds in $T/skew: a computer that slept that long (Python's monotonic
# clock, the awake clock, doesn't move). A watcher's jump goes in $T/jump, and the stand-in sleep adds it to the skew as
# its sleep ends, as a real sleep would: a jump written between two of a watcher's naps would land in neither.
FAKECLOCK="$T/fakeclock"; mkdir -p "$FAKECLOCK"; REALDATE=$(command -v date); REALSLEEP=$(command -v sleep)
echo 0 > "$T/skew"; : > "$T/jump"
cat > "$FAKECLOCK/date" <<EOF
#!/bin/sh
if [ "\$1" = +%s ]; then echo \$(( \$("$REALDATE" +%s) + \$(cat "$T/skew") )); else exec "$REALDATE" "\$@"; fi
EOF
cat > "$FAKECLOCK/sleep" <<EOF
#!/bin/sh
"$REALSLEEP" "\$@"
if [ -s "$T/jump" ]; then echo \$(( \$(cat "$T/skew") + \$(cat "$T/jump") )) > "$T/skew"; : > "$T/jump"; fi
EOF
chmod +x "$FAKECLOCK/date" "$FAKECLOCK/sleep"
n2=$(wc -l < "$T/fix/logs/runner.log")
( cd "$T/fix" && PATH="$FAKECLOCK:$PATH" WAIT_POLL_SECS=1 LIVE_SYNC_SECS=0 WAIT_HOURS=8 ./wait_chain.sh "$n2" > "$T/wc3.out" 2>&1 ) & r=$!
echo 32400 > "$T/jump"   # nine hours go by during a nap: past WAIT_HOURS, had the limit counted the wall clock
wait_for 20 sh -c "! kill -0 $r"; kill $r 2>/dev/null; echo 0 > "$T/skew"; : > "$T/jump"
check "wait_chain: the computer slept, so it returns on waking, says for how long, and hands back the same from-line" \
    sh -c "grep -q 'the computer slept for 9h 00m' '$T/wc3.out' && grep -qx '== next from-line: $n2' '$T/wc3.out'"
check "... a sleep longer than WAIT_HOURS is no timeout: the limit counts awake time" sh -c "! grep -q TIMEOUT '$T/wc3.out'"
s=$(PATH="$FAKECLOCK:$PATH" bash -c "source '$T/fix/platform.sh'; awake_mark; echo 5400 > '$T/skew'; slept_since")
echo 0 > "$T/skew"
check "slept_since: the wall clock ran 1h 30m ahead of the awake clock, so the computer slept that long ($s s)" \
    sh -c "[ '$s' -ge 5390 ] && [ '$s' -le 5410 ]"
check "slept_since: a stretch the computer was awake through is 0" \
    test "$(PATH="$FAKECLOCK:$PATH" bash -c "source '$T/fix/platform.sh'; awake_mark; sleep 1; slept_since")" = 0
check "duration reads as a log line wants it" \
    test "$(bash -c "source '$T/fix/platform.sh'; duration 7500; echo; duration 840")" = "$(printf '2h 05m\n14m')"
check "every watcher keeps the computer awake while it waits" \
    sh -c "for f in fix/wait_chain.sh fix/wait_gate.sh fix/wait_ci.sh verify/wait_verify.sh; do grep -q 'keep_awake \\\$\\\$' \"$KIT/\$f\" || exit 1; done"
check "a session the computer slept through is no strike, in the fix chains and the verify loop" \
    sh -c "grep -q 'awake_mark' '$KIT/fix/fixloop.sh' && grep -q 'not a strike' '$KIT/fix/fixloop.sh' && grep -q 'awake_mark' '$KIT/verify/qa-loop.sh' && grep -q 'not a strike' '$KIT/verify/qa-loop.sh'"
check "a session's time cap counts awake time" grep -q "time.monotonic() > deadline" "$KIT/common/agent_run.py"
if [ "$(uname -s)" = Darwin ]; then
    cat > "$T/held.sh" <<EOF
#!/usr/bin/env bash
source "$T/fix/platform.sh"; keep_awake \$\$ selftest
n=0; for _ in 1 2 3 4 5 6 7 8 9 10; do
    c=\$(pgrep -f "caffeinate -is -w \$\$" | head -n 1)
    [ -n "\$c" ] && n=\$(pmset -g assertions 2>/dev/null | grep -c "pid \$c(caffeinate)"); [ "\$n" -ge 1 ] && break; sleep 0.5
done
echo "\$n \$\$" > "$T/held"
EOF
    bash "$T/held.sh"
    check "keep_awake: caffeinate holds a no-sleep assertion while the process runs" sh -c "[ \$(cut -d' ' -f1 '$T/held') -ge 1 ]"
    check "... and lets go once it ends" wait_for 10 sh -c "! pgrep -f 'caffeinate -is -w $(cut -d' ' -f2 "$T/held")'"
else
    skip "keep_awake's hold: macOS only here (systemd-inhibit on Linux, keep_awake.ps1 on Windows)"
fi

echo "== platform helpers"
p=$(free_port)
"$PY" "$STUBS/st_serve.py" "$p" >/dev/null 2>&1 &
wait_for 20 curl -s "http://127.0.0.1:$p/" -o /dev/null
pid=$(bash -c "source '$T/fix/platform.sh' && port_pid $p")
check "port_pid finds the process listening on :$p ($pid)" test -n "$pid"
bash -c "source '$T/fix/platform.sh' && kill_tree $pid"
check "kill_tree stops it" wait_for 10 sh -c "! curl -s http://127.0.0.1:$p/ -o /dev/null"
check "sha1 prints a SHA-1" sh -c "echo x | bash -c \"source '$T/fix/platform.sh' && sha1\" | grep -qE '^[0-9a-f]{40}'"
[ "$WIN" = 1 ] || check "cygpath stands in for Git Bash's on POSIX" \
    test "$(bash -c "source '$T/fix/platform.sh' && cygpath -m '$T/a b'")" = "$T/a b"
# Windows keep-awake waits on the process's Windows pid (/proc/<pid>/winpid); Git Bash's own pid would let go at once
mkdir -p "$T/ps"; printf '#!/usr/bin/env bash\necho "$*" >> "$SELFTEST_PS_LOG"\n' > "$T/ps/powershell.exe"; chmod +x "$T/ps/powershell.exe"
err=$(PATH="$T/ps:$PATH" SELFTEST_PS_LOG="$T/ps.log" bash -c "source '$T/fix/platform.sh'; PLATFORM=windows; keep_awake 2147483646" 2>&1 >/dev/null)
check "Windows keep-awake with no readable Windows pid says so on stderr ($(echo "$err" | head -1 | cut -c1-80))" \
    sh -c "echo \"\$1\" | grep -qi 'not kept awake'" _ "$err"
check "... and as a toast" wait_for 5 grep -q notify.ps1 "$T/ps.log"
check "... and launches no keep_awake.ps1 that would let go at once" sh -c "! grep -q keep_awake.ps1 '$T/ps.log'"

echo "== test-output parsers: every preset reads its runner's summary, failures and names"
check "dotnet, pytest, jest, vitest, go, cargo, rspec, maven and phpunit output, passing, failing and empty" "$PY" - "$T/fix" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1]); import project as P
cases = [
 ("dotnet", "  Failed Billing.Tests.RetryTests.Retry_BillsTheCurrentCustomer [147 ms]\nFailed! - Failed:     1, Passed:   120, Skipped:     0, Total:   121\nPassed! - Failed:     0, Passed:    40, Skipped:     0, Total:    40", 1, 160, ["Billing.Tests.RetryTests.Retry_BillsTheCurrentCustomer"]),
 ("pytest", "FAILED tests/test_retry.py::test_bills - AssertionError\nERROR tests/test_db.py::test_conn - ConnectionError\n===== 1 failed, 12 passed, 1 error, 2 warnings in 3.21s =====", 2, 12, ["tests/test_db.py::test_conn", "tests/test_retry.py::test_bills"]),
 ("pytest", "3 passed in 0.12s", 0, 3, []),
 ("pytest", "========== no tests ran in 0.01s ==========", 0, 0, []),
 ("jest", "  ● Retry › bills the current customer\n  ● Console\nTests:       1 failed, 30 passed, 31 total", 1, 30, ["Retry › bills the current customer"]),
 ("vitest", " FAIL  src/retry.test.ts > Retry > bills\n      Tests  1 failed | 22 passed (23)", 1, 22, ["src/retry.test.ts > Retry > bills"]),
 ("go", "--- FAIL: TestRetry (0.00s)\n--- PASS: TestSign (0.00s)\n    --- PASS: TestSign/vector (0.00s)\nFAIL", 1, 2, ["TestRetry"]),
 ("cargo", "test retry::bills ... FAILED\ntest result: FAILED. 9 passed; 1 failed; 0 ignored\ntest result: ok. 4 passed; 0 failed; 0 ignored", 1, 13, ["retry::bills"]),
 ("rspec", "rspec ./spec/retry_spec.rb:12 # Retry bills\n25 examples, 1 failure, 2 pending", 1, 22, ["./spec/retry_spec.rb:12"]),
 ("maven", "[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.05 s - in com.x.SignTest\n[ERROR] com.x.RetryTest.bills  Time elapsed: 0.01 s  <<< FAILURE!\n[ERROR] Tests run: 5, Failures: 1, Errors: 0, Skipped: 0", 1, 4, ["com.x.RetryTest.bills"]),
 ("phpunit", "OK (12 tests, 30 assertions)", 0, 12, []),
 ("phpunit", "1) Tests\\RetryTest::testBills\nFAILURES!\nTests: 12, Assertions: 30, Failures: 1.", 1, 11, ["Tests\\RetryTest::testBills"]),
]
for kind, text, f, p, names in cases:
    r = P.parse_tests(text, kind)
    assert (r["failed"], r["passed"], r["failed_tests"]) == (f, p, names), (kind, r)
assert P.parse_tests("no summary here", "jest")["failed"] is None
EOF

echo "== presets: every stack, alone and with a database, makes a profile whose only gaps are marked"
pr="$T/presets-repo"; mkdir -p "$pr" && git -C "$pr" init -q
check "init_project.py --list names every stack and service" sh -c "'$PY' '$KIT/init_project.py' --list | grep -q java-maven && '$PY' '$KIT/init_project.py' --list | grep -q mongodb"
check "each composes; a stack with a database gives its test step and the verify loop that database" "$PY" - "$KIT" "$pr" "$T/fix" <<'EOF'
import json, os, subprocess, sys
kit, repo, run = sys.argv[1:]
sys.path.insert(0, run); import project as P
stacks = sorted(f[:-5] for f in os.listdir(os.path.join(kit, "presets", "stacks")))
dbs = sorted(f[:-5] for f in os.listdir(os.path.join(kit, "presets", "services")))
assert len(stacks) >= 10 and {"postgres", "mysql", "mongodb", "redis", "sqlite"} <= set(dbs), (stacks, dbs)
for stack in stacks:
    for db, via in [(None, "docker")] + [(d, v) for d in dbs for v in ("docker", "native")]:
        args = [sys.executable, os.path.join(kit, "init_project.py"), "--stack", stack, "--via", via, "--force"] + (["--db", db] if db else [])
        r = subprocess.run(args, cwd=repo, capture_output=True, text=True)
        assert r.returncode == 0, (stack, db, via, r.stderr)
        p = json.load(open(os.path.join(repo, ".laneloop", "project.json")))
        probs = [x for x in P.problems(p) if "FILL IN" not in x]
        assert not probs, (stack, db, via, probs)
        if db:
            assert any(db in s.get("services", []) for s in p["gate"]["steps"]), (stack, db)
            assert db in P.verify_services(p) and "{project}" not in json.dumps(p), (stack, db)
            assert db == "sqlite" or P.service_spec(p, db, "verify").get("port") != P.service_spec(p, db).get("port"), (stack, db)
r = subprocess.run([sys.executable, os.path.join(kit, "init_project.py"), "--stack", "node"], cwd=repo, capture_output=True, text=True)
assert r.returncode != 0 and "--force" in r.stderr, r.stderr  # never written over by accident
EOF

echo "== gate: the profile's steps, a fresh service per slot, test parsers, GATE_SKIP"
wt="$T/wt"; mkdir -p "$wt/.fixloop"
gate_run() {  # waits for a verdict; prints --status
    (cd "$wt" && "$PY" "$T/fix/gate.py" --start >/dev/null 2>&1)
    wait_for 180 sh -c "cd '$wt' && '$PY' '$T/fix/gate.py' --status | grep -qE '^gate (PASS|FAIL)'"
    (cd "$wt" && "$PY" "$T/fix/gate.py" --status)
}
init fix "$T/fix" GATE_SKIP= KNOWN_FLAKES= KNOWN_PLATFORM_FAILURES=
: > "$SELFTEST_LOG"; out=$(gate_run)
if ! echo "$out" | grep -q '^gate PASS'; then
    echo "  gate diagnostic: $out"
    for f in "$wt"/.fixloop/logs/gate-*.log "$wt"/.fixloop/logs/gate-runner.err "$wt"/.fixloop/logs/service-*.log; do
        [ -f "$f" ] && { echo "  --- $f"; cat "$f"; }
    done
fi
check "gate passes ($(echo "$out" | head -1))" sh -c "echo \"\$1\" | grep -q '^gate PASS'" _ "$out"
check "every step ran with the profile's env" sh -c "[ \$(grep -c '^st-run' '$SELFTEST_LOG') = 3 ] && ! grep '^st-run' '$SELFTEST_LOG' | grep -qv 'LC_ALL=en_US.UTF-8'"
check "the step that names a service reached its own instance, set up by its init" grep -q "^svc=pong" "$SELFTEST_LOG"
check "only that step got the service's env" sh -c "[ \$(grep -c 'SVC=http://127.0.0.1:$SVC_PORT' '$SELFTEST_LOG') = 1 ]"
check "the service is stopped afterwards" wait_for 15 sh -c "! curl -s http://127.0.0.1:$SVC_PORT/ -o /dev/null"
check "and its folder removed" sh -c "! ls -d '$wt'/.fixloop/state/svc-web-* 2>/dev/null | grep -q ."
check "the verdict names each step's summary and the services it used" sh -c "echo \"\$1\" | grep -q 'unit: Tests: *3 passed' && echo \"\$1\" | grep -q 'services: SVC_URL'" _ "$out"
: > "$SELFTEST_LOG"; out=$(SELFTEST_UNIT_FAIL="Retry › bills the current customer" gate_run)
check "a failing test fails the gate and is named" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'FAILED Retry › bills the current customer'" _ "$out"
check "... and the suites after it still run" grep -q "st-run test integration" "$SELFTEST_LOG"
init fix "$T/fix" KNOWN_FLAKES="bills the current customer"
out=$(SELFTEST_UNIT_FAIL="Retry › bills the current customer" gate_run)
check "a known flake is reported, not counted" sh -c "echo \"\$1\" | grep -q '^gate PASS' && echo \"\$1\" | grep -q 'known flaky (confirm alone): Retry'" _ "$out"
init fix "$T/fix" KNOWN_FLAKES= KNOWN_PLATFORM_FAILURES="bills the current customer"
out=$(SELFTEST_UNIT_FAIL="Retry › bills the current customer" gate_run)
check "a platform failure is reported apart from flakes, not re-run alone" sh -c "echo \"\$1\" | grep -q '^gate PASS' && echo \"\$1\" | grep -q 'fails on this platform every time'" _ "$out"
init fix "$T/fix" KNOWN_PLATFORM_FAILURES=
out=$(SELFTEST_ZERO=1 gate_run)
check "a suite that ran zero tests fails the gate" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'NO TESTS RAN'" _ "$out"
: > "$SELFTEST_LOG"; out=$(SELFTEST_BUILD_FAIL=1 gate_run)
check "a failed build stops the gate, with the step's hint" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'the toolchain is incomplete' && ! grep -q 'st-run test' '$SELFTEST_LOG'" _ "$out"
init fix "$T/fix" GATE_SKIP=integration
: > "$SELFTEST_LOG"; out=$(gate_run)
check "GATE_SKIP: the gate passes and names the step it left out, with what checks it instead" \
    sh -c "echo \"\$1\" | grep -q '^gate PASS.*integration' && echo \"\$1\" | grep -q \"SKIPPED (GATE_SKIP): CI's integration job runs it\"" _ "$out"
check "GATE_SKIP: the step never ran" sh -c "! grep -q 'st-run test integration' '$SELFTEST_LOG'"
write_profile "$T/dead.json" "p['services']['web'].update(start='exec sleep 611', up=None, init=None, timeout=4)"
init fix "$T/fix" GATE_SKIP= PROJECT="$T/dead.json"
out=$(gate_run)
check "a service that never comes up fails the gate, with why" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'web did not come up within 4s'" _ "$out"
check "... and is stopped" wait_for 10 sh -c "! pgrep -f 'sleep 611' >/dev/null"
"$PY" "$STUBS/st_serve.py" "$SVC_PORT" >/dev/null 2>&1 & squat=$!
wait_for 20 curl -s "http://127.0.0.1:$SVC_PORT/" -o /dev/null
init fix "$T/fix" PROJECT="$T/project.json"
out=$(gate_run); kill $squat 2>/dev/null
check "a service port someone else holds is never shared: the gate says which" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'port $SVC_PORT is already taken'" _ "$out"
write_profile "$T/nogate.json" "p['gate']['steps'] = []"
init fix "$T/fix" PROJECT="$T/nogate.json"
out=$(gate_run)
check "a profile with no gate steps fails the gate and says so" sh -c "echo \"\$1\" | grep -q '^gate FAIL' && echo \"\$1\" | grep -q 'no gate.steps'" _ "$out"
init fix "$T/fix" PROJECT="$T/project.json"
if [ "$(uname -s)" = Darwin ]; then
    # A gate is often started straight from a session or merge_base.sh, not through launch.sh: it keeps the Mac awake
    # itself, or an idle sleep stalls it mid-suite. A slow build keeps it running long enough to look.
    rm -f "$wt/.fixloop/gate.json"
    (cd "$wt" && SELFTEST_SLOW_SECS=8 "$PY" "$T/fix/gate.py" --start >/dev/null 2>&1)
    gpid=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$wt/.fixloop/gate.json" 2>/dev/null)
    check "a started gate is kept awake: caffeinate holds a no-sleep assertion for it (pid ${gpid:-none})" \
        wait_for 10 sh -c "[ -n '$gpid' ] && [ \"\$(awake_for '$gpid')\" -ge 1 ]"
    wait_for 120 sh -c "cd '$wt' && '$PY' '$T/fix/gate.py' --status | grep -qE '^gate (PASS|FAIL)'"
    check "... and lets go when the gate ends" wait_for 10 sh -c "[ -n '$gpid' ] && [ \"\$(awake_for '$gpid')\" = 0 ]"
else
    skip "the gate's keep-awake hold: macOS only here (systemd-inhibit on Linux, SetThreadExecutionState on Windows)"
fi

echo "== gate slots: one set for the machine, shared by every run and every project on it"
check "by default the slots are one folder for the machine, outside every run (~/.laneloop/gate-slots)" "$PY" -B -c \
    "import sys; sys.path.insert(0, sys.argv[1]); import init_run as i; assert i.DEFAULTS['GATE_SLOTS'].endswith('/.laneloop/gate-slots'), i.DEFAULTS.get('GATE_SLOTS')" "$KIT"
# Four runs, each its own project profile, one worktree each (x). p1 and p2: an integration suite with one slot on the
# stand-in service, p1's slow enough for the others to start meanwhile; p3: the same step given two slots; p4: another
# project's e2e step on the same service port. The service's commands use its folder as their working directory, not
# {dir}: these checks are about the slots, on every platform.
web="w = p['services']['web']; w['start'] = w['start'].replace(' {dir}', ''); w['init'] = 'echo pong > ping.txt'"
write_profile "$T/px.json" "$web; p['gate']['steps'] = [dict(p['gate']['steps'][2], run='sleep 35; st-run test integration')]"
write_profile "$T/pz.json" "$web; p['gate']['steps'] = [p['gate']['steps'][2]]"
write_profile "$T/px2.json" "$web; p['gate']['steps'] = [dict(p['gate']['steps'][2], run='sleep 2; st-run test integration', slots=2)]"
write_profile "$T/pe.json" "$web; p['gate']['steps'] = [{'name': 'e2e', 'run': 'st-run test e2e', 'tests': 'jest', 'services': ['web']}]"
for r in p1:px p2:pz p3:px2 p4:pe; do
    init fix "$T/${r%%:*}" PROJECT="$T/${r#*:}.json"; mkdir -p "$T/${r%%:*}-wt/x/.fixloop"
done
gs() { (cd "$T/$1-wt/x" && "$PY" "$T/$1/gate.py" --status 2>&1); }
gstart() { (cd "$T/$1-wt/x" && GATE_POLL_SECS=1 "$PY" "$T/$1/gate.py" --start >/dev/null 2>&1); }
gdone() { wait_for "${2:-120}" sh -c "cd '$T/$1-wt/x' && '$PY' '$T/$1/gate.py' --status | grep -qE '^gate (PASS|FAIL)'"; }
: > "$SELFTEST_LOG"
gstart p1
wait_for 60 curl -sf "http://127.0.0.1:$SVC_PORT/ping.txt" -o /dev/null   # p1's suite is running on its service
gstart p4; gstart p2; gstart p3
z=""
for _ in $(seq 1 20); do z=$(gs p2 | head -1); case "$z" in *"waiting for "*) break ;; esac; sleep 1; done
check "a gate of another run waits for the step's one slot, and --status says for what and behind whom ($z)" \
    sh -c "echo \"\$1\" | grep -qE '^running since .*waiting for an integration slot, behind p1/x \(since [0-9]{2}:[0-9]{2}\)'" _ "$z"
check "... gate.json records the wait: the step, who holds its slots, since when" "$PY" - "$T/p2-wt/x/.fixloop/gate.json" <<'EOF'
import json, re, sys
w = json.load(open(sys.argv[1], encoding="utf8")).get("waiting") or {}
assert w.get("step") == "integration" and w.get("behind") == ["p1/x"], w
assert re.match(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$", w.get("since", "")), w
EOF
lg="$wtr/lg"; mkdir -p "$lg/.fixloop"
echo '{"slug": "lg", "status": "in_progress", "phase": "gate", "pr": null, "summary": "", "reviews": [], "notes": []}' > "$lg/.fixloop/status.json"
cp "$T/p2-wt/x/.fixloop/gate.json" "$lg/.fixloop/gate.json"
(cd "$T/fix" && "$PY" live_page.py lg >/dev/null 2>&1; "$PY" live_sync.py lg > "$T/syncg.json" 2>&1)
check "... and the chain's tab says its full test run is waiting, and behind whom" "$PY" - "$T/syncg.json" <<'EOF'
import json, sys
st = [x["data"] for x in json.load(open(sys.argv[1], encoding="utf8"))["writes"] if x["collection"] == "state"][0]
assert "waiting for an integration slot, behind p1/x" in st["quiet"], st["quiet"]
EOF
(cd "$T/fix" && "$PY" live_sync.py lg --done >/dev/null 2>&1)
gdone p3 60; w=$(gs p3 | head -1); x=$(gs p1 | head -1)
check "a profile that gives the step two slots runs beside it meanwhile, in the slot above ($w; p1: $x)" \
    sh -c "echo \"\$1\" | grep -q '^gate PASS' && echo \"\$2\" | grep -q '^running since'" _ "$w" "$x"
gdone p4 60; y=$(gs p4)
check "another project's step on the same service port runs beside it, on a port of its own ($(echo "$y" | head -1))" \
    sh -c "echo \"\$1\" | grep -q '^gate PASS' && grep 'st-run test e2e' '$SELFTEST_LOG' | grep -q 'SVC=http://127.0.0.1:[0-9]' && ! grep 'st-run test e2e' '$SELFTEST_LOG' | grep -q 'SVC=http://127.0.0.1:$SVC_PORT\$'" _ "$y"
gdone p1 90; gdone p2 90
check "once the slot is free the waiting gate runs, and every gate of the four runs passes" \
    sh -c "for r in p1 p2 p3 p4; do cd '$T'/\$r-wt/x && '$PY' '$T'/\$r/gate.py --status | grep -q '^gate PASS' || exit 1; done"
check "... with no wait left in its gate.json" "$PY" -c "import json,sys; assert 'waiting' not in json.load(open(sys.argv[1]))" "$T/p2-wt/x/.fixloop/gate.json"
check "the slots are in the one folder, not in any run's" sh -c "[ -d '$T/slots' ] && ! ls -d '$T'/p[1-4]/locks 2>/dev/null | grep -q ."
# a gate that dies holding a slot: the next gate, from another run, takes it
write_profile "$T/pk.json" "p['gate']['steps'] = [dict(p['gate']['steps'][1], run='sleep 20; st-run test unit', slots=1)]"
write_profile "$T/pk2.json" "p['gate']['steps'] = [dict(p['gate']['steps'][1], slots=1)]"
for r in p5:pk p6:pk2; do
    init fix "$T/${r%%:*}" PROJECT="$T/${r#*:}.json"; mkdir -p "$T/${r%%:*}-wt/x/.fixloop"
done
gstart p5
wait_for 20 sh -c "cd '$T/p5-wt/x' && '$PY' '$T/p5/gate.py' --status | grep -q 'step unit'"; sleep 2
gpid=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "$T/p5-wt/x/.fixloop/gate.json")
bash -c "source '$T/fix/platform.sh' && kill_tree $gpid"
gstart p6; gdone p6 60
check "a slot whose gate died is freed for the next gate, whichever run it is in ($(gs p6 | head -1))" \
    sh -c "cd '$T/p6-wt/x' && '$PY' '$T/p6/gate.py' --status | grep -q '^gate PASS'"
# on Windows the dead gate's step outlives it with its log open: wait for it, so the temp folder can be removed
wait_for 40 rm -f "$T/p5-wt/x/.fixloop/logs/gate-unit.log"

echo "== verify ledger: Requires: lines"
printf '# T1 · Takes A Card Payment\nRequires: payments\n' > "$T/ver/tests/T1.md"
printf '# T2 · Plain\n' > "$T/ver/tests/T2.md"
(cd "$T/ver" && "$PY" init_ledger.py "Selftest" >/dev/null && "$PY" ledger.py requires-check "" >/dev/null)
st() { "$PY" -c "import json,sys; d=json.load(open('$T/ver/ledger.json')); print([t for t in d['tests'] if t['id']==sys.argv[1]][0][sys.argv[2]])" "$1" "$2"; }
check "a test whose requirement is missing is blocked up front" test "$(st T1 status)" = blocked
check "with the ask to make it available, from the profile's caps" sh -c "echo \"\$1\" | grep -q 'payment provider' " _ "$(st T1 ask)"
check "a test with no requirement stays todo" test "$(st T2 status)" = todo
(cd "$T/ver" && "$PY" init_ledger.py "Selftest" --force >/dev/null && "$PY" ledger.py requires-check "payments" >/dev/null)
check "a met requirement leaves the test todo" test "$(st T1 status)" = todo
(cd "$T/ver" && "$PY" ledger.py needs T2 "Turn on the sandbox test card for the test account" >/dev/null)
# the same orchestrator session's verify run joins the fix run's page: its tab is added, nothing is published again
(cd "$T/ver" && "$PY" live_page.py verify >/dev/null 2>&1 && "$PY" live_page.py --url https://claude.ai/artifact/S1 >/dev/null \
    && "$PY" live_sync.py verify > "$T/vsync.json" 2>&1)
check "verify: its tab on the session's page gets the ledger's counts and the blocked test's ask" "$PY" - "$T/vsync.json" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1])); w = o["writes"]
assert o["url"] == "https://claude.ai/artifact/S1", o
st = [x for x in w if x["collection"] == "state"][0]
asks = [x for x in w if x["collection"] == "asks"]
sess = [x["data"] for x in w if x["collection"] == "session"][0]
assert st["doc_id"] == "verify" and st["data"]["order"] == -1, st          # the verify tab comes first
assert st["data"]["counts"]["blocked"] == 1 and st["data"]["counts"]["todo"] >= 2, st
assert [a["data"]["kind"] for a in asks] == ["needs"] and asks[0]["doc_id"].startswith("verify~T2@"), asks
assert "sandbox" in asks[0]["data"]["question"], asks
assert sess["run"] == "ver" and sess["kind"] == "verify" and sess["label"] == "", sess   # a verify run opens no PRs
EOF
check "a verify run folder has the one tab" sh -c "! (cd '$T/ver' && '$PY' live_page.py lp) >/dev/null 2>&1"
cat > "$T/ver/ledger.json" <<'EOF'
{"tests": [{"id": "T1", "title": "Bill A Card", "status": "awaiting_human", "started": "2026-11-07T15:00:00", "ask": "Sign in to the accounting sandbox"}], "sessions": []}
EOF
(cd "$T/ver" && "$PY" live_sync.py verify >/dev/null 2>&1 && "$PY" live_sync.py verify --done >/dev/null)
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); d['tests'][0].update(status='pass', finished='2026-11-07T15:09:00'); json.dump(d, open(sys.argv[1], 'w'))" "$T/ver/ledger.json"
(cd "$T/ver" && "$PY" live_sync.py verify > "$T/vsync2.json" 2>&1)
check "verify: once the sign-in is done, its card leaves the page" "$PY" - "$T/vsync2.json" <<'EOF'
import json, sys
st = [x["data"] for x in json.load(open(sys.argv[1]))["writes"] if x["collection"] == "state"][0]
assert [k for k in st["answered"] if "@signin@" in k], st
EOF
mkdir -p "$T/ver/logs"; echo "[11-07 15:10:00] T2 started" >> "$T/ver/logs/loop.log"; v0=$(wc -l < "$T/ver/logs/loop.log")
( cd "$T/ver" && WAIT_POLL_SECS=1 LIVE_SYNC_SECS=3 ./wait_verify.sh "$v0" > "$T/wv.out" 2>&1 ) & r=$!
sleep 2; echo "[11-07 15:11:00] T2 step 2" >> "$T/ver/logs/loop.log"; touch "$T/ver/ledger.json"
wait_for 30 sh -c "! kill -0 $r"; kill $r 2>/dev/null
check "wait_verify: a progress return hands back the same from-line, so a stop logged meanwhile is still read" \
    sh -c "grep -q 'progress' '$T/wv.out' && grep -qx '== next from-line: $v0' '$T/wv.out'"
v1=$(wc -l < "$T/ver/logs/loop.log")
( cd "$T/ver" && PATH="$FAKECLOCK:$PATH" WAIT_POLL_SECS=1 LIVE_SYNC_SECS=0 ./wait_verify.sh "$v1" > "$T/wv2.out" 2>&1 ) & r=$!
echo 2970 > "$T/jump"   # under 50m: a nap's own second or two on a slow machine still reads as 50m (duration rounds up)
wait_for 20 sh -c "! kill -0 $r"; kill $r 2>/dev/null; echo 0 > "$T/skew"; : > "$T/jump"
check "wait_verify: the computer slept, so it returns on waking with the same from-line" \
    sh -c "grep -q 'the computer slept for 50m' '$T/wv2.out' && grep -qx '== next from-line: $v1' '$T/wv2.out'"

echo "== the verify loop's services: kept, seeded once, reused"
sv() { (cd "$T/ver" && "$PY" services.py "$@" --state state) 2>"$T/sv.err"; }
out=$(sv up --for verify)
if ! echo "$out" | grep -q "export SVC_URL=http://127.0.0.1:$VSVC_PORT"; then
    echo "  verify service diagnostic: $out"
    [ ! -f "$T/sv.err" ] || { echo "  --- services.py stderr"; cat "$T/sv.err"; }
    [ ! -f "$T/ver/logs/service-web.log" ] || { echo "  --- service-web.log"; cat "$T/ver/logs/service-web.log"; }
fi
check "up starts the verify instance on its own port and prints its env" sh -c "echo \"\$1\" | grep -q \"export SVC_URL=http://127.0.0.1:$VSVC_PORT\"" _ "$out"
check "... seeds its new persist folder once" sh -c "[ \$(grep -c seeded '$T/seed.log') = 1 ] && [ -f '$T/persist-web/.laneloop-ready' ]"
check "env gives the same export lines to the build and the app" sh -c "(cd '$T/ver' && '$PY' services.py env --state state) | grep -q 'SVC_URL=http://127.0.0.1:$VSVC_PORT'"
cp "$T/ver/state/services.json" "$T/services.first.json"
out=$(sv up --for verify)
check "a second up reuses the instance already answering, and doesn't seed again" \
    sh -c "grep -q 'reusing' '$T/sv.err' && [ \$(grep -c seeded '$T/seed.log') = 1 ]"
cp "$T/services.first.json" "$T/ver/state/services.json"
sv down
check "down stops what up started" wait_for 15 sh -c "! curl -s http://127.0.0.1:$VSVC_PORT/ -o /dev/null"
check "... and keeps the persist folder" test -f "$T/persist-web/.laneloop-ready"
out=$(sv up --for verify); sv down
check "a later run starts it on the kept data without seeding it again" sh -c "[ \$(grep -c seeded '$T/seed.log') = 1 ]"
exp=$(cd "$T/ver" && "$PY" project.py exports verify)
check "the app's env comes from the profile, with {app_port} filled in" sh -c "echo \"\$1\" | grep -q 'export LC_ALL=en_US.UTF-8'" _ "$exp"

echo "== native database presets, for real where the servers are installed"
for svc in postgres mongodb; do
    case $svc in postgres) need="initdb pg_isready psql"; probe='psql "$DATABASE_URL" -tAc "select current_database()"'; want=app ;;
                 mongodb) need="mongod mongosh"; probe='mongosh --quiet "$MONGO_URL" --eval "db.hello().isWritablePrimary"'; want=true ;; esac
    have=1; for t in $need; do command -v "$t" >/dev/null || have=0; done
    if [ "$WIN" = 1 ] || [ "$have" = 0 ]; then skip "native $svc preset: $need not installed (or Windows)"; continue; fi
    got=$("$PY" - "$T/fix" "$KIT/presets/services/$svc.json" "$(free_port)" "$T/native-$svc" "$probe" 2>&1 <<'EOF'
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1]); import services as S
spec = dict(json.load(open(sys.argv[2]))["native"], port=int(sys.argv[3]) - 1)
os.makedirs(sys.argv[4], exist_ok=True)
with S.Service("db", spec, slot=1, state=sys.argv[4], logs=sys.argv[4]) as env:
    print(subprocess.run(["bash", "-c", sys.argv[5]], env=dict(os.environ, **env), capture_output=True, text=True, timeout=60).stdout.strip())
print("free" if not S.listening(int(sys.argv[3])) else "still listening")
print("left: " + " ".join(d for d in os.listdir(sys.argv[4]) if d.startswith("svc-")))
EOF
)
    check "native $svc: comes up on its slot's port and answers ($(echo "$got" | head -1))" sh -c "echo \"\$1\" | head -1 | grep -qx '$want'" _ "$got"
    check "native $svc: stopped, its port free and its data removed" sh -c "echo \"\$1\" | grep -qx free && echo \"\$1\" | grep -qx 'left: '" _ "$got"
done

echo "== the run's Chrome: found by its profile, stopped without touching any other Chrome"
if [ "$WIN" = 0 ] && [ -e "$chrome" ]; then
    cp=$(free_port)
    "$chrome" --headless=new --remote-debugging-port="$cp" --user-data-dir="$T/chrome-profile" --no-first-run about:blank >/dev/null 2>&1 &
    wait_for 30 curl -s "http://127.0.0.1:$cp/json/version" -o /dev/null
    cpid=$(bash -c "source '$T/ver/platform.sh' && chrome_main_pid '$T/chrome-profile'")
    check "chrome_main_pid finds it ($cpid)" test -n "$cpid"
    bash -c "source '$T/ver/platform.sh' && chrome_stop '$T/chrome-profile'"
    check "chrome_stop stops it" wait_for 15 sh -c "! curl -s http://127.0.0.1:$cp/json/version -o /dev/null"
else
    skip "Chrome helpers: no Chrome (or Windows, where raise_chrome.ps1 does this)"
fi

echo "== launch.sh: detached, kept awake, refused on battery"
if [ "$WIN" = 0 ] && { command -v tmux >/dev/null || command -v screen >/dev/null; }; then
    # caffeinate runs the script in its own place and leaves a helper that takes the no-sleep assertion on its behalf a
    # moment later: the script waits up to 5 s for it
    cat > "$T/hello.sh" <<EOF
#!/usr/bin/env bash
n=0; for _ in 1 2 3 4 5 6 7 8 9 10; do
    n=\$(pmset -g assertions 2>/dev/null | grep -c "on behalf of .bash. (pid \$\$)"); [ "\$n" -ge 1 ] && break; sleep 0.5
done
{ echo ran; echo "\$n"; } > "$T/launched"
EOF
    mkdir -p "$T/battery"; printf '#!/bin/sh\necho "Now drawing from '"'"'Battery Power'"'"'"\n' > "$T/battery/pmset"; chmod +x "$T/battery/pmset"
    if [ "$(uname -s)" = Darwin ]; then
        PATH="$T/battery:$PATH" bash "$T/fix/launch.sh" "$TMUX_NAME" "$T/hello.sh" >/dev/null 2>&1; rc=$?
        check "on battery the launch is refused (exit $rc)" test "$rc" = 3
    fi
    bash "$T/fix/launch.sh" "$TMUX_NAME" "$T/hello.sh" > "$T/launch.out" 2>&1
    check "the script ran detached ($(head -c 80 "$T/launch.out"))" wait_for 10 test -s "$T/launched"
    [ "$(uname -s)" = Darwin ] && check "kept awake: caffeinate holds a no-sleep assertion for it" \
        sh -c "[ \"\$(sed -n 2p '$T/launched')\" -ge 1 ]"
    if [ "$(uname -s)" = Linux ]; then
        # systemd-inhibit present but refused the hold (a container, an SSH login, a CI runner): the loop starts anyway
        mkdir -p "$T/noinhibit"; printf '#!/bin/sh\necho "Failed to inhibit: Access denied" >&2\nexit 1\n' > "$T/noinhibit/systemd-inhibit"
        chmod +x "$T/noinhibit/systemd-inhibit"; rm -f "$T/launched"
        tmux kill-session -t "=$TMUX_NAME" 2>/dev/null; screen -S "$TMUX_NAME" -X quit 2>/dev/null
        PATH="$T/noinhibit:$PATH" bash "$T/fix/launch.sh" "$TMUX_NAME" "$T/hello.sh" > "$T/launch2.out" 2>&1
        check "a systemd-inhibit that refuses the hold doesn't stop the loop from starting" wait_for 10 test -s "$T/launched"
    fi
else
    skip "launch.sh: no tmux or screen (or Windows, where it opens mintty)"
fi

echo "== retire: removes a merged PR's worktree, keeps every one that still holds work"
R="$T/rt"; mkdir -p "$R/bin" "$R/prs"
cat > "$R/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr list ... --head <branch> --jq ...: prints what the --jq filter would, from $SELFTEST_PRS/<branch, / as _>
while [ $# -gt 0 ]; do [ "$1" = --head ] && { cat "$SELFTEST_PRS/${2//\//_}" 2>/dev/null; exit 0; }; shift; done
EOF
chmod +x "$R/bin/gh"
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.com GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.com
git init -q --bare "$R/origin.git" && git clone -q "$R/origin.git" "$R/repo" 2>/dev/null
git -C "$R/repo" symbolic-ref HEAD refs/heads/develop
git -C "$R/repo" commit -q --allow-empty -m base && git -C "$R/repo" push -q origin develop 2>/dev/null
echo ".fixloop/" >> "$R/repo/.git/info/exclude"
branch_wt() {   # <run> <slug>: a pushed branch in its own worktree, with the .fixloop state a chain leaves
    git -C "$R/repo" worktree add -q -b "ai-work/$2" "$R/$1-wt/$2" origin/develop 2>/dev/null
    git -C "$R/$1-wt/$2" commit -q --allow-empty -m "$2" && git -C "$R/$1-wt/$2" push -q origin "ai-work/$2" 2>/dev/null
    mkdir -p "$R/$1-wt/$2/.fixloop/logs" && echo '{}' > "$R/$1-wt/$2/.fixloop/status.json"
}
pr() { echo "$3 #1 $(git -C "$R/$1-wt/$2" rev-parse HEAD)" > "$R/prs/ai-work_$2"; }   # <run> <slug> <state>
init fix "$R/r1" REPO="$R/repo" WT_ROOT="$R/r1-wt" && init fix "$R/r2" REPO="$R/repo" WT_ROOT="$R/r2-wt"
branch_wt r1 merged && pr r1 merged MERGED
mkdir -p "$R/r1-wt/merged/.fixloop/state" && echo "1|x|0.42|y" > "$R/r1-wt/merged/.fixloop/state/sessions.txt"
echo "Title: Merged" > "$R/r1-wt/merged/.fixloop/brief.md"
branch_wt r1 closed && pr r1 closed CLOSED
branch_wt r1 open && pr r1 open OPEN
branch_wt r1 dirty && pr r1 dirty MERGED && echo scratch > "$R/r1-wt/dirty/notes.md"
branch_wt r1 ahead && pr r1 ahead MERGED && git -C "$R/r1-wt/ahead" commit -q --allow-empty -m "after the merge"
git -C "$R/repo" worktree add -q --detach "$R/r1-wt/base" origin/develop 2>/dev/null
branch_wt r2 late && pr r2 late MERGED
retire() { PATH="$R/bin:$PATH" SELFTEST_PRS="$R/prs" bash "$R/r1/retire.sh" "$@" >> "$R/retire.out" 2>&1; }
retire
check "retire: listing alone removes nothing" test -d "$R/r1-wt/merged"
retire --apply
check "retire: a merged PR's worktree is removed" test ! -e "$R/r1-wt/merged"
check "retire: ... its local branch deleted" sh -c "! git -C '$R/repo' rev-parse -q --verify refs/heads/ai-work/merged"
check "retire: ... and its state kept in retired/" test -f "$R/r1/retired/merged/status.json"
check "retire: ... with its brief and sessions, so its tab keeps its title and cost" \
    sh -c "[ -f '$R/r1/retired/merged/brief.md' ] && [ -f '$R/r1/retired/merged/state/sessions.txt' ]"
check "retire: a closed PR's worktree is removed" test ! -e "$R/r1-wt/closed"
check "retire: an open PR's worktree is kept" test -d "$R/r1-wt/open"
check "retire: a merged one with an uncommitted file is kept" test -f "$R/r1-wt/dirty/notes.md"
check "retire: a merged one with a commit after the PR's head is kept" test -d "$R/r1-wt/ahead"
check "retire: a worktree on no branch (a base) is kept" test -d "$R/r1-wt/base"
check "retire: another run's late merge is left without --all-runs" test -d "$R/r2-wt/late"
retire --apply --all-runs   # flags in either order
check "retire --all-runs: retires the late merge of the run beside it" test ! -e "$R/r2-wt/late"
check "retire --all-runs: ... keeping its state in that run's retired/" test -f "$R/r2/retired/late/status.json"
check "retire --all-runs: ... and still keeps this run's open PR" test -d "$R/r1-wt/open"

echo "== merge_base: a stacked branch merges the branch below it, and moves down once that one merges"
mkdir -p "$R/mbbin" "$R/mb"
cat > "$R/mbbin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr view <branch> ... --jq ...: prints what the filter would, from $SELFTEST_MB/<branch, / as _>; gh pr edit is logged
# gh api .../stacks?pull_request=N: the stack holding PR N, from $SELFTEST_MB/stack_N, else none ([])
echo "gh $*" >> "$SELFTEST_MB/gh.log"
[ "$1 $2" = "pr view" ] && cat "$SELFTEST_MB/${3//\//_}" 2>/dev/null
[ "$1" = api ] && { cat "$SELFTEST_MB/stack_${2##*=}" 2>/dev/null || echo '[]'; }
[ "$1 $2" = "pr edit" ] && [ -n "${SELFTEST_MB_EDIT_FAIL:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
exit 0
EOF
chmod +x "$R/mbbin/gh"
init fix "$R/r3" REPO="$R/repo" WT_ROOT="$R/r3-wt" BASE=develop MAX_SESSIONS=0
git -C "$R/repo" fetch -q origin
git -C "$R/repo" worktree add -q -b ai-work/stk-low "$R/r3-wt/stk-low" origin/develop 2>/dev/null
git -C "$R/r3-wt/stk-low" commit -q --allow-empty -m low && git -C "$R/r3-wt/stk-low" push -q origin ai-work/stk-low 2>/dev/null
git -C "$R/repo" worktree add -q -b ai-work/stk-up "$R/r3-wt/stk-up" origin/ai-work/stk-low 2>/dev/null
git -C "$R/r3-wt/stk-up" commit -q --allow-empty -m up && git -C "$R/r3-wt/stk-up" push -q origin ai-work/stk-up 2>/dev/null
mkdir -p "$R/r3-wt/stk-up/.fixloop" && echo ai-work/stk-low > "$R/r3-wt/stk-up/.fixloop/base"
mb() { PATH="$R/mbbin:$PATH" SELFTEST_MB="$R/mb" bash "$R/r3/merge_base.sh" "${1:-stk-up}" > "$R/mb.out" 2>&1; }
echo "OPEN develop" > "$R/mb/ai-work_stk-low"; echo "12 ai-work/stk-low" > "$R/mb/ai-work_stk-up"
git -C "$R/r3-wt/stk-low" commit -q --allow-empty -m "low, after review" && git -C "$R/r3-wt/stk-low" push -q origin ai-work/stk-low 2>/dev/null
mb
check "while the branch below is open, a stacked branch merges it ($(head -c 80 "$R/mb.out"))" \
    sh -c "git -C '$R/r3-wt/stk-up' merge-base --is-ancestor origin/ai-work/stk-low HEAD && [ \"\$(cat '$R/r3-wt/stk-up/.fixloop/base')\" = ai-work/stk-low ]"
check "... and its PR isn't retargeted" sh -c "! grep -q 'pr edit' '$R/mb/gh.log'"
git -C "$R/repo" checkout -q --detach origin/develop 2>/dev/null; git -C "$R/repo" merge -q --no-ff -m "Merge stk-low" origin/ai-work/stk-low 2>/dev/null
git -C "$R/repo" push -q origin HEAD:develop 2>/dev/null; git -C "$R/repo" checkout -q develop 2>/dev/null
echo "MERGED develop" > "$R/mb/ai-work_stk-low"
head=$(git -C "$R/r3-wt/stk-up" rev-parse HEAD)
SELFTEST_MB_EDIT_FAIL=1 mb; rc=$?
check "a retarget that fails leaves the branch on the branch below and exits 4 (exit $rc, base $(cat "$R/r3-wt/stk-up/.fixloop/base"))" \
    sh -c "[ $rc = 4 ] && [ \"\$(cat '$R/r3-wt/stk-up/.fixloop/base')\" = ai-work/stk-low ]"
check "... saying INCOMPLETE and why ($(grep -m1 INCOMPLETE "$R/mb.out" | cut -c1-80))" grep -q "INCOMPLETE.*HTTP 403" "$R/mb.out"
check "... and merges nothing" test "$(git -C "$R/r3-wt/stk-up" rev-parse HEAD)" = "$head"
: > "$R/mb/gh.log"
mb
check "once the branch below merges, the branch moves down onto the base ($(grep -m1 'sits on' "$R/mb.out" | cut -c1-80))" \
    sh -c "[ \"\$(cat '$R/r3-wt/stk-up/.fixloop/base')\" = develop ]"
check "... retargets its PR to the base" grep -q "pr edit 12 --base develop" "$R/mb/gh.log"
check "... and merges the base" git -C "$R/r3-wt/stk-up" merge-base --is-ancestor origin/develop HEAD

echo "== merge_base: in a GitHub stack, GitHub moves the branch down itself; merge_base takes its rebase, never a merge"
git -C "$R/repo" worktree add -q -b ai-work/stk-low2 "$R/r3-wt/stk-low2" origin/develop 2>/dev/null
git -C "$R/r3-wt/stk-low2" commit -q --allow-empty -m low2 && git -C "$R/r3-wt/stk-low2" push -q origin ai-work/stk-low2 2>/dev/null
git -C "$R/repo" worktree add -q -b ai-work/stk-up2 "$R/r3-wt/stk-up2" origin/ai-work/stk-low2 2>/dev/null
git -C "$R/r3-wt/stk-up2" commit -q --allow-empty -m up2 && git -C "$R/r3-wt/stk-up2" push -q origin ai-work/stk-up2 2>/dev/null
mkdir -p "$R/r3-wt/stk-up2/.fixloop" && echo ai-work/stk-low2 > "$R/r3-wt/stk-up2/.fixloop/base"
old=$(git -C "$R/r3-wt/stk-up2" rev-parse HEAD)
# GitHub merges the bottom PR, moves #13 onto the base and rebases (force-pushes) its branch there
git -C "$R/repo" checkout -q --detach origin/develop 2>/dev/null; git -C "$R/repo" merge -q --no-ff -m "Merge stk-low2" origin/ai-work/stk-low2 2>/dev/null
git -C "$R/repo" push -q origin HEAD:develop 2>/dev/null
git -C "$R/repo" commit -q --allow-empty -m "up2 (rebased by GitHub)" && git -C "$R/repo" push -q -f origin HEAD:ai-work/stk-up2 2>/dev/null
git -C "$R/repo" checkout -q develop 2>/dev/null
git -C "$R/repo" update-ref refs/remotes/origin/ai-work/stk-up2 "$old"   # the chain's worktree hasn't fetched GitHub's rebase yet
echo "MERGED develop" > "$R/mb/ai-work_stk-low2"; echo "13 develop" > "$R/mb/ai-work_stk-up2"
echo '[{"number":8,"pull_requests":[{"number":13}]}]' > "$R/mb/stack_13"
git -C "$R/r3-wt/stk-up2" commit -q --allow-empty -m "made here, never pushed"
local_head=$(git -C "$R/r3-wt/stk-up2" rev-parse HEAD); : > "$R/mb/gh.log"
mb stk-up2; rc=$?
check "a local commit not pushed stops the sync (exit $rc): INCOMPLETE, rather than lose it ($(grep -m1 INCOMPLETE "$R/mb.out" | cut -c1-70))" \
    sh -c "[ $rc = 4 ] && grep -q INCOMPLETE '$R/mb.out'"
check "... the branch and its base are left as they were" \
    sh -c "[ \"\$(git -C '$R/r3-wt/stk-up2' rev-parse HEAD)\" = $local_head ] && [ \"\$(cat '$R/r3-wt/stk-up2/.fixloop/base')\" = ai-work/stk-low2 ]"
git -C "$R/r3-wt/stk-up2" reset -q --hard "$old"; : > "$R/mb/gh.log"
mb stk-up2; rc=$?
check "the stacked branch takes GitHub's rebase (exit $rc: $(tail -1 "$R/mb.out" | cut -c1-70))" \
    sh -c "[ $rc = 0 ] && [ \"\$(git -C '$R/r3-wt/stk-up2' rev-parse HEAD)\" = \"\$(git -C '$R/r3-wt/stk-up2' rev-parse origin/ai-work/stk-up2)\" ]"
check "... sits on the PR's live base" sh -c "[ \"\$(cat '$R/r3-wt/stk-up2/.fixloop/base')\" = develop ]"
check "... and neither retargets its PR nor merges" sh -c "! grep -q 'pr edit' '$R/mb/gh.log' && ! git -C '$R/r3-wt/stk-up2' rev-parse -q --verify HEAD^2 >/dev/null"
check "... nor asks GitHub for a stack it doesn't need once the branch was rebased" sh -c "! grep -q 'gh api' '$R/mb/gh.log'"
rm -f "$R/mb/stack_13"; echo ai-work/stk-low2 > "$R/r3-wt/stk-up2/.fixloop/base"
git -C "$R/r3-wt/stk-up2" reset -q --hard "$old"; git -C "$R/r3-wt/stk-up2" update-ref refs/remotes/origin/ai-work/stk-up2 "$old"
mb stk-up2; rc=$?
check "a branch GitHub rebased is synced even once its stack is gone (exit $rc)" \
    sh -c "[ $rc = 0 ] && [ \"\$(git -C '$R/r3-wt/stk-up2' rev-parse HEAD)\" = \"\$(git -C '$R/r3-wt/stk-up2' rev-parse origin/ai-work/stk-up2)\" ]"
echo '[{"number":8,"pull_requests":[{"number":13}]}]' > "$R/mb/stack_13"; echo ai-work/stk-low2 > "$R/r3-wt/stk-up2/.fixloop/base"
head=$(git -C "$R/r3-wt/stk-up2" rev-parse HEAD); : > "$R/mb/gh.log"
mb stk-up2; rc=$?
check "in a stack GitHub moved but hasn't rebased yet: INCOMPLETE, nothing changed (exit $rc)" \
    sh -c "[ $rc = 4 ] && grep -q \"hasn't rebased\" '$R/mb.out' && [ \"\$(git -C '$R/r3-wt/stk-up2' rev-parse HEAD)\" = $head ] && ! grep -q 'pr edit' '$R/mb/gh.log'"
# the remote branch's reflog expired (or was never written): the tip origin/<branch> had before the fetch still counts as pushed
echo ai-work/stk-low2 > "$R/r3-wt/stk-up2/.fixloop/base"
git -C "$R/r3-wt/stk-up2" reset -q --hard "$old"; git -C "$R/r3-wt/stk-up2" update-ref refs/remotes/origin/ai-work/stk-up2 "$old"
rm -f "$(git -C "$R/repo" rev-parse --absolute-git-dir)/logs/refs/remotes/origin/ai-work/stk-up2"
logged=$(git -C "$R/r3-wt/stk-up2" reflog show --format=%H refs/remotes/origin/ai-work/stk-up2 2>/dev/null | wc -l | tr -d ' ')
mb stk-up2; rc=$?
check "with the remote branch's reflog gone ($logged entries), GitHub's rebase is still taken (exit $rc: $(tail -1 "$R/mb.out" | cut -c1-60))" \
    sh -c "[ $logged = 0 ] && [ $rc = 0 ] && [ \"\$(git -C '$R/r3-wt/stk-up2' rev-parse HEAD)\" = \"\$(git -C '$R/r3-wt/stk-up2' rev-parse origin/ai-work/stk-up2)\" ]"

echo "== fixloop: a branch whose parent merged (and was deleted) before it started is built from where the parent merged"
git -C "$R/repo" worktree add -q -b ai-work/stk-gone "$R/gone" origin/develop 2>/dev/null
git -C "$R/gone" commit -q --allow-empty -m gone && git -C "$R/gone" push -q origin ai-work/stk-gone 2>/dev/null
git -C "$R/repo" checkout -q --detach origin/develop 2>/dev/null; git -C "$R/repo" merge -q --no-ff -m "Merge stk-gone" origin/ai-work/stk-gone 2>/dev/null
git -C "$R/repo" push -q origin HEAD:develop 2>/dev/null; git -C "$R/repo" checkout -q develop 2>/dev/null
git -C "$R/repo" worktree remove --force "$R/gone"; git -C "$R/repo" branch -q -D ai-work/stk-gone
git -C "$R/repo" push -q origin --delete ai-work/stk-gone 2>/dev/null; git -C "$R/repo" fetch -q --prune origin
echo "MERGED develop" > "$R/mb/ai-work_stk-gone"
mkdir -p "$R/r3/briefs"
printf '# Fix branch `stk-kid`\n\nPlan signed off: 2026-11-24 by Selftest\nStacked on: stk-gone\n' > "$R/r3/briefs/stk-kid.md"
# MAX_SESSIONS=0: the chain sets up its worktree and stops before any session
PATH="$R/mbbin:$PATH" SELFTEST_MB="$R/mb" bash "$R/r3/fixloop.sh" stk-kid > "$R/kid.out" 2>&1
check "the child gets its worktree, from the base with the parent merged in ($(grep -m1 'stk-kid' "$R/r3/logs/runner.log" | cut -c1-100))" \
    sh -c "git -C '$R/r3-wt/stk-kid' merge-base --is-ancestor origin/develop HEAD"
check "... and sits on the base" sh -c "[ \"\$(cat '$R/r3-wt/stk-kid/.fixloop/base' 2>/dev/null)\" = develop ]"
printf '# Fix branch `stk-kid2`\n\nPlan signed off: 2026-11-24 by Selftest\nStacked on: stk-low2\n' > "$R/r3/briefs/stk-kid2.md"
echo "OPEN develop" > "$R/mb/ai-work_stk-low2"
PATH="$R/mbbin:$PATH" SELFTEST_MB="$R/mb" bash "$R/r3/fixloop.sh" stk-kid2 > "$R/kid2.out" 2>&1
check "a branch whose parent is open is built from the parent's branch, and sits on it" \
    sh -c "git -C '$R/r3-wt/stk-kid2' merge-base --is-ancestor origin/ai-work/stk-low2 HEAD && [ \"\$(cat '$R/r3-wt/stk-kid2/.fixloop/base' 2>/dev/null)\" = ai-work/stk-low2 ]"

echo "== crews: any agent and model per role, every agent driven the same way"
# Stand-in agent CLIs: each answers in its own CLI's event format. SELFTEST_AGENT_MODE: plain (answers "done"), flood
# (big tool results until the wrapper stops it; a resumed session writes its hand-off), flood-always (floods when
# resumed too), shim (tries what a loop session may not do, and records what git/gh said).
cat > "$STUBS/st_agent.py" <<'EOF'
import json, os, subprocess, sys, time
name, args = sys.argv[1], sys.argv[2:]
if args == ["--version"]:
    print(f"{name} stub 1.0"); sys.exit(0)
log, mode = os.environ.get("SELFTEST_LOG"), os.environ.get("SELFTEST_AGENT_MODE", "plain")
state = os.environ.get("LOOP_STATE", ".")
def rec(s):
    if log:
        open(log, "a").write(s + "\n")
def opt(flag):
    return args[args.index(flag) + 1] if flag in args else ""
prompt = sys.stdin.read() if name in ("codex", "gemini") else ""
prompt += " " + (opt("-p") if name in ("agy", "grok", "gemini") else "") + " " + (args[-1] if args else "")
resumed = "[context guard] Context is at" in prompt or "[end gate] You ended without" in prompt
ready = "single word READY" in prompt
model = opt("-m") or opt("--model") or "?"
rec(f"{name} {'RESUME ' if resumed else ''}{'READY ' if ready else ''}" + " ".join(a if len(a) < 70 else a[:40] + "..." for a in args)
    + (" rules-included" if "## Notes for" in prompt else ""))
said = os.environ.get("SELFTEST_ANSWER_AS") or model
answer = "READY" if ready else ("handed off" if resumed else "done")
if resumed:
    open(os.path.join(state, "HANDOFF.md"), "w").write("# Hand-off\n")
    if os.path.exists(os.path.join(state, "status.json")):
        os.utime(os.path.join(state, "status.json"))
if mode == "shim" and not ready and not resumed:
    for c in (["gh", "pr", "merge", "1"], ["git", "push", "--force", "origin", "x"], ["gh", "api", "--method", "GET", "repos/o/r/pulls/1"], ["gh", "pr", "view", "1"]):
        rec(f"shim {' '.join(c)} -> {subprocess.run(c, capture_output=True).returncode}")
BIG = "word " * 30000
def out(d):
    print(json.dumps(d), flush=True)
big = {"codex": lambda i: {"type": "item.completed", "item": {"id": f"i{i}", "type": "command_execution", "aggregated_output": BIG}},
       "agy": lambda i: {"event": "step_update", "step_type": "tool", "state": "DONE", "output": BIG},
       "gemini": lambda i: {"type": "tool_result", "tool_id": f"t{i}", "output": BIG},
       "grok": lambda i: {"type": "tool_result", "output": BIG},
       "opencode": lambda i: {"type": "step_finish", "sessionID": "ses-1", "part": {"tokens": {"input": 140000, "output": 10, "cache": {"read": 0, "write": 0}}, "cost": 0.01}},
       "agent": lambda i: {"type": "tool_call", "subtype": "completed", "tool_call": {"result": BIG}}}[name]
start = {"codex": {"type": "thread.started", "thread_id": "th-1"}, "agy": {"event": "init", "model": said, "conversation_id": "cv-1"},
         "gemini": {"type": "init", "session_id": "s-1", "model": said}, "grok": {"type": "start"},
         "opencode": {"type": "step_start", "sessionID": "ses-1", "part": {}}, "agent": {"type": "system", "subtype": "init", "session_id": "cu-1", "model": said}}[name]
out(start)
if (mode == "flood" and not ready and not resumed) or (mode == "flood-always" and not ready):
    for i in range(40):
        out(big(i)); time.sleep(0.05)
end = {"codex": [{"type": "item.completed", "item": {"id": "i99", "type": "agent_message", "text": answer}}, {"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 5}}],
       "agy": [{"event": "result", "status": "SUCCESS", "response": answer, "conversation_id": "cv-1"}],
       "gemini": [{"type": "message", "role": "assistant", "content": answer, "delta": True}, {"type": "result", "status": "success", "stats": {}}],
       "grok": [{"type": "result", "text": answer, "stopReason": "end_turn"}],
       "opencode": [{"type": "text", "sessionID": "ses-1", "part": {"text": answer}}, {"type": "step_finish", "sessionID": "ses-1", "part": {"tokens": {"input": 900, "output": 5, "cache": {"read": 0, "write": 0}}, "cost": 0.02}}],
       "agent": [{"type": "assistant", "message": {"content": [{"type": "text", "text": answer}]}}, {"type": "result", "subtype": "success", "is_error": False, "result": answer, "session_id": "cu-1"}]}[name]
for e in end:
    out(e)
EOF
for a in codex agy gemini grok opencode agent; do
    printf '#!/usr/bin/env bash\nexec "%s" "%s" %s "$@"\n' "$PY" "$STUBS/st_agent.py" "$a" > "$STUBS/$a"; chmod +x "$STUBS/$a"
done
REALBIN="$T/realbin"; mkdir -p "$REALBIN"   # what the shims hand an allowed git/gh call to
for a in git gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$REALBIN/$a"; chmod +x "$REALBIN/$a"; done
M="$T/mix"
init fix "$M" CREW=mixed || cat "$T/init.log"
for kv in CREW=mixed RESEARCH_PIN=agy/gemini-4-carbon:high PLAN_PIN=codex/gpt-6-astra:xhigh "CODE_PIN='claude/claude-opus-5-5[1m]:high'" \
          PLAN_AGENT=codex PLAN_WINDOW=256000 RESEARCH_AGENT=agy; do
    check "CREW=mixed: loop.conf has $kv" grep -qxF "$kv" "$M/loop.conf"
done
check "init_run names the crew and how to change it" grep -q "crew (mixed)" "$T/init.log"
for role in research plan code; do
    pf=$(cd "$M" && ./preflight.sh $role 2>&1)
    check "preflight $role on its own agent printed ok ($(echo "$pf" | head -c 70))" test "$pf" = ok
done
pf=$(cd "$M" && SELFTEST_ANSWER_AS=gemini-other ./preflight.sh research 2>&1)
check "a research pin whose agent answers as another model is refused ($(echo "$pf" | head -c 60))" sh -c "echo \"\$1\" | grep -q 'answered as'" _ "$pf"
init fix "$M" PLAN_PIN='opencode/openrouter/qwen/qwen3-coder:high@200k'
check "a re-run changes only the pin it is passed" sh -c "grep -qxF \"PLAN_PIN=opencode/openrouter/qwen/qwen3-coder:high@200000\" '$M/loop.conf' && grep -qx CREW=mixed '$M/loop.conf' && grep -qx RESEARCH_PIN=agy/gemini-4-carbon:high '$M/loop.conf' && grep -qx PLAN_WINDOW=200000 '$M/loop.conf'"
init fix "$T/mix2" CREW=clean-code
check "CREW=clean-code: chains sign as Codex, the code pin's agent" grep -qF 'Assisted-by: Codex CLI (GPT-6 Astra)' "$T/mix2/runbook.md"
init fix "$T/mix3" EFFORT=max
check "the pre-crew EFFORT= still sets the main pin's effort" sh -c "grep -qxF \"CODE_PIN='claude/claude-opus-5-5[1m]:max'\" '$T/mix3/loop.conf' && grep -qx EFFORT=max '$T/mix3/loop.conf'"
init fix "$T/mix4" CREW=nosuch; rc=$?
check "an unknown crew is refused, naming the crews there are" sh -c "[ $rc != 0 ] && grep -q 'the crews are' '$T/init.log'"
(cd "$M" && "$PY" crew.py set code=codex/gpt-6.1-sol:medium) > "$T/crewset.out" 2>&1
check "crew.py set in a run changes that role's pin in loop.conf and loop.json" sh -c "grep -qx CODE_PIN=codex/gpt-6.1-sol:medium '$M/loop.conf' && grep -qx CODE_AGENT=codex '$M/loop.conf' && grep -q '\"CODE_PIN\": \"codex/gpt-6.1-sol:medium\"' '$M/loop.json'"
check "crew.py refuses an effort the agent doesn't take, and changes nothing" sh -c "! (cd '$M' && '$PY' crew.py set code=grok/grok-4.7:high) >/dev/null 2>&1 && grep -qx CODE_PIN=codex/gpt-6.1-sol:medium '$M/loop.conf'"
check "crew.py takes the words people use for a role (execution = code)" sh -c "cd '$M' && '$PY' crew.py set execution=claude/claude-opus-5-5[1m]:high >/dev/null && grep -qxF \"CODE_PIN='claude/claude-opus-5-5[1m]:high'\" loop.conf"
CR="$T/crewrepo"; git init -q -b main "$CR"
(cd "$CR" && "$PY" "$KIT/common/crew.py" use budget && "$PY" "$KIT/common/crew.py" set 'plan=claude/claude-fable-5-2[1m]:high') > "$T/crewrepo.out" 2>&1
check "crew.py use/set in a repository writes .laneloop/crew.json: the preset and the roles it overrides" "$PY" -c \
    "import json,sys; d=json.load(open(sys.argv[1])); assert d=={'crew':'budget','plan':'claude/claude-fable-5-2[1m]:high'}, d" "$CR/.laneloop/crew.json"
(cd "$CR" && "$PY" "$KIT/init_run.py" fix "$T/mix5" OWNER=Selftest GH_REPO=o/r GH_LOGIN=selftest PROJECT="$T/project.json") > "$T/init5.log" 2>&1
check "a run in that repository starts with its crew" sh -c "grep -qx CREW=budget '$T/mix5/loop.conf' && grep -qxF \"PLAN_PIN='claude/claude-fable-5-2[1m]:high'\" '$T/mix5/loop.conf' && grep -qx CODE_PIN=codex/gpt-6.1-sol:medium '$T/mix5/loop.conf'"
check "crew.py presets lists the recommended crews first, each role with why" sh -c "'$PY' '$KIT/common/crew.py' presets | head -3 | grep -q '^frontier (' && '$PY' '$KIT/common/crew.py' presets | grep -q 'why code:'"

# sessions on other agents, through agent_run.py, from the mixed run
sess() {  # <state dir> <pin> [env...]: one session with the run's runbook and settings; prints its result line
    local st="$1" pin="$2"; shift 2
    mkdir -p "$st"; echo "Carry on with the task." > "$st/prompt.md"
    env LOOP_STATE="$st" "$@" "$PY" "$M/agent_run.py" session plan --pin "$pin" --prompt "$st/prompt.md" \
        --system "$M/runbook.md" --settings "$M/settings.json" --log "$st/s.jsonl" --err "$st/s.err"
}
chain_state() { mkdir -p "$1"; echo '{"slug":"s","status":"in_progress","phase":"green","notes":[]}' > "$1/status.json"; }
for a in agy/gemini-4-carbon:high gemini/gemini-2.5-pro grok/grok-4.7 cursor/sonnet-5.5; do
    st="$T/sess-${a%%/*}"; mkdir -p "$st"; touch "$st/HANDOFF.md"
    r=$(sess "$st" "$a" SELFTEST_AGENT_MODE=plain)
    check "${a%%/*}: a plain session gives the result line (success|...|done) ($(echo "$r" | head -c 50))" sh -c "echo \"\$1\" | grep -q '^success|.*|done$'" _ "$r"
done
check "every agent but Claude Code gets the run's rules and its own notes ahead of the task" \
    sh -c "[ \$(grep -c 'rules-included' '$SELFTEST_LOG') -ge 4 ]"
chain_state "$T/eg/.fixloop"
r=$(sess "$T/eg/.fixloop" codex/gpt-6-astra:high SELFTEST_AGENT_MODE=plain)
check "end gate: a Codex session that ends without its hand-off is resumed once to write it" \
    sh -c "grep -q '^codex RESUME .* resume th-1' '$SELFTEST_LOG' && test -f '$T/eg/.fixloop/HANDOFF.md' && echo \"\$1\" | grep -q 'handed off'" _ "$r"
chain_state "$T/soft/.fixloop"
r=$(sess "$T/soft/.fixloop" codex/gpt-6-astra:high@200k SELFTEST_AGENT_MODE=flood)
check "context guard (wrapper): at the hand-off threshold a Codex session is interrupted and resumed with the hand-off ask" \
    sh -c "grep -q 'HANDOFF (wrapper)' '$T/soft/.fixloop/logs/ctx.log' && test -f '$T/soft/.fixloop/HANDOFF.md' && test ! -f '$T/soft/.fixloop/state/last_stop.json'"
chain_state "$T/hard/.fixloop"
r=$(sess "$T/hard/.fixloop" codex/gpt-6-astra:high@200k SELFTEST_AGENT_MODE=flood-always)
check "context guard (wrapper): a session that runs on past the hard stop is ended, with last_stop.json as the hook writes it" \
    "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['kind']=='hard-cap' and d['pct']>=0.72 and d['agent']=='codex', d" "$T/hard/.fixloop/state/last_stop.json"
chain_state "$T/oc/.fixloop"
r=$(sess "$T/oc/.fixloop" opencode/openrouter/x/y@200k SELFTEST_AGENT_MODE=flood)
check "context guard (wrapper): OpenCode's reported tokens trip the hand-off, resumed in its own session" \
    sh -c "grep -q 'HANDOFF (wrapper)' '$T/oc/.fixloop/logs/ctx.log' && grep -q '^opencode RESUME .*--session ses-1' '$SELFTEST_LOG'"
if [ "$WIN" = 0 ]; then
    chain_state "$T/shim/.fixloop"; touch "$T/shim/.fixloop/HANDOFF.md"
    r=$(sess "$T/shim/.fixloop" codex/gpt-6-astra:high SELFTEST_AGENT_MODE=shim PATH="$REALBIN:$PATH")
    check "guard rails: a Codex session can't merge or force-push (git/gh refuse with 126)" \
        sh -c "grep -q 'shim gh pr merge 1 -> 126' '$SELFTEST_LOG' && grep -q 'shim git push --force origin x -> 126' '$SELFTEST_LOG'"
    check "guard rails: ... and may still read a PR (gh pr view, gh api --method GET)" \
        sh -c "grep -q 'shim gh pr view 1 -> 0' '$SELFTEST_LOG' && grep -q 'shim gh api --method GET repos/o/r/pulls/1 -> 0' '$SELFTEST_LOG'"
else skip "guard rails: the git/gh shims are bash, for macOS and Linux"; fi
check "codex sessions write in the worktree and the run folder, with the network on" \
    sh -c "grep '^codex ' '$SELFTEST_LOG' | grep -v READY | head -1 | grep -q -- '--sandbox workspace-write -c sandbox_workspace_write.network_access=true --add-dir'"
(cd "$M" && SELFTEST_AGENT_MODE=plain "$PY" consult.py research auth-flow "How does sign-in work?") > "$T/consult.out" 2>&1
check "consult.py: a research question runs read-only on the research pin, answer in consults/<name>.md" \
    sh -c "grep -q '^consults/auth-flow.md · agy/gemini-4-carbon:high' '$T/consult.out' && grep -qx done '$M/consults/auth-flow.md' && grep -q '^agy .*-p' '$SELFTEST_LOG' && ! grep '^agy ' '$SELFTEST_LOG' | grep -v READY | tail -1 | grep -q dangerously"
printf '[{"name": "q1", "question": "one?"}, {"name": "q2", "question": "two?"}]' > "$T/qs.json"
(cd "$M" && "$PY" consult.py plan --batch "$T/qs.json" --par 2) > "$T/consult2.out" 2>&1
check "consult.py --batch: several questions at once, one line each" sh -c "[ \$(grep -c '^consults/q' '$T/consult2.out') = 2 ]"
# an agent that isn't installed: said up front, never a crash, and a crew this machine can run instead
pr=$(LANELOOP_BIN_CODEX=no-codex "$PY" "$KIT/common/crew.py" presets)
check "crew.py presets says which crews this machine can run, and what the others need" \
    sh -c "echo \"\$1\" | grep -q '^frontier (ready here)' && echo \"\$1\" | grep -q '^clean-code (needs Codex CLI)' && echo \"\$1\" | grep -q '^Ready on this machine: frontier'" _ "$pr"
pr=$(METALOOP_BIN_CODEX=no-codex "$PY" "$KIT/common/crew.py" presets)
check "... and still reads a METALOOP_BIN_* override from before the rename" \
    sh -c "echo \"\$1\" | grep -q '^clean-code (needs Codex CLI)'" _ "$pr"
OR="$T/oldrepo"; git init -q -b main "$OR"; mkdir -p "$OR/.metaloop"
echo '{"crew": "budget"}' > "$OR/.metaloop/crew.json"; cp "$T/project.json" "$OR/.metaloop/project.json"
out=$(cd "$OR" && "$PY" "$KIT/common/crew.py" show 2>&1)
check "a repository still on .metaloop/ from before the rename: its crew is read, with a note to move the folder" \
    sh -c "echo \"\$1\" | grep -q budget && echo \"\$1\" | grep -q 'git mv .metaloop .laneloop'" _ "$out"
(cd "$OR" && "$PY" "$KIT/init_run.py" fix "$T/old1" OWNER=Selftest GH_REPO=o/r GH_LOGIN=selftest) > "$T/old1.log" 2>&1
check "... and a run made there uses its .metaloop/project.json" sh -c "grep -qx 'PROJECT=.metaloop/project.json' '$T/old1/loop.conf' && grep -qx CREW=budget '$T/old1/loop.conf'"
out=$(cd "$CR" && LANELOOP_BIN_CODEX=no-codex "$PY" "$KIT/common/crew.py" use mixed 2>&1)
check "crew.py use: a crew needing an agent that isn't installed is saved, with its install, its sign-in and a crew that can run" \
    sh -c "echo \"\$1\" | grep -q 'Codex CLI isn.t installed here.*npm install -g @openai/codex.*sign in' && echo \"\$1\" | grep -q \"'frontier' is the first crew this machine can run\"" _ "$out"
out=$(cd "$CR" && LANELOOP_BIN_CLAUDE=no-claude "$PY" "$KIT/common/crew.py" use auto 2>&1)
check "crew.py use auto: without Claude Code, the first recommended crew whose agents are here (codex)" \
    sh -c "echo \"\$1\" | grep -q \"auto: 'codex'\" && grep -q '\"crew\": \"codex\"' '$CR/.laneloop/crew.json'" _ "$out"
(export LANELOOP_BIN_CLAUDE=no-claude; init fix "$T/mix6")
check "init_run: with no crew chosen and the default's agent missing, the run starts on a crew this machine can run" \
    sh -c "grep -qx CREW=codex '$T/mix6/loop.conf' && grep -q \"uses the 'codex' crew\" '$T/init.log'"
mkdir -p "$T/miss"; echo hi > "$T/miss/p.md"
r=$(LOOP_STATE="$T/miss" LANELOOP_BIN_CODEX=no-codex "$PY" "$M/agent_run.py" session plan --pin codex/gpt-6-astra:high \
    --prompt "$T/miss/p.md" --log "$T/miss/l" --err "$T/miss/e" 2>&1); rc=$?
check "a session whose agent isn't installed ends with an agent_missing line (rc 127) the loops stop on, not a traceback" \
    sh -c "[ $rc = 127 ] && echo \"\$1\" | grep -q '^agent_missing|0|0||Codex CLI' && ! echo \"\$1\" | grep -q Traceback" _ "$r"
check "the fix chain and the verify loop stop on agent_missing instead of counting a strike" \
    sh -c "grep -q 'agent_missing' '$M/fixloop.sh' && grep -q 'agent_missing' '$KIT/verify/qa-loop.sh'"
dm() { (cd "$M" && env "$@" "$PY" doctor.py --json </dev/null) | "$PY" -c "import json,sys; a=('Claude Code','Codex CLI','Antigravity CLI','Gemini CLI','Grok Build','OpenCode','Cursor CLI'); print(json.dumps([i for i in json.load(sys.stdin)['items'] if i['name'].startswith(a)]))"; }
check "doctor: every agent the crew pins is checked (research agy, plan OpenCode, code and verify Claude Code)" "$PY" -c \
    "import json,sys; n=[i['name'].split(' (')[0] for i in json.loads(sys.argv[1])]; assert sorted(n)==['Antigravity CLI','Claude Code','OpenCode'], n" "$(dm)"
check "doctor: a missing research agent is a fallback (the orchestrator researches), a missing plan agent blocks" "$PY" -c \
    "import json,sys; d={i['name'].split(' (')[0]: i for i in json.loads(sys.argv[1])}; assert d['Antigravity CLI']['state']=='fallback' and d['OpenCode']['state']=='missing' and 'crew.py set' in d['OpenCode']['ask'], d" \
    "$(dm LANELOOP_BIN_AGY=no-such-agy LANELOOP_BIN_OPENCODE=no-such-opencode)"

echo "== doctor: a verdict per dependency"
for run in fix ver; do
    "$PY" "$T/$run/doctor.py" --json > "$T/doctor-$run.json" 2>"$T/doctor-$run.err"
    check "$run: doctor --json lists every dependency with a known state" "$PY" - "$T/doctor-$run.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
states = {"ok", "fallback", "skipped", "warn", "missing"}
assert d["items"] and all(i["state"] in states and i["name"] and i["for"] for i in d["items"]), d
assert all(i["install"] or i["state"] in ("ok", "skipped") or i["fallback"] for i in d["items"] if i["state"] != "ok")
EOF
done
"$PY" "$T/fix/doctor.py" > "$T/doctor.txt" 2>&1
check "doctor prints a readable report" grep -q "project profile" "$T/doctor.txt"
dj() { "$PY" "$T/fix/doctor.py" --json | "$PY" -c "import json,sys; i=[x for x in json.load(sys.stdin)['items'] if x['name']==sys.argv[1]]; print(json.dumps(i[0]) if i else '')" "$1"; }
check "doctor: the profile and the tools it requires are checked" sh -c "echo \"\$1\" | grep -q '\"state\": \"ok\"'" _ "$(dj st-run)"
write_profile "$T/needs.json" "p['requires'].append({'tool': 'no-such-tool-xyz', 'for': 'the integration suite', 'install': 'brew install xyz', 'who': 'owner', 'skip': 'integration'})"
init fix "$T/fix" PROJECT="$T/needs.json" GATE_SKIP=
check "doctor: a missing tool blocks the run, with its install and the step the owner may leave out instead" \
    "$PY" -c "import json,sys; i=json.loads(sys.argv[1]); assert i['state']=='missing' and i['ask']=='GATE_SKIP=integration' and 'xyz' in i['install'], i" "$(dj no-such-tool-xyz)"
init fix "$T/fix" PROJECT="$T/needs.json" GATE_SKIP=integration
check "doctor: ... and is skipped once the owner has left that step out" \
    "$PY" -c "import json,sys; i=json.loads(sys.argv[1]); assert i['state']=='skipped', i" "$(dj no-such-tool-xyz)"
write_profile "$T/fill.json" "p['gate']['steps'][0]['run'] = 'FILL IN: the build command'"
init fix "$T/fix" PROJECT="$T/fill.json" GATE_SKIP=
check "doctor: a profile with a FILL IN left blocks the run" \
    "$PY" -c "import json,sys; i=json.loads(sys.argv[1]); assert i['state']=='missing' and 'FILL IN' in i['detail'], i" "$(dj 'project profile')"
init fix "$T/fix" PROJECT="$T/none.json"
rm -f "$T/fix/project.json"
check "doctor: no profile at all blocks the run, and says how to write one" \
    "$PY" -c "import json,sys; i=json.loads(sys.argv[1]); assert i['state']=='missing' and 'init_project.py' in i['install'], i" "$(dj 'project profile')"
init fix "$T/fix" PROJECT="$T/project.json"

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ]
