#!/usr/bin/env bash
# Live check of the worker write-confinement profile against packed-refs.
# Usage: live-packed-refs.sh <repo-root> <builder.py> <label>
# Builds a disposable home, primary checkout, gate and task worktree under a
# fresh /tmp root, generates the real profile with <builder.py>, and drives
# real git commands under /usr/bin/sandbox-exec with that profile.
set -u
REPO=$1 BUILDER=$2 LABEL=$3
ROOT=$(mktemp -d /tmp/nm-live-packed.XXXXXX)
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$ROOT/gitconfig-global"
# Stands in for the host's global fetch.prune=true.
printf '[user]\n\tname = Live\n\temail = live@example.invalid\n[fetch]\n\tprune = true\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
unset GIT_CONFIG_COUNT
H=$ROOT/home P=$H/projects/project WT=$ROOT/pool/task GATE=$ROOT/gate.git
mkdir -p "$ROOT/claude" "$H/config" "$H/data/task" "$H/state" "$H/projects" "$ROOT/pool"
touch "$H/state/task.meta" "$H/state/other.meta"
git init -q "$P" && git -C "$P" commit -q --allow-empty -m init
git -C "$P" commit -q --allow-empty -m second
REAL=$(git -C "$P" rev-parse HEAD) FORGED=$(git -C "$P" rev-parse HEAD~1)
git -C "$P" branch fm/other "$REAL"
git init -q --bare "$GATE"
git -C "$P" remote add no-mistakes "$GATE"
git -C "$P" push -q no-mistakes main main:fm/gone 2>/dev/null
git -C "$P" fetch -q no-mistakes
git -C "$P" stash list >/dev/null
# Pack every ref the way gc leaves them: fm/other and the remote-tracking refs
# now exist only as lines in packed-refs. The task worktree is added after, so
# its own branch is loose as a fresh spawn leaves it.
git -C "$P" pack-refs --all
git -C "$P" worktree add -q -b fm/task "$WT"
# One packed shared stash entry and one packed own archive branch.
( cd "$P" && echo x > stashme && git stash push -q -u -m packed-entry )
git -C "$P" branch archive/task-pipeline-89abcdef "$REAL"
git -C "$P" pack-refs --all --exclude refs/heads/fm/task  # keep the own branch loose
git --git-dir="$GATE" update-ref -d refs/heads/fm/gone
echo "== [$LABEL] fixture: fm/other=$REAL (packed), forged target=$FORGED"
grep -E 'fm/other|fm/gone' "$P/.git/packed-refs"
PROFILE=$ROOT/profile.sb
python3 "$BUILDER" --worktree "$WT" --home "$H" --config "$H/config" --projects "$H/projects" \
  --data "$H/data/task" --state "$H/state" --task task --branch fm/task --harness claude --agent-dir "$ROOT/claude" --claude-session 11111111-2222-4333-8444-555555555555 --profile "$PROFILE" \
  || { echo "builder failed"; exit 1; }
echo "== [$LABEL] profile packed-refs rules:"; grep -n 'packed-refs\|refs/replace' "$PROFILE"
SB() { /usr/bin/sandbox-exec -f "$PROFILE" "$@"; }
# The GIT_CONFIG entry fm-spawn.sh appends to a confined launch.
LAUNCH_GIT='fm_n=${GIT_CONFIG_COUNT:-0}; export "GIT_CONFIG_KEY_$fm_n=fetch.prune" "GIT_CONFIG_VALUE_$fm_n=false" GIT_CONFIG_COUNT=$((fm_n + 1)); unset fm_n; '

echo; echo "== [$LABEL] attack 1: rewrite packed-refs in place with a forged fm/other line"
FORGED_FILE=$(sed "s|^$REAL refs/heads/fm/other\$|$FORGED refs/heads/fm/other|" "$P/.git/packed-refs")
SB /bin/bash -c 'printf "%s\n" "$1" > "$2"' _ "$FORGED_FILE" "$P/.git/packed-refs"; echo "exit=$?"
echo "rev-parse fm/other -> $(git -C "$P" rev-parse fm/other)"
git -C "$P" update-ref refs/heads/fm/other "$REAL" && git -C "$P" pack-refs  # undo a landed attack

echo; echo "== [$LABEL] attack 2: write a forged file to packed-refs.lock and rename it over packed-refs"
SB /bin/bash -c 'printf "%s\n" "$1" > "$2.lock" && mv "$2.lock" "$2"' _ "$FORGED_FILE" "$P/.git/packed-refs"; echo "exit=$?"
rm -f "$P/.git/packed-refs.lock"
echo "rev-parse fm/other -> $(git -C "$P" rev-parse fm/other)"
git -C "$P" update-ref refs/heads/fm/other "$REAL" && git -C "$P" pack-refs  # undo a landed attack

echo; echo "== [$LABEL] attack 3: git update-ref -d of the packed fm/other from the worktree"
SB git -C "$WT" update-ref -d refs/heads/fm/other; echo "exit=$?"
echo "rev-parse fm/other -> $(git -C "$P" rev-parse --verify -q fm/other || echo MISSING)"
git -C "$P" rev-parse -q --verify fm/other >/dev/null || { git -C "$P" branch fm/other "$REAL"; git -C "$P" pack-refs; }

echo; echo "== [$LABEL] legit: own commit, gate push, archive ref, loose stash push/pop"
SB /bin/bash -c "cd '$WT' && echo change > f && git add f && git commit -q -m work && echo commit=ok"
SB git -C "$WT" push -q no-mistakes fm/task 2>&1; echo "push exit=$?"
SB git -C "$WT" branch archive/task-submitted-0123abcd; echo "own archive create exit=$?"
SB git -C "$WT" branch -D archive/task-submitted-0123abcd; echo "own loose archive delete exit=$?"
SB /bin/bash -c "cd '$WT' && echo s > g && git stash push -q -u -m live && git stash pop -q && echo stash=ok"

echo; echo "== [$LABEL] attack 4: git pack-refs --all from the worktree"
SB git -C "$WT" pack-refs --all 2>&1; echo "pack-refs exit=$?"
echo; echo "== [$LABEL] attack 5: git replace of the task HEAD"
SB git -C "$WT" replace -f HEAD "$FORGED" 2>&1; echo "replace exit=$?"
echo "replace refs: $(git -C "$P" for-each-ref refs/replace | wc -l | tr -d ' ')"
git -C "$P" replace -d HEAD >/dev/null 2>&1
echo; echo "== [$LABEL] decided refusals: drop the packed shared stash entry, delete the packed own archive"
SB git -C "$WT" stash drop 2>&1; echo "stash drop exit=$?"
echo "refs/stash: $(git -C "$P" rev-parse --verify -q refs/stash || echo MISSING)"
SB git -C "$WT" branch -D archive/task-pipeline-89abcdef 2>&1; echo "packed own archive delete exit=$?"
echo "archive/task-pipeline-89abcdef: $(git -C "$P" rev-parse --verify -q archive/task-pipeline-89abcdef || echo MISSING)"
echo; echo "== [$LABEL] fetch with host fetch.prune=true and the gate's fm/gone deleted, WITHOUT the launch entry"
SB git -C "$WT" fetch no-mistakes 2>&1; echo "exit=$?"
echo; echo "== [$LABEL] same fetch WITH the launch GIT_CONFIG entry fm-spawn.sh adds"
SB /bin/bash -c "$LAUNCH_GIT"'echo "fetch.prune=$(git config --get fetch.prune)"; git -C "$0" fetch no-mistakes 2>&1; echo "exit=$?"' "$WT"
echo "fm/gone still tracked: $(git -C "$P" rev-parse --verify -q refs/remotes/no-mistakes/fm/gone >/dev/null && echo yes || echo no)"

echo; echo "== [$LABEL] git gc from the worktree"
SB git -C "$WT" gc -q 2>&1; echo "gc exit=$?"
echo; echo "== [$LABEL] observation: own branch packed by Main's gc, refs/heads/fm folder gone, then a worker commit"
git -C "$P" pack-refs --all; ls "$P/.git/refs/heads" | sed 's/^/refs\/heads entry: /'
SB /bin/bash -c "cd '$WT' && echo more >> f && git commit -q -am more 2>&1; echo commit exit=\$?"
echo; echo "== [$LABEL] final: fm/other -> $(git -C "$P" rev-parse fm/other) (real $REAL)"
