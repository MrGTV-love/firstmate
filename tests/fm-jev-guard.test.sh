#!/usr/bin/env bash
# Offline guard policy, service and adapter regressions. The loopback fixture
# supplies controlled answers/errors, not model accuracy or publisher identity.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
# A private lab fixture must not inherit an operational split-home override.
# The override-negative case below sets its own value after this isolation.
while IFS= read -r name; do
  case "$name" in FM_*_OVERRIDE) unset "$name" ;; esac
done < <(compgen -e)
unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test
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
const seen = new Set();
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    appendFileSync(log, JSON.stringify({ path: req.url, auth: req.headers.authorization, body }) + '\n');
    const request = JSON.parse(body);
    const text = JSON.stringify(request.state);
    if (text.includes('socket-reset')) { req.socket.destroy(); return; }
    if (text.includes('fail500') || text.includes('http402')) { res.statusCode = text.includes('http402') ? 402 : 500; res.end('{}'); return; }
    if (text.includes('flaky-once') && !seen.has(text)) { seen.add(text); res.statusCode = 500; res.end('{}'); return; }
    if (text.includes('stall-direct')) return;
    if (text.includes('invalid-json')) { res.end('{'); return; }
    const risky = /\brm\b|fm-herdr-lab\.sh.*teardown|IGNORE PREVIOUS|sk-live/.test(text);
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
    const usage = { input_tokens: 3, output_tokens: 1, extra: 'provider-private-canary' };
    if (text.includes('reported-cost')) usage.cost = 0.001;
    res.setHeader('content-type', 'application/json');
    const reply = () => res.end(JSON.stringify({ model: 'jev-fake', answers, usage, extra: 'provider-private-canary' }));
    if (text.includes('late-answer')) setTimeout(reply, 31000);
    else reply();
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
  out=$(printf '%s' "$1" | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" "${2-firstmate}" FIRSTMATE_JEV_GUARD_V1 2>"$err")
  status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status"
  [ ! -s "$err" ] || fail "hook wrote stderr: $(cat "$err")"
}
denied() { jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' <<<"$1" >/dev/null; }

"${NODE_TS[@]}" --test "$ROOT/bin/ten-levels/tests/level06.test.ts" > "$TMP_ROOT/policy.out" 2>&1 || fail "policy tests: $(cat "$TMP_ROOT/policy.out")"
pass "pure write boundaries"

# T2 recorded shell misfires: execute only disposable fixture paths, never the
# production Herdr lifecycle. Its command fixture proves dispatch, not teardown.
# Claude dispatches through the hook settings a real worker spawn writes.
test_bash_without_judgment() {
  local out dir
  dir="$TMP_ROOT/claude-spawn"
  fm_test_spawn_home "$dir/home" claude
  fm_git_worktree "$dir/project" "$dir/wt" wt-claude-guard
  fm_test_spawn_brief "$dir/home" t2-claude
  out=$(fm_test_run_spawn "$dir/home" "$dir/wt" "$(make_spawn_fakebin "$dir/fake" claude)" t2-claude "$dir/project" --mode no-mistakes --yolo off) \
    || fail "Claude worker spawn: $out"
  CLAUDE_SETTINGS="$dir/wt/.claude/settings.local.json"
  [ -s "$CLAUDE_SETTINGS" ] || fail "Claude worker spawn wrote no hook settings"
  out=$(CLAUDE_SETTINGS="$CLAUDE_SETTINGS" "${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const root = `${process.env.TASK_DATA}/bash-acceptance`;
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const requests = () => readFileSync(process.env.REQUESTS, 'utf8');
const settings = JSON.parse(readFileSync(process.env.CLAUDE_SETTINGS, 'utf8'));
// Claude runs every PreToolUse hook whose matcher matches the tool name.
const claudePretool = tool => (settings.hooks.PreToolUse ?? [])
  .filter(group => new RegExp(!group.matcher || group.matcher === '*' ? '.*' : group.matcher).test(tool))
  .flatMap(group => group.hooks);
for (const host of ['omp', 'claude']) {
  const worktree = `${root}/${host}/repo`;
  const home = `${root}/${host}/home`;
  const data = `${home}/data/t2`;
  const state = `${home}/state`;
  for (const dir of [worktree, data, state, `${home}/config`]) mkdirSync(dir, { recursive: true });
  writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
  const handlers = {};
  const context = { home, config: `${home}/config`, state, task: 't2', data, worktree,
    host, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
  if (host === 'omp') installJevGuard({ on(name, handler) { handlers[name] = handler; } }, context);
  async function run(command, unreachable = false) {
    const before = requests();
    const baseUrl = process.env.FM_JEV_GUARD_BASE_URL;
    // The closed loopback port prevents any paid request in the outage case.
    if (unreachable) process.env.FM_JEV_GUARD_BASE_URL = 'http://127.0.0.1:1/v1/systemone';
    try {
      if (host === 'omp') {
        // A fresh installation prevents an earlier fixture client from retaining its healthy endpoint.
        const current = unreachable ? {} : handlers;
        if (unreachable) installJevGuard({ on(name, handler) { current[name] = handler; } }, context);
        assert.equal(await current.tool_call({ toolName: 'bash', input: { command } }, { cwd: worktree }), undefined);
      } else {
        assert.deepEqual(claudePretool('Bash'), [], 'a Claude shell call must start no guard hook process');
      }
      assert.equal(requests(), before, 'T2(f): a bash pre-call must send no TypeSafe request');
      execFileSync('bash', ['-s'], { cwd: worktree, input: command, stdio: 'pipe' });
    } finally {
      process.env.FM_JEV_GUARD_BASE_URL = baseUrl;
    }
  }
  await test(`${host} T2(a), B68: remove own smoke.py`, async () => {
    const path = `${data}/smoke.py`;
    writeFileSync(path, '# disposable smoke\n');
    await run(`rm ${quote(path)}`);
    assert.equal(existsSync(path), false);
  });
  await test(`${host} T2(b), B69: four-file probe cleanup`, async () => {
    // The assessment truncates three basenames; these retain its four-file shape.
    const paths = ['host-probe.ts', 'native-probe.ts', 'device-probe.ts', 'config-probe.ts'].map(name => `${data}/${name}`);
    for (const path of paths) writeFileSync(path, '// disposable probe\n');
    await run(`rm ${paths.map(quote).join(' ')}`);
    for (const path of paths) assert.equal(existsSync(path), false);
  });
  await test(`${host} T2(c), B57: six tracked cd-guard deletions`, async () => {
    // The report truncates the last basename; retain its six tracked file shape.
    const paths = ['bin/fm-cd-pretool-check.sh', 'bin/fm-cd-command-policy.mjs',
      'tests/fm-cd-pretool-check.test.sh', 'docs/cd-guard.md', '.grok/hooks/fm-primary-cd-check.json',
      '.opencode/plugins/fm-primary-cd-check.ts'];
    execFileSync('git', ['init', '-q', worktree]);
    for (const path of paths) {
      mkdirSync(dirname(`${worktree}/${path}`), { recursive: true });
      writeFileSync(`${worktree}/${path}`, 'disposable tracked guard\n');
    }
    execFileSync('git', ['add', '--', ...paths], { cwd: worktree });
    await run(`rm ${paths.map(quote).join(' ')}`);
    for (const path of paths) assert.equal(existsSync(`${worktree}/${path}`), false);
    assert.equal(execFileSync('git', ['diff', '--name-only'], { cwd: worktree, encoding: 'utf8' }).trim().split('\n').length, 6);
  });
  await test(`${host} T2(d), B22/B48-B50: dispatch lab teardown command`, async () => {
    const script = `${worktree}/fm-herdr-lab.sh`;
    const marker = `${data}/teardown-args`;
    writeFileSync(script, `#!/bin/sh\nprintf '%s' "$1" > ${quote(marker)}\n`, { mode: 0o700 });
    await run(`${quote(script)} teardown`);
    assert.equal(readFileSync(marker, 'utf8'), 'teardown');
  });
  await test(`${host} T2(e), O13: acknowledge inbox with provider unreachable`, async () => {
    const inbox = `${state}/t2.inbox`;
    mkdirSync(`${inbox}/handled`, { recursive: true });
    writeFileSync(`${inbox}/002.msg`, 'disposable steering record\n');
    await run(`mv ${quote(`${inbox}/002.msg`)} ${quote(`${inbox}/handled/`)}`, true);
    assert.equal(existsSync(`${inbox}/002.msg`), false);
    assert.equal(readFileSync(`${inbox}/handled/002.msg`, 'utf8'), 'disposable steering record\n');
  });
  await test(`${host} T2(f): shell admission does not depend on audit availability or payload size`, async () => {
    if (existsSync(`${state}/jev-guard.jsonl`)) unlinkSync(`${state}/jev-guard.jsonl`);
    mkdirSync(`${state}/jev-guard.jsonl`, { recursive: true });
    await run(`printf '%s' ${quote('x'.repeat(300000))} > ${quote(`${data}/large.txt`)}`);
    assert.equal(readFileSync(`${data}/large.txt`, 'utf8'), 'x'.repeat(300000));
  });
}
await test('claude: Bash, Monitor and PowerShell start no generated pre-call hook', () => {
  for (const tool of ['Bash', 'Monitor', 'PowerShell']) {
    assert.deepEqual(claudePretool(tool), [], `${tool}: shell admission must not depend on the hook runtime or its availability`);
  }
});
await test('claude: outbound and unknown shell-prefix names still reach the generated guard', () => {
  for (const [tool, input] of [['WebSearch', { query: 'synthetic-query' }], ['MonitorStatus', {}], ['PowerShellExtra', {}], ['BashScript', {}]]) {
    const hooks = claudePretool(tool);
    assert.equal(hooks.length, 1, `${tool}: only the exact shell-command names are excluded`);
    const output = execFileSync('sh', ['-c', hooks[0].command], { encoding: 'utf8',
      input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: tool, tool_input: input }) });
    assert.equal(JSON.parse(output).hookSpecificOutput.permissionDecision, 'deny', `${tool}: coverage and egress refusals must remain active`);
  }
});
await test('claude: Write and Edit still reach the generated jev-guard hook', () => {
  for (const [tool, input] of [['Write', { file_path: '/etc/fm-jev-guard-outside', content: 'x' }],
    ['Edit', { file_path: '/etc/fm-jev-guard-outside', old_string: 'x', new_string: 'y' }]]) {
    const hooks = claudePretool(tool);
    assert.equal(hooks.length, 1, `${tool} must reach the guard hook`);
    const output = execFileSync('sh', ['-c', hooks[0].command], { encoding: 'utf8',
      input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: tool, tool_input: input }) });
    assert.equal(JSON.parse(output).hookSpecificOutput.permissionDecision, 'deny', `${tool} outside the worktree must still be refused`);
  }
});
JS
  ) || fail "bash acceptance: $out"
  printf '%s\n' "$out"
  pass "T2(a-f) shell pre-calls execute disposable cases on omp and Claude without model requests or a Claude guard hook; Claude Write and Edit still reach it"
}

test_claude_effects() {
  local out before payload
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
  [ -z "$out" ] || fail "credential insertion was denied before commit time"
  claude_hook "$(pre Edit '{"file_path":"src/app.ts","old_string":"sk-live-removed","new_string":""}')"
  [ -z "$out" ] || fail "credential removal was treated as insertion"
  before=$(requests)
  for path in xd://lsp proc://bg_1/kill; do
    claude_hook "$(pre Write "$(jq -cn --arg p "$path" '{file_path:$p,content:"{}"}')")"
    denied "$out" || fail "Claude admitted an OMP device"
  done
  [ "$(requests)" -eq "$before" ] || fail "Claude device payload reached the provider"
  pass "Claude pre-tool allowed write roots, credential insertion deferred to commit time, removals and deterministic device refusal"
}

test_outages_and_scope() {
  local out before marker status project payload
  # Write content is never judged, so provider failures, never-send text and
  # missing model credentials cannot refuse an in-root write or send it.
  before=$(requests)
  for marker in fail500 http402 invalid-json; do
    claude_hook "$(pre Write "$(jq -cn --arg m "$marker" '{file_path:"src/outage.txt",content:$m}')")"
    [ -z "$out" ] || fail "$marker refused a deterministic write"
  done
  mv "$HOME_DIR/.env" "$HOME_DIR/env.off"
  printf 'synthetic-sensitive-token\n' > "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Write '{"file_path":"src/privacy.txt","content":"synthetic-SENSITIVE-token"}')"
  [ -z "$out" ] || fail "never-send text refused a deterministic write"
  jq -se '.[-1] | .decision == "allow" and .branch == "deterministic" and .error_type == null and .request_started == false' "$HOME_DIR/state/jev-guard.jsonl" >/dev/null || fail "deterministic write admission was not audited"
  rm "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Write '{"file_path":"src/deploy.txt","content":"plain write"}')"
  [ -z "$out" ] || fail "missing model credentials refused a deterministic write"
  mv "$HOME_DIR/env.off" "$HOME_DIR/.env"
  printf 'OPENROUTER_API_KEY=fake-openrouter\n' >> "$HOME_DIR/.env"
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"fail500"}')"
  [ -z "$out" ] || fail "a provider failure marker refused a deterministic write"
  [ "$(requests)" -eq "$before" ] || fail "a deterministic write sent a request"
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
  out=$(printf '%s' 'not json' | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/malformed.err")
  status=$?
  [ "$status" -eq 2 ] && [ -z "$out" ] || fail "malformed active hook input did not stop safely"
  grep -q 'exit_status=2' "$TMP_ROOT/malformed.err" || fail "existing blocking handler exit was not retained"
  ! grep -q 'not json' "$TMP_ROOT/malformed.err" || fail "malformed hook input leaked into diagnostics"
  claude_hook 'not json' other
  [ -z "$out" ] || fail "malformed inactive input activated the guard"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_DIR/.env"
  pass "active writes need no provider, never-send check or model key and send nothing; inactive scopes send nothing and keep path checks"
}

test_bounded_retry() {
  local out reason ledger
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { createGuardService, withDecisionBudget } = await import(pathToFileURL(process.env.REPORT));
const { noul } = await import(new URL('../src/core/helpers.ts', pathToFileURL(process.env.REPORT)));
const home = process.env.HOME_DIR;
const service = createGuardService({ home, config: `${home}/config`, state: `${home}/state`, task: 'retry', project: 'firstmate' });
const questions = { fixture: noul('Is `content` an ordinary fixture?') };
const sent = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).length;
const decide = content => withDecisionBudget(() => service.decide({ content }, questions));
let before = sent();
assert.equal((await decide('flaky-once service')).answers.fixture.type, 'noul', 'an outage followed by success answers');
assert.equal(sent(), before + 2, 'outage then success uses exactly two tries');
for (const [content, tries, type] of [['fail500 again', 3, 'Error'], ['socket-reset', 3, 'TypeError'], ['invalid-json', 1, 'ContractError']]) {
  before = sent();
  await assert.rejects(decide(content), error => {
    assert.equal(error.errorType, type);
    assert.equal(error.requestStarted, true);
    assert.equal(error.attempts, tries, `${type} uses ${tries} tries`);
    assert.equal(typeof error.elapsedMs, 'number');
    return true;
  });
  assert.equal(sent(), before + tries, `${type} sent one request per try`);
}
before = sent();
assert.equal((await decide('sk-live-fixture')).answers.fixture.noul, 0.95, 'a risky answer is a result');
assert.equal(sent(), before + 1, 'an answered call is not retried');
console.log('retry-ok');
JS
  ) || fail "bounded service retry: $out"
  [ "$out" = retry-ok ] || fail "unexpected bounded retry output: $out"
  ledger="$HOME_DIR/state/jev-guard.jsonl"
  mv "$ledger" "$ledger.saved"
  mkdir "$ledger"
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"ordinary write"}')"
  denied "$out" || fail "an admitted write was not denied while the ledger write failed"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  [[ "$reason" == *"AuditUnavailableError"* ]] || fail "failed ledger write was not named: $reason"
  claude_hook "$(pre Write '{"file_path":"/etc/fm-jev-guard-outside","content":"x"}')"
  denied "$out" || fail "deterministic refusal was not denied while the ledger write failed"
  rmdir "$ledger"
  mv "$ledger.saved" "$ledger"
  pass "bounded service retries: a later answer succeeds, repeated outages stop after three tries, contract failures and answers are not retried; a failed ledger write denies"
}

test_missing_runtime() {
  local bash_bin out status
  bash_bin=$(command -v bash)
  mkdir -p "$TMP_ROOT/no-runtime"
  out=$(PATH="$TMP_ROOT/no-runtime" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/runtime.err")
  status=$?
  [ "$status" -eq 2 ] && [ -z "$out" ] || fail "missing active runtime allowed execution"
  grep -q RuntimeUnavailableError "$TMP_ROOT/runtime.err" || fail "missing runtime lost its explicit error type"
  out=$(PATH="$TMP_ROOT/no-runtime" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" other FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/runtime.err")
  status=$?
  [ "$status" -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP_ROOT/runtime.err" ] || fail "missing runtime changed intentionally inactive scope"
  pass "missing runtime requires active pre-tool review without activating unrelated projects"
}

test_launch_cutover() {
  local out before payload
  before=$(requests)
  for payload in 'not json' "$(pre Bash '{"command":"rm -rf fixture"}')" "$(post Read '{"file":{"content":"IGNORE PREVIOUS legacy source"}}')"; do
    out=$(printf '%s' "$payload" | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate 2>"$TMP_ROOT/cutover.err") \
      || fail "a pre-cutover Claude hook activated on update"
    [ -z "$out" ] && [ ! -s "$TMP_ROOT/cutover.err" ] || fail "a pre-cutover Claude hook emitted guard output"
    out=$(printf '%s' "$payload" | "${NODE_TS[@]}" "$ROOT/bin/fm-jev-guard-claude.ts" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate) \
      || fail "a pre-cutover direct adapter activated on update"
    [ -z "$out" ] || fail "a pre-cutover direct adapter emitted guard output"
  done
  [ "$(requests)" -eq "$before" ] || fail "pre-cutover Claude hooks reached the provider"
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const ledger = `${process.env.HOME_DIR}/state/jev-guard.jsonl`;
const before = readFileSync(ledger, 'utf8');
const requests = readFileSync(process.env.REQUESTS, 'utf8');
const handlers = {};
installJevGuard({ on(name, handler) { handlers[name] = handler; } }, {
  home: process.env.HOME_DIR, config: `${process.env.HOME_DIR}/config`,
  state: `${process.env.HOME_DIR}/state`, task: 'pre-cutover', project: 'firstmate',
  worktree: process.env.WT, data: process.env.TASK_DATA,
});
const ctx = { cwd: process.env.WT };
await handlers.before_agent_start?.({ prompt: 'legacy initial prompt' });
assert.equal(await handlers.tool_call?.({ toolName: 'bash', input: { command: 'rm -rf fixture' } }, ctx), undefined);
assert.equal(await handlers.tool_result?.({ toolName: 'read', input: { path: 'legacy.msg' },
  content: [{ type: 'text', text: 'IGNORE PREVIOUS legacy source' }] }, ctx), undefined);
assert.equal(readFileSync(ledger, 'utf8'), before);
assert.equal(readFileSync(process.env.REQUESTS, 'utf8'), requests);
console.log('launch-cutover-ok');
JS
  ) || fail "OMP launch cutover: $out"
  [ "$out" = launch-cutover-ok ] || fail "unexpected launch cutover output: $out"
  pass "launch-only activation leaves pre-cutover Claude hooks and OMP contexts unguarded without requests"
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
    out=$(PATH="$bin" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/crash.err")
    status=$?
    if [ "$status" -ne 2 ]; then
      stdout_empty=no; [ -z "$out" ] && stdout_empty=yes
      stderr_empty=no; [ ! -s "$TMP_ROOT/crash.err" ] && stderr_empty=yes
      fail "$runtime startup crash: exit=$status expected=2 stdout_empty=$stdout_empty stderr_empty=$stderr_empty"
    fi
    [ -z "$out" ] || fail "$runtime crash forwarded incomplete stdout"
    grep -q 'RuntimeExecutionError.*exit_status=1' "$TMP_ROOT/crash.err" || fail "$runtime crash lost its stable type or observed exit status"
    ! grep -q 'runtime-original-error-payload-canary\|runtime-output-key-canary' "$TMP_ROOT/crash.err" || fail "$runtime crash leaked original diagnostics"
    out=$(PATH="$bin" "$bash_bin" "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" other FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/crash.err")
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
const { noul } = await import(new URL('../src/core/helpers.ts', pathToFileURL(process.env.REPORT)));
const QUESTIONS = { fixture: noul('Is `content` an ordinary fixture?') };
const home = process.env.HOME_DIR;
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 'service', project: 'firstmate' };
const rows = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const service = createGuardService(context);
const empty = { path: 'file.ts', content: '' };
const overhead = Buffer.byteLength(JSON.stringify({ model: GUARD_MODEL, state: empty, questions: QUESTIONS }));
const remaining = MAX_REQUEST_BYTES - overhead;
const content = 'é'.repeat(Math.floor(remaining / 2)) + 'x'.repeat(remaining % 2);
const result = await service.decide({ ...empty, content }, QUESTIONS);
assert.equal(Buffer.byteLength(result.raw.requestText), 16384);
assert.equal(result.answers.fixture.noul, 0.05);
assert.equal(result.raw.response.extra, 'provider-private-canary');
assert.equal(JSON.parse(result.raw.responseText).extra, 'provider-private-canary');
assert.equal(result.meta.provider, 'typesafe');
assert.deepEqual(result.meta.cost, { amount: null, source: 'unknown' });
const beforeOversize = rows().length;
await assert.rejects(service.decide({ ...empty, content: content + 'x' }, QUESTIONS), { name: 'RequestTooLargeError', requestStarted: false });
assert.equal(rows().length, beforeOversize, 'over-limit request must not send even after a client exists');
const cost = await service.decide({ ...empty, content: 'reported-cost' }, QUESTIONS);
assert.deepEqual(cost.meta.cost, { amount: 0.001, source: 'reported' });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=rotated-fake-key\n');
await service.decide({ ...empty, content: 'same-session' }, QUESTIONS);
assert.equal(rows().at(-1).auth, `Bearer ${process.env.KEY}`);
const second = createGuardService(context);
await second.decide({ ...empty, content: 'new-session' }, QUESTIONS);
assert.equal(rows().at(-1).auth, 'Bearer rotated-fake-key');
writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
// The terminal record keeps usage and cost certainty but no provider answer fields or extensions.
service.record({ hook: 'tool_call', tool: 'write', decision: 'allow', enforcement: 'pretool_allow', branch: 'policy', error_type: null, request_started: true, result });
const recorded = JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
assert.deepEqual(recorded.answers, {});
assert.equal(recorded.usage.input_tokens, 3);
assert.equal(recorded.cost.source, 'unknown');
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

test_pretool_audit_policy() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const base = { home, config: `${home}/config`, state: `${home}/state`, task: 'omp', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
const ctx = { cwd: process.env.WT };
const requests = () => readFileSync(process.env.REQUESTS, 'utf8');
function install(overrides = {}) {
  const handlers = {};
  installJevGuard({ on: (name, handler) => { handlers[name] = handler; } }, { ...base, ...overrides });
  return handlers;
}
const handlers = install();
for (const content of ['x'.repeat(4500) + 'sk-live-fixture', 'é'.repeat(8500)]) {
  const before = requests();
  assert.equal(await handlers.tool_call({ toolName: 'write', input: { path: 'src/large.ts', content } }, ctx), undefined, 'write content is admitted for the commit-time credential check');
  assert.equal(requests(), before, 'write content is never sent for model screening');
}
const bad = install({ state: `${home}/audit-bad` });
assert.match((await bad.tool_call({ toolName: 'write', input: { path: 'src/deploy.txt', content: 'ordinary write' } }, ctx)).reason, /AuditUnavailableError/);
const inactive = install({ noHelpers: true, state: `${home}/audit-bad` });
const beforeInactive = requests();
assert.equal(await inactive.tool_call({ toolName: 'bash', input: { command: 'rm -rf fixture' } }, ctx), undefined);
assert.equal(requests(), beforeInactive);
assert.equal((await inactive.tool_call({ toolName: 'write', input: { path: '/etc/hosts', content: 'fixture' } }, ctx)).block, true);
const row = () => JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
const sent = () => requests().trim().split('\n').filter(Boolean).length;
const beforeReset = sent();
assert.equal(await handlers.tool_call({ toolName: 'write', input: { path: 'src/reset.txt', content: 'socket-reset' } }, ctx), undefined, 'a provider network failure cannot refuse a write');
assert.equal(sent(), beforeReset, 'write content is never sent for model screening');
for (const toolName of ['write', 'edit']) {
  const path = '/etc/guard-refused';
  const refused = await handlers.tool_call({ toolName, input: { path, content: 'x', new_string: 'x' } }, ctx);
  assert.equal(refused.block, true);
  assert.ok(refused.reason.includes(`Refused path: ${JSON.stringify(path)}`));
  assert.equal(row().refused_path, path);
}
console.log('pretool-policy-ok');
JS
) || fail "pre-tool/audit policy: $out"
  [ "$out" = pretool-policy-ok ] || fail "unexpected pre-tool policy output: $out"
  pass "pre-tool credential tails and large writes send nothing, audit failure, inactive independence, provider-independent writes and refused write/edit path"
}
test_claude_node_pretool() {
  local out
  out=$(pre Write '{"file_path":"/etc/fm-jev-guard-node","content":"x"}' | "${NODE_TS[@]}" "$ROOT/bin/fm-jev-guard-claude.ts" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1)
  denied "$out" || fail "node type stripping did not enforce the guard"
  pass "node type stripping still enforces the Claude pre-tool deny"
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
  installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'permissions', worktree: process.env.WT, data: process.env.TASK_DATA, policy: 'FIRSTMATE_JEV_GUARD_V1', ...scope });
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
    for (const path of ['~/a', '~other/a', ':./a', ':../a', ':/tmp/a', '@/tmp/a', '@~/a', 'file:///tmp/a', 'FILE:///tmp/a', '[/x/a]', 'src/a#ABCD]', 'https://example.invalid/a', 's3://bucket/a', 'xd://security_scan', 'xd://lsp/topic', 'proc://bg_1/mode', 'proc://bg_1', 'proc://bg_1/kill?x=1', 'C:/a', '+note.txt', '']) {
      await deny(toolName === 'write' ? { path, content: 'fixture' } : { path, old_string: 'old', new_string: 'fixture' }, ctx, toolName);
    }
    for (const path of ['src/note.txt', `${process.env.WT}/src/note.txt`]) {
      const content = 'sk-live-path-test';
      const input = toolName === 'write' ? { path, content } : { path, old_string: 'old', new_string: content };
      const before = requests();
      assert.equal(await handlers.tool_call({ toolName, input }, ctx), undefined);
      assert.equal(requests(), before, 'allowed write roots must not send contents to a provider');
    }
  }
  for (const input of [{ path: 'src/a.ts' }, { path: 'src/a.ts', newText: 'legacy' }, { paths: ['src/a.ts'], input: 'patch' }, { new_string: 'fixture' }, { path: null, new_string: 'fixture' }, { path: 'src/a.ts', new_string: 1 }]) await deny(input, ctx, 'edit');
  const lsp = args => ({ path: 'xd://lsp', content: JSON.stringify(args) });
  for (const input of [
    ...['references', 'definition', 'implementation', 'type_definition', 'hover', 'symbols', 'diagnostics', 'capabilities', 'reload', 'code_actions'].map(action => lsp({ action, file: 'source.ts', line: 1, symbol: 'value' })),
    lsp({ action: 'status' }), lsp({ action: 'rename', file: 'source.ts', apply: false, new_name: 'renamed' }),
    lsp({ action: 'symbols', file: '*', query: 'value' }), lsp({ action: 'code_actions', file: 'source.ts', line: 1, apply: false }),
    ...['plain space.ts', 'unicode-λ.ts'].map(file => lsp({ action: 'references', file })), { path: 'proc://bg_1/kill' },
  ]) {
    const before = requests();
    assert.equal(await handlers.tool_call({ toolName: 'write', input }, ctx), undefined);
    assert.equal(requests(), before);
  }
  for (const action of ['request', 'rename', 'rename_file', 'code_actions', 'format', 'unknown', 'References', '__proto__', 'constructor', 'toString', '']) await deny(lsp({ action, file: 'source.ts', apply: true }));
  for (const file of [...rewritten, ...rewritten.map(file => `${process.env.WT}/${file}`), '/etc/hosts', `${process.env.TASK_DATA}/outside.ts`, 'escape.ts', '../outside.ts', 'missing.ts', '.', process.env.WT, '/', 'file:///etc/hosts', '~/.env', '@source.ts', ':./source.ts', '[source.ts]', 'src/**/*.ts', '*', '']) await deny(lsp({ action: 'references', file }));
  for (const file of ['src/*.ts', '**', ' *', `*${String.fromCodePoint(0x00a0)}`]) await deny(lsp({ action: 'symbols', file, query: 'value' }));
  await deny(lsp({ action: 'symbols', query: 'value' }));
  for (const apply of ['true', 'yes', 'on', '1', ' TRUE ', 1, 'false', 0, null, {}]) await deny(lsp({ action: 'code_actions', file: 'source.ts', line: 1, apply, query: '0' }));
  for (const content of ['', 'not json', 'null', '[]', '1', '{"action":"references","file":1}']) await deny({ path: 'xd://lsp', content });
  await deny(lsp({ action: 'references', file: 'source.ts' }), { ...ctx, cwd: process.env.TASK_DATA });
  await deny(lsp({ action: 'symbols', file: '*', query: 'value' }), { ...ctx, cwd: process.env.TASK_DATA });
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

test_omp_device_effects() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const config = `${home}/device-config`;
mkdirSync(config);
const sent = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const install = (scope = {}) => {
  const handlers = {};
  installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config, state: `${home}/state`, task: 'devices', worktree: process.env.WT, data: process.env.TASK_DATA, policy: 'FIRSTMATE_JEV_GUARD_V1', project: 'firstmate', host: 'omp', ...scope });
  return handlers.tool_call;
};
const ctx = { cwd: process.env.WT, getAsyncJobSnapshot: () => ({ running: [{ id: 'bg_1' }] }) };
const call = (handler, path, content, toolName = 'write') => handler({ toolName, input: { path, content, ...(toolName === 'edit' ? { new_string: content } : {}) } }, ctx);
const active = install();
// Recorded diagnostics refusal: an existing file in the worker root is a local
// code-index query, including with no credentials/helpers or authorized project.
for (const scope of [{}, { noHelpers: true }, { project: 'vernant' }]) {
  const before = sent().length;
  const handler = install(scope);
  assert.equal(await call(handler, 'xd://lsp', JSON.stringify({ action: 'diagnostics', file: 'source.ts' })), undefined);
  assert.equal(sent().length, before);
  for (const file of ['escape.ts', '*', 'src/**/*.ts', '/etc/hosts', 'missing.ts', '.', ...[0x00a0, 0x2000, 0x202f, 0x205f, 0x3000].map(c => `x${String.fromCodePoint(c)}.ts`)]) {
    const refused = await call(handler, 'xd://lsp', JSON.stringify({ action: 'diagnostics', file }));
    assert.equal(refused?.block, true);
    assert.match(refused.reason, /xd:\/\/lsp/);
    assert.match(refused.reason, /existing file inside this task worktree/);
    assert.doesNotMatch(refused.reason, /needs a plain absolute or worktree-relative path/);
  }
  assert.equal(sent().length, before, 'failed diagnostics scope proofs never send data');
}
// Auto QA uploads every pending grievance and GitHub results return as
// unscreened write output, so both stay refused whatever the arguments say.
for (const scope of [{}, { noHelpers: true }, { project: 'vernant' }]) {
  const handler = install(scope);
  for (const [path, content, reason] of [
    ['xd://report_issue', 'write: refused Auto QA grievance report', /Auto QA is off for firstmate workers/],
    ...['repo_view', 'file_read'].map(op => ['xd://github', JSON.stringify({ op, repo: 'fixture/repo', path: 'README.md' }), /For this read, use gh-axi through the shell instead\..* Apart from the alternative this refusal names, do not retry an equivalent action/]),
  ]) {
    const before = sent().length;
    const refused = await call(handler, path, content);
    assert.equal(refused?.block, true);
    assert.ok(refused.reason.includes(path));
    assert.match(refused.reason, reason);
    assert.doesNotMatch(refused.reason, /needs a plain absolute or worktree-relative path|result is screened/);
    assert.equal(sent().length, before, 'refused devices stop before any screening request');
  }
  for (const content of [...['pr_push', 'pr_create', 'pr_checkout', 'future_op'].map(op => JSON.stringify({ op, repo: 'fixture/repo', path: 'README.md' })), 'not-json', '{}']) {
    const before = sent().length;
    const refused = await call(handler, 'xd://github', content);
    assert.equal(refused?.block, true);
    assert.ok(refused.reason.includes('xd://github'));
    assert.doesNotMatch(refused.reason, /gh-axi|\bgh\b|shell|Apart from/);
    assert.match(refused.reason, /Do not retry an equivalent action through another command, tool, path or encoding\. Report the refused action and reason to Firstmate/);
    assert.equal(sent().length, before, 'refused devices stop before any screening request');
  }
}
for (const path of ['~/a', '/etc/hosts']) {
  const refused = await call(active, path, 'fixture');
  assert.equal(refused?.block, true);
  assert.match(refused.reason, /Do not retry an equivalent action through another command, tool, path or encoding/);
  assert.doesNotMatch(refused.reason, /Apart from the alternative/);
}
for (const handler of [install({ host: 'claude' }), active]) {
  const before = sent().length;
  const tool = handler === active ? 'edit' : 'write';
  assert.equal((await call(handler, 'xd://lsp', JSON.stringify({ action: 'hover', file: 'source.ts' }), tool))?.block, true);
  assert.equal(sent().length, before, 'non-native invocation must not reach a device');
}
// Neither a registered opaque callback nor an unrecognized device may be
// guessed harmless from its URI spelling or from a benign-looking payload.
for (const path of ['xd://propose', 'xd://resolve', 'xd://reject', 'xd://inspect_image', 'xd://future_device', 'xd://report_issue/topic', 'proc://other-task/kill']) {
  const before = sent().length;
  const refused = await call(active, path, '{}');
  assert.equal(refused?.block, true);
  assert.ok(refused.reason.includes(path));
  assert.match(refused.reason, /Firstmate/);
  assert.match(refused.reason, /read |Read proc:\/\//);
  assert.doesNotMatch(refused.reason, /needs a plain absolute or worktree-relative path/);
  assert.equal(sent().length, before);
}
console.log('device-effects-ok');
JS
) || fail "OMP device effects: $out"
  [ "$out" = device-effects-ok ] || fail "unexpected device effects output: $out"
  command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse .omp/fm-worker-overlay.yml as YAML"
  out=$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0])).fetch("dev").fetch("autoqa").inspect' "$ROOT/.omp/fm-worker-overlay.yml" 2>&1) \
    || fail "worker overlay has no dev.autoqa setting: $out"
  [ "$out" = false ] || fail "worker overlay must disable omp Auto QA, got dev.autoqa=$out"
  pass "local devices and workspace symbol search skip models; Auto QA is off for workers; report_issue and GitHub devices stay refused; unknown devices name their review remedy"
}

test_deadlines() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { createGuardService, withDecisionBudget } = await import(pathToFileURL(process.env.REPORT));
const { noul } = await import(new URL('../src/core/helpers.ts', pathToFileURL(process.env.REPORT)));
const home = process.env.HOME_DIR;
const service = createGuardService({ home, config: `${home}/config`, state: `${home}/state`, task: 'deadline', project: 'firstmate' });
const questions = { fixture: noul('Is `content` an ordinary fixture?') };
// A 330-second test limit stands in for a host deadline above the 300-second service budget.
async function beforeHostDeadline(content, limitMs) {
  let timer;
  try {
    return await Promise.race([withDecisionBudget(() => service.decide({ content }, questions)),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${limitMs} ms host deadline exceeded`)), limitMs); })]);
  } finally { clearTimeout(timer); }
}
const started = performance.now();
const [late, stalled] = await Promise.allSettled([beforeHostDeadline('late-answer', 330000), beforeHostDeadline('stall-direct', 330000)]);
assert.equal(late.status, 'fulfilled', 'a judge answer arriving after 30 seconds is waited for');
assert.ok(late.value.meta.elapsedMs >= 30000, `the late answer was actually waited for: ${late.value.meta.elapsedMs}`);
assert.equal(stalled.status, 'rejected');
assert.equal(stalled.reason.errorType, 'TimeoutError');
assert.equal(stalled.reason.attempts, 3, 'a dead judge receives all three full tries');
assert.ok(stalled.reason.elapsedMs >= 270000 && stalled.reason.elapsedMs < 300000, `three 90-second tries and backoff stay inside the decision budget: ${stalled.reason.elapsedMs}`);
assert.ok(performance.now() - started >= 270000, 'outage cannot be reported at the old latency deadline');
console.log('deadlines-ok');
JS
) || fail "service deadlines: $out"
  [ "$out" = deadlines-ok ] || fail "unexpected deadline output: $out"
  pass "actual stalled requests produce a typed service timeout inside the decision budget and before a host deadline"
}

test_ledger_privacy() {
  local ledger="$HOME_DIR/state/jev-guard.jsonl" mode
  mode=$(node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o7777).toString(8))' "$ledger")
  [ "$mode" = 600 ] || fail "ledger is not private"
  ! grep -q "$KEY\|fake-openrouter\|provider-private-canary\|private-output-canary\|IGNORE PREVIOUS\|sk-live\|plain text" "$ledger" || fail "sensitive fixture content or provider extensions reached routine logs"
  jq -se 'all(.[]; .kind == "terminal" and has("error_type") and .outage_policy == "REVIEW_ON_UNAVAILABLE_V1" and .policy_version == "FIRSTMATE_JEV_GUARD_V1" and (has("state")|not) and (has("raw")|not) and (has("message")|not) and (has("command")|not) and (has("path")|not)) and any(.[]; .usage.input_tokens == 3 and .cost.source == "unknown") and any(.[]; .branch == "deterministic" and .decision == "allow" and .cost.source == "not_called") and any(.[]; .decision == "inactive" and .error_type == null and .cost.source == "not_called")' "$ledger" >/dev/null || fail "terminal audit contract lost policy, usage, admission or certainty"
  pass "private terminal audit keeps admissions, usage and cost certainty without payloads, answers or provider extensions"
}

test_oversize_writes() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const { MAX_REQUEST_BYTES } = await import(pathToFileURL(process.env.REPORT));
const home = process.env.HOME_DIR;
const handlers = {};
installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'oversize', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
const ctx = { cwd: process.env.WT };
const sent = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).length;
const row = () => JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
const lines = count => Array.from({ length: count }, (_, i) => `L${i}: const answer = compute(${i}); // ordinary source line\n`);
const benign = lines(700).join('');
const frictionPath = `${home}/state/friction.jsonl`;
const taskDigest = 'sha256:' + createHash('sha256').update('oversize').digest('hex');
const sizeEvents = () => (existsSync(frictionPath) ? readFileSync(frictionPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [])
  .filter(r => r.guard_id === 'FM-JEV-SIZE' && r.task_id === taskDigest);
// Write size no longer has a screening budget: oversized, unplannable and
// never-send content is admitted locally, and the commit hooks inspect it.
writeFileSync(`${home}/config/dispatch-never-send`, 'never-send-canary-value\n');
try {
  for (const [name, path, content] of [
    ['oversized', 'src/big.ts', benign],
    ['never-send', 'src/big.ts', benign + 'never-send-canary-value\n'],
    ['unplannable path', `src/${'p'.repeat(MAX_REQUEST_BYTES)}.ts`, 'ordinary content'],
    ['beyond the former coarse precheck', 'src/huge.ts', 'x'.repeat(16 * MAX_REQUEST_BYTES + 1)],
  ]) {
    for (const toolName of ['write', 'edit']) {
      const before = sent();
      const input = toolName === 'write' ? { path, content } : { path, old_string: 'old', new_string: content };
      assert.equal(await handlers.tool_call({ toolName, input }, ctx), undefined, `${name} ${toolName} must be admitted`);
      assert.equal(sent(), before, `${name} ${toolName} must send nothing`);
      const r = row();
      assert.equal(r.decision, 'allow');
      assert.equal(r.branch, 'deterministic');
      assert.equal(r.error_type, null);
      assert.equal(r.request_started, false);
      assert.equal(r.chunks, 0);
      assert.equal(r.cost.source, 'not_called');
    }
  }
} finally {
  rmSync(`${home}/config/dispatch-never-send`);
}
assert.deepEqual(sizeEvents(), [], 'no write raises the retired FM-JEV-SIZE refusal');
console.log('oversize-ok');
JS
) || fail "oversize writes: $out"
  [ "${out##*$'\n'}" = oversize-ok ] || fail "oversize writes did not reach their final line: $out"
  pass "oversized, unplannable and never-send write content is admitted locally with no request, size refusal or friction event"
}

# Every pre-tool refusal the audit recorded is mirrored into the optional
# fm-friction.v1 ledger through the single writer; allows write nothing, a
# repeated event identity writes nothing, and a writer failure never changes
# the refusal. Only digests and typed tokens reach the ledger.
test_friction_refusal_ledger() {
  local out ledger before line digest_task digest_subject digest_revision scratch scratch_lines writer_diagnostic guard_diagnostic writer_lines guard_lines
  ledger="$HOME_DIR/state/friction.jsonl"
  friction_lines() { if [ -f "$ledger" ]; then grep -c '' "$ledger"; else echo 0; fi; }
  sha() { node -e 'const { createHash } = require("node:crypto"); const { readFileSync } = require("node:fs"); const [mode, value] = process.argv.slice(1); console.log("sha256:" + createHash("sha256").update(mode === "file" ? readFileSync(value) : value).digest("hex"));' "$@"; }
  before=$(friction_lines)
  claude_hook "$(pre Write '{"file_path":"/etc/fm-jev-guard-friction-path-canary","content":"friction-content-canary"}')"
  denied "$out" || fail "the known deterministic write refusal was not denied"
  [ "$(friction_lines)" -eq $((before + 1)) ] || fail "a Claude pre-tool deny did not write exactly one friction event"
  claude_hook "$(pre Write "$(jq -cn --arg path "$WT/src/friction-allowed.ts" '{file_path:$path,content:"friction-content-canary"}')")"
  [ -z "$out" ] || fail "the clean control write was denied"
  claude_hook "$(pre Bash '{"command":"echo friction-control"}')"
  [ -z "$out" ] || fail "the clean control shell call was denied"
  [ "$(friction_lines)" -eq $((before + 1)) ] || fail "a clean allow wrote a friction event"
  line=$(tail -n 1 "$ledger")
  digest_task=$(sha text t1)
  digest_subject=$(sha text "t1:tool_call:write")
  digest_revision=$(sha file "$REPORT")
  jq -e --arg task "$digest_task" --arg subject "$digest_subject" --arg revision "$digest_revision" '
    .schema == "fm-friction.v1" and .guard_id == "FM-JEV-GUARD" and .rule_id == "deterministic" and .outcome == "blocked"
    and .task_id == $task and .subject == {kind: "tool_call-write", identity: $subject, head: "unknown"}
    and .guard_revision == $revision and .actor == "worker" and .execution_kind == "test"
    and .exit_printed == true and .exit_kind == "machine" and .reason == "deterministic"
    and .theater == "unknown" and .new_information == "unknown" and .adjudication == "unknown"
    and .proof_digest == "unknown" and .elapsed_ms == null and .first_block_at == .at
    and .attempt_id == .event_id and .operation_id == .event_id and .episode_id == .event_id' <<<"$line" >/dev/null \
    || fail "the Jev refusal event does not carry the expected fm-friction.v1 fields: $line"
  scratch="$TMP_ROOT/friction-validate"
  mkdir -p "$scratch"
  printf '%s\n' "$line" | FM_HOME="$scratch" python3 "$ROOT/bin/fm-friction-ledger.py" 2>"$scratch/err"
  scratch_lines=$(grep -c '' "$scratch/state/friction.jsonl")
  [ ! -s "$scratch/err" ] && [ "$scratch_lines" -eq 1 ] || fail "the writer rejected the Jev refusal event as invalid: $(cat "$scratch/err")"
  ! grep -F -q -e fm-jev-guard-friction-path-canary -e friction-content-canary -e "$WT" -e "$HOME_DIR" -e "$KEY" "$ledger" \
    || fail "a raw path, content or credential reached the friction ledger"
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, renameSync, rmdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
const ledger = `${home}/state/friction.jsonl`;
const handlers = {};
installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'friction', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
const ctx = { cwd: process.env.WT };
const events = () => (existsSync(ledger) ? readFileSync(ledger, 'utf8').split('\n').filter(Boolean).map(JSON.parse) : []);
const audit = () => JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
// Every typed refusal branch is the event's rule, taken from the audit row itself.
for (const [toolName, input] of [
  ['write', { path: '/etc/fm-jev-guard-friction-branch', content: 'x' }],
  ['write', { path: 'xd://report_issue', content: '{}' }],
  ['fixture_unclassified_tool', { any: 'value' }],
  ['write', { path: 'src/friction-outage.ts', content: 42 }],
]) {
  const before = events().length;
  const refused = await handlers.tool_call({ toolName, input }, ctx);
  assert.equal(refused?.block, true, `${toolName} must be refused`);
  const row = audit();
  assert.equal(row.enforcement, 'pretool_deny');
  const added = events().slice(before);
  assert.equal(added.length, 1, `${toolName} ${row.branch} refusal writes exactly one event`);
  assert.equal(added[0].rule_id, row.branch, 'the rule is the audit row branch');
  assert.equal(added[0].subject.kind, `tool_call-${toolName}`);
  assert.equal(added[0].guard_id, 'FM-JEV-GUARD');
}
assert.ok(new Set(events().map(e => e.rule_id)).size >= 4, 'distinct branches were exercised');
// A repeated event identity writes nothing more.
process.env.FM_FRICTION_EVENT_ID = 'fixture-repeated-identity';
let before = events().length;
for (let repeat = 0; repeat < 2; repeat++) {
  assert.equal((await handlers.tool_call({ toolName: 'write', input: { path: '/etc/fm-jev-guard-friction-dup', content: 'x' } }, ctx)).block, true);
}
delete process.env.FM_FRICTION_EVENT_ID;
assert.equal(events().length, before + 1, 'a repeated event identity is written once');
assert.equal(events().at(-1).event_id, 'fixture-repeated-identity');
// A writer failure prints its own diagnostic and leaves the refusal unchanged.
const expected = await handlers.tool_call({ toolName: 'write', input: { path: '/etc/fm-jev-guard-friction-fail', content: 'x' } }, ctx);
before = events().length;
renameSync(ledger, `${ledger}.saved`);
mkdirSync(ledger);
let failed;
try {
  failed = await handlers.tool_call({ toolName: 'write', input: { path: '/etc/fm-jev-guard-friction-fail', content: 'x' } }, ctx);
} finally {
  rmdirSync(ledger);
  renameSync(`${ledger}.saved`, ledger);
}
assert.deepEqual(failed, expected, 'an unwritable ledger leaves the refusal unchanged');
assert.equal(events().length, before, 'an unwritable ledger records nothing');
// A missing writer runtime prints the guard-side diagnostic and leaves the refusal unchanged.
const path = process.env.PATH;
mkdirSync(`${home}/no-python`, { recursive: true });
process.env.PATH = `${home}/no-python`;
let missing;
try {
  missing = await handlers.tool_call({ toolName: 'write', input: { path: '/etc/fm-jev-guard-friction-fail', content: 'x' } }, ctx);
} finally {
  process.env.PATH = path;
}
assert.deepEqual(missing, expected, 'a missing writer leaves the refusal unchanged');
assert.equal(events().length, before, 'a missing writer records nothing');
assert.equal(await handlers.tool_call({ toolName: 'write', input: { path: 'src/friction-control.ts', content: 'x' } }, ctx), undefined);
assert.equal(events().length, before, 'an allowed write records nothing');
console.log('friction-ok');
JS
) || fail "friction refusal ledger: $out"
  [ "${out##*$'\n'}" = friction-ok ] || fail "friction refusal ledger did not reach its final line: $out"
  # Exactly one writer-side line (the unwritable ledger, where the writer ran) and exactly one
  # guard-side line (the missing runtime, where it could not), so neither failure prints both.
  writer_diagnostic='fm-friction: telemetry unavailable; preserve event identity and retry telemetry later; event_id='
  guard_diagnostic='fm-friction: refusal telemetry unavailable; guarded result unchanged; no event identity was recorded'
  writer_lines=$(grep -c "$writer_diagnostic" <<<"$out")
  guard_lines=$(grep -c "$guard_diagnostic" <<<"$out")
  [ "$writer_lines" -eq 1 ] || fail "the writer diagnostic was not printed exactly once, for the unwritable ledger: $out"
  [ "$guard_lines" -eq 1 ] || fail "the guard-side diagnostic was not printed exactly once, for the missing writer: $out"
  pass "every pre-tool refusal mirrors one digest-only fm-friction.v1 event keyed by its audit branch; allows, repeated identities and writer failures write nothing and never change the refusal"
}

test_bash_without_judgment
test_claude_effects
test_outages_and_scope
test_bounded_retry
test_missing_runtime
test_launch_cutover
test_crashing_runtime
test_service_contract
test_pretool_audit_policy
test_claude_node_pretool
test_omp_permissions
test_omp_device_effects
test_deadlines
test_oversize_writes
test_friction_refusal_ledger
test_ledger_privacy
