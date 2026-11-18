#!/usr/bin/env bash
# Builds the task's old (no successor) and new (recorded successor) write profiles
# with the production generator, the same arguments bin/fm-spawn.sh passes, and
# runs real git writes under /usr/bin/sandbox-exec with each.
# Usage: drive-kernel.sh <worktree> <lab-home>
set -u
WT_REPO=$1; LAB=$2; export FM_HOME=$LAB GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
T=fm-lab-scott-task; OLD=fm/$T; SUCC=$(sed -n 's/^successor_branch=//p' $LAB/state/$T.meta)
FX=$LAB/fx; COPY=$FX/slots/22/project; PROJ=$FX/project; K=$LAB/kernel; mkdir -p $K
P=$(git -C $PROJ rev-parse refs/heads/$SUCC); S=$(git -C $PROJ rev-parse refs/heads/$OLD)
git -C $PROJ update-ref refs/heads/fm/other-task "$S"
# a second task record so the generator knows fm/other-task belongs to another task
printf 'kind=ship\nbranch=fm/other-task\nproject=%s\nworktree=%s/other-wt\n' "$PROJ" "$FX" > $LAB/state/other-task.meta
gen() { python3 "$WT_REPO/bin/fm-write-confinement.py" --worktree "$COPY" --home "$LAB" --config "$LAB/config" --projects "$LAB/projects" \
  --data "$LAB/data/$T" --state "$(cd $LAB/state && pwd -P)" --task "$T" --harness claude --claude-session 11111111-2222-4333-8444-555555555555 \
  --branch "$OLD" --profile "$1" "${@:2}"; }
echo "recorded successor: $SUCC"
gen $K/old.sb && echo "built old.sb (no successor)"
gen $K/new.sb --successor-branch "$SUCC" && echo "built new.sb (--successor-branch $SUCC)"
echo "--- diff old.sb new.sb (every changed line)"; diff $K/old.sb $K/new.sb
echo "--- generator refuses an out-of-family or wildcard successor"
gen $K/bad1.sb --successor-branch develop; echo "[exit $?]"
gen $K/bad2.sb --successor-branch "fm/$T-*"; echo "[exit $?]"
attempt() { # <profile> <label> <cmd...>
  local pf=$1 label=$2; shift 2
  local before; before=$(git -C $PROJ for-each-ref --format='%(refname) %(objectname)' refs/heads | shasum | cut -c1-12)
  local out rc; out=$(/usr/bin/sandbox-exec -f "$pf" "$@" 2>&1); rc=$?
  local after; after=$(git -C $PROJ for-each-ref --format='%(refname) %(objectname)' refs/heads | shasum | cut -c1-12)
  printf '%-4s %-48s exit=%-3s refs %s->%s | %s\n' "$(basename $pf .sb)" "$label" "$rc" "$before" "$after" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-170)"
}
echo "--- kernel runs (cwd = the task copy)"
cd $COPY
attempt $K/new.sb "move successor (update-ref)" git update-ref refs/heads/$SUCC "$S"
git -C $PROJ update-ref refs/heads/$SUCC "$P"
git -C $PROJ update-ref -d refs/heads/$SUCC
attempt $K/new.sb "git branch <successor> <P> (create)" git branch $SUCC "$P"
attempt $K/new.sb "delete successor" git branch -D $SUCC
git -C $PROJ update-ref refs/heads/$SUCC "$P"
attempt $K/old.sb "move successor (update-ref)" git update-ref refs/heads/$SUCC "$S"
git -C $PROJ update-ref -d refs/heads/$SUCC
attempt $K/old.sb "git branch <successor> <P> (create)" git branch $SUCC "$P"
git -C $PROJ update-ref refs/heads/$SUCC "$P"
attempt $K/new.sb "own branch move (update-ref)" git update-ref refs/heads/$OLD "$P"
git -C $PROJ update-ref refs/heads/$OLD "$S"
attempt $K/new.sb "create fm/unrelated" git branch fm/unrelated "$P"
attempt $K/new.sb "create successor-as-prefix $SUCC-x" git branch $SUCC-x "$P"
attempt $K/new.sb "create successor-as-suffix fm/pre-$SUCC" git branch fm/pre-$SUCC "$P"
attempt $K/new.sb "mkdir refs/heads/fm/pre-fm (same dir)" mkdir -p $PROJ/.git/refs/heads/fm/pre-fm
attempt $K/new.sb "create old-as-prefix $OLD-x" git branch $OLD-x "$P"
attempt $K/new.sb "move another task's branch fm/other-task" git update-ref refs/heads/fm/other-task "$P"
attempt $K/new.sb "delete another task's branch fm/other-task" git branch -D fm/other-task
attempt $K/new.sb "create planted-family fm/$T-foo2" git branch fm/$T-foo2 "$P"
echo "--- unconfined controls (prove the refused commands are valid on their own)"
for n in fm/unrelated $SUCC-x fm/pre-$SUCC $OLD-x fm/$T-foo2; do git branch $n "$P" && echo "unconfined create $n: ok" && git branch -q -D $n; done
rmdir $PROJ/.git/refs/heads/fm/pre-fm 2>/dev/null; true
echo "fm/other-task now: $(git -C $PROJ rev-parse refs/heads/fm/other-task) (S=$S)"
git -C $PROJ update-ref -d refs/heads/fm/other-task; rm -f $LAB/state/other-task.meta
