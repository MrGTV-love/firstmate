#!/usr/bin/env bash
# Usage: drive.sh RUNROOT TREE LABEL STEP...
# RUNROOT: the run worktree (owner of fm-lab-home.sh). TREE: tree under test.
# STEP = mode@action@bound. action: arm | watch (real bin/fm-watch-checkpoint.sh around real bin/fm-watch.sh).
set -uo pipefail
RUNROOT=$1 ROOT=$2 LABEL=$3; shift 3
DRV=$(cd "$(dirname "$0")" && pwd)
OUTFILE=$DRV/../$LABEL.txt
exec > >(tee "$OUTFILE") 2>&1
eval "$("$RUNROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-final.XXXXXX")
mkdir -p "$WORK/control"
printf ok > "$WORK/control/mode"
TOKEN=fixture-token-not-a-secret
export SLACK_BOT_TOKEN=$TOKEN FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER \
  FM_SLACK_POLL_MAX_ANSWERS=20 PYTHONDONTWRITEBYTECODE=1 no_proxy='*' NO_PROXY='*' \
  FM_DURATION_FILE="$WORK/durations.jsonl"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY FM_CHECK_TIMEOUT NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
python3 "$DRV/fake_slack_server.py" "$ROOT" "$ROOT/tests/fixtures/slack/mirror/transcript.json" "$WORK/fake-slack-state" "$WORK/control" &
SRV=$!
cleanup() {
  kill "$SRV" 2>/dev/null
  "$RUNROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 && rm -rf "$FM_HOME"
  rm -rf "$WORK"
}
trap cleanup EXIT
for _ in $(seq 50); do [ -s "$WORK/control/port" ] && break; sleep 0.1; done
bash "$ROOT/tests/fixtures/slack/make-home.sh" mirror "$FM_HOME" >/dev/null 2>&1 || { echo "make-home failed"; exit 1; }
# Keep unrelated sweeps quiet in this disposable home: the fixture holds are dated 2026-10-01,
# and the memory alarm has no baseline. Neither touches the Slack path.
printf '{"age_limits_seconds":{"unanswered_question":999999999}}\n' > "$FM_HOME/config/open-loops.json"
printf '9999999999\n' > "$FM_HOME/state/.memory-health-next"
export FM_LIVE_SLACK_BASE="http://127.0.0.1:$(cat "$WORK/control/port")/api/" FM_LIVE_BIN="$ROOT/bin" \
  FM_LIVE_CONTROL="$WORK/control" PYTHONPATH="$DRV/hook"
cards() { python3 - "$WORK/fake-slack-state/outbound.jsonl" <<'PY'
import json, sys, os
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
print(sum(1 for r in rows if r['method'] == 'chat.postMessage'))
PY
}
echo "### label=$LABEL tree=$ROOT commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'base-archive-ff15a3d5')  lab home, fake Slack on 127.0.0.1, synthetic token"
for step in "$@"; do
  IFS=@ read -r mode action bound <<<"$step"
  printf '%s' "$mode" > "$WORK/control/mode"
  : > "$WORK/control/client.jsonl"
  start=$(python3 -c 'import time;print(time.monotonic())')
  if [ "$action" = arm ]; then
    out=$(bash "$ROOT/bin/fm-slack-check.sh" arm 2>&1); rc=$?
  else
    out=$(FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$bound" 2>&1); rc=$?
  fi
  secs=$(python3 -c "import time;print('%.1f' % (time.monotonic()-$start))")
  echo "--- step mode=$mode action=$action bound=${bound:-na} exit=$rc wall=${secs}s cards_posted_total=$(cards)"
  printf '%s\n' "$out" | sed 's/^/    out| /'
  if [ "$action" = watch ]; then
    q=$("$ROOT/bin/fm-wake-drain.sh" --queued 2>&1); echo "    queued_wake_rows=$(printf '%s' "$q" | grep -c .)"
    printf '%s\n' "$q" | cut -f3- | sed 's/^/    wake| /'
    d=$("$ROOT/bin/fm-wake-drain.sh" 2>&1)
    ack=$(printf '%s\n' "$d" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | head -1)
    # shellcheck disable=SC2086
    [ -z "$ack" ] || "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1 || echo "    ack failed: $ack"
    [ ! -f "$FM_HOME/state/.watch-triage.log" ] || { grep -h 'check slack' "$FM_HOME/state/.watch-triage.log" | sed 's/^/    triage| /'; : > "$FM_HOME/state/.watch-triage.log"; }
  fi
  python3 - "$WORK/control/client.jsonl" <<'PY'
import json, sys, os
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
if rows:
    errs = [(r['method'], r['error'], r['seconds']) for r in rows if r['error']]
    print('    requests=%d processes=%d socket_timeouts=%s longest_single_request=%.3fs sum_request_time=%.1fs errors=%s' % (
        len(rows), len({r['pid'] for r in rows}), sorted({r['socket_timeout'] for r in rows if r['socket_timeout'] is not None}),
        max(r['seconds'] for r in rows), sum(r['seconds'] for r in rows), json.dumps(errs)))
    pids = {r['pid'] for r in rows}
    alive = []
    for p in pids:
        try:
            os.kill(p, 0); alive.append(p)
        except OSError:
            pass
    print('    check_processes_still_alive=%d' % len(alive))
PY
done
grep -hE 'SIG|trickle-client-gone|post-committed' "$WORK/control/server.jsonl" 2>/dev/null | sed 's/^/    server| /'
python3 - "$WORK/fake-slack-state/outbound.jsonl" <<'PY'
import collections, json, os, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
posts = [r for r in rows if r['method'] == 'chat.postMessage']
c = collections.Counter(r['text'] for r in posts)
print('final: chat.postMessage rows=%d distinct_texts=%d duplicate_texts=%d' % (len(posts), len(c), sum(1 for v in c.values() if v > 1)))
PY
python3 - "$FM_HOME/state/slack-watch/state.json" <<'PY'
import json, sys, os
s = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
print('final: threads=%d pending=%d failure=%r' % (len(s.get('threads', {})), len(s.get('pending', [])), s.get('failure')))
PY
hits=$(grep -rlF "$TOKEN" "$FM_HOME" "$WORK/control" "$WORK/fake-slack-state" 2>/dev/null | grep -v "^$FM_HOME/\.env$" | wc -l | tr -d ' ')
echo "final: synthetic token found in $hits file(s) outside the fixture .env"
