#!/usr/bin/env bash
# Live drive of `fm-control <task> successor` on a disposable lab home with the
# Scott-shaped fixture. The caller's real Claude session takes the lab home lock
# through bin/fm-lock.sh, so the verb runs as the real lock-owning main.
# Usage: drive-successor.sh <worktree> <lab-home>
set -u
WT_REPO=$1; LAB=$2
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_GATE_REFUSE_BYPASS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
TASK=fm-lab-scott-task
OLD=fm/$TASK; SUCC=fm/$TASK-v2
FX=$LAB/fx
CTL="bash $WT_REPO/bin/fm-control.sh"
step() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
snap() { # <tag>
  mkdir -p "$LAB/snap/$1"
  cp "$FM_HOME/state/$TASK.meta" "$LAB/snap/$1/meta"
  cp "$FM_HOME/data/$TASK/brief.md" "$LAB/snap/$1/brief"
  git -C "$FX/project" for-each-ref --format='%(refname) %(objectname)' > "$LAB/snap/$1/refs"
  git -C "$FX/gate.git" for-each-ref --format='%(refname) %(objectname)' > "$LAB/snap/$1/gate-refs"
  (cd "$FX/slots/22/project" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256; git status --porcelain=v2 --branch) > "$LAB/snap/$1/copy"
  ls "$FM_HOME/state" > "$LAB/snap/$1/state-list"
}
same() { # <a> <b> <what>
  if diff -r "$LAB/snap/$1" "$LAB/snap/$2" >/dev/null; then echo "CHECK same($1,$2): $3 -> IDENTICAL"; else echo "CHECK same($1,$2): $3 -> DIFFERENT"; diff -r "$LAB/snap/$1" "$LAB/snap/$2"; fi
}

step "build the Scott-shaped fixture under the lab home (task id renamed to $TASK)"
mkdir -p "$FX" "$LAB/tools"
sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$TASK/" "$WT_REPO/tests/fixtures/fm-scott-task-shape.sh" > "$LAB/tools/maker.sh"
bash "$LAB/tools/maker.sh" "$FX"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
mv "$FX/home/state/$TASK.meta" "$FX/home/state/$TASK.status" "$FX/home/state/$TASK.inbox" "$FM_HOME/state/"
mv "$FX/home/data/$TASK" "$FM_HOME/data/"
P=$(git -C "$FX/project" rev-parse "refs/heads/$SUCC")
S=$(git -C "$FX/project" rev-parse "refs/heads/$OLD")
M=$(git -C "$FX/project" rev-parse main)
echo "S(old branch tip)=$S P(pipeline head = successor tip)=$P M(root/main)=$M"
echo "--- task record before"; cat "$FM_HOME/state/$TASK.meta"
echo "--- brief before"; cat "$FM_HOME/data/$TASK/brief.md"

step "take the lab home lock as this real Claude session (bin/fm-lock.sh)"
run bash "$WT_REPO/bin/fm-lock.sh"
run bash "$WT_REPO/bin/fm-lock.sh" status
snap before

step "ADVERSARIAL: a worker session (FM_TASK_ID set) calls the verb"
run env FM_TASK_ID=$TASK $CTL $TASK successor --branch "$SUCC" --tip "$P" --note "worker try"
snap after-worker; same before after-worker "worker call changed nothing"

step "ADVERSARIAL: first admission with no --tip"
run $CTL $TASK successor --branch "$SUCC" --note "no tip"
snap after-notip; same before after-notip "missing --tip changed nothing"

step "ADVERSARIAL: first admission with a wrong --tip (the root commit M every branch shares)"
run $CTL $TASK successor --branch "$SUCC" --tip "$M" --note "root tip"
snap after-roottip; same before after-roottip "wrong --tip changed nothing"

step "ADVERSARIAL: names outside the task's name family or otherwise inadmissible"
git -C "$FX/project" branch develop "$P"
git -C "$FX/project" branch "fm/${TASK}v2" "$P"
for name in develop "fm/${TASK}v2" "$OLD" main "fm/$TASK-*" "archive/$TASK-pipeline-${P:0:8}"; do
  run $CTL $TASK successor --branch "$name" --tip "$P" --note "bad name"
done
snap after-names
git -C "$FX/project" branch -D develop "fm/${TASK}v2" >/dev/null
snap after-names-clean; same before after-names-clean "bad-name calls changed nothing (after removing the two scratch branches this driver made)"

step "ADVERSARIAL (R3-1): the worker plants archive/$TASK-pipeline-<root 8 hex> at the root commit, then Main is asked to admit fm/$TASK-foo by --tip <root>"
git -C "$FX/project" branch "archive/$TASK-pipeline-${M:0:8}" "$M"
git -C "$FX/project" branch "fm/$TASK-foo" "$M"
cp "$FM_HOME/state/$TASK.meta" "$LAB/snap/planted-meta-before"
run $CTL $TASK successor --branch "fm/$TASK-foo" --tip "$M" --note "planted archive"
cmp -s "$LAB/snap/planted-meta-before" "$FM_HOME/state/$TASK.meta" && echo "CHECK planted-archive admission: record unchanged" || echo "CHECK planted-archive admission: RECORD CHANGED"

step "HAPPY: Main admits $SUCC with --tip = pipeline head P read from the run record"
run $CTL $TASK successor --branch "$SUCC" --tip "$P" --note "Scott v2 custody: the pipeline head lives on the successor branch"
snap after-admit
echo "--- record diff before -> after"; diff "$LAB/snap/before/meta" "$LAB/snap/after-admit/meta"
echo "--- brief diff before -> after"; diff "$LAB/snap/before/brief" "$LAB/snap/after-admit/brief"
for p in refs gate-refs copy; do cmp -s "$LAB/snap/before/$p" "$LAB/snap/after-admit/$p" && echo "CHECK $p unchanged by admission: IDENTICAL" || echo "CHECK $p unchanged by admission: DIFFERENT"; done

step "IDEMPOTENT: the same call again"
run $CTL $TASK successor --branch "$SUCC" --tip "$P" --note "Scott v2 custody: the pipeline head lives on the successor branch"
snap after-repeat; same after-admit after-repeat "repeat call changed nothing"

step "ADVERSARIAL: a different second successor while one is recorded"
git -C "$FX/project" branch "fm/$TASK-v3" "$P"
run $CTL $TASK successor --branch "fm/$TASK-v3" --tip "$P" --note "second"
git -C "$FX/project" branch -D "fm/$TASK-v3" >/dev/null
snap after-second; same after-admit after-second "second successor refused, nothing changed"
