# Shared helpers for the live private Web server scenarios. Sourced after $CODE, $HOME_LAB and $LAB are set.
say() { printf '\n=== %s\n' "$*"; }
start_server() { # <tag> <session-a> [<session-b>]
  local tag=$1 a=$2 b=${3:-}
  local dir="$LAB/$tag"; mkdir -p "$dir/commands" "$dir/dsh" "$dir/home"
  python3 - "$dir/launch.yml" "$CODE" "$HOME_LAB" "$dir" "$DRIVER" "$a" "$b" <<'PY'
import json, sys
out, code, home, d, driver, a, b = sys.argv[1:]
rows=[{"id":"firstmate-primary","name":code+"/.dsh/fm-primary.mjs","config":{"root":code,"home":home,"sessionId":a}}]
if b: rows.append({"id":"firstmate-primary-b","name":code+"/.dsh/fm-primary.mjs","config":{"root":code,"home":home,"sessionId":b}})
rows.append({"id":"fm-lab-driver","name":driver,"config":{"home":home,"commands":d+"/commands"}})
json.dump([{"id":"session-persistence-jsonl","config":{"root":d+"/dsh/sessions","compression":"none"}},{"insert":rows}], open(out,"w"), indent=1)
PY
  ( cd "$HOME_LAB" && exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u DSH_PROFILE -u DSH_SESSION_ID -u DSH_SHELL -u HERDR_ENV -u TMUX -u TMUX_PANE \
      HOME="$dir/home" DSH_HOME="$dir/dsh" FM_POLL=1 FM_CHECK_INTERVAL=1 \
      dsh --profile web --patch "$dir/launch.yml" --no-open --host 127.0.0.1 --port 0 ) > "$dir/server.log" 2>&1 &
  eval "SERVER_$tag=$!"
  SERVERS="${SERVERS:-} $!"
  local n=0
  until [ "$n" -gt 200 ] || grep -q 'http://127' "$dir/server.log" 2>/dev/null; do sleep 0.25; n=$((n+1)); done
  # The printed launch token never goes in the evidence.
  sed -E 's/token=[A-Za-z0-9_.-]+/token=REDACTED/' "$dir/server.log" | head -8
}
cmd() { # <tag> <op> <id>
  local dir="$LAB/$1/commands" n; n=$(( $(cat "$LAB/.cmd-n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LAB/.cmd-n"
  printf '{"op":"%s","id":"%s"}' "$2" "$3" > "$dir/$n.tmp"; mv "$dir/$n.tmp" "$dir/$n.cmd"
  local i=0; until [ -f "$dir/$n.reply" ] || [ "$i" -gt 400 ]; do sleep 0.1; i=$((i+1)); done
  cat "$dir/$n.reply" 2>/dev/null || echo '{"ok":false,"error":"driver timeout"}'; echo
}
pair() { printf 'state/.lock=[%s] state/.lock-session=[%s]\n' "$(cat "$STATE/.lock" 2>/dev/null || echo ABSENT)" "$(cat "$STATE/.lock-session" 2>/dev/null || echo ABSENT)"; }
events() { jq -c 'with_entries(select(.key!="at" and .key!="pid" and .key!="id"))' "$STATE/.dsh-primary-events.jsonl" 2>/dev/null; }
errors() { jq -c 'select(.event=="release-error") | .detail' "$STATE/.dsh-primary-events.jsonl" 2>/dev/null; }
count() { jq -c --arg e "$1" 'select(.event==$e)' "$STATE/.dsh-primary-events.jsonl" 2>/dev/null | wc -l | tr -d ' '; }
wait_count() { local i=0; until [ "$(count "$1")" -ge "$2" ] || [ "$i" -gt "${3:-300}" ]; do sleep 0.1; i=$((i+1)); done; [ "$(count "$1")" -ge "$2" ]; }
stop_servers() { for p in ${SERVERS:-}; do kill "$p" 2>/dev/null || :; done; sleep 2; for p in ${SERVERS:-}; do kill -9 "$p" 2>/dev/null || :; done; }
