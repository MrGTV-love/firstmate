#!/usr/bin/env bash
# Independent live drive of the main-home Slack mirror/poll against disposable
# homes. Slack is the product's own --replay transport; the remote host is a
# fake ssh (FM_SSH_BIN) that runs the requested tracked script in the remote home.
# Usage: live-drive.sh <worktree>
set -uo pipefail
ROOT=${1:?worktree}
T=$(mktemp -d "$HOME/tmp/fm-slack-live.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
unset FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_SLACK_FAULT NO_MISTAKES_GATE
TOKEN="xoxb-livedrive-$$-$(date +%s)"
export SLACK_BOT_TOKEN="$TOKEN" FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER FM_SLACK_POLL_MAX_ANSWERS=20
REPLAY="$ROOT/tests/fixtures/slack/card-payload/transcript.json"
OUT="$T/all-output.txt"
step() { printf '\n=== %s\n' "$*"; }
in_home() { local h=$1; shift; FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$@"; }
run() { local h=$1; shift; local rc; in_home "$h" "$@" > "$T/o" 2>&1; rc=$?; cat "$T/o" | tee -a "$OUT"; echo "[exit $rc]"; return 0; }
open_rc() { in_home "$1" bash "$ROOT/bin/fm-captain-hold.sh" open "$2" >/dev/null 2>&1; echo $?; }
backlog_line() { grep -n -A3 -- "$2" "$1/data/backlog.md" | head -6; }

MAIN=$T/main LANE=$T/lane REMOTE=$T/remote-home
for h in "$MAIN" "$LANE" "$REMOTE"; do
  in_home "$h" bash "$ROOT/tests/fixtures/slack/make-home.sh" config "$h" >/dev/null 2>&1
  printf 'config-call\tfixture done\t\tdone\n' | in_home "$h" bash "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source fixture >/dev/null
done
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z in_home "$MAIN" bash "$ROOT/bin/fm-captain-hold.sh" hold main-call --title 'Main release' --reason 'Which main release?' >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z in_home "$LANE" bash "$ROOT/bin/fm-captain-hold.sh" hold lane-call --title 'Lane schema' --reason 'Which schema for the lane?' >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z in_home "$REMOTE" bash "$ROOT/bin/fm-captain-hold.sh" hold remote-call --title 'Remote deploy' --reason 'Deploy remote now?' >/dev/null

cat > "$T/ssh" <<'PY'
#!/usr/bin/env python3
import base64, os, sys, json
from pathlib import Path
a = sys.argv[1:]; i = a.index('fm-remote-entrypoint.sh')
host = a[i-1]
root = base64.b64decode(a[i+2]).decode(); home = base64.b64decode(a[i+3]).decode()
argv = base64.b64decode(a[i+4]).decode().rstrip('\0').split('\0')
with open(os.environ['LIVE_ROUTE_LOG'], 'a') as f:
    f.write(json.dumps({'host': host, 'home': home, 'argv': argv[:2], 'slack_env': any(k.startswith('SLACK_') for k in os.environ)}) + '\n')
if not os.path.isdir(home):
    sys.stderr.write('error: remote home is not a safe directory\n'); sys.exit(64)
env = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=home+'/state', FM_DATA_OVERRIDE=home+'/data', FM_CONFIG_OVERRIDE=home+'/config')
os.execve('/bin/bash', ['bash', root+'/bin/'+argv[0], *argv[1:]], env)
PY
chmod 700 "$T/ssh"
export FM_SSH_BIN="$T/ssh" LIVE_ROUTE_LOG="$T/routes.jsonl"
REG="$MAIN/data/secondmates.md"
GOOD="- lane - Local lane (home: $LANE; scope: lane; projects: sample; added 2026-10-01)
- far - Remote lane (host: far-host; root: $ROOT; home: $REMOTE; scope: far; projects: sample; added 2026-10-01)"
printf '%s\n' "$GOOD" > "$REG"

step "S1 mirror: main + registered local lane + registered remote home"
run "$MAIN" bash "$ROOT/bin/fm-slack-mirror.sh" --replay "$REPLAY"
RS() { ls "$MAIN"/state/slack-watch/replay-state-*.json; }
python3 - "$(RS)" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))['messages']
for msg in m:
    if msg.get('text','').startswith(('Task:', '*Task')) or 'Task: ' in msg.get('text',''):
        print('--- card ts=%s' % msg['ts']); print(msg['text'])
PY
python3 - "$MAIN/state/slack-watch/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for k, r in s['threads'].items():
    print('thread key=%s owner=%s ts=%s' % (r['key'], (r.get('owner') or {}).get('id', 'main'), r['ts']))
PY
step "S1b repeat mirror: no new cards"
run "$MAIN" bash "$ROOT/bin/fm-slack-mirror.sh" --replay "$REPLAY"
python3 -c "import json,sys; print('thread count:', len(json.load(open(sys.argv[1]))['threads']))" "$MAIN/state/slack-watch/state.json"

reply() { # <owner-id|main> <ts> <text>
  python3 - "$MAIN/state/slack-watch/state.json" "$(RS)" "$1" "$2" "$3" <<'PY'
import json, sys
state, rs, owner, ts, text = sys.argv[1:]
rec = next(r for r in json.load(open(state))['threads'].values() if (r.get('owner') or {}).get('id', 'main') == owner)
d = json.load(open(rs)); d['messages'].append({'ts': ts, 'thread_ts': rec['ts'], 'user': 'U0TESTOWNER', 'text': text})
json.dump(d, open(rs, 'w'))
print('typed reply in thread %s (%s): %s' % (rec['ts'], owner, text))
PY
}
cp "$MAIN/data/backlog.md" "$T/main-before.md"
step "S2 typed answer to the local lane card"
echo "before: lane open rc=$(open_rc "$LANE" lane-call) main open rc=$(open_rc "$MAIN" main-call)"
reply lane 950.000001 'use schema v2'
run "$MAIN" bash "$ROOT/bin/fm-slack-poll.sh" --replay "$REPLAY"
echo "after: lane open rc=$(open_rc "$LANE" lane-call) (1=closed)  main main-call rc=$(open_rc "$MAIN" main-call) (0=open)"
backlog_line "$LANE" lane-call
step "S3 typed answer to the remote card"
echo "before: remote open rc=$(open_rc "$REMOTE" remote-call)"
reply far 950.000002 'deploy tomorrow'
run "$MAIN" bash "$ROOT/bin/fm-slack-poll.sh" --replay "$REPLAY"
echo "after: remote open rc=$(open_rc "$REMOTE" remote-call) (1=closed)"
backlog_line "$REMOTE" remote-call
cmp -s "$T/main-before.md" "$MAIN/data/backlog.md" && echo "main backlog byte-identical after both secondmate answers"
echo "remote routes used:"; sort -u "$T/routes.jsonl" | python3 -c "import sys,json; [print(' ', json.loads(l)) for l in sys.stdin]"

step "S4 unreadable registered local home (exists, chmod 000) and missing remote home"
FM_CAPTAIN_HOLD_NOW=2026-10-02T00:00:00Z in_home "$LANE" bash "$ROOT/bin/fm-captain-hold.sh" hold lane-two --title 'Lane two' --reason 'Second?' >/dev/null
LOCKED=$T/locked; mkdir -p "$LOCKED"/{data,state,config,projects}; cp "$LANE/.tasks.toml" "$LOCKED/"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCKED/data/backlog.md"; chmod 000 "$LOCKED"
printf '%s\n- locked - Locked lane (home: %s; scope: x; projects: sample; added 2026-10-01)\n- gone - Gone remote (host: far-host; root: %s; home: %s/gone; scope: x; projects: sample; added 2026-10-01)\n' "$GOOD" "$LOCKED" "$ROOT" "$T" > "$REG"
run "$MAIN" bash "$ROOT/bin/fm-slack-mirror.sh" --replay "$REPLAY"
python3 -c "import json,sys; print('lane-two cards:', sum(1 for r in json.load(open(sys.argv[1]))['threads'].values() if r['key']=='lane-two'))" "$MAIN/state/slack-watch/state.json"
chmod 700 "$LOCKED"

step "S5 main-home answer still works with the unreadable homes still registered"
reply main 950.000003 'ship main'
run "$MAIN" bash "$ROOT/bin/fm-slack-poll.sh" --replay "$REPLAY"
echo "main main-call open rc=$(open_rc "$MAIN" main-call) (1=closed)"

step "S6 no token or env leak"
if grep -rqF -- "$TOKEN" "$OUT" "$MAIN/state" "$MAIN/data" "$LANE" "$REMOTE" 2>/dev/null; then echo "TOKEN LEAKED"; else echo "token absent from all output, state and data"; fi
grep -q '"slack_env": true' "$T/routes.jsonl" && echo "SLACK_ env reached remote" || echo "no SLACK_ variable reached the remote transport"
