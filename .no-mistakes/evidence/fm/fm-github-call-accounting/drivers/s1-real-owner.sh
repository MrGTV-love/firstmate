#!/usr/bin/env bash
# Real owner + real gh-axi + real ps in a marked lab home. Bounded: about 3 rate_limit reads, then 1 more on restart.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; make_caller "$FIX"
S="$FM_HOME/state/github-accounting"
echo "--- before start status"; python3 "$OWNER" status
# C1 outlives a quota interval; C2 is short; C3 survives the owner stop.
( FIX_SECS=22 "$FIX/fixture-parent.sh" "$FIX/gh" api graphql --field query=CANARY_A_viewer --token CANARY_B_ghp_abc & echo $! > "$FIX/c1.pid"; wait ) &
( FIX_SECS=3 "$FIX/fixture-parent.sh" "$FIX/gh" pr create --title CANARY_C_title --body CANARY_D_body & wait ) &
( FIX_SECS=120 GH_TOKEN=CANARY_G_env "$FIX/fixture-parent.sh" "$FIX/gh" issue list --repo CANARY_E_org/repo & echo $! > "$FIX/c3.pid"; wait ) &
( FIX_SECS=8 bash -c "$FIX/gh api graphql --field q=CANARY_F_shell; true" & wait ) &
sleep 0.3
echo "--- start"; date +%s; python3 "$OWNER" start; echo "start_exit=$?"
echo "--- start again (idempotent)"; python3 "$OWNER" start; echo "start2_exit=$?"
echo "--- second run refused"; python3 "$OWNER" run --duration 1; echo "second_run_exit=$?"
echo "--- records while running is busy"; python3 "$OWNER" records >/dev/null; echo "records_exit=$?"
echo "--- status"; python3 "$OWNER" status
sleep 32
echo "--- stop"; time python3 "$OWNER" stop; echo "stop_exit=$?"
echo "--- status after stop"; python3 "$OWNER" status
C3=$(pgrep -f "$FIX/gh issue list" | head -1); echo "c3_alive_after_stop_pid=$C3"
python3 "$OWNER" records > "$EV/s1-run1-records.jsonl"; echo "records_exit=$?"
echo "--- new owner sees survivor as new process row"
python3 "$OWNER" start >/dev/null; sleep 2; python3 "$OWNER" stop >/dev/null
[ -n "$C3" ] && pkill -f "$FIX/gh issue list"
sleep 0.5
python3 "$OWNER" start >/dev/null; sleep 1; python3 "$OWNER" stop >/dev/null
python3 "$OWNER" records > "$EV/s1-all-records.jsonl"
echo "--- leftover owner processes"; pgrep -fl "$OWNER" | grep -v pgrep || echo none
echo "--- canary scan of raw state"; grep -l CANARY "$S"/* 2>/dev/null || echo "no CANARY in any state file"
ls -la "$S"
stat -f '%Lp %N' "$S" "$S/observations.sqlite"
pkill -f "$FIX/gh" 2>/dev/null; pkill -f "$FIX/fixture-parent" 2>/dev/null
wait 2>/dev/null
echo "FIX_PREFIX=$FIX"
echo "$FM_HOME" > "$EV/.s1-home"
tmux_dir=$TMUX_TMPDIR
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"; rm -f "$EV/.s1-home"
