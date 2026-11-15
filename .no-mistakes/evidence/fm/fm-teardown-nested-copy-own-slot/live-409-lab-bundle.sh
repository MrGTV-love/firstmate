#!/usr/bin/env bash
# Live lab driver: the real bin/fm-teardown.sh, the real treehouse binary on a
# disposable pool (TREEHOUSE_ROOT), real git with a local bare origin, real tmux
# on the lab's private socket dir, and the real tasks-axi on the lab backlog.
# Only the GitHub / no-mistakes service CLIs (gh, gh-axi, no-mistakes) are
# stubbed so nothing reaches a real forge or the shared daemon.
# Usage: live-409-lab.sh <worktree> <out-dir> <shape: plain|prior> <claim: mine|other|none>
#                        <variant: landed|slot-unlanded|copy-dirty> <force: yes|no> <leftovers: yes|no> [rerun: no|land] [slotmode: tmuxget|lease]
#   slotmode=tmuxget (default): the task window runs an interactive `treehouse get` like bin/fm-spawn.sh,
#   so the slot is process-held, not durably leased. slotmode=lease: `treehouse get --lease`.
#   rerun=land: after the first run, push the slot root HEAD to origin main and run a plain teardown again.
set -u
ROOT=$1 OUT=$2 SHAPE=$3 CLAIM=$4 VARIANT=$5 FORCE=$6 LEFT=$7 RERUN=${8:-no} SLOTMODE=${9:-tmuxget}
mkdir -p "$OUT"
unset TMUX TMUX_PANE
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do unset "$v"; done
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>"$OUT/lab-env.stderr")"
base=${TMPDIR:-/tmp}; base=${base%/}
W=$(mktemp -d "$base/fm-live-world.XXXXXX")
W=$(cd "$W" && pwd -P)
cleanup() {
  tmux kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 && rm -rf "$FM_HOME"
  chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"
}
trap cleanup EXIT
export TREEHOUSE_ROOT="$W/th" NM_HOME="$W/nm" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$W/fakebin" "$NM_HOME"
cat > "$W/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$W/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1 ;; esac
exit 0
SH
cat > "$W/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$W/fakebin"/*

# Project with a local bare origin.
git init -q --bare -b main "$W/origin.git"
git init -q -b main "$W/seed"
printf 'hello\n' > "$W/seed/README.md"; printf '.claude/\n' > "$W/seed/.gitignore"
git -C "$W/seed" add . && git -C "$W/seed" commit -qm init && git -C "$W/seed" push -q "$W/origin.git" main
PROJ="$FM_HOME/projects/proj"
git clone -q "$W/origin.git" "$PROJ"

# A real pool slot leased through the real treehouse.
if [ "$SLOTMODE" = lease ]; then
  SLOT=$(cd "$PROJ" && treehouse get --lease --lease-holder task-x1 --no-fetch 2>"$OUT/treehouse-get.stderr")
else
  tmux new-session -d -x 200 -y 50 -s firstmate -n fm-task-x1 -c "$PROJ" \
    "env TREEHOUSE_ROOT='$TREEHOUSE_ROOT' SHELL=/bin/bash treehouse get --no-fetch; exec sleep 3600"
  SLOT=
  for _ in $(seq 1 60); do
    SLOT=$(tmux display-message -p -t firstmate:fm-task-x1 '#{pane_current_path}' 2>/dev/null)
    case "$SLOT" in "$TREEHOUSE_ROOT"/*) break ;; *) SLOT= ;; esac
    sleep 0.5
  done
  [ -n "$SLOT" ] || { echo "treehouse get did not enter a slot" >&2; tmux capture-pane -p -t firstmate:fm-task-x1 >&2; exit 3; }
fi
SLOT=$(cd "$SLOT" && pwd -P)
SLOTDIR=$(dirname "$SLOT")
NESTED="$SLOT/.claude/worktrees/task-x1-v2"
mkdir -p "$SLOT/.claude/worktrees"
git -C "$SLOT" worktree add -q -b fm/task-x1-v2 "$NESTED" origin/main
case "$CLAIM" in
  mine) printf 'task=task-x1\nhome=%s\n' "$FM_HOME" > "$SLOTDIR/.fm-slot-owner" ;;
  other) printf 'task=other-task\nhome=%s\n' "$FM_HOME" > "$SLOTDIR/.fm-slot-owner" ;;
  none) : ;;
esac
case "$VARIANT" in
  slot-unlanded) printf 'slot work\n' > "$SLOT/slot.txt"; git -C "$SLOT" add slot.txt; git -C "$SLOT" commit -qm "slot work" ;;
  copy-dirty) printf 'dirty\n' > "$NESTED/dirty.txt"; git -C "$NESTED" add dirty.txt ;;
  bundle)
    # d5 shape: the slot root HEAD holds an unlanded commit; the nested copy builds on it with
    # its own unlanded commit; one verified bundle of the copy holds both.
    printf 'slot work\n' > "$SLOT/slot.txt"; git -C "$SLOT" add slot.txt; git -C "$SLOT" commit -qm "slot work"
    git -C "$NESTED" reset -q --hard "$(git -C "$SLOT" rev-parse HEAD)"
    printf 'copy work\n' > "$NESTED/copy.txt"; git -C "$NESTED" add copy.txt; git -C "$NESTED" commit -qm "copy work"
    bundle="$W/bundles/task-x1.bundle"; mkdir -p "${bundle%/*}" "$FM_HOME/data/task-x1"
    git -C "$NESTED" bundle create "$bundle" --all 2>/dev/null && git -C "$NESTED" bundle verify "$bundle" >/dev/null 2>&1 &&
    digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
    tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
    printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/task-x1/preservation-bundles.tsv"
    ;;
esac

# The task record, endpoint, inbox, status, tasktmp and backlog row.
TT="$W/tasktmp"; mkdir -p "$TT"; printf 'scratch\n' > "$TT/scratch.txt"
S="$FM_HOME/state"; D="$FM_HOME/data"
{
  echo "window=firstmate:fm-task-x1"; echo "endpoint_task_id=task-x1"
  echo "worktree=$NESTED"; echo "project=$PROJ"; echo "harness=claude"; echo "kind=ship"
  echo "mode=no-mistakes"; echo "branch=fm/task-x1-v2"; echo "tasktmp=$TT"
  echo "spawn_gen=live-gen-1"
  [ "$SHAPE" = prior ] && echo "prior_worktree=$SLOT"
} > "$S/task-x1.meta"
mkdir -p "$S/task-x1.inbox"; printf 'steer\n' > "$S/task-x1.inbox/001.msg"
printf 'working: live lab\n' > "$S/task-x1.status"
[ "$SLOTMODE" = lease ] && tmux new-session -d -s firstmate -n fm-task-x1 'sleep 3600'
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$D/backlog.md"
tasks-axi add task-x1 "live lab task" --kind ship --file "$D/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$D/backlog.md" >/dev/null
if [ "$VARIANT" = bundle ] && [ "${HOLD:-yes}" = yes ]; then
  "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --owner captain \
    --reason "Land or drop the unlanded commits of task-x1: preserved in bundle $bundle, recorded tips $tips." > "$OUT/captain-hold.out" 2>&1
  echo "captain-hold rc=$?" >> "$OUT/captain-hold.out"
fi
if [ "$LEFT" = yes ]; then
  printf 'id=task-x1\ndata=%s\nspawn_gen=live-gen-1\ncleanup_incomplete=0\narg=--note\narg=dropped\n' "$D" > "$S/task-x1.backlog-close"
  printf 'spawn_gen=live-gen-1\nslot=\n' > "$S/task-x1.teardown-return-pending"
fi
printf 'Captain: drop the copy; its commits are on main and a verified bundle holds them.\n' > "$W/drop.txt"

snapshot() {
  {
    for dir in "$S" "$D" "$TT"; do
      [ -d "$dir" ] || { echo "absent $dir"; continue; }
      find "$dir" ! -name '*.lock' ! -path '*.lock/*' ! -name '.last-watcher-beat' ! -name '.guard-watcher-stale-banner' ! -name '.fm-lab*' | LC_ALL=C sort | while IFS= read -r f; do
        if [ -f "$f" ]; then printf 'file %s %s\n' "${f#$W}" "$(shasum -a 256 < "$f" | cut -c1-16)"; else printf 'dir %s\n' "$f"; fi
      done
    done
    for dir in "$NESTED" "$SLOT"; do
      [ -d "$dir" ] || { echo "tree $dir absent"; continue; }
      find "$dir" -name .git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf 'file %s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -c1-16)"; done
    done
    echo "nested-head $(git -C "$NESTED" rev-parse HEAD 2>/dev/null || echo absent)"
    echo "slot-head $(git -C "$SLOT" rev-parse HEAD 2>/dev/null || echo absent)"
    git -C "$PROJ" for-each-ref --format='ref %(refname) %(objectname)' refs/heads
    echo "claim $( [ -f "$SLOTDIR/.fm-slot-owner" ] && tr '\n' ' ' < "$SLOTDIR/.fm-slot-owner" || echo absent)"
    echo "tmux-windows $(tmux list-windows -a -F '#S:#W' 2>/dev/null | tr '\n' ' ')"
  } > "$1"
}

{
  echo "== setup =="
  echo "shape=$SHAPE claim=$CLAIM variant=$VARIANT force=$FORCE leftovers=$LEFT"
  echo "FM_HOME=$FM_HOME (marked lab home)"; echo "TREEHOUSE_ROOT=$TREEHOUSE_ROOT"
  echo "slotmode=$SLOTMODE"; echo "slot=$SLOT"; echo "nested copy=$NESTED"
  echo "--- task-x1.meta"; cat "$S/task-x1.meta"
  echo "--- claim"; cat "$SLOTDIR/.fm-slot-owner" 2>/dev/null || echo "(no claim)"
  echo "--- treehouse status (before)"; (cd "$PROJ" && treehouse status 2>&1)
  echo "--- tmux windows (before)"; tmux list-windows -a -F '#S:#W'
  echo "--- state dir (before)"; ls -1 "$S"
} > "$OUT/transcript.txt" 2>&1
snapshot "$OUT/snapshot.before"

args=(task-x1)
[ "$FORCE" = yes ] && args+=(--force --drop-file "$W/drop.txt")
umask 022
rc=0
(cd "$PROJ" && PATH="$W/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" "${args[@]}") > "$OUT/teardown.stdout" 2> "$OUT/teardown.stderr" || rc=$?
snapshot "$OUT/snapshot.after"

{
  echo; echo "== bin/fm-teardown.sh ${args[*]} =="; echo "exit=$rc"
  echo "--- stdout"; cat "$OUT/teardown.stdout"
  echo "--- stderr"; cat "$OUT/teardown.stderr"
  echo; echo "== after =="
  echo "nested copy: $([ -e "$NESTED" ] && echo kept || echo removed)"
  echo "slot root dir: $([ -d "$SLOT" ] && echo present || echo absent)"
  echo "claim: $([ -e "$SLOTDIR/.fm-slot-owner" ] && echo kept || echo removed)"
  for n in meta status inbox backlog-close teardown-return-pending; do echo "task-x1.$n: $([ -e "$S/task-x1.$n" ] && echo kept || echo removed)"; done
  echo "tasktmp: $([ -e "$TT" ] && echo kept || echo removed)"
  echo "--- treehouse status (after)"; (cd "$PROJ" && treehouse status 2>&1)
  echo "--- tmux windows (after)"; tmux list-windows -a -F '#S:#W' 2>&1
  echo "--- backlog (after)"; cat "$D/backlog.md"
  echo "--- umask during run: $(umask)"
  echo "--- data/task-x1 file modes (after)"
  find "$D/task-x1" -type f -exec stat -f '%Lp %N' {} \; 2>/dev/null | sed "s#$D/##"
  echo "--- snapshot diff (before -> after)"
  if diff "$OUT/snapshot.before" "$OUT/snapshot.after"; then echo "(no difference)"; fi
} >> "$OUT/transcript.txt" 2>&1
if [ "$RERUN" = land ]; then
  git -C "$SLOT" push -q origin HEAD:main 2>>"$OUT/transcript.txt"
  git -C "$PROJ" fetch -q origin
  rc2=0
  (cd "$PROJ" && PATH="$W/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1) > "$OUT/rerun.stdout" 2> "$OUT/rerun.stderr" || rc2=$?
  {
    echo; echo "== slot root HEAD pushed to origin main (landed); plain re-run: bin/fm-teardown.sh task-x1 =="; echo "exit=$rc2"
    echo "--- stdout"; cat "$OUT/rerun.stdout"; echo "--- stderr"; grep -v '^●' "$OUT/rerun.stderr"
    echo "nested copy: $([ -e "$NESTED" ] && echo kept || echo removed)"
    echo "claim: $([ -e "$SLOTDIR/.fm-slot-owner" ] && echo kept || echo removed)"
    for n in meta status inbox backlog-close teardown-return-pending; do echo "task-x1.$n: $([ -e "$S/task-x1.$n" ] && echo kept || echo removed)"; done
    echo "tasktmp: $([ -e "$TT" ] && echo kept || echo removed)"
    echo "--- treehouse status (after re-run)"; (cd "$PROJ" && treehouse status 2>&1)
    echo "--- tmux windows (after re-run)"; tmux list-windows -a -F '#S:#W' 2>&1
  } >> "$OUT/transcript.txt" 2>&1
  echo "exit=$rc rerun_exit=$rc2"
else
  echo "exit=$rc"
fi
