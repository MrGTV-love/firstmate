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
for id in t-off-1 t-on-1 t-off-2 t-on-2; do
  fm_test_spawn_brief "$HOME_DIR" "$id" "Manual drive task $id."; done
printf 'TYPESAFE_API_KEY=manual-key\n' > "$HOME_DIR/.env"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake"); fm_fake_exit0 "$FAKEBIN" claude
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
sleep 4
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

now() { python3 -c 'import time;print(time.time())'; }
for pair in "'' t-off-1" "1 t-on-1" "'' t-off-2" "1 t-on-2"; do
  eval "set -- $pair"; f=$1 id=$2
  t0=$(now); launch "$f" "$id" >/dev/null; rc=$?; t1=$(now)
  echo "flag=${f:-off} id=$id exit=$rc fm-spawn returned in $(python3 -c "print(round($t1-$t0,2))") s; row for $id right after return: $(q "select count(*) from dispatch_log where task_key='$id'")"
done
waitfor '[ "$(q "select count(*) from dispatch_log where task_key in ('"'"'t-on-1'"'"','"'"'t-on-2'"'"')")" -ge 2 ]' && echo "both flag-on rows landed later (detached)"
q "select task_key,rule_worker,rule_effort,picker_status from dispatch_log"
