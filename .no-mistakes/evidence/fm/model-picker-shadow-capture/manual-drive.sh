#!/usr/bin/env bash
# Manual drive of real bin/fm-spawn.sh launches in a throwaway home.
set -u
WTROOT=$1 EVID=$2
cd "$WTROOT"
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-shadow-manual-drive)
CASE="$TMP_ROOT/case"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"; DATA="$CASE/data"
CALLS="$CASE/calls.jsonl"; SETTINGS="$CASE/settings.json"; LAUNCH_LOG="$CASE/launch.log"
mkdir -p "$CASE" "$DATA/projection"
for slug in claude-sonnet-5-5-high claude-opus-5-5-high claude-haiku-5-5 gpt-6-1-sol-high gpt-6-luna-low deepseek-v4-flash; do
  cp "$ROOT/tests/fixtures/model-picker-shadow/projection/$slug.json" "$DATA/projection/"; done
printf '%s\n' '{"verdict":"TRUSTED"}' > "$DATA/verdict.json"
fm_test_spawn_home "$HOME_DIR" claude
printf '%s\n' '{"rules":[{"when":"Any task in the fixture.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"claude","model":"opus","effort":"high"},{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low"},{"harness":"omp","model":"deepseek/deepseek-v4-flash","effort":"high"}]}],"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$HOME_DIR/config/crew-dispatch.json"
fm_git_worktree "$PROJ" "$WT" "wt-manual"
for id in off-1 on-1 par-1 par-2 par-3 par-4 par-5 down-on down-off scout-1; do
  fm_test_spawn_brief "$HOME_DIR" "$id" "Manual drive task $id."; done
printf 'TYPESAFE_API_KEY=manual-key\n' > "$HOME_DIR/.env"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake"); fm_fake_exit0 "$FAKEBIN" claude
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' > "$CASE/quota.json"
# Scripted Jev endpoint stand-in (external API), same shape as the repo test's.
sed -n "/^cat > \"\$CASE\/provider.py\" <<'PY'$/,/^PY$/p" tests/fm-model-picker-shadow-spawn.test.sh | sed '1d;$d' | sed 's/Bearer synthetic-key/Bearer manual-key/' > "$CASE/provider.py"
printf '%s\n' '{"work_type":"feature","worker":"candidate_2","validator":"candidate_6","effort_score":2}' > "$SETTINGS"
: > "$CALLS"
python3 "$CASE/provider.py" "$SETTINGS" "$CALLS" "$CASE/port" & SERVER=$!
trap 'kill $SERVER 2>/dev/null; fm_test_cleanup' EXIT
for _ in {1..100}; do [ -f "$CASE/port" ] && break; sleep .05; done
export FM_MODEL_PICKER_DATA="$DATA" FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$CASE/port")" QUOTA_AXI_FIXTURE="$CASE/quota.json"
export FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG"
q() { python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); [print("|".join("" if v is None else str(v) for v in r)) for r in c.execute(sys.argv[2])]' "$DATA/aa.sqlite" "$1" 2>/dev/null; }
count() { local n; n=$(q "select count(*) from dispatch_log where mode='shadow'"); echo "${n:-0}"; }
launch() {  # <flag> <id> [args]
  local flag=$1 id=$2; shift 2
  FM_MODEL_PICKER_SHADOW="$flag" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off --harness claude --model opus --effort high "$@"
}
waitfor() { local d=$((SECONDS+60)); until eval "$1"; do [ $SECONDS -lt $d ] || return 1; sleep .2; done; }
echo "== Step 0: Phase-1 store (pre-picker columns) with one old row; --report must migrate it"
python3 -I - "$DATA/aa.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE dispatch_log (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('shadow','live')), task_type TEXT, work_type TEXT, complexity_score REAL,
  chosen_worker TEXT, chosen_validator TEXT, effort TEXT, rule_worker TEXT, rule_validator TEXT, rule_effort TEXT,
  jev_raw_payload BLOB, jev_candidate_version TEXT, gates TEXT, pareto_pruned TEXT, spend_priority TEXT, snapshot_age REAL,
  validator_verdict TEXT, validator_disagreement TEXT, rework INTEGER, captain_acceptance TEXT)""")
c.execute("CREATE TABLE outcomes (dispatch_id INTEGER PRIMARY KEY, quality REAL, rework INTEGER, time_s REAL, accepted INTEGER, notes TEXT)")
c.commit()
PY
echo "columns before: $(q "select group_concat(name,' ') from pragma_table_info('dispatch_log')" | wc -w | tr -d ' ')"
FM_MODEL_PICKER_SHADOW=1 bash bin/fm-model-picker-shadow.sh --report; echo "report exit=$?"
echo "columns after:  $(q "select group_concat(name,' ') from pragma_table_info('dispatch_log')" | wc -w | tr -d ' ')"
echo
echo "== Step 1: flag OFF real fm-spawn launch"
OUT=$(launch '' off-1); echo "exit=$? out: $OUT"
sleep 3
echo "rows=$(count) jev_calls=$(wc -l < "$CALLS" | tr -d ' ')"
echo
echo "== Step 2: flag ON real fm-spawn launch (timed return)"
t0=$(python3 -c 'import time;print(time.time())')
OUT=$(launch 1 on-1); rc=$?
t1=$(python3 -c 'import time;print(time.time())')
echo "exit=$rc out: $OUT"
echo "fm-spawn returned in $(python3 -c "print(round($t1-$t0,2))") s; rows right after return: $(count)"
waitfor '[ "$(count)" -ge 1 ]' && echo "row landed (detached capture)"
echo "rows=$(count)"
q "select id,task_key,rule_worker,rule_effort,picker_status,chosen_worker,chosen_validator,effort,hook from dispatch_log" 2>/dev/null || q "select id,task_key,rule_worker,rule_effort,picker_status,chosen_worker,chosen_validator,effort from dispatch_log"
echo
echo "== Step 3: five parallel real fm-spawn launches"
PIDS=(); for i in 1 2 3 4 5; do ( launch 1 par-$i > "$CASE/par-$i.out"; echo "par-$i exit=$?" >> "$CASE/par.rc" ) & PIDS+=($!); done; wait "${PIDS[@]}"
cat "$CASE/par.rc"; for i in 1 2 3 4 5; do grep -o "spawned par-$i[^ ]*" "$CASE/par-$i.out"; done
waitfor '[ "$(q "select count(*) from dispatch_log where task_key like '"'"'par-%'"'"'")" -ge 5 ]' && echo "five rows landed"
sleep 2
q "select task_key,count(*),rule_worker,rule_effort,picker_status from dispatch_log where task_key like 'par-%' group by task_key"
echo
echo "== Step 4: scout launch"
OUT=$(FM_MODEL_PICKER_SHADOW=1 fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" scout-1 "$PROJ" --scout --harness claude --model opus --effort high); echo "exit=$? out: $OUT"
waitfor '[ "$(q "select count(*) from dispatch_log where task_key='"'"'scout-1'"'"'")" -ge 1 ]' && echo "scout row landed"
q "select task_key,rule_worker,rule_effort,picker_status from dispatch_log where task_key='scout-1'"
echo
echo "== Step 5 (adversarial): Jev endpoint DOWN; compare launch with flag on vs off"
kill $SERVER; sleep .3
: > "$LAUNCH_LOG"
OUT_ON=$(launch 1 down-on); rc_on=$?
cp "$LAUNCH_LOG" "$CASE/launch-on"; : > "$LAUNCH_LOG"
OUT_OFF=$(launch '' down-off); rc_off=$?
cp "$LAUNCH_LOG" "$CASE/launch-off"
echo "flag on : exit=$rc_on out: $OUT_ON"
echo "flag off: exit=$rc_off out: $OUT_OFF"
norm() { sed -e 's/down-on/ID/g; s/down-off/ID/g' -e 's/at=[0-9]*/at=T/g' -e 's#operational-inbox/[0-9a-f-]*\.msg#operational-inbox/X.msg#g' "$1"; }
if diff <(norm "$CASE/launch-on") <(norm "$CASE/launch-off") >/dev/null; then echo "launch commands identical (modulo task id)"; else echo "LAUNCH COMMANDS DIFFER"; diff <(norm "$CASE/launch-on") <(norm "$CASE/launch-off"); fi
[ "$(printf '%s' "$OUT_ON" | sed 's/down-on/ID/g;s/wt-[^ ]*/W/g')" = "$(printf '%s' "$OUT_OFF" | sed 's/down-off/ID/g;s/wt-[^ ]*/W/g')" ] && echo "spawn stdout identical (modulo task id)" || echo "SPAWN STDOUT DIFFERS"
waitfor '[ "$(q "select count(*) from dispatch_log where task_key='"'"'down-on'"'"'")" -ge 1 ]' && echo "endpoint-down launch still recorded"
q "select task_key,rule_worker,rule_effort,picker_status from dispatch_log where task_key like 'down-%'"
echo
echo "== Step 6: final store and --report"
q "select task_key,count(*) from dispatch_log group by task_key order by task_key"
FM_MODEL_PICKER_SHADOW=1 bash bin/fm-model-picker-shadow.sh --report; echo "report exit=$?"
