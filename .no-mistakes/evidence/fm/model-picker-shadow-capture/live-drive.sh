#!/usr/bin/env bash
# Live drive of bin/fm-spawn.sh shadow capture in a throwaway home. Prints a transcript.
set -u
WTROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5MTT81P8BWYWQFDAMK6GJCT
. "$WTROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-shadow-live-drive)
CASE="$TMP_ROOT/case"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; DATA="$CASE/data"
CALLS="$CASE/calls.jsonl"; SETTINGS="$CASE/settings.json"
mkdir -p "$CASE" "$DATA/projection"
for slug in claude-sonnet-5-5-high claude-opus-5-5-high claude-haiku-5-5 gpt-6-1-sol-high gpt-6-luna-low deepseek-v4-flash; do
  cp "$ROOT/tests/fixtures/model-picker-shadow/projection/$slug.json" "$DATA/projection/"
done
printf '%s\n' '{"verdict":"TRUSTED"}' > "$DATA/verdict.json"
printf '%s\n' '{"rules":[{"when":"Any task in the fixture.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"claude","model":"opus","effort":"high"},{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low"},{"harness":"omp","model":"deepseek/deepseek-v4-flash","effort":"high"}]}],"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$HOME_DIR.rules.json" 2>/dev/null || true
fm_test_spawn_home "$HOME_DIR" claude
cp "$HOME_DIR.rules.json" "$HOME_DIR/config/crew-dispatch.json"
fm_git_init_commit "$PROJ"; fm_git_add_origin "$PROJ" "$PROJ.origin.git"
mkwt() { git -C "$PROJ" worktree add --quiet -b "$1" "$CASE/wt-$1"; echo "$CASE/wt-$1"; }
printf 'TYPESAFE_API_KEY=synthetic-key\n' > "$HOME_DIR/.env"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
fm_fake_exit0 "$FAKEBIN" claude
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' > "$CASE/quota.json"
# Endpoint: same scripted Jev as the spawn suite, plus an optional delay knob.
sed -n '/^cat > "\$CASE\/provider.py" <<.PY.$/,/^PY$/p' "$ROOT/tests/fm-model-picker-shadow-spawn.test.sh" | sed '1d;$d' > "$CASE/provider.py"
python3 - "$CASE/provider.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("    def do_POST(self):\n", "    def do_POST(self):\n        import time, os\n        d=float(json.loads(open(settings_path).read()).get('delay',0))\n        time.sleep(d)\n",1)
open(p,'w').write(s)
PY
printf '%s\n' '{"work_type":"feature","worker":"candidate_2","validator":"candidate_6","effort_score":2}' > "$SETTINGS"
: > "$CALLS"
python3 "$CASE/provider.py" "$SETTINGS" "$CALLS" "$CASE/port" & SERVER=$!
trap 'kill $SERVER 2>/dev/null; fm_test_cleanup' EXIT
for _ in {1..100}; do [ -f "$CASE/port" ] && break; sleep .05; done
export FM_MODEL_PICKER_DATA="$DATA" FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$CASE/port")" QUOTA_AXI_FIXTURE="$CASE/quota.json"
sql() { python3 -I -c 'import sqlite3,sys
try: print("\n".join("|".join("" if v is None else str(v) for v in r) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))
except Exception as e: print(0)' "$DATA/aa.sqlite" "$1"; }
wait_until() { local dl=$((SECONDS + ${2:-60})); until eval "$1"; do [ $SECONDS -lt $dl ] || return 1; sleep .2; done; }
spawn() {  # <flag> <id> <wt> [args]
  local flag=$1 id=$2 wt=$3; shift 3
  fm_test_spawn_brief "$HOME_DIR" "$id" "Live drive brief for $id."
  FM_MODEL_PICKER_SHADOW="$flag" FM_FAKE_LAUNCH_LOG="$CASE/launch-$id.log" \
    fm_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" "$@"
}
hdr() { printf '\n===== %s =====\n' "$*"; }
ARGS=(--mode no-mistakes --yolo off --harness claude --model opus --effort high)

hdr "S1 flag off vs flag on: spawn output and launch command"
W=$(mkwt s1off); OUT_OFF=$(spawn '' s1-off "$W" "${ARGS[@]}"); echo "rc=$? off: $OUT_OFF"
W=$(mkwt s1on); OUT_ON=$(spawn 1 s1-on "$W" "${ARGS[@]}"); echo "rc=$? on:  $OUT_ON"
echo "normalized output identical: $([ "$(sed 's/s1-off/ID/g;s/s1off/WT/g' <<<"$OUT_OFF")" = "$(sed 's/s1-on/ID/g;s/s1on/WT/g' <<<"$OUT_ON")" ] && echo yes || echo NO)"
norm() { sed -E 's/s1-off|s1-on/ID/g;s/s1off|s1on/WT/g;s/operational-inbox\/[0-9]+-[0-9a-f]+\.msg/operational-inbox\/MSG/g' "$1"; }
echo "launch command identical (inbox message file name normalized): $(diff <(norm "$CASE/launch-s1-off.log") <(norm "$CASE/launch-s1-on.log") >/dev/null && echo yes || echo NO)"
wait_until '[ "$(sql "select count(*) from dispatch_log")" -ge 1 ]' || echo "no row before deadline"
sleep 2
echo "rows: task_key|rule_worker|rule_effort|picker_status|chosen_worker"
sql "select task_key,rule_worker,rule_effort,picker_status,chosen_worker from dispatch_log order by id"

hdr "S2 five parallel real fm-spawn launches"
rm -f "$DATA/aa.sqlite"; rm -rf "$DATA/resolver-rows"
for i in 1 2 3 4 5; do W=$(mkwt par$i); fm_test_spawn_brief "$HOME_DIR" par-$i "Parallel $i"; done
t0=$SECONDS
pids=()
for i in 1 2 3 4 5; do
  ( FM_MODEL_PICKER_SHADOW=1 fm_test_run_spawn "$HOME_DIR" "$CASE/wt-par$i" "$FAKEBIN" par-$i "$PROJ" "${ARGS[@]}" > "$CASE/par$i.out"; echo "rc=$?" >> "$CASE/par$i.out" ) & pids+=($!)
done
wait "${pids[@]}"
for i in 1 2 3 4 5; do tail -2 "$CASE/par$i.out" | tr '\n' ' '; echo; done
echo "all five spawns returned in $((SECONDS-t0)) s"
wait_until '[ "$(sql "select count(*) from dispatch_log")" -ge 5 ]' || echo "fewer than five rows before deadline"
sleep 3
echo "row count: $(sql "select count(*) from dispatch_log where mode='shadow'")"
sql "select task_key,rule_worker,rule_effort,picker_status from dispatch_log order by task_key"

hdr "S3 scout launch is captured"
W=$(mkwt scout1); OUT=$(spawn 1 scout-1 "$W" --scout --harness claude --model opus --effort high); echo "rc=$? $OUT"
wait_until '[ "$(sql "select count(*) from dispatch_log where task_key=\"scout-1\"")" -ge 1 ]' 60 || echo "no scout row"
sql "select task_key,rule_worker,rule_effort,picker_status from dispatch_log where task_key='scout-1'"

hdr "S4 slow endpoint (35 s per call): spawn returns at once; capture is bounded"
printf '%s\n' '{"work_type":"feature","worker":"candidate_2","validator":"candidate_6","effort_score":2,"delay":35}' > "$SETTINGS"
W=$(mkwt slow); t0=$(python3 -c 'import time;print(time.time())')
OUT=$(spawn 1 slow-1 "$W" "${ARGS[@]}"); rc=$?
t1=$(python3 -c 'import time;print(time.time())')
echo "rc=$rc $OUT"; echo "spawn wall time: $(python3 -c "print(round($t1-$t0,2))") s"
echo "detached helpers right after spawn: $(pgrep -f fm-model-picker-shadow-spawn.sh | wc -l | tr -d ' ')"
sleep 45
echo "detached helpers 45 s later: $(pgrep -f fm-model-picker-shadow-spawn.sh | wc -l | tr -d ' ')"
echo "slow row (bounded observe): $(sql "select task_key,rule_worker,picker_status from dispatch_log where task_key='slow-1'")"
printf '%s\n' '{"work_type":"feature","worker":"candidate_2","validator":"candidate_6","effort_score":2}' > "$SETTINGS"

hdr "S5 dead endpoint: spawn unchanged, failure swallowed"
W=$(mkwt dead); OUT=$(FM_TYPESAFE_TEST_ENDPOINT=http://127.0.0.1:9 spawn 1 dead-1 "$W" "${ARGS[@]}"); echo "rc=$? $OUT"
wait_until '[ "$(sql "select count(*) from dispatch_log where task_key=\"dead-1\"")" -ge 1 ]' 60 || echo "no row for dead endpoint"
echo "row: $(sql "select task_key,rule_worker,picker_status,gates from dispatch_log where task_key='dead-1'")"

hdr "S6 no TypeSafe key: spawn unchanged, no row"
mv "$HOME_DIR/.env" "$HOME_DIR/.env.off"
W=$(mkwt nokey); OUT=$(spawn 1 nokey-1 "$W" "${ARGS[@]}"); echo "rc=$? $OUT"
sleep 10
echo "rows for nokey-1: $(sql "select count(*) from dispatch_log where task_key='nokey-1'")"
mv "$HOME_DIR/.env.off" "$HOME_DIR/.env"

hdr "S7 refused launch (no brief) writes no row"
W=$(mkwt refused); rm -rf "$HOME_DIR/data/refused-1"
OUT=$(FM_MODEL_PICKER_SHADOW=1 fm_test_run_spawn "$HOME_DIR" "$W" "$FAKEBIN" refused-1 "$PROJ" "${ARGS[@]}"); echo "rc=$? $(head -3 <<<"$OUT")"
sleep 8
echo "rows for refused-1: $(sql "select count(*) from dispatch_log where task_key='refused-1'")"

hdr "S8 --report on the store written by real launches"
FM_MODEL_PICKER_SHADOW=1 bash "$ROOT/bin/fm-model-picker-shadow.sh" --report; echo "rc=$?"

hdr "S9 Phase-1 store: report, then a real launch migrates and writes, report again"
rm -f "$DATA/aa.sqlite"; rm -rf "$DATA/resolver-rows"
python3 -I - "$DATA/aa.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE dispatch_log (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('shadow','live')), task_type TEXT, work_type TEXT, complexity_score REAL,
  chosen_worker TEXT, chosen_validator TEXT, effort TEXT, rule_worker TEXT, rule_validator TEXT, rule_effort TEXT,
  jev_raw_payload BLOB, jev_candidate_version TEXT, gates TEXT, pareto_pruned TEXT, spend_priority TEXT, snapshot_age REAL,
  validator_verdict TEXT, validator_disagreement TEXT, rework INTEGER, captain_acceptance TEXT)""")
c.execute("CREATE TABLE outcomes (dispatch_id INTEGER PRIMARY KEY, quality REAL, rework INTEGER, time_s REAL, accepted INTEGER, notes TEXT)")
c.execute("INSERT INTO dispatch_log (at,mode,task_type,chosen_worker,rule_worker) VALUES ('2026-10-01T00:00:00Z','shadow','ship','claude:opus','claude:opus')")
c.commit()
PY
echo "phase-1 columns: $(python3 -I -c 'import sqlite3,sys;print(len(list(sqlite3.connect(sys.argv[1]).execute("pragma table_info(dispatch_log)"))))' "$DATA/aa.sqlite")"
bash "$ROOT/bin/fm-model-picker-shadow.sh" --report; echo "report rc=$?"
echo "columns after report: $(python3 -I -c 'import sqlite3,sys;print(len(list(sqlite3.connect(sys.argv[1]).execute("pragma table_info(dispatch_log)"))))' "$DATA/aa.sqlite")"
python3 -I - "$DATA/aa.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("DROP TABLE dispatch_log"); c.commit()
c.execute("""CREATE TABLE dispatch_log (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('shadow','live')), task_type TEXT, work_type TEXT, complexity_score REAL,
  chosen_worker TEXT, chosen_validator TEXT, effort TEXT, rule_worker TEXT, rule_validator TEXT, rule_effort TEXT,
  jev_raw_payload BLOB, jev_candidate_version TEXT, gates TEXT, pareto_pruned TEXT, spend_priority TEXT, snapshot_age REAL,
  validator_verdict TEXT, validator_disagreement TEXT, rework INTEGER, captain_acceptance TEXT)"""); c.commit()
PY
echo "reset to a Phase-1 store; launching five in parallel plus a concurrent --report"
for i in 1 2 3 4 5; do W=$(mkwt p1par$i); fm_test_spawn_brief "$HOME_DIR" p1-$i "Phase1 parallel $i"; done
pids=(); for i in 1 2 3 4 5; do ( FM_MODEL_PICKER_SHADOW=1 fm_test_run_spawn "$HOME_DIR" "$CASE/wt-p1par$i" "$FAKEBIN" p1-$i "$PROJ" "${ARGS[@]}" >/dev/null ) & pids+=($!); done
bash "$ROOT/bin/fm-model-picker-shadow.sh" --report > "$CASE/r.out" 2>&1; echo "concurrent report rc=$?: $(head -3 "$CASE/r.out")"
wait "${pids[@]}"
wait_until '[ "$(sql "select count(*) from dispatch_log")" -ge 5 ]' || echo "fewer than five rows on Phase-1 store"
sleep 3
echo "rows on migrated Phase-1 store: $(sql "select count(*) from dispatch_log where picker_status='accepted'") accepted of $(sql "select count(*) from dispatch_log")"
bash "$ROOT/bin/fm-model-picker-shadow.sh" --report; echo "report rc=$?"
echo "outcomes rows (must be 0): $(sql "select count(*) from outcomes")"
