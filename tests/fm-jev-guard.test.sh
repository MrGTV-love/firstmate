#!/usr/bin/env bash
# Offline guard policy, service and adapter regressions. The loopback fixture
# supplies controlled answers/errors, not model accuracy or publisher identity.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
TMP_ROOT=$(fm_test_tmproot fm-jev-guard)
NODE_TS=(node --experimental-strip-types --no-warnings)
KEY=fm-jev-guard-test-key
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/worktree"
TASK_DATA="$HOME_DIR/data/t1"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TASK_DATA" "$WT"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
cat > "$TMP_ROOT/fake.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    appendFileSync(log, JSON.stringify({ path: req.url, auth: req.headers.authorization, body }) + '\n');
    const request = JSON.parse(body);
    const text = JSON.stringify(request.state);
    if (text.includes('fail500') || text.includes('http402')) { res.statusCode = text.includes('http402') ? 402 : 500; res.end('{}'); return; }
    if (text.includes('stall-direct')) return;
    if (text.includes('invalid-json')) { res.end('{'); return; }
    const risky = /rm -rf|IGNORE PREVIOUS|sk-live/.test(text);
    const probability = /probability=([0-9.]+)/.exec(text);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') {
        answers[id] = { type: 'noul', noul: probability ? Number(probability[1]) : risky ? 0.95 : 0.05, extra: 'provider-private-canary' };
        continue;
      }
      const keys = Object.keys(q.criteria);
      const pick = risky && keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])), extra: 'provider-private-canary' };
    }
    if (text.includes('missing-answer')) delete answers.injection;
    if (text.includes('invalid-answer')) answers.injection = { type: 'noul', noul: '0.01' };
    const usage = { input_tokens: 3, output_tokens: 1, extra: 'provider-private-canary' };
    if (text.includes('reported-cost')) usage.cost = 0.001;
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage, extra: 'provider-private-canary' }));
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
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL
export HOME_DIR WT TASK_DATA REQUESTS KEY
GUARD="$ROOT/bin/fm-jev-guard.ts"
REPORT="$ROOT/bin/ten-levels/extensions/report.ts"
export GUARD REPORT
requests() { wc -l < "$REQUESTS" | tr -d ' '; }
pre() { jq -cn --arg cwd "$WT" --arg tool "$1" --argjson input "$2" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:$input,tool_use_id:"fixture-call"}'; }
post() { jq -cn --arg cwd "$WT" --arg tool "$1" --argjson response "$2" '{hook_event_name:"PostToolUse",cwd:$cwd,tool_name:$tool,tool_input:{file_path:"fixture.txt"},tool_response:$response,tool_use_id:"fixture-result"}'; }
claude_hook() {
  local err status
  err="$TMP_ROOT/hook.err"
  out=$(printf '%s' "$1" | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" "${2-firstmate}" 2>"$err")
  status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status"
  [ ! -s "$err" ] || fail "hook wrote stderr: $(cat "$err")"
}
denied() { jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' <<<"$1" >/dev/null; }

"${NODE_TS[@]}" --test "$ROOT/bin/ten-levels/tests/level06.test.ts" > "$TMP_ROOT/policy.out" 2>&1 || fail "policy tests: $(cat "$TMP_ROOT/policy.out")"
pass "pure shell/write boundaries and calibrated injection equality, ambiguity, invalid and empty values"

test_claude_effects() {
  local out before payload
  before=$(requests)
  claude_hook "$(pre Bash '{"command":"rm -rf build"}')"
  denied "$out" || fail "destructive shell command was not denied"
  claude_hook "$(pre Bash '{"command":"ls -la"}')"
  [ -z "$out" ] || fail "read-only shell command did not proceed"
  [ "$(requests)" -eq $((before + 2)) ] || fail "shell calls did not receive one judgment each"
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"/etc/fm-jev-guard-outside","content":"x"}')"
  denied "$out" || fail "outside-root write was not denied"
  [ "$(requests)" -eq "$before" ] || fail "outside-root content reached the provider"
  for path in "$WT/src/app.ts" "$TASK_DATA/report.md" "$TMP_ROOT/scratch.txt"; do
    payload=$(jq -cn --arg path "$path" '{file_path:$path,content:"plain text"}')
    claude_hook "$(pre Write "$payload")"
    [ -z "$out" ] || fail "an allowed-root write was denied"
  done
  claude_hook "$(pre Edit '{"file_path":"src/app.ts","old_string":"a","new_string":"token = sk-live-fixture"}')"
  denied "$out" || fail "credential insertion was not denied"
  claude_hook "$(pre Edit '{"file_path":"src/app.ts","old_string":"sk-live-removed","new_string":""}')"
  [ -z "$out" ] || fail "credential removal was treated as insertion"
  before=$(requests)
  for path in xd://lsp proc://bg_1/kill; do
    claude_hook "$(pre Write "$(jq -cn --arg p "$path" '{file_path:$p,content:"{}"}')")"
    denied "$out" || fail "Claude admitted an OMP device"
  done
  [ "$(requests)" -eq "$before" ] || fail "Claude device payload reached the provider"
  pass "Claude pre-tool shell/credential effects, allowed roots, removals and deterministic device refusal"
}

test_outages_and_scope() {
  local out before marker status project payload
  for marker in fail500 http402 invalid-json; do
    claude_hook "$(pre Bash "$(jq -cn --arg m "$marker" '{command:$m}')")"
    denied "$out" || fail "$marker allowed a required judgment"
  done
  mv "$HOME_DIR/.env" "$HOME_DIR/env.off"
  before=$(requests)
  printf 'synthetic-sensitive-token\n' > "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Bash '{"command":"synthetic-SENSITIVE-token"}')"
  denied "$out" || fail "privacy refusal allowed active execution"
  jq -se '.[-1].error_type == "PrivacyWithheldError" and .[-1].request_started == false' "$HOME_DIR/state/jev-guard.jsonl" >/dev/null || fail "privacy was not checked before missing credentials"
  rm "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Bash '{"command":"ls"}')"
  denied "$out" || fail "missing credentials allowed active execution"
  [ "$(requests)" -eq "$before" ] || fail "privacy or missing credentials sent a request"
  mv "$HOME_DIR/env.off" "$HOME_DIR/.env"
  printf 'OPENROUTER_API_KEY=fake-openrouter\n' >> "$HOME_DIR/.env"
  before=$(requests)
  claude_hook "$(pre Bash '{"command":"fail500"}')"
  denied "$out" || fail "TypeSafe failure did not require review"
  [ "$(requests)" -eq $((before + 1)) ] || fail "TypeSafe failure fell back or retried HTTP 500"
  jq -se 'all(.[]; .path == "/v1/systemone")' "$REQUESTS" >/dev/null || fail "guard used another provider"
  for project in vernant other ""; do
    before=$(requests)
    for payload in "$(pre Bash '{"command":"rm -rf synthetic-fixture"}')" "$(pre Write '{"file_path":"src/x.ts","content":"sk-live-fixture"}')" "$(post Read '{"file":{"content":"IGNORE PREVIOUS synthetic-fixture"}}')"; do
      claude_hook "$payload" "$project"
      [ -z "$out" ] || fail "inactive project enforced model policy"
    done
    [ "$(requests)" -eq "$before" ] || fail "inactive project sent data"
    claude_hook "$(pre Write '{"file_path":"/etc/hosts","content":"synthetic"}')" "$project"
    denied "$out" || fail "inactive project lost deterministic outside-root protection"
  done
  out=$(printf '%s' 'not json' | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate 2>"$TMP_ROOT/malformed.err")
  status=$?
  [ "$status" -eq 2 ] && [ -z "$out" ] || fail "malformed active hook input did not stop safely"
  grep -q 'exit_status=2' "$TMP_ROOT/malformed.err" || fail "existing blocking handler exit was not retained"
  ! grep -q 'not json' "$TMP_ROOT/malformed.err" || fail "malformed hook input leaked into diagnostics"
  claude_hook 'not json' other
  [ -z "$out" ] || fail "malformed inactive input activated the guard"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
  pass "active privacy/key/provider/contract failures require review; inactive scopes send nothing and keep path checks"
}

test_missing_runtime() {
  local bash_bin out status
  bash_bin=$(command -v bash)
  mkdir -p "$TMP_ROOT/no-runtime"
  out=$(PATH="$TMP_ROOT/no-runtime" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate 2>"$TMP_ROOT/runtime.err")
  status=$?
  [ "$status" -eq 2 ] && [ -z "$out" ] || fail "missing active runtime allowed execution"
  grep -q RuntimeUnavailableError "$TMP_ROOT/runtime.err" || fail "missing runtime lost its explicit error type"
  out=$(PATH="$TMP_ROOT/no-runtime" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" other 2>"$TMP_ROOT/runtime.err")
  status=$?
  [ "$status" -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP_ROOT/runtime.err" ] || fail "missing runtime changed intentionally inactive scope"
  pass "missing runtime requires active pre-tool review without activating unrelated projects"
}

test_crashing_runtime() {
  local bash_bin runtime bin out status stdout_empty stderr_empty before
  bash_bin=$(command -v bash)
  before=$(requests)
  for runtime in bun node; do
    bin="$TMP_ROOT/crashing-$runtime"
    mkdir -p "$bin"
    cat > "$bin/$runtime" <<'SH'
#!/bin/sh
printf '%s\n' 'runtime-output-key-canary'
printf '%s\n' 'runtime-original-error-payload-canary' >&2
exit 1
SH
    chmod +x "$bin/$runtime"
    out=$(PATH="$bin" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate 2>"$TMP_ROOT/crash.err")
    status=$?
    if [ "$status" -ne 2 ]; then
      stdout_empty=no; [ -z "$out" ] && stdout_empty=yes
      stderr_empty=no; [ ! -s "$TMP_ROOT/crash.err" ] && stderr_empty=yes
      fail "$runtime startup crash: exit=$status expected=2 stdout_empty=$stdout_empty stderr_empty=$stderr_empty"
    fi
    [ -z "$out" ] || fail "$runtime crash forwarded incomplete stdout"
    grep -q 'RuntimeExecutionError.*exit_status=1' "$TMP_ROOT/crash.err" || fail "$runtime crash lost its stable type or observed exit status"
    ! grep -q 'runtime-original-error-payload-canary\|runtime-output-key-canary' "$TMP_ROOT/crash.err" || fail "$runtime crash leaked original diagnostics"
    out=$(PATH="$bin" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" other 2>"$TMP_ROOT/crash.err")
    status=$?
    [ "$status" -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP_ROOT/crash.err" ] || fail "$runtime crash activated inactive scope or leaked raw output"
  done
  [ "$(requests)" -eq "$before" ] || fail "a stub runtime crash reached a provider"
  pass "present Bun/Node crashes require active review with sanitized output and preserve inactive scope"
}

test_service_contract() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { createGuardService, MAX_REQUEST_BYTES, GUARD_MODEL } = await import(pathToFileURL(process.env.REPORT));
const { SCREEN_QUESTIONS, screenResult } = await import(new URL('../src/levels/level06/index.ts', pathToFileURL(process.env.REPORT)));
const home = process.env.HOME_DIR;
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 'service', project: 'firstmate' };
const rows = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const service = createGuardService(context);
const empty = { tool: 'bash', source_role: 'tool_result', content: '' };
const overhead = Buffer.byteLength(JSON.stringify({ model: GUARD_MODEL, state: empty, questions: SCREEN_QUESTIONS }));
const remaining = MAX_REQUEST_BYTES - overhead;
const content = 'é'.repeat(Math.floor(remaining / 2)) + 'x'.repeat(remaining % 2);
const result = await service.decide({ ...empty, content }, SCREEN_QUESTIONS);
assert.equal(Buffer.byteLength(result.raw.requestText), 16384);
assert.equal(screenResult(result.answers).decision, 'clear');
assert.equal(result.raw.response.extra, 'provider-private-canary');
assert.equal(JSON.parse(result.raw.responseText).extra, 'provider-private-canary');
assert.equal(result.meta.provider, 'typesafe');
assert.deepEqual(result.meta.cost, { amount: null, source: 'unknown' });
const beforeOversize = rows().length;
await assert.rejects(service.decide({ ...empty, content: content + 'x' }, SCREEN_QUESTIONS), { name: 'RequestTooLargeError', requestStarted: false });
assert.equal(rows().length, beforeOversize, 'over-limit request must not send even after a client exists');
const cost = await service.decide({ ...empty, content: 'reported-cost' }, SCREEN_QUESTIONS);
assert.deepEqual(cost.meta.cost, { amount: 0.001, source: 'reported' });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=rotated-fake-key\n');
await service.decide({ ...empty, content: 'same-session' }, SCREEN_QUESTIONS);
assert.equal(rows().at(-1).auth, `Bearer ${process.env.KEY}`);
const second = createGuardService(context);
await second.decide({ ...empty, content: 'new-session' }, SCREEN_QUESTIONS);
assert.equal(rows().at(-1).auth, 'Bearer rotated-fake-key');
writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
assert.equal(process.env.TYPESAFE_API_KEY, undefined);
assert.equal(process.env.TYPESAFE_API_KEY_PRIVATE, undefined);
const badState = `${home}/audit-bad`;
mkdirSync(`${badState}/jev-guard.jsonl`, { recursive: true });
const bad = createGuardService({ ...context, state: badState });
assert.throws(() => bad.record({ hook: 'tool_call', tool: 'bash', decision: 'allow', enforcement: 'pretool_allow', branch: 'policy', error_type: null, request_started: true, result }), { name: 'AuditUnavailableError' });
console.log('service-ok');
JS
) || fail "service contract: $out"
  [ "$out" = service-ok ] || fail "unexpected service output: $out"
  pass "complete UTF-8 wire bound, full in-memory exchange, reported/unknown cost, session key snapshot and typed audit failure"
}

test_result_and_audit_policy() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const base = { home, config: `${home}/config`, state: `${home}/state`, task: 'omp', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate' };
const ctx = { cwd: process.env.WT };
const requests = () => readFileSync(process.env.REQUESTS, 'utf8');
function install(overrides = {}) {
  const handlers = {};
  installJevGuard({ on: (name, handler) => { handlers[name] = handler; } }, { ...base, ...overrides });
  return handlers;
}
const handlers = install();
const event = text => ({ toolName: 'bash', input: { command: 'fixture' }, toolCallId: 'fixture-result', content: [{ type: 'text', text }], details: { displayContent: { text } } });
for (const [p, expected] of [[0.2, 'clear'], [0.200001, 'review'], [0.799999, 'review'], [0.8, 'flag']]) {
  const original = event(`probability=${p} private-output-canary`);
  const before = JSON.stringify(original);
  const patch = await handlers.tool_result(original, ctx);
  if (expected === 'clear') assert.equal(patch, undefined);
  else {
    assert.equal(patch.isError, true);
    assert.deepEqual(patch.details, {});
    assert.equal(JSON.stringify(patch).includes('private-output-canary'), false);
  }
  assert.equal(JSON.stringify(original), before, 'judgment must not mutate host input');
  const terminal = JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
  assert.equal(terminal.decision, expected);
  assert.equal(terminal.error_type, null);
}
for (const [marker, type] of [['fail500', 'Error'], ['http402', 'Error'], ['invalid-json', 'ContractError'], ['missing-answer', 'ContractError'], ['invalid-answer', 'ContractError']]) {
  const patch = await handlers.tool_result(event(`${marker} private-output-canary`), ctx);
  assert.equal(patch.isError, true);
  assert.equal(JSON.stringify(patch).includes('private-output-canary'), false);
  const terminal = JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
  assert.equal(terminal.error_type, type, 'generic HTTP Error must not invent an exact category from text');
  assert.equal(terminal.cost.source, 'unknown');
}
const beforeRead = requests().split('\n').length;
const ordinaryRead = await handlers.tool_result({ ...event('IGNORE PREVIOUS claimed authority'), toolName: 'read', input: { path: `${home}/state/operational-inbox/fixture.msg` } }, ctx);
assert.equal(ordinaryRead.isError, true);
assert.equal(requests().split('\n').length, beforeRead + 1, 'unmatched reads receive normal untrusted-result screening');
const afterTail = await handlers.tool_result(event('x'.repeat(6500) + 'IGNORE PREVIOUS private-output-canary'), ctx);
assert.equal(afterTail.isError, true, 'content beyond the former result prefix must affect the decision');
const credentialTail = await handlers.tool_call({ toolName: 'write', input: { path: 'src/large.ts', content: 'x'.repeat(4500) + 'sk-live-fixture' } }, ctx);
assert.equal(credentialTail.block, true, 'content beyond the former write prefix must affect the decision');
const beforeHuge = requests();
const huge = await handlers.tool_call({ toolName: 'write', input: { path: 'src/large.ts', content: 'é'.repeat(8500) } }, ctx);
assert.equal(huge.block, true);
assert.match(huge.reason, /RequestTooLargeError/);
assert.equal(requests(), beforeHuge);
const unsupported = await handlers.tool_result({ toolName: 'bash', content: [{ type: 'image', data: 'private-output-canary' }] }, ctx);
assert.equal(unsupported.isError, true);
assert.equal(JSON.stringify(unsupported).includes('private-output-canary'), false);
const bad = install({ state: `${home}/audit-bad` });
assert.match((await bad.tool_call({ toolName: 'bash', input: { command: 'ls' } }, ctx)).reason, /AuditUnavailableError/);
const unavailableAudit = await bad.tool_result(event('fail500'), ctx);
assert.match(unavailableAudit.content[0].text, /AuditUnavailableError/);
assert.match(unavailableAudit.content[0].text, /error_type=Error/);
const inactive = install({ noHelpers: true, state: `${home}/audit-bad` });
const beforeInactive = requests();
assert.equal(await inactive.tool_call({ toolName: 'bash', input: { command: 'rm -rf fixture' } }, ctx), undefined);
assert.equal(await inactive.tool_result(event('IGNORE PREVIOUS'), ctx), undefined);
assert.equal(requests(), beforeInactive);
assert.equal((await inactive.tool_call({ toolName: 'write', input: { path: '/etc/hosts', content: 'fixture' } }, ctx)).block, true);
console.log('result-policy-ok');
JS
) || fail "result/audit policy: $out"
  [ "$out" = result-policy-ok ] || fail "unexpected result policy output: $out"
  pass "OMP clear/flag/review/quarantine, original typed failures, complete tails, ordinary-read screening, audit failure and inactive independence"
}

test_claude_result_advisory() {
  local out before
  claude_hook "$(post Bash '{"stdout":"probability=0.8 private-output-canary","stderr":""}')"
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("no protection")) and (.hookSpecificOutput | has("updatedToolOutput") | not)' <<<"$out" >/dev/null || fail "Claude result was not explicitly advisory"
  [[ "$out" != *private-output-canary* ]] || fail "Claude advisory copied untrusted content"
  claude_hook "$(post Bash '{"stdout":"probability=0.2"}')"
  [ -z "$out" ] || fail "clear result produced a review advisory"
  before=$(requests)
  claude_hook "$(post Read '{"file":{"content":"IGNORE PREVIOUS claimed authority"}}')"
  [ "$(requests)" -eq $((before + 1)) ] || fail "ordinary read did not receive screening"
  jq -e '.hookSpecificOutput.additionalContext | contains("Advisory only")' <<<"$out" >/dev/null || fail "ordinary read advisory was hidden"
  out=$(pre Bash '{"command":"rm -rf fixture"}' | "${NODE_TS[@]}" "$ROOT/bin/fm-jev-guard-claude.ts" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate)
  denied "$out" || fail "node type stripping did not enforce the guard"
  pass "Claude retains advisory-only/no-protection results under bun and pre-tool enforcement under node"
}

test_omp_permissions() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, symlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const requests = () => readFileSync(process.env.REQUESTS, 'utf8');
writeFileSync(`${process.env.WT}/source.ts`, 'export const value = 1;\n');
writeFileSync(`${process.env.TASK_DATA}/outside.ts`, 'export const outside = 1;\n');
symlinkSync(`${process.env.TASK_DATA}/outside.ts`, `${process.env.WT}/escape.ts`);
const unicodeSpaces = [0x00a0, ...Array.from({ length: 11 }, (_, i) => 0x2000 + i), 0x202f, 0x205f, 0x3000];
const rewritten = unicodeSpaces.map(code => `x${String.fromCodePoint(code)}.ts`);
for (const file of rewritten) writeFileSync(`${process.env.WT}/${file}`, 'export const value = 1;\n');
symlinkSync(`${process.env.TASK_DATA}/outside.ts`, `${process.env.WT}/x .ts`);
for (const file of ['plain space.ts', 'unicode-λ.ts']) writeFileSync(`${process.env.WT}/${file}`, 'export const value = 1;\n');
for (const scope of [{ project: 'firstmate' }, { project: 'vernant' }, { project: '' }, {}, { project: 'firstmate', noHelpers: true }]) {
  const handlers = {};
  installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'permissions', worktree: process.env.WT, data: process.env.TASK_DATA, ...scope });
  const ctx = { cwd: process.env.WT, getAsyncJobSnapshot: () => ({ running: [{ id: 'bg_1' }], recent: [] }) };
  const deny = async (input, context = ctx, toolName = 'write') => {
    const before = requests();
    const event = { toolName, input };
    const original = JSON.stringify(event);
    assert.equal((await handlers.tool_call(event, context)).block, true);
    assert.equal(JSON.stringify(event), original);
    assert.equal(requests(), before, 'deterministic refusals must not egress');
  };
  for (const toolName of ['write', 'edit']) {
    for (const path of ['~/a', '~other/a', ':./a', ':../a', ':/tmp/a', '@/tmp/a', '@~/a', 'file:///tmp/a', 'FILE:///tmp/a', '[/x/a]', 'src/a#ABCD]', 'https://example.invalid/a', 's3://bucket/a', 'xd://report_issue', 'xd://security_scan', 'xd://lsp/topic', 'proc://bg_1/mode', 'proc://bg_1', 'proc://bg_1/kill?x=1', 'C:/a', '+note.txt', '']) {
      await deny(toolName === 'write' ? { path, content: 'fixture' } : { path, old_string: 'old', new_string: 'fixture' }, ctx, toolName);
    }
    for (const path of ['src/note.txt', `${process.env.WT}/src/note.txt`]) {
      for (const content of ['hello', 'sk-live-path-test']) {
        const input = toolName === 'write' ? { path, content } : { path, old_string: 'old', new_string: content };
        const before = requests();
        const result = await handlers.tool_call({ toolName, input }, ctx);
        if (scope.project === 'firstmate' && !scope.noHelpers) {
          assert.equal(result?.block === true, content !== 'hello');
        } else { assert.equal(result, undefined); assert.equal(requests(), before); }
      }
    }
  }
  for (const input of [{ path: 'src/a.ts' }, { path: 'src/a.ts', newText: 'legacy' }, { paths: ['src/a.ts'], input: 'patch' }, { new_string: 'fixture' }, { path: null, new_string: 'fixture' }, { path: 'src/a.ts', new_string: 1 }]) await deny(input, ctx, 'edit');
  const lsp = args => ({ path: 'xd://lsp', content: JSON.stringify(args) });
  for (const input of [
    ...['references', 'definition', 'implementation', 'type_definition', 'hover', 'symbols'].map(action => lsp({ action, file: 'source.ts', line: 1, symbol: 'value' })),
    ...['plain space.ts', 'unicode-λ.ts'].map(file => lsp({ action: 'references', file })), { path: 'proc://bg_1/kill' },
  ]) {
    const before = requests();
    assert.equal(await handlers.tool_call({ toolName: 'write', input }, ctx), undefined);
    assert.equal(requests(), before);
  }
  for (const action of ['diagnostics', 'request', 'rename', 'rename_file', 'code_actions', 'format', 'reload', 'status', 'capabilities', 'unknown', 'References', '']) await deny(lsp({ action, file: 'source.ts', apply: true }));
  for (const file of [...rewritten, ...rewritten.map(file => `${process.env.WT}/${file}`), '/etc/hosts', `${process.env.TASK_DATA}/outside.ts`, 'escape.ts', '../outside.ts', 'missing.ts', '.', process.env.WT, '/', 'file:///etc/hosts', '~/.env', '@source.ts', ':./source.ts', '[source.ts]', 'src/**/*.ts', '*', '']) await deny(lsp({ action: 'references', file }));
  await deny(lsp({ action: 'symbols' }));
  for (const content of ['', 'not json', 'null', '[]', '1', '{"action":"references","file":1}']) await deny({ path: 'xd://lsp', content });
  await deny(lsp({ action: 'references', file: 'source.ts' }), { ...ctx, cwd: process.env.TASK_DATA });
  await deny(lsp({ action: 'references', file: 'source.ts' }), { cwd: process.env.WT });
  await deny({ ...lsp({ action: 'references', file: 'source.ts' }), path: 'XD://lsp' });
  await deny({ ...lsp({ action: 'references', file: 'source.ts' }), new_string: 'x' }, ctx, 'edit');
  for (const path of ['proc://bg_2/kill', 'proc://lookalike-service/kill', 'proc:///kill', 'proc://bg_1/kill/', 'proc://bg_1/kill#x', 'PROC://bg_1/kill']) await deny({ path });
  for (const getAsyncJobSnapshot of [undefined, () => null, () => ({ running: [] }), () => ({ running: [null, { id: 'bg_2' }] }), () => ({ running: [], recent: [{ id: 'bg_1' }] }), () => { throw new Error('snapshot unavailable'); }]) await deny({ path: 'proc://bg_1/kill' }, { cwd: process.env.WT, getAsyncJobSnapshot });
}
console.log('permissions-ok');
JS
) || fail "OMP permissions: $out"
  [ "$out" = permissions-ok ] || fail "unexpected permissions output: $out"
  pass "path/edit/device/root permissions survive active and explicitly inactive scopes without mutating arguments"
}

test_deadlines() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const handlers = {};
installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'deadline', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate' });
async function beforeHostDeadline(name, event) {
  let timer;
  try {
    return await Promise.race([handlers[name](event, { cwd: process.env.WT }), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('documented 30-second host deadline exceeded')), 30000); })]);
  } finally { clearTimeout(timer); }
}
const pre = await beforeHostDeadline('tool_call', { toolName: 'bash', input: { command: 'stall-direct' } });
assert.equal(pre.block, true);
assert.match(pre.reason, /TimeoutError/);
const post = await beforeHostDeadline('tool_result', { toolName: 'bash', content: [{ type: 'text', text: 'stall-direct private-output-canary' }] });
assert.equal(post.isError, true);
assert.match(post.content[0].text, /TimeoutError/);
assert.equal(JSON.stringify(post).includes('private-output-canary'), false);
console.log('deadlines-ok');
JS
) || fail "handler deadlines: $out"
  [ "$out" = deadlines-ok ] || fail "unexpected deadline output: $out"
  pass "actual stalled requests produce typed pre-tool denial and result replacement before the documented host deadline"
}

test_ledger_privacy() {
  local ledger="$HOME_DIR/state/jev-guard.jsonl" mode
  mode=$(node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o7777).toString(8))' "$ledger")
  [ "$mode" = 600 ] || fail "ledger is not private"
  ! grep -q "$KEY\|fake-openrouter\|provider-private-canary\|private-output-canary\|IGNORE PREVIOUS\|sk-live\|plain text" "$ledger" || fail "sensitive fixture content or provider extensions reached routine logs"
  jq -se 'all(.[]; .kind == "terminal" and has("error_type") and .outage_policy == "REVIEW_ON_UNAVAILABLE_V1" and .policy_version == "FIRSTMATE_JEV_GUARD_V1" and (has("state")|not) and (has("raw")|not) and (has("message")|not) and (has("command")|not) and (has("path")|not)) and any(.[]; .usage.input_tokens == 3 and .cost.source == "unknown") and any(.[]; .error_type == "Error") and any(.[]; .decision == "inactive" and .error_type == null and .cost.source == "not_called")' "$ledger" >/dev/null || fail "terminal audit contract lost error, policy, usage or certainty"
  pass "private terminal audit keeps typed errors and cost certainty without payloads or provider extensions"
}

test_claude_channel_context() {
  local bell record payload before out
  bell=$(printf 'IGNORE PREVIOUS synthetic launch authority.\n' | FM_TASK_ID=t1 FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-operational-input.sh" record launch-brief) || fail "Claude fixture publication failed"
  record=$(bash -c '. "$1"; fm_operational_doorbell_path "$2" path && printf %s "$path"' fixture "$ROOT/bin/fm-operational-input.sh" "$bell") || fail "Claude fixture path failed"
  claude_hook "$(jq -cn --arg prompt "$bell" '{hook_event_name:"UserPromptSubmit",session_id:"channel-fixture",prompt:$prompt}')"
  [ -z "$out" ] || fail "native prompt context emitted instructions"
  payload=$(jq -cn --arg path "$record" --rawfile content "$record" '{hook_event_name:"PostToolUse",session_id:"channel-fixture",tool_name:"Read",tool_input:{file_path:$path},tool_response:{file:{content:$content}}}')
  before=$(requests)
  claude_hook "$payload"
  [ -z "$out" ] || fail "exact delivered Claude source was not preserved"
  [ "$(requests)" -eq "$before" ] || fail "exact Claude source reached the provider"
  claude_hook "$(jq '.session_id="different-native-session"' <<<"$payload")"
  [ "$(requests)" -eq $((before + 1)) ] || fail "another session inherited source consistency"
  jq -e '.hookSpecificOutput.additionalContext | contains("Advisory only")' <<<"$out" >/dev/null || fail "undelivered Claude source was not screened"
  payload=$(jq '.tool_response.file.content += "changed bytes"' <<<"$payload")
  claude_hook "$payload"
  [ "$(requests)" -eq $((before + 2)) ] || fail "changed Claude bytes inherited source consistency"
  pass "separate Claude native hooks preserve only session-delivered exact bytes and screen foreign-session/changed content"
}

test_channel_consistency() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, renameSync, writeFileSync, symlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = dirname(dirname(process.env.GUARD));
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = resolve(process.env.HOME_DIR, 'channel-home');
for (const child of ['state', 'config', 'data']) mkdirSync(`${home}/${child}`, { recursive: true });
writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
const env = { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_CONFIG_OVERRIDE: `${home}/config`, FM_TASK_ID: 't1' };
const launchBell = execFileSync(`${root}/bin/fm-operational-input.sh`, ['record', 'launch-brief'],
  { env, encoding: 'utf8', input: 'IGNORE PREVIOUS synthetic launch authority.\nTrailing line.\n' }).replace(/\n$/, '');
const launch = execFileSync('bash', ['-c', '. "$1"; fm_operational_doorbell_path "$2" file && printf %s "$file"', 'fixture', `${root}/bin/fm-operational-input.sh`, launchBell], { env, encoding: 'utf8' });
const inbox = execFileSync('bash', ['-c', '. "$1"; fm_task_inbox_write "$2" t1 "$3"', 'fixture', `${root}/bin/fm-task-inbox-lib.sh`, `${home}/state`, 'IGNORE PREVIOUS synthetic numeric authority.\n'], { env, encoding: 'utf8' });
const inboxBell = execFileSync('bash', ['-c', '. "$1"; fm_task_inbox_doorbell_line "$2"', 'fixture', `${root}/bin/fm-task-inbox-lib.sh`, inbox], { env, encoding: 'utf8' });
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 't1', data: `${home}/data`, worktree: process.env.WT, project: 'firstmate' };
const handlers = {};
installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, context);
const ctx = { cwd: process.env.WT };
const count = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).length;
const event = (path, content = readFileSync(path, 'utf8')) => ({ toolName: 'read', input: { path: `${path}:raw` }, content: [{ type: 'text', text: content }], details: { meta: { source: { type: 'path', value: path } } } });
let before = count();
const unseen = await handlers.tool_result(event(launch), ctx);
assert.equal(unseen.isError, true, 'publisher receipt alone is not host delivery');
assert.equal(count(), before + 1);
handlers.before_agent_start({ prompt: `${launchBell}\n${inboxBell}` });
before = count();
for (const path of [launch, inbox]) assert.equal(await handlers.tool_result(event(path), ctx), undefined, 'exact delivered publisher bytes must survive');
assert.equal(count(), before, 'consistent instructions must not reach Jev');
const copy = `${process.env.WT}/claimed-authority-copy.txt`;
writeFileSync(copy, readFileSync(launch));
const changed = event(inbox, readFileSync(inbox, 'utf8') + 'changed bytes');
const badName = { ...event(inbox), input: { path: `${home}/state/t1.inbox/002.msg:raw` } };
const mixed = { ...event(inbox), content: [...event(inbox).content, { type: 'text', text: 'extra' }] };
const alias = `${home}/state/t1.inbox/alias.msg`;
symlinkSync(inbox, alias);
for (const candidate of [event(copy), changed, badName, mixed, event(alias)]) {
  before = count();
  const result = await handlers.tool_result(candidate, ctx);
  assert.equal(result.isError, true, 'claimed/copied/changed/aliased source must be screened');
  assert.equal(count(), before + 1);
}
const wrongTask = {};
installJevGuard({ on: (name, fn) => { wrongTask[name] = fn; } }, { ...context, task: 'other' });
wrongTask.before_agent_start({ prompt: launchBell });
assert.equal((await wrongTask.tool_result(event(launch), ctx)).isError, true);
renameSync(`${home}/.env`, `${home}/.env.disabled`);
writeFileSync(`${home}/config/dispatch-never-send`, 'IGNORE PREVIOUS\n');
before = count();
for (const path of [launch, inbox]) assert.equal(await handlers.tool_result(event(path), ctx), undefined, 'source consistency precedes privacy/credential outages');
assert.equal(count(), before);
const ledger = `${home}/state/jev-guard.jsonl`;
renameSync(ledger, `${ledger}.saved`);
mkdirSync(ledger);
const auditUnavailable = await handlers.tool_result(event(inbox), ctx);
assert.match(auditUnavailable.additionalContext, /AuditUnavailableError/);
assert.equal('content' in auditUnavailable, false, 'audit outage must not erase consistent instructions');
assert.equal(count(), before);
console.log('channel-consistency-ok');
JS
) || fail "channel consistency: $out"
  [ "$out" = channel-consistency-ok ] || fail "unexpected consistency output: $out"
  pass "actual publishers bind host-delivered path/name/bytes; copies, changed bytes and unseen/foreign delivery screen; source survives outages"
}

test_claude_effects
test_outages_and_scope
test_missing_runtime
test_crashing_runtime
test_service_contract
test_result_and_audit_policy
test_claude_result_advisory
test_claude_channel_context
test_channel_consistency
test_omp_permissions
test_deadlines
test_ledger_privacy
