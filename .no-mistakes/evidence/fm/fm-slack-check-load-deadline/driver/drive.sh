#!/usr/bin/env bash
# Usage: drive.sh ROOT LABEL WORKDIR STEP...   STEP = mode:action, e.g. ok:arm latency:6:check
set -uo pipefail
ROOT=$1 LABEL=$2 WORK=$3; shift 3
DRV=$(cd "$(dirname "$0")" && pwd)
rm -rf "$WORK"; mkdir -p "$WORK/control"
HOME_DIR="$WORK/home"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" SLACK_BOT_TOKEN=fixture-token-not-a-secret \
  FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER FM_SLACK_POLL_MAX_ANSWERS=20 \
  PYTHONDONTWRITEBYTECODE=1 no_proxy='*' NO_PROXY='*'
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
bash "$ROOT/tests/fixtures/slack/make-home.sh" mirror "$HOME_DIR" >/dev/null 2>&1 || { echo "make-home failed"; exit 1; }
bash "$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null 2>&1 || { echo "bind failed"; exit 1; }
python3 "$DRV/fake_slack_server.py" "$ROOT" "$ROOT/tests/fixtures/slack/mirror/transcript.json" "$WORK/fake-slack-state" "$WORK/control" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 50); do [ -s "$WORK/control/port" ] && break; sleep 0.1; done
export FM_LIVE_SLACK_BASE="http://127.0.0.1:$(cat "$WORK/control/port")/api/" FM_LIVE_BIN="$ROOT/bin" \
  FM_LIVE_CONTROL="$WORK/control" PYTHONPATH="$DRV/hook"
cards() { [ -f "$WORK/fake-slack-state/outbound.jsonl" ] && python3 -c "import sys,json;print(sum(1 for l in open(sys.argv[1]) if json.loads(l)['method']=='chat.postMessage'))" "$WORK/fake-slack-state/outbound.jsonl" 2>/dev/null || echo 0; }
echo "### tree=$LABEL ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "$ROOT"))  fake Slack at 127.0.0.1 (local, no credentials)"
for step in "$@"; do
  mode=${step%:*} action=${step##*:}
  printf '%s' "$mode" > "$WORK/control/mode"
  : > "$WORK/control/client.jsonl"
  start=$(python3 -c 'import time;print(time.monotonic())')
  if [ "$action" = watch ]; then
    out=$(env -u FM_CHECK_TIMEOUT FM_DURATION_FILE="$WORK/empty-durations.jsonl" bash -c '
      . "$1"
      WATCHER_PID=$$
      trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
      watcher_beat force
      echo "watcher: CHECK_TIMEOUT(no-progress bound)=${CHECK_TIMEOUT}s"
      run_check_capture slack "$2" || exit 21
      echo "watcher: FM_CHECK_STATUS=$FM_CHECK_STATUS FM_CHECK_STOPPED=${FM_CHECK_STOPPED:-<none>}"
      printf "watcher: FM_CHECK_RESULT=%s\n" "${FM_CHECK_RESULT:-<empty>}"
    ' _ "$ROOT/bin/fm-watch.sh" "$HOME_DIR/state/slack.check.sh" 2>&1); rc=$?
    [ -f "$HOME_DIR/state/.watch-triage.log" ] && out="$out
triage-log: $(cat "$HOME_DIR/state/.watch-triage.log")"
  elif [ "$action" = check ]; then out=$(bash "$HOME_DIR/state/slack.check.sh" 2>&1); rc=$?
  else out=$(bash "$ROOT/bin/fm-slack-check.sh" "$action" 2>&1); rc=$?; fi
  secs=$(python3 -c "import time;print('%.1f' % (time.monotonic()-$start))")
  echo "--- step: mode=$mode action=$action  exit=$rc  wall=${secs}s  cards_posted_total=$(cards)"
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/    out| /'; else echo "    out| (no output)"; fi
  python3 - "$WORK/control/client.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
if rows:
    errs = [r for r in rows if r['error']]
    print('    requests=%d  longest_single_request=%.3fs  sum_request_time=%.1fs  errors=%s' % (
        len(rows), max(r['seconds'] for r in rows), sum(r['seconds'] for r in rows),
        json.dumps([(r['method'], r['error'], r['seconds']) for r in errs])))
PY
done
grep -h SIG "$WORK/control/server.jsonl" 2>/dev/null | sed 's/^/    server| /'
