# Helpers sourced after env.sh. A row = one fresh lab workspace whose pane runs
# a recipient, and the labmate record bound to that pane.
UUID=5a3eec19-de12-4999-bed2-bbd561089154
GEN=g-lab-1
ID=labmate
META="$FM_HOME/state/$ID.meta"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr; . "$ROOT/bin/fm-launch-proof-lib.sh"

write_meta() { # <pane> <ws> <tab> [legacy]
  { echo "window=$SESSION:$1"; echo "endpoint_task_id=$ID"; echo "worktree=$WT"; echo "project=$LAB/proj"
    echo "harness=claude"; echo "kind=secondmate"; echo "mode=secondmate"; echo "yolo=off"
    echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SESSION"
    echo "herdr_workspace_id=$2"; echo "herdr_tab_id=$3"; echo "herdr_pane_id=$1"
    [ "${4:-}" = legacy ] || echo "launch_proof=env-v1"
    echo "spawn_gen=$GEN"; echo "home=$WT"; } > "$META"
}

new_row() { # <row> <recipient: unpinned|unreadable|pinned|elsewhere|shell> [legacy]
  ROW=$1; KEYLOG="$LAB/keys-$ROW.log"; : > "$KEYLOG"
  local ws info cmd
  ws=$(herdr workspace create --cwd "$WT" --label "fm-$ID-$ROW" --no-focus)
  WS=$(printf '%s' "$ws" | jq -r '.result.workspace.workspace_id')
  PANE=$(herdr pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
  TAB=$(herdr pane get "$PANE" | jq -r '.result.pane.tab_id')
  case "$2" in
    unpinned)   cmd="env -u FM_SPAWN_GEN KEYLOG=$KEYLOG $LAB/bin/claude --resume $UUID" ;;
    unreadable) cmd="env -i KEYLOG=$KEYLOG $LAB/bin/claude --resume $UUID" ;;
    pinned)     cmd="env FM_SPAWN_GEN=$GEN KEYLOG=$KEYLOG $LAB/bin/claude --resume $UUID" ;;
    elsewhere)  cmd="env FM_SPAWN_GEN=g-other-launch KEYLOG=$KEYLOG $LAB/bin/claude --resume $UUID" ;;
    shell)      cmd='' ;;
  esac
  sleep 1
  if [ -n "$cmd" ]; then
    herdr pane send-text "$PANE" "cd $WT && $cmd" >/dev/null; herdr pane send-keys "$PANE" Enter >/dev/null
    local i; for i in $(seq 1 50); do herdr pane read "$PANE" --format text 2>/dev/null | grep -q 'fake-claude ready' && break; sleep 0.2; done
  fi
  write_meta "$PANE" "$WS" "$TAB" "${3:-}"
  sleep 0.5
}

probe() { # prints state, verdict, judged cause
  printf 'agent_state=%s\n' "$(fm_backend_agent_state herdr "$SESSION:$PANE")"
  printf 'verdict=%s\n' "$(fm_launch_proof_herdr "$META")"
  printf 'judged=%s\n' "$(fm_launch_proof_herdr_judge "$META" | tr '\t' '|')"
}

# Protected records: every file under both state dirs except the gate-refuse audit
# log and the reboot sweep's own bookkeeping (cursor, notice), which the contract
# keeps apart from task-record mutation; those are listed separately.
state_hash() { (cd "$FM_HOME/state" && find . -type f ! -name 'guard-events.jsonl' ! -name '.reboot-recovery-cursor' ! -name '*.reboot-notice' -exec shasum -a 256 {} + | LC_ALL=C sort; cd "$WT/state" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort) | shasum -a 256 | cut -c1-16; }
keys() { printf 'keylog_bytes=%s' "$(wc -c < "$KEYLOG" | tr -d ' ')"; [ -s "$KEYLOG" ] && printf ' hex=%s' "$(xxd -p "$KEYLOG" | tr -d '\n' | cut -c1-80)"; echo; }
screen() { herdr pane read "$PANE" --format text 2>/dev/null; }

consumer() { # <label> <cmd...>: run one consumer, print rc, output, keys and state change
  local label=$1 out rc=0 h0 h1 s0 s1; shift
  h0=$(state_hash); s0=$(screen | shasum | cut -c1-12)
  out=$(env -u NO_MISTAKES_GATE_BYPASS "$@" 2>&1) || rc=$?
  h1=$(state_hash); s1=$(screen | shasum | cut -c1-12)
  printf -- '--- [%s] %s\n$ %s\nrc=%s\n%s\n' "$ROW" "$label" "$*" "$rc" "$out"
  printf '%s state_changed=%s screen_changed=%s\n' "$(keys)" "$([ "$h0" = "$h1" ] && echo no || echo yes)" "$([ "$s0" = "$s1" ] && echo no || echo yes)"
}
save_row() { printf 'ROW=%q PANE=%q WS=%q TAB=%q KEYLOG=%q\n' "$ROW" "$PANE" "$WS" "$TAB" "$KEYLOG" > "$LAB/row.sh"; }
. "$(dirname "${BASH_SOURCE[0]}")/consumers.sh"
add_rival() { # a second live task record that names the same home and worktree
  { echo "window=$SESSION:w99:p99"; echo "endpoint_task_id=rival"; echo "worktree=$WT"; echo "project=$LAB/proj"
    echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "backend=herdr"; echo "herdr_session=$SESSION"
    echo "launch_proof=env-v1"; echo "spawn_gen=g-rival"; echo "home=$WT"; } > "$FM_HOME/state/rival.meta"
}
settle() { # <want>: wait until the pane's agent state reads <want> (up to 20s)
  local i s; for i in $(seq 1 40); do s=$(fm_backend_agent_state herdr "$SESSION:$PANE"); [ "$s" = "$1" ] && { echo "settled=$s"; return 0; }; sleep 0.5; done; echo "settle-failed last=$s"; return 1
}
meta_sha() { printf 'meta_sha=%s\n' "$(shasum -a 256 "$META" | cut -c1-16)"; }
env_facts() { # the product's own pid selector and env reader, on the current row
  local pid env; pid=$(fm_launch_proof_herdr_pid "$META") && echo "attributed_pid=$pid" || { echo "attributed_pid=NONE"; return; }
  if env=$(fm_remote_herdr_process_env "$pid"); then
    printf 'env_read=ok has_PATH=%s has_HOME=%s has_FM_SPAWN_GEN=%s\n' \
      "$(grep -c '^PATH=' <<< "$env")" "$(grep -c '^HOME=' <<< "$env")" "$(grep -c '^FM_SPAWN_GEN=' <<< "$env")"
  else echo env_read=failed; fi
}
