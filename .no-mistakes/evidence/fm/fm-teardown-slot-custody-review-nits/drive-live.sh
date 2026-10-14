#!/usr/bin/env bash
# Live driver: run the real bin/fm-teardown.sh against a disposable, marked lab
# FM_HOME with real git repos and real linked worktrees (no pool inventory).
# Only external side-effect tools are shimmed so nothing reaches the operator's
# real Treehouse pool, no-mistakes daemon, GitHub, or Docker:
#   treehouse   -> logs its argv to $LAB/treehouse.log (behaviour per scenario)
#   no-mistakes/gh/gh-axi/docker -> inert
# tmux is the real binary, isolated to the lab's private socket dir.
set -u
WT=${1:?worktree}
SCEN=${2:?scenario}
OUT=${3:?outdir}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/shim"
SMROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-sm.XXXXXX")
cleanup() { rm -rf "$LAB" "$SMROOT"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ID=fmlab-x1
PROJ="$LAB/projects/demo"
TASKWT="$LAB/worktrees/demo-x1"
git init -q --bare "$LAB/origin.git"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
git -C "$LAB/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$LAB/seed" push -q origin main
rm -rf "$LAB/seed"
git clone -q "$LAB/origin.git" "$PROJ"
git -C "$PROJ" remote set-head origin main
mkdir -p "$LAB/worktrees"
git -C "$PROJ" worktree add -q -b "fm/$ID" "$TASKWT" main

for t in no-mistakes gh gh-axi docker; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/shim/$t"
done
# Default treehouse: log + succeed.
cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/treehouse.log"
exit 0
SH
chmod +x "$LAB/shim/"*

write_meta() {  # <file> <id> <wt> <kind> [extra...]
  local f=$1 id=$2 wt=$3 kind=$4; shift 4
  { printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=%s\nmode=local-only\nspawn_gen=lab-%s\n' \
      "$id" "$id" "$wt" "$PROJ" "$kind" "$id"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$f"
}
printf 'Captain: drop this lab task; live validation fixture.\n' > "$LAB/drop.txt"

teardown() {
  ( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
      FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" NM_HOME="$LAB/nm" \
      FM_TREEHOUSE_RETURN_LOCK_RETRIES="${RETRIES:-1}" FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
      PATH="$LAB/shim:$PATH" "$WT/bin/fm-teardown.sh" "$@" )
}
show_state() {
  say "--- after-state"
  say "task meta present:      $([ -e "$LAB/state/$ID.meta" ] && echo yes || echo NO)"
  say "task worktree present:  $([ -e "$TASKWT/.git" ] && echo yes || echo NO)"
  [ -n "${NESTED:-}" ] && say "nested copy present:    $([ -e "$NESTED/.git" ] && echo yes || echo NO)"
  say "treehouse calls:        $( [ -f "$LAB/treehouse.log" ] && wc -l < "$LAB/treehouse.log" | tr -d ' ' || echo 0)"
  [ -f "$LAB/treehouse.log" ] && sed 's/^/  treehouse /' "$LAB/treehouse.log"
  say "registered worktrees:"; git -C "$PROJ" worktree list | sed "s#$LAB#\$LAB#g; s/^/  /"
}

run_scenario() {
  local rc=0
  say "=== scenario: $SCEN"
  say "LAB=$LAB (marked lab home)"
  "$@" > "$LAB/out" 2> "$LAB/err" || rc=$?
  say "--- fm-teardown.sh exit code: $rc"
  say "--- stderr"; sed "s#$LAB#\$LAB#g" "$LAB/err"
  say "--- stdout"; sed "s#$LAB#\$LAB#g" "$LAB/out"
  show_state
}

case "$SCEN" in
  nonpool-nested-refused)
    write_meta "$LAB/state/$ID.meta" "$ID" "$TASKWT" ship
    NESTED="$TASKWT/.claude/worktrees/parked"
    git -C "$PROJ" worktree add -q --detach "$NESTED" main
    say "fixture: plain linked worktree (no Treehouse pool inventory) with a registered nested copy at \$LAB/worktrees/demo-x1/.claude/worktrees/parked"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    say; say "=== follow the printed recovery: remove the nested copy by hand, then re-run teardown"
    git -C "$PROJ" worktree remove "$NESTED"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    ;;
  nonpool-clean-control)
    write_meta "$LAB/state/$ID.meta" "$ID" "$TASKWT" ship
    say "fixture: plain linked worktree, no nested copy (positive control)"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    ;;
  nonpool-nested-appears-before-retry)
    write_meta "$LAB/state/$ID.meta" "$ID" "$TASKWT" ship
    NESTED="$TASKWT/.claude/worktrees/parked"
    LOCKP=$(git -C "$TASKWT" rev-parse --git-path index.lock)
    cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/treehouse.log"
if [ ! -e "$LAB/attempted" ]; then
  touch "$LAB/attempted"
  git -C "$PROJ" worktree add -q --detach "$NESTED" main
  echo "fatal: Unable to create '$LOCKP': File exists." >&2
  exit 128
fi
exit 0
SH
    say "fixture: first provider return fails with a transient index.lock and a nested copy gets registered before the retry"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    ;;
  slot-vanishes-before-retry)
    write_meta "$LAB/state/$ID.meta" "$ID" "$TASKWT" ship
    cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/treehouse.log"
mv "$TASKWT" "$LAB/retained-copy" || exit 2
echo "fatal: Unable to create 'index.lock': File exists." >&2
exit 128
SH
    say "fixture: first provider return moves the target away and fails with a transient index.lock"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    say "retained copy present:  $([ -e "$LAB/retained-copy/.git" ] && echo yes || echo NO)"
    ;;
  secondmate-child-nested-refused)
    SMHOME="$SMROOT/secondmate-home"
    mkdir -p "$SMHOME/state" "$SMHOME/data" "$SMHOME/config" "$SMHOME/projects"
    printf '%s\n' "$ID" > "$SMHOME/.fm-secondmate-home"
    write_meta "$LAB/state/$ID.meta" "$ID" "$TASKWT" secondmate "home=$SMHOME"
    CHILDWT="$SMROOT/worktrees/child-a"
    git -C "$PROJ" worktree add -q -b fm/child-a "$CHILDWT" main
    write_meta "$SMHOME/state/child-a.meta" child-a "$CHILDWT" ship
    : > "$SMHOME/state/child-a.status"
    NESTED="$CHILDWT/.claude/worktrees/parked"
    git -C "$PROJ" worktree add -q --detach "$NESTED" main
    say "fixture: secondmate task whose child-a owns a plain linked worktree (no pool) holding a registered nested copy"
    run_scenario teardown "$ID" --force --drop-file "$LAB/drop.txt"
    say "child worktree present: $([ -e "$CHILDWT/.git" ] && echo yes || echo NO)"
    say "child record present:   $([ -e "$SMHOME/state/child-a.meta" ] && echo yes || echo NO)"
    ;;
  *) echo "unknown scenario $SCEN" >&2; exit 2 ;;
esac
