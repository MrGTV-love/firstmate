#!/usr/bin/env bash
# Shared setup and fast fixture inspectors for tests/fm-slack-watch*.test.sh.
# Every Slack call is a checked-in replay transcript; no socket is opened.
# FM_SLACK_NO_NETWORK closes the real transport for the whole suite.
# shellcheck disable=SC2034
set -euo pipefail
export FM_SLACK_NO_NETWORK=1
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
TMP=$(fm_test_tmproot fm-slack-watch)
FIX="$ROOT/tests/fixtures/slack"
# shellcheck source=tests/fixtures/slack/registered-gate.sh
. "$FIX/registered-gate.sh"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
HELPER="$ROOT/tests/fm_slack_watch_test.py"

assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
# grep reads its whole input (no -q, no early exit): under pipefail a grep that stopped at its first match left the writer with a broken pipe.
assert_contains() { printf '%s' "$1" | grep -- "$2" >/dev/null || fail "$3: missing [$2]"; }
assert_not_contains() { ! printf '%s' "$1" | grep -- "$2" >/dev/null || fail "$3: unexpected [$2]"; }
assert_open() {
  set +e; "$CAPTAIN" open "$1" >/dev/null; rc=$?; set -e
  [ "$rc" = "${2:-0}" ] || fail "$3: open $1 rc=$rc"
}
assert_closed() {
  set +e; "$CAPTAIN" open "$1" >/dev/null; rc=$?; set -e
  [ "$rc" = "${2:-1}" ] || fail "$3: open $1 rc=$rc"
}

new_home() {  # <scenario> [per-poll cap] [allowed authors]
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  bash "$FIX/make-home.sh" "$1" "$HOME_DIR" ${2:+"$2"} ${3:+"$3"} >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
}

bind() { "$CAPTAIN" bind slack-dm >/dev/null; }
mirror() { "$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/$1/transcript.json"; }
poll() { "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/$1/transcript.json"; }
closed_count() { printf '%s\n' "$1" | grep -c '^closed: ' || true; }
check_count() { printf '%s\n' "$1" | grep -c '^check: ' || true; }
state_file() { printf '%s/slack-watch/state.json' "$FM_STATE_OVERRIDE"; }

# Pure-bash / jq fast inspectors avoid importing the 4,890-line Python test
# module on every read-only assertion.
replay_file() {
  local f
  for f in "$FM_STATE_OVERRIDE/slack-watch"/replay-state-*.json; do
    if [ -e "$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  printf '\n'
}
thread_count() {
  local sf key=${1:-}
  sf=$(state_file)
  if [ ! -f "$sf" ]; then
    printf '0\n'
    return 0
  fi
  jq -r --arg k "$key" '[(.threads // {}) | .[] | select($k == "" or .key == $k)] | length' "$sf"
}
outbound_count() {
  local f="$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" method=$1 thread=${2:-}
  if [ ! -f "$f" ]; then
    printf '0\n'
    return 0
  fi
  jq -rs --arg m "$method" --arg t "$thread" '
    [.[] | select(.method == $m and ($t == "" or .thread_ts == $t or ($m == "chat.update" and .ts == $t)))] | length
  ' "$f"
}
thread_field() {
  local sf
  sf=$(state_file)
  jq -r --arg k "$1" --arg f "$2" '
    (first((.threads // {}) | .[] | select(.key == $k)) // error("no thread with key \($k)"))
    | if has($f) then .[$f] else error("thread \($k) has no field \($f)") end
    | if . == true then "True" elif . == false then "False" elif . == null then "None" else tostring end
  ' "$sf"
}
thread_texts() {
  local rf
  rf=$(replay_file)
  jq -r --arg t "$1" '[.messages[] | select(.thread_ts == $t) | (.text // "")] | join("\n")' "$rf"
}
resolution_count() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' '
}
answer_line() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Answer: [^"]*' | sed 's/^Answer: //' | sed 's/\\n.*//' | tr -d '\n'
}
label_line() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full \
    | grep -o 'Answer as shown to the captain: [^"]*' | sed 's/^Answer as shown to the captain: //' | sed 's/\\n.*//' | tr -d '\n'
}
task_state() {  # <task-id>
  "$ROOT/bin/fm-tasks-axi.sh" show "$1" | sed -n 's/^  state: //p'
}
write_board() {  # <generated> <captains-call-json-array>
  mkdir -p "$FM_HOME/.lavish"
  printf '<html><script id="bearings-data" type="application/json">{"schema":"fm-bearings-board.v1","generated":"%s","captains_call":%s}</script></html>\n' \
    "$1" "$2" > "$FM_HOME/.lavish/bearings-board.html"
}
reply_to() {  # <thread-ts> <ts> <text>
  python3 "$HELPER" reply "$(replay_file)" "$1" "$2" U0TESTOWNER "$3"
}
close_terminal() {  # <task-id>
  printf 'terminal fixture answer\n' > "$FM_HOME/decision.txt"
  "$CAPTAIN" answer "$1" --decision-file "$FM_HOME/decision.txt" >/dev/null
}

armed() { [ -e "$FM_STATE_OVERRIDE/slack.check.sh" ] || [ -e "$FM_STATE_OVERRIDE/slack.check-trust" ]; }

# A copy of the Slack entry points whose intake wrapper can fail on demand, so
# transient intake and call-state failures are exercised without touching the
# real intake. FM_SHIM_* name flag files; FM_SHIM_LOG records every intake call.
make_shim() {
  local dir="$TMP/shim"
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-slack-lib.sh" "$ROOT/bin/fm-slack-poll.sh" "$ROOT/bin/fm-slack-mirror.sh" "$ROOT/bin/fm-slack-check.sh" \
    "$ROOT/bin/fm-env-lib.sh" "$ROOT/bin/fm_slack.py" "$ROOT/bin/fm_slack_replay.py" \
    "$ROOT/bin/fm_slack_watch.py" "$dir/"
  cat > "$dir/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
[ -z "\${FM_SHIM_ENVLOG:-}" ] || printf '%s\\n' "\${SLACK_BOT_TOKEN:-unset}" >> "\$FM_SHIM_ENVLOG"
[ -z "\${FM_SHIM_SECRETLOG:-}" ] || printf '%s\\n' "\${SLACK_SIGNING_SECRET:-unset}/\${SLACK_APP_TOKEN:-unset}" >> "\$FM_SHIM_SECRETLOG"
exec bash "$ROOT/bin/fm-fleet-snapshot.sh" "\$@"
SH
  cat > "$dir/fm-captain-hold.sh" <<SH
#!/usr/bin/env bash
[ -z "\${FM_SHIM_LOG:-}" ] || printf '%s\\n' "\$*" >> "\$FM_SHIM_LOG"
[ -z "\${FM_SHIM_ENVLOG:-}" ] || printf '%s\\n' "\${SLACK_BOT_TOKEN:-unset}" >> "\$FM_SHIM_ENVLOG"
[ -z "\${FM_SHIM_SECRETLOG:-}" ] || printf '%s\\n' "\${SLACK_SIGNING_SECRET:-unset}/\${SLACK_APP_TOKEN:-unset}" >> "\$FM_SHIM_SECRETLOG"
if [ "\${1:-}" = open ] && [ -f "\${FM_SHIM_UNBIND_ON_OPEN:-/nonexistent}" ]; then
  rm -f "\$FM_SHIM_UNBIND_ON_OPEN"
  bash "$ROOT/bin/fm-captain-hold.sh" unbind slack-dm >/dev/null
fi
if [ "\${1:-}" = binding ] && [ -n "\${FM_SHIM_NEEDLE:-}" ]; then
  { printf '%s\\n' "\$@"; env | grep -v '^FM_SHIM_'; } | grep -c -F -- "\$FM_SHIM_NEEDLE" >> "\$FM_SHIM_NEEDLE_LOG" || true
fi
if [ "\${1:-}" = binding ] && [ -n "\${FM_SHIM_RACE:-}" ]; then
  n=\$(( \$(cat "\$FM_SHIM_RACE.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "\$n" > "\$FM_SHIM_RACE.n"
  out=\$(bash "$ROOT/bin/fm-captain-hold.sh" "\$@"); rc=\$?
  if [ "\$n" = "\$(cat "\$FM_SHIM_RACE")" ]; then
    # The real unbind is started by another process right after the check answered, and given time to reach its wait.
    ( bash "$ROOT/bin/fm-captain-hold.sh" unbind slack-dm > "\$FM_SHIM_RACE.out" 2>&1; echo done > "\$FM_SHIM_RACE.done" ) </dev/null >/dev/null 2>&1 &
    sleep 1
  fi
  printf '%s\\n' "\$out"
  exit "\$rc"
fi
if [ "\${1:-}" = binding ] && [ -f "\${FM_SHIM_UNBIND_AFTER_BINDING:-/nonexistent}" ]; then
  out=\$(bash "$ROOT/bin/fm-captain-hold.sh" "\$@"); rc=\$?
  rm -f "\$FM_SHIM_UNBIND_AFTER_BINDING"
  bash "$ROOT/bin/fm-captain-hold.sh" unbind slack-dm >/dev/null
  printf '%s\\n' "\$out"
  exit "\$rc"
fi
if [ "\${1:-}" = open ] && [ -f "\${FM_SHIM_OPEN_FAIL:-/nonexistent}" ]; then exit 2; fi
if [ "\${1:-}" = answers ] && [ -f "\${FM_SHIM_ANSWERS_FAIL:-/nonexistent}" ]; then
  echo 'fm-captain-hold: simulated backlog read bound' >&2
  exit 1
fi
if [ "\${1:-}" = answers ] && [ -f "\${FM_SHIM_ANSWERS_NOTE:-/nonexistent}" ]; then
  out=\$(bash "$ROOT/bin/fm-captain-hold.sh" "\$@"); rc=\$?
  printf '%s\\n' "\$out"
  echo 'simulated parent delivery problem' >&2
  exit "\$rc"
fi
exec bash "$ROOT/bin/fm-captain-hold.sh" "\$@"
SH
  chmod +x "$dir/fm-fleet-snapshot.sh" "$dir/fm-captain-hold.sh"
  printf '%s' "$dir"
}
SHIM=$(make_shim)
shim_poll() { env "$@" "$SHIM/fm-slack-poll.sh" --replay "$FIX/$SHIM_FIXTURE/transcript.json"; }
