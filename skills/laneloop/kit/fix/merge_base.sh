#!/usr/bin/env bash
# After the owner merges PRs: bring one open branch up to date with ITS base: the branch below it in its PR stack
# (.fixloop/base), or BASE at the bottom. A stack is brought up bottom-up: push each branch before the one above it.
# Once the branch below has merged, this one moves down onto that branch's own base, and its PR is retargeted. In a GitHub
# stack, GitHub has done both itself (and rebased the branch): the local branch takes origin's rebase, nothing is merged.
#   merge_base.sh <slug>                 fetch + merge origin/<its base>; prints the conflicted files (exit 3) or the clean merge;
#                                        a PR it couldn't retarget, or a rebase it couldn't take, prints INCOMPLETE (exit 4)
#                                        and changes nothing
#   merge_base.sh <slug> --commit "why"  after you resolved every conflict: commit the merge with attribution, start the gate
# Never push before the gate (or, for a clean re-merge, at least the build and the area's tests) has passed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/loop.conf"
source "$HERE/platform.sh"
cd "$WT_ROOT/$1" || { echo "no worktree for $1"; exit 2; }
base=$(tr -d '\r\n' < .fixloop/base 2>/dev/null); base="${base:-$BASE}"; was="$base"
while [ "$base" != "$BASE" ]; do   # the branch below merged: sit on what it merged into
    below=$(gh pr view "$base" --repo "$GH_REPO" --json state,baseRefName --jq '"\(.state) \(.baseRefName)"' 2>/dev/null)
    [ "${below%% *}" = MERGED ] || break
    echo "the branch below, $base, has merged into ${below#* }: this branch now sits on ${below#* }"
    base="${below#* }"
done
br=$(git branch --show-current)
own=$(gh pr view "$br" --repo "$GH_REPO" --json number,baseRefName,state --jq 'select(.state == "OPEN") | "\(.number) \(.baseRefName)"' 2>/dev/null)
if [ -n "$own" ] && [ "$base" != "$was" ] && [ "${own#* }" != "$was" ] && [ "${2:-}" != "--commit" ]; then
    # GitHub already moved this PR down: in a GitHub stack, merging the PR below retargets this one AND rebases (force-
    # pushes) its branch. Take that rebase; a merge on top would be refused as a non-fast-forward, or need a force-push.
    live="${own#* }"
    [ -z "$(git status --porcelain | grep -v '^??')" ] || { echo "working tree not clean:"; git status --short | head; exit 2; }
    # every tip the remote branch has had here: its tip before this fetch, and its reflog (which expires) for older ones
    seen="$(git rev-parse -q --verify "refs/remotes/origin/$br") $(git reflog show --format=%H "refs/remotes/origin/$br" 2>/dev/null)"
    git fetch -q origin "$br"
    ahead=$(git rev-list --count HEAD --not "origin/$br")
    unpushed=$(git rev-list --count HEAD --not "origin/$br" $seen)
    if [ "$ahead" -gt "$unpushed" ]; then   # commits once pushed are gone from origin/$br: it was rebased
        if [ "$unpushed" -gt 0 ]; then
            echo "INCOMPLETE: GitHub moved PR #${own%% *} onto $live and rebased $br, but $unpushed local commit(s) were never"
            echo "pushed and would be lost. Push nothing; replay them onto origin/$br by hand, then run merge_base.sh again."
            exit 4
        fi
        git reset -q --keep "origin/$br" || { echo "INCOMPLETE: couldn't move $br to origin/$br"; exit 4; }
        echo "$live" > .fixloop/base
        echo "GitHub moved PR #${own%% *} onto $live and rebased it: $br now matches origin/$br ($(git log --oneline -1 | cat))"
        echo "nothing merged or retargeted; run the gate before the next push, and never force-push"
        exit 0
    # the stacks API answer names pull_requests only when the PR is in a stack ([] otherwise, a 404 without stacks)
    elif gh api "repos/$GH_REPO/stacks?pull_request=${own%% *}" 2>/dev/null | grep -q '"pull_requests"'; then
        echo "INCOMPLETE: PR #${own%% *} is in a GitHub stack and now on $live, but GitHub hasn't rebased $br yet."
        echo "Nothing changed; run merge_base.sh again once it has."
        exit 4
    fi
fi
if [ -n "$own" ] && [ "${own#* }" != "$base" ]; then
    # The new base is kept only once the PR targets it: a branch merged onto a base its PR doesn't target shows the wrong diff
    if err=$(gh pr edit "${own%% *}" --base "$base" --repo "$GH_REPO" 2>&1 >/dev/null); then
        echo "PR #${own%% *} retargeted: ${own#* } -> $base"
    else
        echo "INCOMPLETE: PR #${own%% *} couldn't be retargeted to $base ($(echo "$err" | tail -1)); nothing merged, the branch"
        echo "still sits on $was. Fix that, then run merge_base.sh again."
        exit 4
    fi
fi
[ "$base" = "$was" ] || echo "$base" > .fixloop/base
attribution="Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
if [ "${2:-}" = "--commit" ]; then
    git rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "no merge in progress"; exit 2; }
    markers=$( { git diff --name-only --diff-filter=U; git diff --name-only HEAD; } | sort -u |
               while IFS= read -r f; do [ -f "$f" ] && grep -lE '^(<<<<<<<|>>>>>>>)( |$)' "$f"; done)
    [ -z "$markers" ] || { echo "still conflicted (markers left):"; echo "$markers"; exit 3; }
    git add -u   # stages the resolved files (tracked only: stray untracked files stay out); merge-added files are staged
    left=$(git diff --name-only --diff-filter=U)
    [ -z "$left" ] || { echo "still unmerged: $left"; exit 3; }
    git commit -q -m "Merge origin/$base into $(git branch --show-current)

${3:-}

$attribution" && git log --oneline -1 | cat
    "$PYTHON" "$HERE/gate.py" --start | head -1
    exit 0
fi
[ -z "$(git status --porcelain | grep -v '^??')" ] || { echo "working tree not clean:"; git status --short | head; exit 2; }
git fetch -q origin "$base"
before=$(git rev-parse HEAD)
if git merge --no-edit "origin/$base" >/dev/null 2>&1; then
    if [ "$(git rev-parse HEAD)" = "$before" ]; then
        echo "already up to date with origin/$base: nothing merged"; exit 0
    fi
    if ! git rev-parse -q --verify HEAD^2 >/dev/null; then
        echo "fast-forwarded to origin/$base (the branch had no commits of its own): $(git log --oneline -1 | cat)"; exit 0
    fi
    # Only a real merge commit made just now gets its message replaced.
    git commit -q --amend -m "Merge origin/$base into $(git branch --show-current)

$attribution"
    echo "clean merge: $(git log --oneline -1 | cat)"
    echo "files the branch shares with what landed (check them for semantic clashes):"
    mb=$(git merge-base HEAD^1 "origin/$base")
    comm -12 <(git diff --name-only "$mb" HEAD^1 | sort) <(git diff --name-only "$mb" "origin/$base" | sort)
else
    echo "CONFLICTS in:"; git diff --name-only --diff-filter=U; exit 3
fi
