#!/usr/bin/env bash
# Retirement test for jev-shell-model-gate.
# The gate asked Jev whether a shell command was irreversible or destructive and
# refused it on that answer; the assessment at data/fm-jev-guard-e2e/report.md
# found 63 of its 69 refusals were the worker's own cleanup.
# Pass case: shell commands the gate refused, sent while the judge would refuse
# them, now pass on omp and on a Claude worker that still carries the old Bash
# hook registration, with no judge request and no guard audit row.
# Block case: a write the same judge refuses still reaches it and still denies.
# Every case uses a loopback fixture judge; no provider is called.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
unset FM_JEV_GUARD_BASE_URL
unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-shell-model-gate)
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/worktree"
TASK_DATA="$HOME_DIR/data/t1"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TASK_DATA" "$WT"
printf 'TYPESAFE_API_KEY=%s\n' fm-retired-jev-shell-model-gate-key > "$HOME_DIR/.env"
HOOK="$ROOT/bin/fm-jev-guard-hook.sh"
HOOK_ARGS=("$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1)

cat > "$TMP_ROOT/fake.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    appendFileSync(log, 'request\n');
    const answers = {};
    for (const [id, q] of Object.entries(JSON.parse(body).questions)) {
      if (q.type === 'noul') { answers[id] = { type: 'noul', noul: 0.95 }; continue; }
      const keys = Object.keys(q.criteria);
      const pick = keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])) };
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
JS
REQUESTS="$TMP_ROOT/requests.log"
: > "$REQUESTS"
node "$TMP_ROOT/fake.mjs" "$REQUESTS" "$TMP_ROOT/port" &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.05; done
[ -s "$TMP_ROOT/port" ] || fail "fake TypeSafe endpoint did not start"
FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$TMP_ROOT/port")/v1/systemone"
export FM_JEV_GUARD_BASE_URL

out=''
status=0
run_hook() {  # <payload>
  out=$(printf '%s' "$1" | "$HOOK" "${HOOK_ARGS[@]}" 2>"$TMP_ROOT/hook.err")
  status=$?
}
requests() { wc -l < "$REQUESTS" | tr -d ' '; }

# --- pass cases: the commands the gate refused now run unjudged ---------------
COMMANDS=('rm -rf build' "rm '$TASK_DATA/smoke.py'" 'git reset --hard HEAD' "$WT/fm-herdr-lab.sh teardown")
for command in "${COMMANDS[@]}"; do
  run_hook "$(jq -cn --arg cwd "$WT" --arg c "$command" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$c},tool_use_id:"retired-call"}')"
  [ "$status" -eq 0 ] || fail "Claude shell call exited $status: $command"
  [ -z "$out" ] || fail "Claude shell call was still judged: $command: $out"
  [ ! -s "$TMP_ROOT/hook.err" ] || fail "Claude shell call wrote stderr: $(cat "$TMP_ROOT/hook.err")"
done
out=$(GUARD="$ROOT/bin/fm-jev-guard.ts" HOME_DIR="$HOME_DIR" WT="$WT" TASK_DATA="$TASK_DATA" \
  COMMANDS="$(jq -cn '$ARGS.positional' --args "${COMMANDS[@]}")" \
  node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const handlers = {};
installJevGuard({ on(name, handler) { handlers[name] = handler; } }, { home, config: `${home}/config`, state: `${home}/state`,
  task: 't1', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1', host: 'omp' });
for (const command of JSON.parse(process.env.COMMANDS)) {
  assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command } }, { cwd: process.env.WT }), undefined, command);
}
console.log('omp-shell-ok');
JS
) || fail "omp shell calls: $out"
[ "$out" = omp-shell-ok ] || fail "unexpected omp shell output: $out"
[ "$(requests)" -eq 0 ] || fail "a shell call reached the judge"
[ ! -e "$HOME_DIR/state/jev-guard.jsonl" ] || fail "a shell call wrote a guard audit row"
pass "shell commands the gate refused pass on omp and an old-matcher Claude worker without a judge request or audit row"

# --- block case: the same judge still refuses a write -------------------------
run_hook "$(jq -cn --arg cwd "$WT" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:"src/retired.txt",content:"sk-live-fixture"},tool_use_id:"retired-write"}')"
[ "$status" -eq 0 ] || fail "write deny exited $status instead of the deny path's 0"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null || fail "the refusing judge no longer denies a write: $out"
[ "$(requests)" -eq 1 ] || fail "the write did not receive exactly one judgment"
pass "a write the same judge refuses still reaches it and denies"
