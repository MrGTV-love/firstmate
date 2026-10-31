#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# Shadow model picker behavior through bin/fm-model-picker-shadow.sh: route identity against
# real projections, gate eligibility, strict within-family Pareto pruning, currency separation
# (a cross-currency trial is flagged, never pruned), unknown-route handling, Jev refusal and
# malformed payloads, a TRUSTED-snapshot gate, the post-pick re-check, cross-family validator
# fallback and the single-family NULL validator, the per-work-type disagreement report, the
# never-send filter, and the flag's off-by-default behavior. The fixture numbers are copied
# from data/model-picker/projection/<slug>.json (the sources named in SOURCES.txt).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-picker-shadow)
BIN="$ROOT/bin/fm-model-picker-shadow.sh"
DATA="$TMP_ROOT/data"
CONFIG="$TMP_ROOT/config"
CALLS="$TMP_ROOT/calls.jsonl"
SETTINGS="$TMP_ROOT/settings.json"
mkdir -p "$DATA/projection" "$CONFIG"
# Fixture projections are reduced copies of data/model-picker/projection/<slug>.json from
# the 2026-10-16 snapshot; every number below is the source projection's own value.
for slug in claude-sonnet-5-5-high claude-opus-5-5-high claude-haiku-5-5 \
            gpt-6-1-sol-high gpt-6-luna-low deepseek-v4-flash; do
  cp "$ROOT/tests/fixtures/model-picker-shadow/projection/$slug.json" "$DATA/projection/" \
    || fail "missing fixture projection $slug"
done
mkdir -p "$TMP_ROOT/home"
# The fixture rule set is the real six concrete routes, written here so CI needs no home.
printf '%s\n' '{"rules":[{"when":"Any task in the fixture.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"claude","model":"opus","effort":"high"},{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low"},{"harness":"dsh","model":"deepseek/deepseek-v4-flash","effort":"high"}]}],"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$TMP_ROOT/rules-base.json"
printf '%s\n' '{"verdict":"TRUSTED","ran_at":"2026-10-17T01:09:21Z","checked":6762,"mismatches":0}' > "$DATA/verdict.json"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' > "$TMP_ROOT/quota.json"
printf '%s\n' '{"status":"clear","chosen":{"profile":{"harness":"claude","model":"opus","effort":"high"}},"candidates":[{"profile":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},"eligible":true,"reason":"ok","pct":80,"spendPriority":0.8,"runway":"through_reset"},{"profile":{"harness":"claude","model":"opus","effort":"high"},"eligible":true,"reason":"ok","pct":60,"spendPriority":0.8,"runway":"through_reset"},{"profile":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"eligible":true,"reason":"ok","capacity":{"status":"usable","bestAccountHeadroom":0.9}}]}' > "$TMP_ROOT/result.json"
printf '%s\n' '# Task' "## Captain's intent" 'Fix a bounded bug in bin/example.sh and add a guard in tests/example.test.sh. The cause is known: a stale lock left by a killed worker. Reproduce it, fix it, and keep the existing acceptance tests green.' '## Firstmate spec' 'Use the existing implementation; no new architecture.' > "$TMP_ROOT/brief.md"

cat > "$TMP_ROOT/provider.py" <<'PY'
import http.server, json, os, sys, time
settings_path, calls_path, port_path = sys.argv[1:4]
responses_path = sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', '0'))
        body = self.rfile.read(n)
        settings = json.loads(open(settings_path).read())
        with open(calls_path, 'ab') as fh:
            fh.write(body + b'\n')
        if settings.get('delay'):
            time.sleep(settings['delay'])
        if settings.get('http') and (not settings.get('http_if') or settings['http_if'] in json.loads(body)['questions']):
            self.send_response(settings['http'])
            self.end_headers()
            self.wfile.write(b'private-error-sentinel')
            return
        if settings.get('raw') is not None and (not settings.get('raw_if') or settings['raw_if'] in json.loads(body)['questions']):
            self.send_response(200)
            self.send_header('content-type', 'application/json')
            self.end_headers()
            self.wfile.write(settings['raw'].encode())
            return
        req = json.loads(body)
        answers = {}
        single_validator = list(req['questions']) == ['validator']
        for qid, q in req['questions'].items():
            if q['type'] == 'choice':
                keys = list(q['criteria'])
                if qid == 'validator':
                    name = 'validator_fallback' if single_validator else 'validator'
                else:
                    name = qid
                pick = settings.get(name) or keys[0]
                if settings.get('force_question') == qid and settings.get('force_choice'):
                    pick = settings['force_choice']
                if pick not in keys and settings.get('force_question') != qid:
                    pick = keys[0]
                answers[qid] = {'type': 'choice', 'choice': pick,
                                'confidence': settings.get(qid + '_confidence', 0.9),
                                'probabilities': {k: (1.0 if k == pick else 0.0) for k in keys}}
            elif q['type'] == 'score':
                score = settings.get(qid + '_score', 3 if qid == 'complexity' else 2)
                answers[qid] = {'type': 'score', 'score': score, 'confidence': 0.9,
                                'probabilities': {str(i): (1.0 if i == score else 0.0) for i in range(len(q['criteria']))},
                                'legend': {str(i): s for i, s in enumerate(q['criteria'])}}
            else:
                answers[qid] = {'type': 'noul', 'noul': 0}
        out = json.dumps({'model': 'jev-1.13.0', 'answers': answers,
                          'usage': {'input_tokens': 100, 'output_tokens': 20}}).encode()
        with open(responses_path, 'ab') as fh:
            fh.write(out + b'\n')
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), H)
open(port_path, 'w').write(str(server.server_port))
server.serve_forever()
PY
printf '%s\n' '{}' > "$SETTINGS"
python3 "$TMP_ROOT/provider.py" "$SETTINGS" "$CALLS" "$TMP_ROOT/port" "$TMP_ROOT/responses.jsonl" &
SERVER=$!
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null; fm_test_cleanup' EXIT
for _ in {1..100}; do [ ! -f "$TMP_ROOT/port" ] || break; sleep .05; done
[ -f "$TMP_ROOT/port" ] || fail "local Jev provider did not start"
ENDPOINT="http://127.0.0.1:$(cat "$TMP_ROOT/port")"

run_observe() {  # <status> [extra args...]
  local status=$1 never_send=()
  shift
  [ -z "${NEVER_SEND:-}" ] || never_send=(--never-send "$NEVER_SEND")
  [ "${KEEP_DB:-0}" = 1 ] || rm -f "$DATA/aa.sqlite"
  : > "$CALLS"
  OUT='' ERR='' CODE=0
  FM_HOME="$TMP_ROOT/home" FM_MODEL_PICKER_DATA="$DATA" FM_MODEL_PICKER_SHADOW=1 \
    FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT" \
    bash "$BIN" --observe --brief "$TMP_ROOT/brief.md" --task-text "$TMP_ROOT/brief.md" \
      --rules "${RULES_FILE:-$TMP_ROOT/rules-base.json}" \
      --result "${RESULT_FILE:-$TMP_ROOT/result.json}" --quota "$TMP_ROOT/quota.json" \
      --status "$status" ${never_send[@]+"${never_send[@]}"} \
      3< <(printf 'synthetic-canary-key\n') "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || CODE=$?
  OUT=$(cat "$TMP_ROOT/out")
  ERR=$(cat "$TMP_ROOT/err")
}
dump_row() {
  python3 -I - "$DATA/aa.sqlite" "$TMP_ROOT/row.json" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1]); conn.row_factory = sqlite3.Row
row = conn.execute('select * from dispatch_log order by id desc limit 1').fetchone()
doc = dict(row) if row else {}
for key in ('gates', 'pareto_pruned', 'spend_priority', 'complexity_components'):
    if doc.get(key):
        try: doc[key] = json.loads(doc[key])
        except ValueError: pass
for key in ('jev_raw_payload', 'jev_raw_support'):
    if isinstance(doc.get(key), bytes):
        doc[key] = '<bytes:%d>' % len(doc[key])
json.dump(doc, open(sys.argv[2], 'w'), sort_keys=True)
PY
}
row() { dump_row; jq -r "$1" "$TMP_ROOT/row.json"; }
calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
settings() { printf '%s\n' "$1" > "$SETTINGS"; }

# --- cases ---------------------------------------------------------------------
CASE='' FAILED=0
begin() { CASE=$1; CASE_FAILED=0; }
check() { if ! eval "$1"; then echo "FAIL $CASE: $2"; CASE_FAILED=1; fi; }
finish() { [ "$CASE_FAILED" -eq 0 ] && echo "ok $CASE" || FAILED=$((FAILED + 1)); }

begin "route table maps every configured route to a real projection"
OUT=$("$BIN" --check-routes --rules "$TMP_ROOT/rules-base.json" --data-root "$DATA" 2>&1); RC=$?
check '[ "$RC" -eq 0 ]' "check-routes exits 0"
check 'grep -q "claude:opus .*claude-opus-5-5-high *yes" <<<"$OUT"' "Opus maps to its high projection"
check 'grep -q "dsh:deepseek/deepseek-v4-flash .*deepseek-v4-flash *yes" <<<"$OUT"' "DeepSeek maps to its projection"
mv "$DATA/projection/claude-opus-5-5-high.json" "$TMP_ROOT/opus.saved"
OUT=$("$BIN" --check-routes --rules "$TMP_ROOT/rules-base.json" --data-root "$DATA" 2>&1); RC=$?
mv "$TMP_ROOT/opus.saved" "$DATA/projection/claude-opus-5-5-high.json"
check '[ "$RC" -eq 1 ]' "a missing projection refuses the route table"
cp "$DATA/projection/deepseek-v4-flash.json" "$TMP_ROOT/deepseek.saved"
jq '.creator = "Someone Else"' "$TMP_ROOT/deepseek.saved" > "$DATA/projection/deepseek-v4-flash.json"
OUT=$("$BIN" --check-routes --rules "$TMP_ROOT/rules-base.json" --data-root "$DATA" 2>&1); RC=$?
check '[ "$RC" -eq 1 ]' "a creator mismatch refuses the route table"
check 'grep -q "dsh:deepseek/deepseek-v4-flash .*REFUSED: projection creator" <<<"$OUT"' "the creator refusal names the route"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
run_observe clear
check 'grep -q "projection creator" "$CALLS"' "observe refuses the same projection"
cp "$TMP_ROOT/deepseek.saved" "$DATA/projection/deepseek-v4-flash.json"
OUT=$(FM_TEST_SEAM=0 "$BIN" --check-routes --rules "$TMP_ROOT/rules-base.json" --data-root "$DATA" \
  --table "$ROOT/bin/fm_model_picker/routes.json" 2>&1); RC=$?
check '[ "$RC" -eq 2 ]' "--table is refused outside the test seam"
finish

begin "one shadow run records both picks, the raw Jev body and the classification"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","complexity_score":3,"effort_score":2}'
run_observe clear
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check '[ "$(row ".mode")" = shadow ]' "mode is shadow"
check '[ "$(row ".picker_status")" = accepted ]' "pick is accepted"
check '[ "$(row ".work_type")" = "Feature / capability" ]' "work type is recorded"
check '[ "$(row ".chosen_worker")" = "claude:opus" ]' "picker worker matches the answer"
check '[ "$(row ".chosen_validator")" = "omp:openai-codex/gpt-6.1-sol" ]' "picker validator is cross-family"
check '[ "$(row ".effort")" = high ]' "effort maps from the Score"
check '[ "$(row ".rule_worker")" = "claude:opus" ]' "the rule route is recorded beside the pick"
check '[ "$(row ".rule_effort")" = high ]' "the rule effort is recorded"
check '[ "$(row ".confidence_band")" = dispatch ]' "the confidence band is logged"
check '[ "$(row ".policy_version")" = "2026-10-19.1" ]' "the policy version is logged"
check '[ -n "$(row ".task_key")" ]' "a task join key is logged"
check '[ "$(row ".snapshot_age|type")" != null ]' "snapshot age is numeric"
check '[ "$(jq -r ".gates.recheck.accepted" "$TMP_ROOT/row.json")" = true ]' "the re-check accepts the pick"
check '[ "$(jq -r ".jev_candidate_version" "$TMP_ROOT/row.json")" = "jev-1.13.0" ]' "the Jev version is retained"
pickcall=$(grep -c '"worker"' "$CALLS")
check '[ "$pickcall" -ge 1 ]' "the worker question was sent"
stored=$(python3 -I -c 'import sqlite3,sys,hashlib; b=sqlite3.connect(sys.argv[1]).execute("select jev_raw_payload from dispatch_log order by id desc limit 1").fetchone()[0]; print(hashlib.sha256(b).hexdigest())' "$DATA/aa.sqlite")
body=$(python3 -I -c 'import sys,hashlib; lines=open(sys.argv[1],"rb").read().splitlines(); print(hashlib.sha256(lines[-1]).hexdigest())' "$TMP_ROOT/responses.jsonl")
check '[ "$stored" = "$body" ]' "the pick response is stored byte for byte"
finish

begin "same-family candidates are pruned only by strict Pareto dominance"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
run_observe clear
check '[ "$(jq -r ".pareto_pruned[0].route" "$TMP_ROOT/row.json")" = "claude:claude-sonnet-5-5[1m]" ]' "Sonnet is pruned"
check '[ "$(jq -r ".pareto_pruned[0].dominated_by[0]" "$TMP_ROOT/row.json")" = "claude:opus" ]' "Opus dominates it"
check '[ "$(jq -r ".gates.pruned | length" "$TMP_ROOT/row.json")" -ge 1 ]' "gate pruning is recorded beside Pareto"
worker_options=$(jq -r 'select(.questions.worker) | .state.candidates[].route' "$CALLS")
check '! grep -qx "claude:claude-sonnet-5-5\[1m\]" <<<"$worker_options"' "the pruned route is not offered as a worker"
check 'grep -qx "claude:opus" <<<"$worker_options"' "the dominating route is offered as a worker"
finish

begin "a cross-currency pair is flagged as a trial and never pruned"
python3 -I - "$ROOT/bin/fm_model_picker/routes.json" "$TMP_ROOT/table-api.json" <<'PY'
import json, sys
table = json.load(open(sys.argv[1]))
table['routes']['omp:anthropic/claude-sonnet-5-5-api'] = {
    'family': 'anthropic', 'currency': 'api', 'provider': None,
    'projections': {'high': {'slug': 'claude-sonnet-5-5-high', 'name': 'Claude Sonnet 5.5 (High, Default Fallback)'}}}
json.dump(table, open(sys.argv[2], 'w'))
PY
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"omp","model":"anthropic/claude-sonnet-5-5-api","effort":"high"}]}]}' > "$TMP_ROOT/rules-api.json"
RULES_FILE="$TMP_ROOT/rules-api.json" RESULT_FILE="$TMP_ROOT/result.json" \
  run_observe clear --table "$TMP_ROOT/table-api.json"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1","effort_score":2}'
RULES_FILE="$TMP_ROOT/rules-api.json" run_observe clear --table "$TMP_ROOT/table-api.json"
dump_row
check '[ "$(jq -r ".gates.currency_trials | length" "$TMP_ROOT/row.json")" -ge 1 ]' "the cross-currency pair is flagged"
check '[ "$(jq -r ".pareto_pruned | length" "$TMP_ROOT/row.json")" -eq 0 ]' "nothing is pruned across currencies"
check 'grep -q "anthropic/claude-sonnet-5-5-api" "$CALLS"' "the API candidate reached the picker"
finish

begin "a route the table cannot map stays a candidate with UNKNOWN facts"
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"claude","model":"unmeasured-next-model","effort":"high"}]}]}' > "$TMP_ROOT/rules-unknown.json"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1"}'
RULES_FILE="$TMP_ROOT/rules-unknown.json" run_observe clear
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check 'grep -q "Facts UNKNOWN" "$CALLS"' "the unknown route reached the picker as UNKNOWN"
check '[ "$(jq -r "[.gates.pruned[].route] | index(\"claude:unmeasured-next-model\")" "$TMP_ROOT/row.json")" = null ]' "the unknown route is not pruned"
check '[ "$(row ".picker_status")" = accepted ]' "a pick is still made"
finish

begin "a malformed Jev payload is retained and rejected, never acted on"
settings '{"raw":"{\"answers\": "}'
run_observe clear
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check '[ "$(row ".picker_status")" = invalid-response ]' "the malformed answer is rejected"
check '[ "$(row ".chosen_worker")" = null ]' "no worker is accepted"
check '[ "$(row ".jev_raw_payload")" != null ]' "the malformed body is retained"
check '[ "$(row ".reject_reason")" != null ]' "the reason is recorded"
finish

begin "an HTTP failure never changes the dispatch and still records the attempt"
settings '{"http":500}'
run_observe clear
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check '[ "$(row ".picker_status")" = picker-error ]' "the failure is recorded"
check '[ "$(row ".chosen_worker")" = null ]' "no pick is fabricated"
finish

begin "benchmark facts are read only from a TRUSTED snapshot"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1"}'
printf '%s\n' '{"verdict":"UNTRUSTED","reason":"matrix rebuilt without chart-diff"}' > "$DATA/verdict.json"
run_observe clear
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check '[ "$(row ".picker_status")" = no-trusted-snapshot ]' "the snapshot is refused"
check '[ "$(calls)" -eq 0 ]' "no Jev request is made"
printf '%s\n' '{"verdict":"TRUSTED"}' > "$DATA/verdict.json"
finish

begin "a pick that fails the post-pick effort re-check is rejected, never replaced"
python3 -I - "$ROOT/bin/fm_model_picker/routes.json" "$TMP_ROOT/table-codex.json" <<'PY'
import json, sys
table = json.load(open(sys.argv[1]))
table['routes']['codex:gpt-6.1-sol'] = {
    'family': 'openai', 'currency': 'subscription', 'provider': 'codex',
    'projections': {'high': {'slug': 'gpt-6-1-sol-high', 'name': 'GPT-6.1 Sol (High)'}}}
json.dump(table, open(sys.argv[2], 'w'))
PY
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"codex","model":"gpt-6.1-sol","effort":"high"}]}]}' > "$TMP_ROOT/rules-codex.json"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1","effort_score":4}'
RULES_FILE="$TMP_ROOT/rules-codex.json" run_observe clear --table "$TMP_ROOT/table-codex.json"
check '[ "$(row ".picker_status")" = rejected ]' "the pick is rejected"
check '[ "$(row ".chosen_worker")" = null ]' "no accepted worker is recorded"
check 'grep -q "not accepted by codex" <<<"$(row ".reject_reason")"' "the failing check is named"
check '[ "$(jq -r ".gates.recheck.accepted" "$TMP_ROOT/row.json")" = false ]' "the re-check records the failure"
finish

begin "a same-family validator answer falls back to a different family"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_3","validator_fallback":"candidate_6","effort_score":2}'
run_observe clear
check '[ "$(row ".picker_status")" = accepted ]' "the pick is accepted after the fallback"
check '[ "$(row ".chosen_validator")" = "omp:openai-codex/gpt-6.1-sol" ]' "the fallback validator is cross-family"
check '[ "$(calls)" -ge 3 ]' "a second bounded validator call was made"
finish

begin "a single-family candidate set records a NULL validator with its reason"
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"claude","model":"opus","effort":"high"}]}]}' > "$TMP_ROOT/rules-single.json"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1","effort_score":2}'
RULES_FILE="$TMP_ROOT/rules-single.json" run_observe clear
check '[ "$(row ".picker_status")" = accepted ]' "the worker pick is accepted"
check '[ "$(row ".chosen_validator")" = null ]' "no validator is fabricated"
check '[ "$(jq -r ".gates.validator_reason" "$TMP_ROOT/row.json")" = "no cross-family validator route exists" ]' "the reason is recorded"
finish

begin "the shadow path never writes outcomes, rework or captain acceptance"
check '[ "$(python3 -I -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(\"select count(*) from outcomes\").fetchone()[0])" "$DATA/aa.sqlite")" -eq 0 ]' "outcomes stays empty"
check '[ "$(python3 -I -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(\"select count(*) from dispatch_log where rework is not null or captain_acceptance is not null\").fetchone()[0])" "$DATA/aa.sqlite")" -eq 0 ]' "rework and acceptance stay NULL"
finish

begin "the report counts disagreements by work type and never calls an empty log zero disagreements"
rm -f "$DATA/aa.sqlite"
OUT=$(FM_MODEL_PICKER_DATA="$DATA" bash "$BIN" --report 2>/dev/null)
check '[ "$OUT" = "0 shadow dispatches logged" ]' "an empty log says zero dispatches"
python3 - "$ROOT/bin" "$DATA/aa.sqlite" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fm_model_picker import aadb
conn = aadb.connect(sys.argv[2]); aadb.init_calibration(conn)
rows = [
    dict(work_type='Feature / capability', rule_worker='a', rule_validator='x', rule_effort='high', chosen_worker='b', chosen_validator='y', effort='high', confidence_band='dispatch'),
    dict(work_type='Feature / capability', rule_worker='a', rule_validator='x', rule_effort='high', chosen_worker='a', chosen_validator='x', effort='high', confidence_band='ask'),
    dict(work_type='Feature / capability', rule_worker=None, rule_validator=None, rule_effort=None, chosen_worker='b', chosen_validator=None, effort='low', confidence_band='escalate'),
    dict(work_type='Verification', rule_worker='c', rule_validator='x', rule_effort='low', chosen_worker='c', chosen_validator='z', effort='low', confidence_band='dispatch'),
    dict(work_type='Verification', rule_worker='c', rule_validator=None, rule_effort='low', chosen_worker='d', chosen_validator=None, effort='high', confidence_band='dispatch'),
    dict(work_type='none-fit', rule_worker='a', rule_validator='x', rule_effort='high', chosen_worker='b', chosen_validator='y', effort='high', confidence_band='dispatch'),
    dict(work_type='Feature / capability', rule_worker='a', rule_validator='x', rule_effort='high', chosen_worker=None, chosen_validator=None, effort=None, picker_status='rejected'),
]
for row in rows:
    aadb.log_dispatch(conn, mode='shadow', **row)
conn.close()
PY
OUT=$(FM_MODEL_PICKER_DATA="$DATA" bash "$BIN" --report 2>/dev/null)
counts() { grep "^$1 " <<<"$OUT" | cut -c35- | tr -s ' ' | sed 's/^ //'; }
# runs rule noRte noPick wDen wDiff vDen vDiff eDen eDiff dispatch ask escal stale
check '[ "$(counts "Feature / capability")" = "4 3 1 1 2 1 2 1 2 0 1 1 1 0" ]' "feature counts match the seeded rows"
check '[ "$(counts "Verification")" = "2 2 0 0 2 1 1 1 2 1 2 0 0 0" ]' "verification counts match the seeded rows"
check 'grep -q "routing evidence, not outcome labels" <<<"$OUT"' "the report labels itself routing evidence"
check 'grep -q "worker disagreement over 5 rows where both" <<<"$OUT"' "a rejected pick is not in the worker denominator"
check 'grep -q "1 rows have no picker pick; 1 rows have no rule route" <<<"$OUT"' "the no-pick and no-rule-route counts are printed"
rm -f "$DATA/aa.sqlite"
python3 - "$ROOT/bin" "$DATA/aa.sqlite" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fm_model_picker import aadb
conn = aadb.connect(sys.argv[2]); aadb.init_calibration(conn)
for status in ('picker-error', 'no-trusted-snapshot'):
    aadb.log_dispatch(conn, mode='shadow', work_type=None, rule_worker='a', rule_validator='x',
                      rule_effort='high', picker_status=status)
conn.close()
PY
OUT=$(FM_MODEL_PICKER_DATA="$DATA" bash "$BIN" --report 2>/dev/null)
check '[ "$(counts "unclassified")" = "2 2 0 2 0 0 0 0 0 0 0 0 0 0" ]' "rows with no picker pick compare nothing"
check 'grep -q "worker disagreement over 0 rows where both" <<<"$OUT"' "an empty compared set prints a zero denominator"
check 'grep -q "validator disagreement over 0 rows" <<<"$OUT"' "the validator denominator is zero"
check 'grep -q "effort disagreement over 0 rows" <<<"$OUT"' "the effort denominator is zero"
check 'grep -q "2 rows have no picker pick" <<<"$OUT"' "the rows with no picker pick are counted"
finish

begin "the never-send filter withholds the request and the key never leaks"
printf '%s\n' 'CANARY-PRIVATE-PHRASE' > "$TMP_ROOT/never-send"
printf '%s\n' '# Task' "## Captain's intent" 'CANARY-PRIVATE-PHRASE must never leave this machine.' '## Firstmate spec' 'No send.' > "$TMP_ROOT/brief-private.md"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1"}'
rm -f "$DATA/aa.sqlite"; : > "$CALLS"; CODE=0
FM_HOME="$TMP_ROOT/home" FM_MODEL_PICKER_DATA="$DATA" FM_MODEL_PICKER_SHADOW=1 \
  FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT" \
  bash "$BIN" --observe --brief "$TMP_ROOT/brief-private.md" --task-text "$TMP_ROOT/brief-private.md" \
    --rules "$TMP_ROOT/rules-base.json" --result "$TMP_ROOT/result.json" \
    --quota "$TMP_ROOT/quota.json" --status clear --never-send "$TMP_ROOT/never-send" \
    3< <(printf 'synthetic-canary-key\n') >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
check '[ "$CODE" -eq 0 ]' "observe exits 0"
check '[ "$(calls)" -eq 0 ]' "no request was sent"
check '[ "$(row ".picker_status")" = withheld ]' "the row records the withholding"
check '! grep -q "CANARY-PRIVATE-PHRASE" "$TMP_ROOT/out" "$TMP_ROOT/err"' "the phrase is not printed"
check '! grep -q "CANARY-PRIVATE-PHRASE" "$CALLS"' "the phrase was never sent"
dump=$(python3 -I -c 'import sqlite3,sys; print("\n".join(str(v) for r in sqlite3.connect(sys.argv[1]).execute("select * from dispatch_log") for v in r))' "$DATA/aa.sqlite")
check '! grep -q "CANARY-PRIVATE-PHRASE" <<<"$dump"' "the phrase is not stored"
check '! grep -q "synthetic-canary-key" <<<"$dump"' "the key is not stored"
finish

begin "the flag is off by default and off means no data-root read or write"
rm -f "$DATA/aa.sqlite"; : > "$CALLS"
for value in '' 0 false off no; do
  FM_HOME="$TMP_ROOT/home" FM_MODEL_PICKER_DATA="$DATA" FM_MODEL_PICKER_SHADOW="$value" \
    FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT" \
    bash "$BIN" --observe --brief "$TMP_ROOT/brief.md" --task-text "$TMP_ROOT/brief.md" \
      --rules "$TMP_ROOT/rules-base.json" --result "$TMP_ROOT/result.json" \
      --quota "$TMP_ROOT/quota.json" --status clear 3< <(printf 'synthetic-canary-key\n') \
      >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || code=$?
  [ "${code:-0}" -eq 0 ] || check 'false' "flag value '$value' must exit 0"
done
check '[ "$(calls)" -eq 0 ]' "no request is made when the flag is off"
check '[ ! -e "$DATA/aa.sqlite" ]' "no store is created when the flag is off"
FM_MODEL_PICKER_SHADOW=live bash "$BIN" --observe --brief "$TMP_ROOT/brief.md" --status clear >/dev/null 2>"$TMP_ROOT/err"
check 'grep -q "cannot enable live" "$TMP_ROOT/err"' "a live value is refused with a warning"
finish


begin "snapshot age is the real age and staleness is disclosed, never a drop"
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}]}]}' > "$TMP_ROOT/rules-age.json"
python3 -I - "$DATA/projection/gpt-6-1-sol-high.json" 20100 >/dev/null <<'PY'
import datetime, json, sys
path, minutes_ago = sys.argv[1], int(sys.argv[2])
doc = json.load(open(path))
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')
for metric in doc['metrics'].values():
    metric['observed_at'] = stamp
doc['as_of'] = stamp
json.dump(doc, open(path, 'w'))
PY
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1"}'
cp "$TMP_ROOT/result.json" "$TMP_ROOT/result-age.json"
python3 -I - "$TMP_ROOT/result-age.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc['chosen'] = {'profile': {'harness': 'omp', 'model': 'openai-codex/gpt-6.1-sol', 'effort': 'high'}}
json.dump(doc, open(sys.argv[1], 'w'))
PY
RULES_FILE="$TMP_ROOT/rules-age.json" RESULT_FILE="$TMP_ROOT/result-age.json" run_observe clear
age=$(row ".snapshot_age")
check '[ "$(row ".snapshot_stale")" = 0 ]' "13 days 23 hours is not stale"
check '[ "$(python3 -c "print(1 if 20090*60 <= float($age) <= 20110*60 else 0)")" = 1 ]' "the age is the real observed_at age"
python3 -I - "$DATA/projection/gpt-6-1-sol-high.json" 20161 >/dev/null <<'PY'
import datetime, json, sys
path, minutes_ago = sys.argv[1], int(sys.argv[2])
doc = json.load(open(path))
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')
for metric in doc['metrics'].values():
    metric['observed_at'] = stamp
doc['as_of'] = stamp
json.dump(doc, open(path, 'w'))
PY
RULES_FILE="$TMP_ROOT/rules-age.json" run_observe clear
check '[ "$(row ".snapshot_stale")" = 1 ]' "14 days 1 minute is flagged stale"
check '[ "$(row ".picker_status")" = accepted ]' "a stale snapshot is disclosed, not dropped"
python3 -I - "$DATA/projection/gpt-6-1-sol-high.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
for metric in doc['metrics'].values():
    metric.pop('observed_at', None)
doc.pop('as_of', None)
json.dump(doc, open(path, 'w'))
PY
RULES_FILE="$TMP_ROOT/rules-age.json" run_observe clear
check '[ "$(row ".snapshot_age")" = null ]' "an unknown age is NULL, never zero"
check '[ "$(row ".snapshot_stale")" = 0 ]' "an unknown age is not called stale"
finish

begin "every work type is classified, and an unknown label is none-fit"
failed_types=0
for pair in 'defect_fix|Defect fix' 'diagnosis|Diagnosis / investigation' 'feature|Feature / capability' \
            'hardening|Hardening / edge-case closure' 'verification|Verification' 'code_review|Code review' \
            'research|Research / question-answering' 'analysis|Analysis (data & financial)' \
            'design|Design / planning' 'ops|Ops / infrastructure' 'writing|Writing / comms' \
            'upstream|Upstream engagement' 'none_fit|none-fit'; do
  option=${pair%%|*}; label=${pair#*|}
  settings "{\"work_type\":\"$option\",\"worker\":\"candidate_3\",\"validator\":\"candidate_6\"}"
  run_observe clear
  got=$(row ".work_type")
  [ "$got" = "$label" ] || { echo "FAIL $CASE: $option -> $got"; failed_types=1; }
done
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","force_question":"work_type","force_choice":"not_in_the_set"}'
run_observe clear
check '[ "$(row ".work_type")" = none-fit ]' "an out-of-set label is none-fit"
check '[ "$(row ".classification_uncertain")" = 1 ]' "an out-of-set label is disclosed as uncertain"
check '[ "$failed_types" = 0 ]' "all twelve mined types round-trip"
check '[ "$(row ".complexity_score")" != null ]' "the complexity read is recorded"
finish

begin "the request carries computed facts, never raw projection JSON"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
run_observe clear
assertions=$(python3 -I - "$CALLS" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
pick = [d for d in lines if 'worker' in d['questions']][-1]
types = {q['type'] for q in pick['questions'].values()}
candidate = pick['state']['candidates'][0]
raw = json.dumps(pick)
print(int(types <= {'choice', 'score', 'noul'}))
print(int('metrics' not in candidate and 'summary' in candidate))
print(int('fit' in candidate['summary']))
PY
)
check 'grep -qx 1 <<<"$(sed -n 1p <<<"$assertions")"' "only Choice, Score and Noul questions are sent"
check 'grep -qx 1 <<<"$(sed -n 2p <<<"$assertions")"' "candidates are code-computed summaries, not raw projections"
check 'grep -qx 1 <<<"$(sed -n 3p <<<"$assertions")"' "the normalized fit is in the facts Jev sees"
finish

begin "the tool documents itself"
OUT=$("$BIN" --help 2>&1); RC=$?
check '[ "$RC" -eq 0 ]' "--help exits 0"
check 'grep -q -- "--observe" <<<"$OUT"' "help lists --observe"
check 'grep -q -- "--report" <<<"$OUT"' "help lists --report"
check 'grep -q -- "--check-routes" <<<"$OUT"' "help lists --check-routes"
check 'grep -q "FM_MODEL_PICKER_SHADOW" <<<"$OUT"' "help names the flag"
check 'grep -q "Exit codes" <<<"$OUT"' "help states exit codes"
finish


begin "the confidence bands are applied in code and only logged"
for pair in '0.95|dispatch' '0.85|dispatch' '0.8499|ask' '0.55|ask' '0.5499|escalate' '0.10|escalate'; do
  confidence=${pair%%|*}; band=${pair#*|}
  settings "{\"work_type\":\"feature\",\"worker\":\"candidate_3\",\"validator\":\"candidate_6\",\"worker_confidence\":$confidence}"
  run_observe clear
  got=$(row ".confidence_band")
  check '[ "$got" = "'"$band"'" ]' "confidence $confidence is band $band"
done
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","worker_confidence":null}'
run_observe clear
check '[ "$(row ".confidence_band")" = null ]' "a missing confidence takes no band"
finish

begin "two dispatches write two rows and keep both picks"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
rm -f "$DATA/aa.sqlite"
KEEP_DB=1 run_observe clear
KEEP_DB=1 run_observe clear
count=$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log").fetchone()[0])' "$DATA/aa.sqlite")
check '[ "$count" = 2 ]' "two dispatches give two rows"
finish

begin "a resolver error or withheld resolve records no rule route and no classification"
for status in error withheld; do
  settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
  run_observe "$status" --reason 'worker account pin failed'
  check '[ "$(row ".rule_worker")" = null ]' "a $status row carries no rule route"
  check '[ "$(row ".rule_effort")" = null ]' "a $status row carries no rule effort"
  check '[ "$(row ".work_type")" = null ]' "a $status row is not a none-fit classification"
  check '[ "$(row ".classification_uncertain")" = null ]' "a $status row has no classification flag"
  check '[ "$(row ".snapshot_stale")" = null ]' "a $status row has no staleness claim"
  check '[ "$(calls)" -eq 0 ]' "a $status resolve sends nothing"
done
finish

begin "a route outside the resolver's candidates reads only its applicable quota rows"
cp "$TMP_ROOT/quota.json" "$TMP_ROOT/quota.saved"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}},{"scope":"model:opus","status":"known","effectivePercentRemaining":5,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":0.05}}]}}]}' > "$TMP_ROOT/quota.json"
printf '%s\n' '{"rules":[{"when":"Any task.","use":[{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"dsh","model":"deepseek/deepseek-v4-flash","effort":"high"}]}]}' > "$TMP_ROOT/rules-quota.json"
printf '%s\n' '{"status":"clear","chosen":{"profile":{"harness":"claude","model":"claude-haiku-5-5","effort":"max"}},"candidates":[]}' > "$TMP_ROOT/result-quota.json"
settings '{"work_type":"writing","worker":"candidate_1","validator":"candidate_2","complexity_score":0}'
RULES_FILE="$TMP_ROOT/rules-quota.json" RESULT_FILE="$TMP_ROOT/result-quota.json" run_observe clear
cp "$TMP_ROOT/quota.saved" "$TMP_ROOT/quota.json"
haiku=$(jq -r 'select(.questions.worker) | .state.candidates[] | select(.route == "claude:claude-haiku-5-5") | .summary' "$CALLS")
check 'grep -q "quota spendPriority 0.8, headroom 80%, runway through_reset" <<<"$haiku"' "Haiku is not charged the Opus-scoped row"
finish

begin "a validator answer outside the offered options or a bad range is rejected, never clamped"
settings '{"work_type":"feature","worker":"candidate_1","validator":"candidate_1","force_question":"validator","force_choice":"candidate_2"}'
RULES_FILE="$TMP_ROOT/rules-unknown.json" run_observe clear
check '[ "$(row ".picker_status")" = rejected ]' "an unmapped validator id is rejected"
check 'grep -q "validator answer names no listed route" <<<"$(row ".reject_reason")"' "the reason names the unlisted validator"
check '[ "$(row ".chosen_validator")" = null ]' "no validator is accepted"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_3","force_question":"validator","force_choice":"candidate_2"}'
run_observe clear
check '[ "$(row ".picker_status")" = rejected ]' "a same-family id outside the fallback options is rejected"
check 'grep -q "validator answer names no listed route" <<<"$(row ".reject_reason")"' "the fallback reason names the unlisted validator"
check '[ "$(calls)" -eq 3 ]' "the fallback call was made"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","effort_score":7}'
run_observe clear
check '[ "$(row ".picker_status")" = invalid-response ]' "an effort Score outside the criteria is malformed"
check 'grep -q "outside 0..4" <<<"$(row ".reject_reason")"' "the range is named"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","complexity_score":-1}'
run_observe clear
check '[ "$(row ".picker_status")" = invalid-response ]' "a complexity Score below zero is malformed"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","worker_confidence":1.5}'
run_observe clear
check '[ "$(row ".picker_status")" = invalid-response ]' "a confidence above 1 is malformed"
check '[ "$(row ".confidence_band")" = null ]' "no band is logged for a malformed confidence"
finish

begin "a validator must pass the same eligibility gate as a worker"
python3 -I - "$TMP_ROOT/result.json" "$TMP_ROOT/result-inelig.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for candidate in doc['candidates']:
    if candidate['profile']['model'] == 'openai-codex/gpt-6.1-sol':
        candidate.pop('capacity', None)
        candidate['eligible'] = False
        candidate['reason'] = 'harness not permitted by launch policy'
json.dump(doc, open(sys.argv[2], 'w'))
PY
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6","force_question":"validator","force_choice":"candidate_6"}'
RESULT_FILE="$TMP_ROOT/result-inelig.json" run_observe clear
validator_options=$(jq -r 'select(.questions.worker) | .questions.validator.criteria | keys[]' "$CALLS")
check '! grep -qx candidate_6 <<<"$validator_options"' "an ineligible route is not offered as a validator"
check '[ "$(row ".picker_status")" = rejected ]' "an ineligible validator answer is rejected"
check '[ "$(row ".chosen_validator")" = null ]' "no ineligible validator is accepted"
finish

begin "a standalone observe run checks the home never-send policy by default"
mkdir -p "$TMP_ROOT/home/config"
printf '%s\n' 'stale lock' > "$TMP_ROOT/home/config/dispatch-never-send"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
run_observe clear
check '[ "$(calls)" -eq 0 ]' "no request is sent without --never-send"
check '[ "$(row ".picker_status")" = withheld ]' "the home policy withholds the request"
rm -f "$TMP_ROOT/home/config/dispatch-never-send"
mkdir "$TMP_ROOT/home/config/dispatch-never-send"
run_observe clear
rmdir "$TMP_ROOT/home/config/dispatch-never-send"
check '[ "$(calls)" -eq 0 ]' "a policy that cannot be read sends nothing"
check '[ "$(row ".picker_status")" = withheld ]' "an unreadable policy withholds the request"
finish


# phase1_store: replaces the store with a Phase-1 one that predates the picker's columns.
phase1_store() {
rm -f "$DATA/aa.sqlite"
python3 -I - "$DATA/aa.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE dispatch_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('shadow','live')),
  task_type TEXT, work_type TEXT, complexity_score REAL,
  chosen_worker TEXT, chosen_validator TEXT, effort TEXT,
  rule_worker TEXT, rule_validator TEXT, rule_effort TEXT,
  jev_raw_payload BLOB, jev_candidate_version TEXT, gates TEXT,
  pareto_pruned TEXT, spend_priority TEXT, snapshot_age REAL,
  validator_verdict TEXT, validator_disagreement TEXT, rework INTEGER,
  captain_acceptance TEXT)""")
c.execute("CREATE TABLE outcomes (dispatch_id INTEGER PRIMARY KEY, quality REAL, rework INTEGER, time_s REAL, accepted INTEGER, notes TEXT)")
c.commit(); c.close()
PY
}

begin "the report migrates a Phase-1 store before reading its own columns"
phase1_store
OUT=$(FM_MODEL_PICKER_DATA="$DATA" bash "$BIN" --report 2>"$TMP_ROOT/report.err"); RC=$?
check '[ "$RC" -eq 0 ]' "report exits 0 on a Phase-1 store"
check '[ "$OUT" = "0 shadow dispatches logged" ]' "an unreadable-by-Phase-1 store reads as zero dispatches"
cols=$(python3 -I -c 'import sqlite3,sys;print(" ".join(r[1] for r in sqlite3.connect(sys.argv[1]).execute("pragma table_info(dispatch_log)")))' "$DATA/aa.sqlite")
check 'grep -q "confidence_band" <<<"$cols"' "the report applied the additive migration"
finish

# report_runs: the dispatches --report counts, the sum of its runs column.
report_runs() {
  FM_MODEL_PICKER_DATA="$DATA" bash "$BIN" --report 2>/dev/null \
    | sed -n '/^work_type /,/^Denominators:/p' | sed '1d;$d' | cut -c35- | awk '{s+=$1} END {print s+0}'
}
# parallel_briefs <prefix>: one distinct task brief per parallel dispatch.
parallel_briefs() {
  local i
  for i in 1 2 3 4 5; do
    mkdir -p "$TMP_ROOT/home/data/$1-$i"
    cp "$TMP_ROOT/brief.md" "$TMP_ROOT/home/data/$1-$i/brief.md"
  done
}

begin "five parallel dispatches write five rows"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
rm -f "$DATA/aa.sqlite"
parallel_briefs par
pids=()
for i in 1 2 3 4 5; do
  ( FM_HOME="$TMP_ROOT/home" FM_MODEL_PICKER_DATA="$DATA" FM_MODEL_PICKER_SHADOW=1 \
      FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT" \
      bash "$BIN" --observe --brief "$TMP_ROOT/home/data/par-$i/brief.md" \
        --task-text "$TMP_ROOT/home/data/par-$i/brief.md" \
        --rules "$TMP_ROOT/rules-base.json" --result "$TMP_ROOT/result.json" \
        --quota "$TMP_ROOT/quota.json" --status clear \
        3< <(printf 'synthetic-canary-key\n') >"$TMP_ROOT/par.$i.out" 2>"$TMP_ROOT/par.$i.err" ) &
  pids+=($!)
done
wait "${pids[@]}"
count=$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log where mode=\"shadow\"").fetchone()[0])' "$DATA/aa.sqlite")
check '[ "$count" = 5 ]' "five parallel dispatches give five rows"
accepted=$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log where picker_status=\"accepted\"").fetchone()[0])' "$DATA/aa.sqlite")
check '[ "$accepted" = 5 ]' "all five picks are accepted"
check '[ "$(report_runs)" = 5 ]' "the report counts five parallel dispatches"
finish

begin "a migration that finds its column already added by another writer still completes"
phase1_store
race=$(python3 -I - "$ROOT/bin" "$DATA/aa.sqlite" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
from fm_model_picker import aadb
conn = aadb.connect(sys.argv[2])
aadb.init_calibration(conn)
class StaleSchema:
    """A writer whose PRAGMA read happened before another writer's ALTER."""
    def __init__(self, conn):
        self.conn = conn
    def execute(self, sql, *args):
        if sql.startswith("PRAGMA table_info"):
            return iter([(0, "id")])
        return self.conn.execute(sql, *args)
    def commit(self):
        self.conn.commit()
aadb.init_calibration(StaleSchema(conn))
print("migrated")
PY
)
check '[ "$race" = migrated ]' "a duplicate column from a concurrent first open is not an error: $race"
finish

begin "five parallel first opens of a Phase-1 store write five rows"
settings '{"work_type":"feature","worker":"candidate_3","validator":"candidate_6"}'
phase1_store
parallel_briefs par1
pids=()
for i in 1 2 3 4 5; do
  ( FM_HOME="$TMP_ROOT/home" FM_MODEL_PICKER_DATA="$DATA" FM_MODEL_PICKER_SHADOW=1 \
      FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="$ENDPOINT" \
      bash "$BIN" --observe --brief "$TMP_ROOT/home/data/par1-$i/brief.md" \
        --task-text "$TMP_ROOT/home/data/par1-$i/brief.md" \
        --rules "$TMP_ROOT/rules-base.json" --result "$TMP_ROOT/result.json" \
        --quota "$TMP_ROOT/quota.json" --status clear \
        3< <(printf 'synthetic-canary-key\n') >"$TMP_ROOT/par1.$i.out" 2>"$TMP_ROOT/par1.$i.err" ) &
  pids+=($!)
done
wait "${pids[@]}"
count=$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log where mode=\"shadow\" and picker_status=\"accepted\"").fetchone()[0])' "$DATA/aa.sqlite")
check '[ "$count" = 5 ]' "five parallel first opens of a Phase-1 store give five accepted rows: $(cat "$TMP_ROOT"/par1.*.err)"
check '[ "$(report_runs)" = 5 ]' "the report counts five parallel first-open dispatches"
finish

[ "$FAILED" -eq 0 ] || fail "$FAILED shadow picker case(s) failed"
pass "shadow picker: gates, Pareto, currency separation, unknown routes, Jev failures, trusted data, re-check, validator pairing, report, privacy and flag"
