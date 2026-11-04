#!/usr/bin/env bash
# drive.sh <scenario-name> <pr-url> <copy: gone|<commit-ish>> [extra env...]
# Runs the REAL bin/fm-teardown.sh in a fresh marked lab home against a disposable
# partial clone of MrGTV-love/vernant, with the REAL gh reading the real forge.
# Only treehouse, tmux, docker and no-mistakes are stubbed (hard gates forbid the real ones).
set -u
WTREE=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6K36FZCVEQ6HZ97VFD9BZ03
L=/Users/charlesabrooker/tmp/fm-live-train.SeZNpF
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6K36FZCVEQ6HZ97VFD9BZ03
name=$1 pr=$2 copy=$3
PROJ=$L/vernant-origin-clone
ID=train-live-$name
BR=fm/$ID
cd "$WTREE"
unset NO_MISTAKES_GATE_UNUSED FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>"$L/$name.labenv.stderr")"
LAB=$FM_HOME
out=$E/live-$name.txt
{
  echo "# scenario: $name"
  echo "# lab home: $LAB"
  echo "# project: $PROJ (disposable blob:none clone of https://github.com/MrGTV-love/vernant, origin main $(git -C "$PROJ" rev-parse origin/main))"
  echo "# recorded pr: $pr"
  if [ "$copy" = gone ]; then
    WT=$L/copies/$ID   # never created: the copy is gone (record-only route)
    echo "# copy: none (recorded worktree $WT does not exist)"
  else
    WT=$L/copies/$ID
    mkdir -p "$L/copies"
    git -C "$PROJ" worktree add -q -b "$BR" "$WT" "$copy" 2>&1
    [ "${DIRTY:-0}" != 1 ] || printf "uncommitted edit\n" > "$WT/uncommitted-edit.txt"
    echo "# copy: $WT at $(git -C "$WT" rev-parse HEAD), status lines: $(git -C "$WT" status --porcelain | wc -l | tr -d ' ')"
  fi
  printf '%s\n' "window=firstmate:fm-$ID" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=live-$ID" "branch=$BR" "pr=$pr" > "$LAB/state/$ID.meta"
  touch "$LAB/state/.last-watcher-beat"
  : > "$LAB/config/fleet-ledger"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  tasks-axi add "$ID" "live train teardown check" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$LAB/data/backlog.md" >/dev/null
  if [ "${HOLD:-0}" = 1 ]; then
    echo "# captain hold: bin/fm-captain-hold.sh hold $ID"
    env PATH="$L/fakebin:$PATH" FM_HOME="$LAB" bin/fm-captain-hold.sh hold "$ID" --reason "captain must choose the follow-up" 2>&1 | sed 's/^/  hold> /'
  fi
  echo "# command: FM_HOME=$LAB PATH=<stubs: treehouse tmux docker no-mistakes>:\$PATH ${EXTRA_ENV:-} bin/fm-teardown.sh $ID"
  echo "----- stdout+stderr -----"
  export FM_LIVE_TREEHOUSE_LOG=$L/$name.treehouse.log
  rm -f "$FM_LIVE_TREEHOUSE_LOG"
  env ${EXTRA_ENV:-} PATH="${FAULT_BIN:+$FAULT_BIN:}$L/fakebin:$PATH" FM_HOME="$LAB" bin/fm-teardown.sh "$ID" 2>&1
  rc=$?
  echo "----- end -----"
  echo "exit=$rc"
  echo "task record present after: $([ -e "$LAB/state/$ID.meta" ] && echo yes || echo no)"
  echo "copy present after: $([ -d "$WT" ] && echo yes || echo no)"
  echo "treehouse calls: $(cat "$FM_LIVE_TREEHOUSE_LOG" 2>/dev/null | wc -l | tr -d ' ') $(cat "$FM_LIVE_TREEHOUSE_LOG" 2>/dev/null | tr '\n' ';')"
  echo "guard events (teardown-unlanded):"; grep -h teardown-unlanded "$LAB/state/guard-events.jsonl" 2>/dev/null | jq -c "{guard,rule,decision,source_ok}" || echo "  (none)"
  echo "fault injection bin: ${FAULT_BIN:-none}"
  if [ "${HOLD:-0}" = 1 ]; then
    echo "----- pending close record left by teardown -----"
    cat "$LAB/state/$ID.backlog-close" 2>&1
    printf 'Proceed with the landed train.\n' > "$L/$name.answer.txt"
    echo "# captain answer: bin/fm-captain-hold.sh answer $ID --decision-file <file>"
    env PATH="$L/fakebin:$PATH" FM_HOME="$LAB" bin/fm-captain-hold.sh answer "$ID" --decision-file "$L/$name.answer.txt" 2>&1 | sed 's/^/  answer> /'
    echo "----- held row after answer (--full) -----"
    tasks-axi show "$ID" --full --file "$LAB/data/backlog.md" 2>&1
  fi
  echo "----- backlog row after -----"
  tasks-axi show "$ID" --file "$LAB/data/backlog.md" 2>&1
  echo "----- backlog.md Done section -----"
  sed -n '/^## Done/,$p' "$LAB/data/backlog.md"
} > "$out" 2>&1
cat "$out"
# Remove the lab with the exact teardown line fm-lab-home printed.
td=$(grep -o '[^ ]*fm-lab-home.sh teardown .*' "$L/$name.labenv.stderr" | head -1)
echo "# lab teardown: $td" | tee -a "$out"
eval "$td" && echo "# lab removed: $([ -d "$LAB" ] && echo no || echo yes)" | tee -a "$out"
if [ "$copy" != gone ] && [ -d "$WT" ]; then git -C "$PROJ" worktree remove --force "$WT"; fi
git -C "$PROJ" branch -D "$BR" >/dev/null 2>&1 || true
