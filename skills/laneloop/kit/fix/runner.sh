#!/usr/bin/env bash
# Runs the branches listed in a queue file as parallel chains, MAX_PAR at a time; starts the next as one ends. A branch
# stacked on another (its brief's "Stacked on:") starts once that one has opened its pull request. Keeps the computer
# awake while it runs.
# Every chain end (and the runner's own end) is written to logs/runner.log and raised as a toast.
#   QUEUE=queue.txt MAX_PAR=5 ./runner.sh          (start.sh opens it in its own window)
#   ./runner.sh --preflight-only                   check the code and plan pins and stop
# Plain bash 3.2 (macOS's): no mapfile, no associative arrays.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1
_max_par="${MAX_PAR:-}"
source ./loop.conf
source ./platform.sh
MAX_PAR="${_max_par:-$MAX_PAR}"   # the caller's MAX_PAR wins over loop.conf
QUEUE="${QUEUE:-queue.txt}"
STAGGER_SECS="${STAGGER_SECS:-45}"   # between chain starts: staggers worktree creation and first builds
POLL_SECS="${POLL_SECS:-30}"
mkdir -p logs
log() { echo "[$(date '+%m-%d %H:%M:%S')] [runner] $*" | tee -a logs/runner.log; }
notify() { platform_notify "$1" "$2"; }

pf=$(./preflight.sh code)
[ "$pf" = ok ] || { log "STOP: code-pin preflight refused ($CODE_PIN): $pf"; notify "Runner stopped" "preflight refused: $pf"; exit 1; }
Q=()
while IFS= read -r line; do Q+=("$line"); done < <(grep -v '^#' "$QUEUE" 2>/dev/null | sed 's/\r$//' | grep -v '^$')
# No branch starts without a signed-off plan: make_briefs.py writes the "Plan signed off:" line only for a plan the owner
# signed off (sign_plan.py). A started branch answers from its worktree's copy of the brief, a new one from briefs/.
for s in ${Q[@]+"${Q[@]}"}; do
    b="briefs/$s.md"; [ -f "$WT_ROOT/$s/.fixloop/brief.md" ] && b="$WT_ROOT/$s/.fixloop/brief.md"
    grep -q '^Plan signed off: ' "$b" 2>/dev/null && continue
    log "STOP: $s: its brief has no 'Plan signed off:' line. Get the plan page signed off, record it with sign_plan.py, then make_briefs.py"
    notify "Runner stopped" "$s has no signed-off plan"; exit 1
done
# The plan pin too when a queued branch's next session runs on it (task.py pin: a design branch not yet signed off), or
# when asked. A started branch answers from its worktree, where the sign-off note is; a new one from its brief.
plan=""
for s in ${Q[@]+"${Q[@]}"}; do
    if [ -f "$WT_ROOT/$s/.fixloop/status.json" ]; then p=$(cd "$WT_ROOT/$s" && "$PYTHON" "$ROOT/task.py" pin 2>/dev/null)
    else p=$("$PYTHON" "$ROOT/task.py" pin "briefs/$s.md" 2>/dev/null); fi
    [ "$p" = plan ] && plan=1
done
if [ -n "$plan" ] || [ "${1:-}" = "--preflight-only" ]; then
    pf=$(./preflight.sh plan)
    [ "$pf" = ok ] || { log "STOP: plan-pin preflight refused ($PLAN_PIN): $pf"; notify "Runner stopped" "plan-pin preflight refused: $pf"; exit 1; }
    plan=" · plan pin $PLAN_PIN"
fi
log "preflight ok: code pin $CODE_PIN$plan · MAX_PAR=$MAX_PAR · queue $QUEUE"
[ "${1:-}" = "--preflight-only" ] && exit 0
# The run's PR label (loop.conf PR_LABEL) must exist before a chain opens a pull request with it: gh refuses an unknown
# label, and a chain may not make one. Empty PR_LABEL = no label.
if [ -n "${PR_LABEL:-}" ]; then
    if out=$(gh label create "$PR_LABEL" --repo "$GH_REPO" --color 2563EB --force \
                --description "Pull requests from the LaneLoop run ${RUN_NAME:0:60}" 2>&1); then
        log "PR label ready: $PR_LABEL on $GH_REPO"
    else
        log "STOP: could not create the PR label '$PR_LABEL' on $GH_REPO: $(echo "$out" | tr '\n' ' ' | cut -c1-300). Fix gh's access to the repository, or set PR_LABEL= (empty) in loop.conf to open pull requests without a label"
        notify "Runner stopped" "could not create the PR label $PR_LABEL"; exit 1
    fi
fi
# Chains run unattended for hours: keep the computer awake for as long as this runner lives, however it was started
# (launch.sh holds it too, but a runner started any other way had nothing).
keep_awake $$ "LaneLoop is running the run's chains"
SLUGS=(); PIDS=()   # the running chains: SLUGS[k] runs as PIDS[k]

reap() {  # log every chain that has ended and drop it from the running lists
    local k s=() p=() st
    for ((k = 0; k < ${#PIDS[@]}; k++)); do
        if kill -0 "${PIDS[$k]}" 2>/dev/null; then s+=("${SLUGS[$k]}"); p+=("${PIDS[$k]}"); continue; fi
        wait "${PIDS[$k]}" 2>/dev/null
        st=$(cd "$WT_ROOT/${SLUGS[$k]}" 2>/dev/null && "$PYTHON" "$ROOT/task.py" status 2>/dev/null)
        log "chain ended: ${SLUGS[$k]} (${st:-unknown})"; notify "Chain ended: ${SLUGS[$k]}" "${st:-unknown}"
    done
    SLUGS=(${s[@]+"${s[@]}"}); PIDS=(${p[@]+"${p[@]}"})
}

# PR stacks: a branch whose brief says "Stacked on: <slug>" starts only once that branch has opened its pull request (its
# branch is on origin to build from); a parent that ended without one means it never starts, and the log says why.
# A design branch on a design branch starts once that one has pushed its page: a design chain pushes, then ends
# awaiting_owner with no PR. A build branch on a design branch still waits for its PR.
brief_of() { if [ -f "$WT_ROOT/$1/.fixloop/brief.md" ]; then echo "$WT_ROOT/$1/.fixloop/brief.md"; else echo "briefs/$1.md"; fi; }
parent_of() { sed -n 's/^Stacked on: \([^ ]*\).*/\1/p' "$(brief_of "$1")" 2>/dev/null | tr -d '\r' | head -n 1; }
has_pr() {  # its worktree's state, or the state retire.sh kept once it merged
    local f; for f in "$WT_ROOT/$1/.fixloop/status.json" "retired/$1/status.json"; do
        [ -f "$f" ] && "$PYTHON" -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1],encoding='utf8')).get('pr') else 1)" "$f" 2>/dev/null && return 0
    done; return 1
}
pin_of() {  # plan: a design branch not signed off yet (task.py pin); its worktree's state once started, else its brief
    if [ -f "$WT_ROOT/$1/.fixloop/status.json" ] && [ -f "$WT_ROOT/$1/.fixloop/brief.md" ]; then
        (cd "$WT_ROOT/$1" && "$PYTHON" "$ROOT/task.py" pin 2>/dev/null)
    else "$PYTHON" "$ROOT/task.py" pin "$(brief_of "$1")" 2>/dev/null; fi
}
page_pushed() {  # <design parent>: its chain ended awaiting the owner (task.py ready, after the push)
    [ "$(pin_of "$1")" = plan ] && [ "$(cd "$WT_ROOT/$1" 2>/dev/null && "$PYTHON" "$ROOT/task.py" status 2>/dev/null)" = awaiting_owner ]
}
below_ready() {  # <slug> <parent>: the parent has what the branch builds on
    has_pr "$2" || { [ "$(pin_of "$1")" = plan ] && page_pushed "$2"; }
}
listed() { local x w="$1"; shift; for x in "$@"; do [ "$x" = "$w" ] && return 0; done; return 1; }
P=(${Q[@]+"${Q[@]}"})   # queued, not started yet
while [ "${#P[@]}" -gt 0 ] || [ "${#PIDS[@]}" -gt 0 ]; do
    reap
    rest=()
    for slug in ${P[@]+"${P[@]}"}; do
        parent=$(parent_of "$slug")
        if [ -n "$parent" ] && [ "$parent" != - ] && ! below_ready "$slug" "$parent"; then
            if listed "$parent" ${P[@]+"${P[@]}"} ${SLUGS[@]+"${SLUGS[@]}"}; then rest+=("$slug"); continue; fi
            log "not started: $slug: stacked on $parent, which ended without a pull request"
            notify "Chain not started: $slug" "stacked on $parent, which has no pull request"; continue
        fi
        if [ "${#PIDS[@]}" -ge "$MAX_PAR" ]; then rest+=("$slug"); continue; fi
        ./fixloop.sh "$slug" &
        SLUGS+=("$slug"); PIDS+=("$!")
        on=""; [ -n "$parent" ] && [ "$parent" != - ] && on=" · stacked on $parent"
        log "chain started: $slug (pid $!)$on"
        sleep "$STAGGER_SECS"
    done
    P=(${rest[@]+"${rest[@]}"})
    [ "${#PIDS[@]}" -gt 0 ] && sleep "$POLL_SECS"
done
log "all chains ended"
notify "Chains finished" "All ${#Q[@]} in $QUEUE have stopped; see logs/runner.log"
