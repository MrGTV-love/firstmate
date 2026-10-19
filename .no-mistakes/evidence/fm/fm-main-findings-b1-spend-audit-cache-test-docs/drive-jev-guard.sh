#!/usr/bin/env bash
# Live driver: runs the REAL Claude hook (bin/fm-jev-guard-hook.sh -> adapter -> guard -> service -> client -> audit ledger)
# against a disposable loopback fake provider. No model request, no network beyond 127.0.0.1.
# usage: drive-jev-guard.sh <tree-root-containing-bin/> <label> <outdir>
set -u
TREE=$1 LABEL=$2 OUT=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/jevdrive.XXXXXX")
HOME_DIR=$T/home WT=$T/wt
TASK_DATA=$HOME_DIR/data/t1
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TASK_DATA" "$WT" "$OUT"
printf 'TYPESAFE_API_KEY=drive-fixture-key\n' > "$HOME_DIR/.env"
cat > "$T/fake.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
const seen = new Set();
createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const request = JSON.parse(body);
    const text = JSON.stringify(request.state);
    appendFileSync(log, JSON.stringify({ n: text.length, fail: text.includes('fail500'), flaky: text.includes('flaky-once') }) + '\n');
    if (text.includes('fail500')) { res.statusCode = 500; res.end('{}'); return; }
    if (text.includes('flaky-once') && !seen.has(text)) { seen.add(text); res.statusCode = 500; res.end('{}'); return; }
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      answers[id] = q.type === 'noul' ? { type: 'noul', noul: 0.05 }
        : { type: 'choice', choice: Object.keys(q.criteria)[0], confidence: 1, probabilities: Object.fromEntries(Object.keys(q.criteria).map((k, i) => [k, i === 0 ? 1 : 0])) };
    }
    const usage = { input_tokens: 3, output_tokens: 1 };
    if (text.includes('reported-cost')) usage.cost = 0.001;
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage }));
  });
}).listen(0, '127.0.0.1', function () { writeFileSync(portFile, String(this.address().port)); });
JS
REQ=$T/requests.log; : > "$REQ"
node "$T/fake.mjs" "$REQ" "$T/port" & FAKE=$!
trap 'kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 100); do [ -s "$T/port" ] && break; sleep 0.05; done
[ -s "$T/port" ] || { echo "fake did not start" >&2; exit 1; }
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$T/port")/v1/systemone"
LEDGER=$HOME_DIR/state/jev-guard.jsonl
hook() { printf '%s' "$1" | "$TREE/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$T/hook.err"; }
pre()  { jq -cn --arg cwd "$WT" --arg tool "$1" --argjson input "$2" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:$input,tool_use_id:"drive"}'; }
post() { jq -cn --arg cwd "$WT" --arg tool "$1" --argjson response "$2" '{hook_event_name:"PostToolUse",cwd:$cwd,tool_name:$tool,tool_input:{file_path:"x.txt"},tool_response:$response,tool_use_id:"drive"}'; }
filler() { head -c "$1" /dev/zero | tr '\0' "${2:-a}"; }
rows() { [ -f "$LEDGER" ] && wc -l < "$LEDGER" | tr -d ' ' || echo 0; }
reqs() { wc -l < "$REQ" | tr -d ' '; }
# scenario <name> <hook-payload>
scenario() {
  local name=$1 payload=$2 r0 q0 out status started
  r0=$(rows); q0=$(reqs); started=$(date +%s)
  out=$(hook "$payload"); status=$?
  local r1; r1=$(rows)
  local row="null"
  [ "$r1" -gt "$r0" ] && row=$(tail -n 1 "$LEDGER")
  jq -cn --arg label "$LABEL" --arg name "$name" --argjson status "$status" --argjson new_rows "$((r1 - r0))" --argjson provider_requests "$(( $(reqs) - q0 ))" \
    --argjson wall_s "$(( $(date +%s) - started ))" --arg denied "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)" --argjson row "$row" \
    '{label:$label,scenario:$name,hook_exit:$status,permission:$denied,audit_rows_added:$new_rows,provider_requests:$provider_requests,wall_s:$wall_s,
      row:(if $row == null then null else ($row | {tool,decision,enforcement,branch,error_type,request_started,attempts,ms,chunks,planned_chunks,failures,cost,usage}) end)}' \
    | tee -a "$OUT/$LABEL-scenarios.jsonl"
}
: > "$OUT/$LABEL-scenarios.jsonl"
# 3 pieces: piece 1 answers with a reported cost, pieces 2 and 3 each hit a provider 500 (3 tries each).
TWO_FAIL=$(printf 'reported-cost %s fail500 %s fail500 %s' "$(filler 22000)" "$(filler 15500)" "$(filler 6000)")
scenario "S1a result: two failed pieces beside one answered piece" "$(post Bash "$(jq -cn --arg s "$TWO_FAIL" '{stdout:$s,stderr:""}')")"
scenario "S1b write:  two failed pieces beside one answered piece" "$(pre Write "$(jq -cn --arg p "$WT/src/big.ts" --arg c "$TWO_FAIL" '{file_path:$p,content:$c}')")"
# Blank middle piece: 'reported-cost' at both ends, spaces between. Only two pieces need screening.
BLANK=$(printf 'reported-cost %s reported-cost end' "$(filler 40000 ' ')")
scenario "S3 result: blank middle piece (adversarial)" "$(post Bash "$(jq -cn --arg s "$BLANK" '{stdout:$s,stderr:""}')")"
# Failures before any piece exists.
scenario "S4a write: non-string content fails before planning" "$(pre Write "$(jq -cn --arg p "$WT/src/x.ts" '{file_path:$p,content:42}')")"
scenario "S4b result: oversize beyond 16 pieces" "$(post Bash "$(jq -cn --arg s "$(filler 270000)" '{stdout:$s,stderr:""}')")"
printf 'drive-never-send-canary\n' > "$HOME_DIR/config/dispatch-never-send"
scenario "S4c result: never-send canary inside oversize payload" "$(post Bash "$(jq -cn --arg s "drive-never-send-canary$(filler 40000)tail" '{stdout:$s,stderr:""}')")"
rm -f "$HOME_DIR/config/dispatch-never-send"
# Control: one ordinary request with a reported cost stays complete.
scenario "S6a control: single ordinary reported request" "$(pre Bash '{"command":"ls reported-cost"}')"
# Retried success: first provider try fails, the guard retries and the second succeeds.
scenario "S5 retried success: bash call, first try 500 then ok" "$(pre Bash '{"command":"echo flaky-once reported-cost"}')"
