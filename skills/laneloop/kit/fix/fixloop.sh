#!/usr/bin/env bash
# One branch as a chain of fresh headless sessions, each seeded by .fixloop/HANDOFF.md, each on the agent and model the
# crew pins for its role (agent_run.py: Claude Code, Codex, Antigravity, Gemini CLI, Grok Build, OpenCode or Cursor). A
# design branch runs on the plan pin until its sign-off; every other session on the code pin (task.py pin decides).
# Stops when the task reaches awaiting_owner / needs_owner / blocked / done, after MAX_SESSIONS, after two sessions in a
# row with no progress (status, HEAD, working tree and notes unchanged), or after four in a row that only added notes.
#   fixloop.sh <slug>          (normally started by runner.sh)
set -u
SLUG="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/loop.conf"
source "$ROOT/platform.sh"
WT="$WT_ROOT/$SLUG"
BR="${BRANCH_PREFIX}${SLUG_PREFIX}${SLUG}"

export LOOP_SOFT_PCT="$SOFT_PCT" LOOP_HARD_PCT="$HARD_PCT"
export FIXLOOP="$ROOT"

mkdir -p "$ROOT/logs"
log() { echo "[$(date '+%m-%d %H:%M:%S')] [$SLUG] $*" | tee -a "$ROOT/logs/$SLUG.log" >> "$ROOT/logs/runner.log"; }

# PR stacks: the brief's "Stacked on: <slug>" is the branch this one builds on and opens its PR against; "-" is the base.
# .fixloop/base keeps it for the sessions, task.py pr and merge_base.sh (which moves it down once the branch below merges).
brief="$WT/.fixloop/brief.md"; [ -f "$brief" ] || brief="$ROOT/briefs/$SLUG.md"
parent=$(sed -n 's/^Stacked on: \([^ ]*\).*/\1/p' "$brief" 2>/dev/null | tr -d '\r' | head -n 1)
if [ -n "$parent" ] && [ "$parent" != - ]; then FROM="${BRANCH_PREFIX}${SLUG_PREFIX}${parent}"; else FROM="$BASE"; fi
if [ ! -d "$WT" ] || [ ! -s "$WT/.fixloop/base" ]; then
    # The branch below merged before this one started (retire.sh then deletes it): build on what it merged into, as
    # merge_base.sh does
    while [ "$FROM" != "$BASE" ]; do
        below=$(gh pr view "$FROM" --repo "$GH_REPO" --json state,baseRefName --jq '"\(.state) \(.baseRefName)"' 2>/dev/null)
        [ "${below%% *}" = MERGED ] || break
        log "$FROM has merged into ${below#* }: building on ${below#* }"; FROM="${below#* }"
    done
fi
if [ ! -d "$WT" ]; then
    git -C "$REPO" fetch -q origin "$FROM" || { log "STOP: stacked on $FROM, which isn't on origin yet"; exit 1; }
    if git -C "$REPO" show-ref --quiet "refs/heads/$BR"; then
        git -C "$REPO" worktree add -q "$WT" "$BR" || { log "STOP: worktree add failed"; exit 1; }
    else
        git -C "$REPO" worktree add -q -b "$BR" "$WT" "origin/$FROM" || { log "STOP: worktree add failed"; exit 1; }
    fi
    log "worktree $WT on $BR from $FROM at $(git -C "$WT" rev-parse --short HEAD)"
fi
cd "$WT" || exit 1
mkdir -p .fixloop/state .fixloop/logs .fixloop/handoffs
[ -s .fixloop/base ] || echo "$FROM" > .fixloop/base
[ -f .fixloop/brief.md ] || cp "$ROOT/briefs/$SLUG.md" .fixloop/brief.md || { log "STOP: no briefs/$SLUG.md"; exit 1; }
[ -f .fixloop/status.json ] || "$PYTHON" -c "
import json; json.dump({'slug':'$SLUG','branch':'$BR','status':'todo','phase':None,'pr':None,'notes':[],'reviews':[],'summary':''},
open('.fixloop/status.json','w',encoding='utf8'),indent=1)"
export LOOP_STATE="$(cygpath -m "$WT/.fixloop")"

# Progress = the task's state without its timestamped notes (the end gate makes every session add one), plus HEAD and the
# working tree. Two sessions in a row that change none of these and no note stop the chain; four that only add notes do too.
fingerprint() { { "$PYTHON" -c "import json; d=json.load(open('.fixloop/status.json',encoding='utf8')); d.pop('notes',None); print(json.dumps(d,sort_keys=True))"
                  git rev-parse HEAD; git status --porcelain; } 2>/dev/null | sha1 | cut -c1-12; }
notes_fp() { "$PYTHON" -c "import json; print(json.load(open('.fixloop/status.json',encoding='utf8')).get('notes'))" 2>/dev/null | sha1 | cut -c1-12; }

n=$(ls .fixloop/logs/session-*.jsonl 2>/dev/null | wc -l)
started=0; strikes=0; soft=0; last_end=""
while :; do
    st=$("$PYTHON" "$ROOT/task.py" status)
    case "$st" in awaiting_owner|needs_owner|blocked|done)
        log "chain stops: $st · $("$PYTHON" -c "import json;print(json.load(open('.fixloop/status.json',encoding='utf8')).get('summary',''))")"; break ;; esac
    started=$((started + 1)); n=$((n + 1))
    if [ "$started" -gt "$MAX_SESSIONS" ]; then
        log "STOP: reached MAX_SESSIONS=$MAX_SESSIONS"; "$PYTHON" "$ROOT/task.py" block "chain reached $MAX_SESSIONS sessions without finishing" >/dev/null; break
    fi

    prompt=".fixloop/state/prompt-$n.md"
    {
        echo "Session $n of branch $BR (task $SLUG). Now: $(date '+%Y-%m-%d %H:%M'). Worktree: $(cygpath -m "$WT")."
        echo; echo "## Task status"; "$PYTHON" "$ROOT/task.py" show
        echo; echo "## Hand-off from the previous session"
        if [ -f .fixloop/HANDOFF.md ]; then cat .fixloop/HANDOFF.md
        elif [ -n "$last_end" ]; then echo "(none: the previous session ended with '$last_end' without writing one)"
        else echo "(none: this is the first session)"; fi
        if [ -f .fixloop/state/last_stop.json ]; then
            echo; echo "## The previous session was force-stopped by the context guard"; cat .fixloop/state/last_stop.json; echo
            echo "It may have stopped mid-step. Check git status/log and task.py notes before redoing anything."
        fi
        echo; echo "Begin by reading .fixloop/brief.md, then carry on from the current phase."
    } > "$prompt"
    [ -f .fixloop/HANDOFF.md ] && mv .fixloop/HANDOFF.md ".fixloop/handoffs/$n-in.md"
    [ -f .fixloop/state/last_stop.json ] && mv .fixloop/state/last_stop.json ".fixloop/state/stop-before-$n.json"

    fp_before=$(fingerprint); notes_before=$(notes_fp)
    pin=$("$PYTHON" "$ROOT/task.py" pin)   # the role this session plays: plan or code
    date +%s > .fixloop/state/session_start
    log "session $n start (status $st, $pin pin: $("$PYTHON" "$ROOT/agent_run.py" pin "$pin"))"
    # agent_run.py starts the role's agent on its model (re-read from loop.conf, so crew.py set applies from the next
    # session), feeds it the runbook and the prompt, keeps its context in bounds and prints the session's result line.
    awake_mark
    res=$("$PYTHON" "$ROOT/agent_run.py" session "$pin" --prompt "$prompt" \
        --system "$(cygpath -m "$ROOT/runbook.md")" --settings "$(cygpath -m "$ROOT/settings.json")" \
        --log ".fixloop/logs/session-$n.jsonl" --err ".fixloop/logs/session-$n.err")
    rc=$?
    slept=$(slept_since)   # the computer slept during the session: its calls may have failed, through no fault of its own
    IFS='|' read -r sub cost turns apierr text <<< "$res"
    if [ "$sub" = agent_missing ]; then   # the pin's agent isn't installed (or was removed): not a session, not a strike
        n=$((n - 1))
        log "STOP: $text"; "$PYTHON" "$ROOT/task.py" block "$text" >/dev/null; break
    fi
    if [ "$apierr" = usage_limit_reached ] || [ "$apierr" = rate_limit_error ]; then
        # The account hit its usage limit. Not a session, not a strike: hand the next session what this one was handed
        # (unless it wrote its own hand-off before the limit hit), wait for the reset, then go on. Any other preflight
        # refusal while waiting stops the chain, as the start-up preflight does.
        [ -f .fixloop/HANDOFF.md ] || { [ -f ".fixloop/handoffs/$n-in.md" ] && mv ".fixloop/handoffs/$n-in.md" .fixloop/HANDOFF.md; }
        [ -f .fixloop/state/last_stop.json ] || { [ -f ".fixloop/state/stop-before-$n.json" ] && mv ".fixloop/state/stop-before-$n.json" .fixloop/state/last_stop.json; }
        log "usage limit ($text): waiting for the reset; checking every 30 minutes"
        started=$((started - 1))
        while sleep 1800; do
            pf=$("$ROOT/preflight.sh" "$pin")
            [ "$pf" = ok ] && break
            if ! grep -qiE "limit" <<<"$pf"; then
                log "STOP: preflight refused while waiting for the limit: $pf"
                "$PYTHON" "$ROOT/task.py" block "preflight refused while waiting for a usage limit: $pf" >/dev/null; break 2
            fi
            log "still limited"
        done
        log "usage limit lifted: carrying on"; continue
    fi
    kind=""
    [ -f .fixloop/state/last_stop.json ] && kind=$("$PYTHON" -c "import json; print(json.load(open('.fixloop/state/last_stop.json')).get('kind',''))")
    last_end="${kind:-$sub}"
    echo "$n|$last_end|$cost|$turns|$(date +%s)" >> .fixloop/state/sessions.txt
    log "session $n end: $last_end · \$$cost · $turns turns · rc=$rc · $("$PYTHON" "$ROOT/task.py" status)$([ "$slept" -gt 0 ] && echo " · the computer slept $(duration "$slept")")"
    case "$kind" in wrong-model|guard-error)
        log "STOP: guard ($kind)"; "$PYTHON" "$ROOT/task.py" block "context guard stopped the chain: $kind" >/dev/null; break ;; esac
    if [ "$(fingerprint)" != "$fp_before" ]; then
        strikes=0; soft=0
    elif [ "$(notes_fp)" = "$notes_before" ] && [ "$slept" -gt 0 ]; then
        log "no progress in session $n, but the computer slept for $(duration "$slept") during it: not a strike"
    elif [ "$(notes_fp)" = "$notes_before" ]; then
        strikes=$((strikes + 1)); log "no progress in session $n (strike $strikes of 2)"
        if [ "$strikes" -ge 2 ]; then "$PYTHON" "$ROOT/task.py" block "two sessions in a row made no progress" >/dev/null; log "STOP: no progress"; break; fi
    else
        soft=$((soft + 1)); log "session $n only added notes ($soft of 4 in a row)"
        if [ "$soft" -ge 4 ]; then "$PYTHON" "$ROOT/task.py" block "four sessions in a row only added notes" >/dev/null; log "STOP: notes only"; break; fi
    fi
done
