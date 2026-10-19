#!/usr/bin/env bash
# Shared helpers for the live Slack-plane lab. Source this, do not run it.
# Real: bin/fm-slack-*.sh, bin/fm_slack.py (urllib), bin/fm_slack_watch.py,
#       bin/fm-captain-hold.sh, tasks-axi, fm-check-register.sh.
# Fake: only the Slack server (loopback), reached through sitecustomize.py.
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M59ZARSPM5WA50K9D683VMFR
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M59ZARSPM5WA50K9D683VMFR
LABTOOLS=$EV/lab
FAKE_TOKEN=xoxb-lab-fake-token-0001
OWNER=U0LABOWNER1
export PYTHONDONTWRITEBYTECODE=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

lab_start() {
  LABROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-lab.XXXXXX")
  python3 "$LABTOOLS/fake_slack.py" "$LABROOT/port" "$FAKE_TOKEN" >"$LABROOT/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 100); do [ -s "$LABROOT/port" ] && break; sleep 0.1; done
  [ -s "$LABROOT/port" ] || { echo "fake server did not start"; return 1; }
  export LAB_SLACK_PORT=$(cat "$LABROOT/port")
  export PYTHONPATH=$LABTOOLS
}
lab_stop() { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$LABROOT"; }

admin() {  # <endpoint> [k=v ...]
  local ep=$1; shift; local args=()
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -s -G "http://127.0.0.1:$LAB_SLACK_PORT/_admin/$ep" ${args[@]+"${args[@]}"}
}
reply() { admin reply "thread=$1" "text=$2" "${@:3}" >/dev/null; }   # <thread> <text> [user=..]
react() { admin react "ts=$1" "name=$2" "${@:3}" >/dev/null; }
unreact() { admin unreact "ts=$1" "name=$2" "${@:3}" >/dev/null; }

# new_home <make-home scenario> [env overrides as KEY=VALUE ...]
new_home() {
  HOME_DIR=$(mktemp -d "$LABROOT/home.XXXXXX")
  bash "$REPO/tests/fixtures/slack/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  shift
  cat > "$HOME_DIR/.env" <<ENV
SLACK_BOT_TOKEN=$FAKE_TOKEN
FM_SLACK_DM_USER=$OWNER
FM_SLACK_ALLOWED_AUTHORS=$OWNER
FM_SLACK_POLL_MAX_ANSWERS=20
ENV
  for kv in "$@"; do printf '%s\n' "$kv" >> "$HOME_DIR/.env"; done
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  CAPTAIN=$REPO/bin/fm-captain-hold.sh
}

# thread ts for a task key from the plane's own journal
thread_ts() {
  python3 - "$FM_STATE_OVERRIDE/slack-watch/state.json" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for occ, rec in s['threads'].items():
    if rec['key'] == sys.argv[2]:
        print(rec['ts']); break
PY
}
thread_field() {
  python3 - "$FM_STATE_OVERRIDE/slack-watch/state.json" "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for occ, rec in s['threads'].items():
    if rec['key'] == sys.argv[2]:
        print(rec.get(sys.argv[3])); break
PY
}
thread_texts() {  # <thread-ts>: every message in the thread, as posted
  admin state | python3 -c '
import json, sys
st = json.load(sys.stdin)
for m in st["messages"]:
    if m["ts"] == sys.argv[1] or m.get("thread_ts") == sys.argv[1]:
        who = "BOT " if m.get("bot_id") else "HUMAN "
        print("--- " + who + m["ts"] + " user=" + m["user"])
        print(m["text"])
' "$1"
}
answer_line() {
  "$REPO/bin/fm-tasks-axi.sh" show "$1" --full | grep -o 'Answer: [^"]*' | sed 's/^Answer: //;s/\\n.*//' | tr -d '\n'
}
label_line() {
  "$REPO/bin/fm-tasks-axi.sh" show "$1" --full | grep -o 'Answer as shown to the captain: [^"]*' | sed 's/^Answer as shown to the captain: //;s/\\n.*//' | tr -d '\n'
}
is_open() { set +e; "$CAPTAIN" open "$1" >/dev/null; local rc=$?; set -e; [ "$rc" = 0 ] && echo open || echo closed; }
bot_count() {  # count of bot messages in thread
  admin state | python3 -c '
import json, sys
st = json.load(sys.stdin)
print(sum(1 for m in st["messages"] if m.get("bot_id") and (m["ts"] == sys.argv[1] or m.get("thread_ts") == sys.argv[1])))
' "$1"
}
requests_total() { admin log | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
requests_unauth() { admin log | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if not r["auth_ok"]))'; }
mirror() { "$REPO/bin/fm-slack-mirror.sh" "$@"; }
poll() { "$REPO/bin/fm-slack-poll.sh" "$@"; }
step() { printf '\n=== %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }
expect_eq() { [ "$1" = "$2" ] && ok "$3 (= $2)" || bad "$3: expected [$2] got [$1]"; }
expect_has() { printf '%s' "$1" | grep -qF -- "$2" && ok "$3 (has: $2)" || bad "$3: missing [$2] in [$1]"; }
expect_not() { printf '%s' "$1" | grep -qF -- "$2" && bad "$3: unexpected [$2]" || ok "$3 (absent: $2)"; }
