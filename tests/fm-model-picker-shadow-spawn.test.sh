#!/usr/bin/env bash
# End-to-end shadow capture through bin/fm-spawn.sh: a real ship spawn with a fake
# tmux/treehouse/harness writes exactly one dispatch_log row carrying the route that
# actually launched, and the flag-off launch writes none. The picker's Jev endpoint is
# scripted; quota-axi is a fixture. This is the launch path that bypasses the typed
# resolver, so it is the capture path this test exists to prove.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-picker-shadow-spawn)
CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
PROJ="$CASE/project"
WT="$CASE/wt"
DATA="$CASE/data"
CALLS="$CASE/calls.jsonl"
SETTINGS="$CASE/settings.json"
mkdir -p "$CASE" "$DATA/projection"
for slug in claude-sonnet-5-5-high claude-opus-5-5-high claude-haiku-5-5 \
            gpt-6-1-sol-high gpt-6-luna-low deepseek-v4-flash; do
  cp "$ROOT/tests/fixtures/model-picker-shadow/projection/$slug.json" "$DATA/projection/"
done
printf '%s\n' '{"verdict":"TRUSTED"}' > "$DATA/verdict.json"
printf '%s\n' '{"rules":[{"when":"Any task in the fixture.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"claude","model":"opus","effort":"high"},{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low"},{"harness":"omp","model":"deepseek/deepseek-v4-flash","effort":"high"}]}],"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$CASE/crew-dispatch.json"

fm_test_spawn_home "$HOME_DIR" claude
cp "$CASE/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.json"
fm_git_worktree "$PROJ" "$WT" "wt-shadow-capture"
fm_test_spawn_brief "$HOME_DIR" "shadow-capture" "Prove the launch capture path."
FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
fm_fake_exit0 "$FAKEBIN" claude
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '0.1.51\n'; exit 0; }
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' > "$CASE/quota.json"

# Threaded scripted Jev endpoint: the capture helper makes two calls on one launch.
cat > "$CASE/provider.py" <<'PY'
import http.server, json, sys
settings_path, calls_path, port_path = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', '0'))
        body = self.rfile.read(n)
        with open(calls_path, 'ab') as fh:
            fh.write(body + b'\n')
        settings = json.loads(open(settings_path).read())
        req = json.loads(body)
        answers = {}
        for qid, q in req['questions'].items():
            if q['type'] == 'choice':
                keys = list(q['criteria'])
                pick = settings.get(qid) or keys[0]
                if pick not in keys:
                    pick = keys[0]
                answers[qid] = {'type': 'choice', 'choice': pick, 'confidence': 0.9,
                                'probabilities': {k: (1.0 if k == pick else 0.0) for k in keys}}
            elif q['type'] == 'score':
                score = settings.get(qid + '_score', 3 if qid == 'complexity' else 2)
                answers[qid] = {'type': 'score', 'score': score, 'confidence': 0.9,
                                'probabilities': {str(i): (1.0 if i == score else 0.0) for i in range(len(q['criteria']))},
                                'legend': {str(i): s for i, s in enumerate(q['criteria'])}}
            else:
                answers[qid] = {'type': 'noul', 'noul': 0}
        out = json.dumps({'model': 'jev-1.14.0', 'answers': answers,
                          'usage': {'input_tokens': 10, 'output_tokens': 2}}).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(port_path, 'w').write(str(server.server_port))
server.serve_forever()
PY
printf '%s\n' '{"work_type":"feature","worker":"candidate_2","validator":"candidate_6","effort_score":2}' > "$SETTINGS"
: > "$CALLS"
python3 "$CASE/provider.py" "$SETTINGS" "$CALLS" "$CASE/port" &
SERVER=$!
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null; fm_test_cleanup' EXIT
for _ in {1..100}; do [ ! -f "$CASE/port" ] || break; sleep .05; done
[ -f "$CASE/port" ] || fail "scripted endpoint did not start"

row_count() {
  python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log where mode=\"shadow\"").fetchone()[0])' "$DATA/aa.sqlite" 2>/dev/null || echo 0
}
row_field() {
  python3 -I -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("select "+sys.argv[2]+" from dispatch_log where mode=\"shadow\" order by id desc limit 1").fetchone(); print(r[0] if r else "")' "$DATA/aa.sqlite" "$1"
}
run_launch() {  # <flag> [extra args]
  local flag=$1
  shift
  OUT='' CODE=0
  # fm_test_run_spawn starts fm-spawn.sh with its own env prefix, so the picker
  # settings must be exported to survive into the child.
  ENDPOINT_URL="http://127.0.0.1:$(cat "$CASE/port")"
  export TYPESAFE_API_KEY=synthetic-key FM_MODEL_PICKER_SHADOW="$flag" \
    FM_MODEL_PICKER_DATA="$DATA" FM_TEST_SEAM=1 \
    FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT_URL" \
    QUOTA_AXI_FIXTURE="$CASE/quota.json"
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "shadow-capture" "$PROJ" \
      --mode no-mistakes --yolo off --harness claude --model opus --effort high "$@") || CODE=$?
}

rm -f "$DATA/aa.sqlite"; : > "$CALLS"
run_launch ''
assert_equals 0 "$CODE" 'flag-off spawn succeeds'
assert_contains "$OUT" "spawned shadow-capture" 'flag-off spawn reports its task'
assert_equals 0 "$(row_count)" 'flag-off launch writes no shadow row'
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" 'flag-off launch makes no picker request'

rm -f "$DATA/aa.sqlite"; : > "$CALLS"
run_launch 1
assert_equals 0 "$CODE" 'flag-on spawn succeeds'
assert_contains "$OUT" "spawned shadow-capture" 'flag-on spawn output is unchanged'
assert_equals 1 "$(row_count)" 'one real launch writes exactly one shadow row'
assert_equals 'claude:opus' "$(row_field rule_worker)" 'the row records the route that actually launched'
assert_equals 'high' "$(row_field rule_effort)" 'the row records the launched effort'
assert_equals 'accepted' "$(row_field picker_status)" 'the picker accepted its pick'
[ -n "$(row_field chosen_worker)" ] || fail 'the row records the picker worker'
[ -n "$(row_field jev_raw_payload)" ] || fail 'the row retains the raw Jev result'
[ "$(wc -l < "$CALLS" | tr -d ' ')" -ge 2 ] || fail 'the launch observation made its bounded calls'

pass 'spawn capture: a real launch writes one row with the launched route; flag off writes none'
