#!/usr/bin/env bash
# Live relaunch before and after rerecord-slot, on the lab's private tmux server. The relaunch runs with a throwaway
# HOME so Claude workspace trust is never written into the operator's real ~/.claude.json.
E=$(cd "$(dirname "$0")" && pwd)
. "$E/rr-live-lib.sh"
cd "$WT_ROOT" || exit 1
relaunch() {
  mkdir -p "$FX/user-home"
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
    echo "\$ fm-control $RR_ID relaunch --note 'resume after the slot renewal'"
    HOME="$FX/user-home" CLAUDE_CONFIG_DIR="$FX/user-home/.claude" LAB_SLOT_RECORD=$MANIFEST \
      "$CONTROL" "$RR_ID" relaunch --note 'resume after the slot renewal' 2>&1 | grep -v '^fm-gate-refuse: gate agent'
    echo "exit=${PIPESTATUS[0]}" )
}
fixture; renew
tmux new-session -d -s fmses -n "fm-$RR_ID" -c "$COPY" 'exec /bin/zsh -f -i'; sleep 1
say "R1 the project renewed the durable record; relaunch WITHOUT rerecord-slot (the reported problem)"
b=$(inventory); m0=$(meta_sha)
relaunch
echo "record_unchanged=$([ "$m0" = "$(meta_sha)" ] && echo yes || echo no)"
tmux list-panes -a -F 'pane: #{session_name}:#{window_name} cmd=#{pane_current_command}'
say "R2 rerecord-slot, then the ordinary relaunch"
rr --manifest-sha "$(msha)" --note "$NOTE"
relaunch
sleep 3
tmux list-panes -a -F 'pane: #{session_name}:#{window_name} cmd=#{pane_current_command}'
say "H14 the relaunched real Claude agent is running in the task window -> a check reports it is not stopped"
bash -c '. "$1/bin/fm-backend.sh"; printf "backend agent state: %s\n" "$(fm_backend_agent_state tmux "$2")"' _ "$WT_ROOT" "fmses:fm-$RR_ID"
rr --check | grep -E 'stopped_proof|write_would|already|exit='
echo "journal:"; cat "$FM_HOME/state/$RR_ID.control-relaunch" 2>/dev/null
echo "slot lines after relaunch:"; slot_lines
echo "--- pane capture:"; tmux capture-pane -p -t "fmses:fm-$RR_ID" | sed '/^$/d' | tail -25
echo "FX=$FX"
