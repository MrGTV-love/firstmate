#!/usr/bin/env bash
# run-case.sh <case> <action-script> [spawn-env-assignments...]
# One live lab scenario: fresh lab home, private tmux server, real treehouse pool,
# scratch origin/project, real bin/fm-spawn.sh typed into the lab primary pane.
set -u
CASE=$1 ACTION=$2; shift 2
SPAWN_ENV="$*"
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6HSPCJNFEMN8N3ZF46DWQ85
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M6HSPCJNFEMN8N3ZF46DWQ85
OUT=$EV/live-$CASE.txt
D=/tmp/fm-lab-driver
cd "$WT" || exit 1
labenv_err=$(mktemp)
eval "$(bin/fm-lab-home.sh env 2>"$labenv_err")"
TEARDOWN=$(grep -E 'teardown' "$labenv_err" | tail -1 | sed 's/^[^/]*//')
S=$(mktemp -d /tmp/fm-lab-scratch.XXXXXX)
HOLDER_PID=
cleanup() {
  [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null
  tmux -L fm-lab kill-server 2>/dev/null
  [ ! -f /tmp/fm-lab-driver/stub.pids ] || kill $(cat /tmp/fm-lab-driver/stub.pids) 2>/dev/null
  pkill -f "$FM_HOME" 2>/dev/null; sleep 1
  rm -f /tmp/fm-lab-driver/stub.pids /tmp/fm-lab-driver/launch.log
  rm -rf "/tmp/fm-lab-$CASE" "/tmp/fm-lab-$CASE+"*
  sleep 0; "$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 || echo "teardown failed: $TEARDOWN" >> "$OUT"
  chmod -R u+w "$FM_HOME" 2>/dev/null; rm -rf "$FM_HOME"
  [ -d "$FM_HOME" ] && echo "lab home left: $FM_HOME" >> "$OUT"
  chmod -R u+w "$S" 2>/dev/null
  rm -rf "$S" "$labenv_err"
}
trap cleanup EXIT
rm -f /tmp/fm-lab-driver/stub.pids /tmp/fm-lab-driver/launch.log
"$D/mkproject.sh" "$S" >/dev/null
[ -z "${FM_LAB_PRE:-}" ] || FM_LAB_SCRATCH="$S" bash "$FM_LAB_PRE" "$S" > "$S/pre.log" 2>&1
id="lab-$CASE"
mkdir -p "$FM_HOME/data/$id"
printf '# Task\n## Captain'"'"'s intent\nLab scout for %s.\n\n## Firstmate spec\nDo nothing.\n' "$CASE" > "$FM_HOME/data/$id/brief.md"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
{
  echo "# live lab case: $CASE"
  echo "# head: $(git -C "$WT" rev-parse HEAD)"
  echo "# FM_HOME=$FM_HOME (marked lab home)  TMUX_TMPDIR=$TMUX_TMPDIR  tmux socket: -L fm-lab"
  echo "# scratch: $S  TREEHOUSE_ROOT=$S/pool  treehouse $(treehouse --version 2>&1)"
  echo "# action script ($ACTION):"; sed 's/^/#   /' "$ACTION"
  [ -z "${FM_LAB_PRE:-}" ] || { echo "# pre-spawn origin publish ($FM_LAB_PRE):"; sed 's/^/#   /' "$FM_LAB_PRE"; }
  echo "# treehouse get runs through /tmp/fm-lab-driver/bin/treehouse (real treehouse get --no-fetch) so the slot is cut stale"
  [ -z "$SPAWN_ENV" ] || echo "# spawn env: $SPAWN_ENV"
} > "$OUT"
export TREEHOUSE_ROOT="$S/pool" SHELL="$D/labshell" FM_LAB_ACTION="$ACTION" FM_LAB_SCRATCH="$S" \
  PATH="$D/bin:$PATH"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab -f /dev/null new-session -d -s primary -x 220 -y 50 -c "$WT" -e FM_HOME="$FM_HOME" \
  /bin/bash --noprofile --norc
tmux -L fm-lab send-keys -t primary "$SPAWN_ENV bin/fm-spawn.sh $id '$S/project' --scout > '$S/spawn.out' 2>&1; echo EXIT=\$? >> '$S/spawn.out'" Enter
for _ in $(seq 1 900); do
  if [ -e "$S/.need-holder" ] && [ -z "$HOLDER_PID" ]; then
    slot=$(cat "$S/slot-path"); (cd "$slot" && exec sleep 900) & HOLDER_PID=$!
    echo "# driver started unrelated holder pid $HOLDER_PID with cwd $slot" >> "$OUT"
    touch "$S/.holder-go"
  fi
  grep -q '^EXIT=' "$S/spawn.out" 2>/dev/null && break
  sleep 1
done
slot=$(cat "$S/slot-path" 2>/dev/null || echo none)
{
  echo; echo "## \$ bin/fm-spawn.sh $id $S/project --scout"; cat "$S/spawn.out" 2>/dev/null
  echo; echo "## seeding action log"; cat "$S/action.log" 2>/dev/null
  echo; echo "## slot: $slot"
  echo "origin/main tip (bare origin): $(git -C "$S/origin.git" rev-parse main)"
  echo "slot HEAD after spawn: $(git -C "$slot" rev-parse HEAD 2>&1)"
  echo; echo "## tmux windows on lab server"; tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} cwd=#{pane_current_path} cmd=#{pane_current_command}' 2>&1
  echo; echo "## worker window screen"; tmux -L fm-lab capture-pane -p -t "primary:fm-$id" 2>&1 | grep -v '^$' | tail -15
  echo; echo "## stub harness launch log"; cat /tmp/fm-lab-driver/launch.log 2>/dev/null || echo "(no harness launched)"
  echo; echo "## slot snapshot diff: seeded state (before spawn) vs after spawn  [HEAD, show-ref, index digest, sha256 of every file outside .git]"
  /tmp/fm-lab-driver/snap.sh "$slot" > "$S/after.snap" 2>&1
  diff "$S/before.snap" "$S/after.snap" && echo "(identical)"
  echo; echo "## seeded snapshot"; cat "$S/before.snap"
} >> "$OUT" 2>&1
[ -z "${FM_LAB_POST:-}" ] || bash "$FM_LAB_POST" "$slot" >> "$OUT" 2>&1
echo "wrote $OUT"
