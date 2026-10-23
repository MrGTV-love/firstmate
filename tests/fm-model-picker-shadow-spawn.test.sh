#!/usr/bin/env bash
# shellcheck disable=SC2016  # wait_until conditions are expanded on every poll.
# End-to-end shadow capture through bin/fm-spawn.sh: a real ship spawn with a fake
# tmux/treehouse/harness writes exactly one dispatch_log row carrying the route that
# actually launched, and the flag-off launch writes none. The capture runs detached, so
# every positive check polls the store with a deadline. A typed dispatch whose resolver
# already logged its row, and a relaunch, add no second row; a re-resolve supersedes the
# earlier resolver row, and a stale or edited-brief marker gets its own row. The TypeSafe key lives only
# in the home's .env, and the scripted Jev endpoint refuses any other bearer, so an
# accepted pick proves the hook resolved it. quota-axi is a fixture. This is the launch
# path that bypasses the typed resolver, so it is the capture path this test exists to prove.
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
for id in shadow-off shadow-capture shadow-typed shadow-override shadow-manual shadow-nomodel \
          shadow-noeffort shadow-withheld shadow-rerun shadow-stale shadow-edited; do
  fm_test_spawn_brief "$HOME_DIR" "$id" "Prove the launch capture path."
done
printf 'TYPESAFE_API_KEY=synthetic-key\n' > "$HOME_DIR/.env"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
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
        if self.headers.get('authorization') != 'Bearer synthetic-key':
            self.send_response(401)
            self.end_headers()
            return
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

row_count() {  # [task-key]
  python3 -I -c 'import sqlite3,sys; q="select count(*) from dispatch_log where mode=\"shadow\""; a=sys.argv[2:]; print(sqlite3.connect(sys.argv[1]).execute(q+(" and task_key=?" if a else ""), a).fetchone()[0])' "$DATA/aa.sqlite" "$@" 2>/dev/null || echo 0
}
row_field() {  # <column> <task-key>
  python3 -I -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("select "+sys.argv[2]+" from dispatch_log where mode=\"shadow\" and task_key=? order by id desc limit 1", (sys.argv[3],)).fetchone(); print("" if r is None or r[0] is None else r[0])' "$DATA/aa.sqlite" "$1" "$2"
}
# The capture is detached from the spawn, so wait for its evidence with a deadline
# above the 40-second outer bound.
wait_until() {  # <shell-condition>
  local deadline=$((SECONDS + 60))
  until eval "$1"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep .2
  done
}
FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$CASE/port")"
export FM_MODEL_PICKER_DATA="$DATA" FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT \
  QUOTA_AXI_FIXTURE="$CASE/quota.json"
run_launch() {  # <flag> <id> [extra args]
  local flag=$1 id=$2
  shift 2
  OUT='' CODE=0
  # fm_test_run_spawn starts fm-spawn.sh with its own env prefix, so the picker
  # settings must be exported to survive into the child.
  export FM_MODEL_PICKER_SHADOW="$flag"
  OUT=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" \
      --mode no-mistakes --yolo off --harness claude --model opus --effort high "$@") || CODE=$?
}
# A relaunch needs the recorded window listed and its pane at an idle shell.
run_relaunch() {  # <id>
  local id=$1 bin="$CASE/relaunch-shell"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$FAKEBIN/tmux" "\$@"
SH
  chmod +x "$bin/tmux"
  OUT='' CODE=0
  export FM_MODEL_PICKER_SHADOW=1
  OUT=$(FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$HOME_DIR/state/$id.meta")" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$bin:$FAKEBIN" "$id" --relaunch) || CODE=$?
}

rm -f "$DATA/aa.sqlite"; rm -rf "$DATA/resolver-rows"; : > "$CALLS"
run_launch '' shadow-off
assert_equals 0 "$CODE" 'flag-off spawn succeeds'
assert_contains "$OUT" "spawned shadow-off" 'flag-off spawn reports its task'
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" 'flag-off launch makes no picker request'

run_launch 1 shadow-capture
assert_equals 0 "$CODE" 'flag-on spawn succeeds'
assert_contains "$OUT" "spawned shadow-capture" 'flag-on spawn output is unchanged'
wait_until '[ "$(row_count)" -ge 1 ]' || fail 'the detached capture wrote no row before the deadline'
assert_equals 1 "$(row_count)" 'one real launch writes exactly one shadow row'
assert_equals 0 "$(row_count shadow-off)" 'flag-off launch writes no shadow row'
assert_equals 'claude:opus' "$(row_field rule_worker shadow-capture)" 'the row records the route that actually launched'
assert_equals 'high' "$(row_field rule_effort shadow-capture)" 'the row records the launched effort'
assert_equals 'accepted' "$(row_field picker_status shadow-capture)" 'the picker accepted its pick with the .env key'
[ -n "$(row_field chosen_worker shadow-capture)" ] || fail 'the row records the picker worker'
[ -n "$(row_field jev_raw_payload shadow-capture)" ] || fail 'the row retains the raw Jev result'
[ "$(wc -l < "$CALLS" | tr -d ' ')" -ge 2 ] || fail 'the launch observation made its bounded calls'
assert_equals project "$(python3 -I -c 'import json,sys; print(sorted({json.loads(l)["state"]["project"] for l in open(sys.argv[1]) if l.strip()}) == ["project"] and "project" or "missing")' "$CALLS")" 'every launch request carries the launch project'

run_relaunch shadow-capture
assert_equals 0 "$CODE" "relaunch succeeds: $OUT"

# The typed path: the resolver hook's own observe call logs the row first, and the
# launch then attaches the route that actually launched to that one row.
resolver_observe() {  # <id> <status> <result-json>
  printf '%s\n' "$3" > "$CASE/result-$1.json"
  FM_MODEL_PICKER_SHADOW=1 FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-model-picker-shadow.sh" --observe \
    --brief "$HOME_DIR/data/$1/brief.md" --task-text "$HOME_DIR/data/$1/brief.md" \
    --rules "$CASE/crew-dispatch.json" --result "$CASE/result-$1.json" --quota "$CASE/quota.json" \
    --status "$2" --project project 3< <(printf 'synthetic-key') >/dev/null 2>&1
}
attached() {  # <id> <field>: the resolver route kept under gates.launch_attached
  python3 -I -c 'import json,sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("select gates from dispatch_log where task_key=?", (sys.argv[2],)).fetchone(); a=json.loads(r[0]).get("launch_attached") if r else None; print("missing" if a is None else ("" if a.get(sys.argv[3]) is None else a[sys.argv[3]]))' "$DATA/aa.sqlite" "$1" "$2"
}

resolver_observe shadow-typed ambiguous '{"status":"ambiguous","candidates":[]}'
assert_equals 1 "$(row_count shadow-typed)" 'the resolver hook logs the ambiguous dispatch'
assert_equals '' "$(row_field rule_worker shadow-typed)" 'an ambiguous resolve names no rule route'
[ -e "$DATA/resolver-rows/shadow-typed" ] || fail 'the resolver row leaves its one-shot marker'
run_launch 1 shadow-typed
assert_equals 0 "$CODE" 'the ambiguous-then-launched dispatch succeeds'
wait_until '[ "$(row_field rule_worker shadow-typed)" = claude:opus ]' \
  || fail 'the launch was not attached to the ambiguous resolver row'
assert_equals 'high' "$(row_field rule_effort shadow-typed)" 'the ambiguous row carries the launched effort'
assert_equals '' "$(attached shadow-typed resolver_worker)" 'the attachment keeps the resolver route, none here'
[ ! -e "$DATA/resolver-rows/shadow-typed" ] || fail 'the spawn hook consumed the resolver marker'

resolver_observe shadow-override clear \
  '{"status":"clear","chosen":{"profile":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"low"}},"candidates":[]}'
assert_equals 'omp:openai-codex/gpt-6.1-sol' "$(row_field rule_worker shadow-override)" 'the clear resolve logs its own route'
run_launch 1 shadow-override
assert_equals 0 "$CODE" 'the overridden launch succeeds'
wait_until '[ "$(row_field rule_worker shadow-override)" = claude:opus ]' \
  || fail 'the overriding launch was not attached to the clear resolver row'
assert_equals 'high' "$(row_field rule_effort shadow-override)" 'the overridden row carries the launched effort'
assert_equals 'omp:openai-codex/gpt-6.1-sol' "$(attached shadow-override resolver_worker)" 'the resolver proposal is kept under gates'
assert_equals 'low' "$(attached shadow-override resolver_effort)" 'the resolver effort is kept under gates'

# A manual launch with no resolver row still gets its row; it lands after the
# relaunch and typed-spawn captures would have, so their absence is settled.
run_launch 1 shadow-manual
assert_equals 0 "$CODE" 'the manual launch succeeds'
wait_until '[ "$(row_count shadow-manual)" -ge 1 ]' || fail 'the manual launch wrote no row before the deadline'
assert_equals 1 "$(row_count shadow-capture)" 'a relaunch writes no second row'
assert_equals 1 "$(row_count shadow-typed)" 'an ambiguous typed dispatch keeps exactly one row'
assert_equals 1 "$(row_count shadow-override)" 'an overridden typed dispatch keeps exactly one row'
assert_equals 1 "$(row_count shadow-manual)" 'a manual launch with no resolver row gets one row'
assert_equals missing "$(attached shadow-manual resolver_worker)" 'a manual launch attaches to no resolver row'
assert_equals 4 "$(row_count)" 'one row per dispatch'

# A launch with no concrete model records no rule route; no effort records NULL.
spawn_hook() {  # <id> [hook args]
  local id=$1
  shift
  FM_MODEL_PICKER_SHADOW=1 FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-model-picker-shadow-spawn.sh" \
    --brief "$HOME_DIR/data/$id/brief.md" --harness claude --rules "$CASE/crew-dispatch.json" \
    --never-send "$HOME_DIR/config/dispatch-never-send" --kind ship --project project "$@"
}
spawn_hook shadow-nomodel --model default --effort high
assert_equals 1 "$(row_count shadow-nomodel)" 'a default-model launch is still observed'
assert_equals '' "$(row_field rule_worker shadow-nomodel)" 'a default-model launch records no rule route'
spawn_hook shadow-noeffort --model opus --effort ''
assert_equals 'claude:opus' "$(row_field rule_worker shadow-noeffort)" 'an effortless launch keeps its route'
assert_equals '' "$(row_field rule_effort shadow-noeffort)" 'an empty effort is not a rule effort'
assert_equals 1 "$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from dispatch_log where task_key=? and rule_effort is null", (sys.argv[2],)).fetchone()[0])' "$DATA/aa.sqlite" shadow-noeffort)" 'an empty effort is stored as NULL'

# A launch brief the never-send policy withholds still records the launched route.
printf '%s\n' '# Task' '<!-- dispatch-never-send:start -->' 'secret' '<!-- dispatch-never-send:end -->' \
  > "$HOME_DIR/data/shadow-withheld/brief.md"
spawn_hook shadow-withheld --model opus --effort high
assert_equals 'withheld' "$(row_field picker_status shadow-withheld)" 'an unmarked-policy brief is withheld'
assert_equals 'claude:opus' "$(row_field rule_worker shadow-withheld)" 'a withheld launch keeps its launched route'

gate_field() {  # <row-id> <key>
  python3 -I -c 'import json,sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("select gates from dispatch_log where id=?", (int(sys.argv[2]),)).fetchone(); v=json.loads(r[0] or "{}").get(sys.argv[3]) if r else None; print("missing" if v is None else v)' "$DATA/aa.sqlite" "$1" "$2"
}
live_count() {  # <task-key>: rows the report counts, i.e. not superseded
  python3 -I -c 'import json,sqlite3,sys; print(sum("superseded_by" not in json.loads(g or "{}") for (g,) in sqlite3.connect(sys.argv[1]).execute("select gates from dispatch_log where task_key=?", (sys.argv[2],))))' "$DATA/aa.sqlite" "$1"
}
report_no_route() {
  FM_MODEL_PICKER_DATA="$DATA" bash "$ROOT/bin/fm-model-picker-shadow.sh" --report 2>/dev/null \
    | sed -n 's/.*; \([0-9][0-9]*\) rows have no rule route\..*/\1/p'
}
AMBIGUOUS='{"status":"ambiguous","candidates":[]}'

# Two resolves for one task then one launch: the first row is superseded, the second
# carries the launched route, and the report counts the dispatch once.
no_route_before=$(report_no_route)
[ -n "$no_route_before" ] || fail 'the report states its no-rule-route count'
resolver_observe shadow-rerun ambiguous "$AMBIGUOUS"
first=$(row_field id shadow-rerun)
resolver_observe shadow-rerun ambiguous "$AMBIGUOUS"
second=$(row_field id shadow-rerun)
assert_equals "$second" "$(gate_field "$first" superseded_by)" 'a re-resolve supersedes the earlier resolver row'
spawn_hook shadow-rerun --model opus --effort high
assert_equals 2 "$(row_count shadow-rerun)" 'the launch after a re-resolve writes no third row'
assert_equals 1 "$(live_count shadow-rerun)" 'exactly one non-superseded row for the re-resolved dispatch'
assert_equals 'claude:opus' "$(row_field rule_worker shadow-rerun)" 'the newest resolver row carries the launched route'
[ "$(gate_field "$second" launch_attached)" != missing ] || fail 'the launch attached to the newest resolver row'
assert_equals missing "$(gate_field "$first" launch_attached)" 'the superseded row is not attached'
[ ! -e "$DATA/resolver-rows/shadow-rerun" ] || fail 'the spawn hook consumed the re-resolve marker'
assert_equals "$no_route_before" "$(report_no_route)" 'the report leaves the superseded row out'

# A marker older than one hour is deleted and the launch writes its own row.
resolver_observe shadow-stale ambiguous "$AMBIGUOUS"
stale=$(row_field id shadow-stale)
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["created_at"]-=7200; open(p,"w").write(json.dumps(d))' \
  "$DATA/resolver-rows/shadow-stale"
spawn_hook shadow-stale --model opus --effort high
assert_equals 2 "$(row_count shadow-stale)" 'a stale marker leaves the launch its own row'
[ ! -e "$DATA/resolver-rows/shadow-stale" ] || fail 'the spawn hook deleted the stale marker'
[ "$(row_field id shadow-stale)" != "$stale" ] || fail 'the launch row is new'
assert_equals 'claude:opus' "$(row_field rule_worker shadow-stale)" 'the launch row carries the launched route'
assert_equals missing "$(gate_field "$stale" launch_attached)" 'the stale resolver row is not attached'
assert_equals '' "$(python3 -I -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select rule_worker from dispatch_log where id=?", (int(sys.argv[2]),)).fetchone()[0] or "")' "$DATA/aa.sqlite" "$stale")" 'the stale resolver row keeps its own route'

# A marker written for a brief that changed before the launch is not this dispatch's.
resolver_observe shadow-edited ambiguous "$AMBIGUOUS"
edited=$(row_field id shadow-edited)
printf '%s\n' 'One more detail.' >> "$HOME_DIR/data/shadow-edited/brief.md"
spawn_hook shadow-edited --model opus --effort high
assert_equals 2 "$(row_count shadow-edited)" 'an edited-brief marker leaves the launch its own row'
[ ! -e "$DATA/resolver-rows/shadow-edited" ] || fail 'the spawn hook deleted the edited-brief marker'
assert_equals missing "$(gate_field "$edited" launch_attached)" 'the edited-brief resolver row is not attached'

pass 'spawn capture: one row per launched dispatch carrying the launched route; a typed launch attaches to its fresh same-brief resolver row; a re-resolve supersedes; flag off and relaunch add none'
