#!/usr/bin/env bash
# Offline guard policy, service and adapter regressions. The loopback fixture
# supplies controlled answers/errors, not model accuracy or publisher identity.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
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
  denied "$out" || fail "credential insertion was not denied"
  claude_hook "$(pre Edit '{"file_path":"src/app.ts","old_string":"sk-live-removed","new_string":""}')"
  [ -z "$out" ] || fail "credential removal was treated as insertion"
  before=$(requests)
  for path in xd://lsp proc://bg_1/kill; do
    claude_hook "$(pre Write "$(jq -cn --arg p "$path" '{file_path:$p,content:"{}"}')")"
    denied "$out" || fail "Claude admitted an OMP device"
  done
  [ "$(requests)" -eq "$before" ] || fail "Claude device payload reached the provider"
  pass "Claude pre-tool credential effects, allowed roots, removals and deterministic device refusal"
}

test_outages_and_scope() {
  local out before marker status project payload
  for marker in fail500 http402 invalid-json; do
    claude_hook "$(pre Write "$(jq -cn --arg m "$marker" '{file_path:"src/outage.txt",content:$m}')")"
    denied "$out" || fail "$marker allowed a required judgment"
  done
  mv "$HOME_DIR/.env" "$HOME_DIR/env.off"
  before=$(requests)
  printf 'synthetic-sensitive-token\n' > "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Write '{"file_path":"src/privacy.txt","content":"synthetic-SENSITIVE-token"}')"
  denied "$out" || fail "privacy refusal allowed active execution"
  jq -se '.[-1].error_type == "PrivacyWithheldError" and .[-1].request_started == false' "$HOME_DIR/state/jev-guard.jsonl" >/dev/null || fail "privacy was not checked before missing credentials"
  rm "$HOME_DIR/config/dispatch-never-send"
  claude_hook "$(pre Write '{"file_path":"src/deploy.txt","content":"plain write"}')"
  denied "$out" || fail "missing credentials allowed active execution"
  [ "$(requests)" -eq "$before" ] || fail "privacy or missing credentials sent a request"
  mv "$HOME_DIR/env.off" "$HOME_DIR/.env"
  printf 'OPENROUTER_API_KEY=fake-openrouter\n' >> "$HOME_DIR/.env"
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"fail500"}')"
  denied "$out" || fail "TypeSafe failure did not require review"
  [ "$(requests)" -eq $((before + 3)) ] || fail "TypeSafe failure fell back or did not stop after three tries of HTTP 500"
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
  pass "active privacy/key/provider/contract failures require review; inactive scopes send nothing and keep path checks"
}

test_bounded_retry() {
  local out before reason ledger
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"flaky-once write"}')"
  [ -z "$out" ] || fail "an outage followed by success did not allow the call"
  [ "$(requests)" -eq $((before + 2)) ] || fail "outage then success did not use exactly two tries"
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"fail500 again"}')"
  denied "$out" || fail "three outages allowed a required judgment"
  [ "$(requests)" -eq $((before + 3)) ] || fail "persistent outage did not stop after two retries"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  [[ "$reason" == *"could not run"* && "$reason" == *"same call once more"* ]] || fail "outage deny text lost the retry guidance: $reason"
  jq -se '.[-1] | .error_type == "Error" and .request_started == true and .attempts == 3 and (.ms | type == "number")' "$HOME_DIR/state/jev-guard.jsonl" >/dev/null || fail "failure row lost attempts and ms"
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"sk-live-fixture"}')"
  denied "$out" || fail "policy block was not denied"
  [ "$(requests)" -eq $((before + 1)) ] || fail "policy block was retried"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  before=$(requests)
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"invalid-json"}')"
  denied "$out" || fail "malformed response allowed a required judgment"
  [ "$(requests)" -eq $((before + 1)) ] || fail "contract failure was retried"
  jq -se '.[-1] | .error_type == "ContractError" and .attempts == 1' "$HOME_DIR/state/jev-guard.jsonl" >/dev/null || fail "contract failure row lost its single try"
  ledger="$HOME_DIR/state/jev-guard.jsonl"
  mv "$ledger" "$ledger.saved"
  mkdir "$ledger"
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"sk-live-fixture"}')"
  denied "$out" || fail "policy block was not denied while the ledger write failed"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  [[ "$reason" == *"AuditUnavailableError"* ]] || fail "failed ledger write was not named: $reason"
  claude_hook "$(pre Write '{"file_path":"/etc/fm-jev-guard-outside","content":"x"}')"
  denied "$out" || fail "deterministic refusal was not denied while the ledger write failed"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  claude_hook "$(pre Write '{"file_path":"src/retry.txt","content":"fail500 ledger"}')"
  denied "$out" || fail "outage was not denied while the ledger write failed"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")
  rmdir "$ledger"
  mv "$ledger.saved" "$ledger"
  pass "bounded outage retries: a later answer allows, repeated outage requests review, policy and contract results are not retried"
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
const { WRITE_QUESTIONS } = await import(new URL('../src/levels/level06/index.ts', pathToFileURL(process.env.REPORT)));
const home = process.env.HOME_DIR;
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 'service', project: 'firstmate' };
const rows = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const service = createGuardService(context);
const empty = { path: 'file.ts', content: '' };
const overhead = Buffer.byteLength(JSON.stringify({ model: GUARD_MODEL, state: empty, questions: WRITE_QUESTIONS }));
const remaining = MAX_REQUEST_BYTES - overhead;
const content = 'é'.repeat(Math.floor(remaining / 2)) + 'x'.repeat(remaining % 2);
const result = await service.decide({ ...empty, content }, WRITE_QUESTIONS);
assert.equal(Buffer.byteLength(result.raw.requestText), 16384);
assert.equal(result.answers.contains_secret.noul, 0.05);
assert.equal(result.raw.response.extra, 'provider-private-canary');
assert.equal(JSON.parse(result.raw.responseText).extra, 'provider-private-canary');
assert.equal(result.meta.provider, 'typesafe');
assert.deepEqual(result.meta.cost, { amount: null, source: 'unknown' });
const beforeOversize = rows().length;
await assert.rejects(service.decide({ ...empty, content: content + 'x' }, WRITE_QUESTIONS), { name: 'RequestTooLargeError', requestStarted: false });
assert.equal(rows().length, beforeOversize, 'over-limit request must not send even after a client exists');
const cost = await service.decide({ ...empty, content: 'reported-cost' }, WRITE_QUESTIONS);
assert.deepEqual(cost.meta.cost, { amount: 0.001, source: 'reported' });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=rotated-fake-key\n');
await service.decide({ ...empty, content: 'same-session' }, WRITE_QUESTIONS);
assert.equal(rows().at(-1).auth, `Bearer ${process.env.KEY}`);
const second = createGuardService(context);
await second.decide({ ...empty, content: 'new-session' }, WRITE_QUESTIONS);
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
const credentialTail = await handlers.tool_call({ toolName: 'write', input: { path: 'src/large.ts', content: 'x'.repeat(4500) + 'sk-live-fixture' } }, ctx);
assert.equal(credentialTail.block, true, 'content beyond the former write prefix must affect the decision');
const beforeHuge = requests();
const huge = await handlers.tool_call({ toolName: 'write', input: { path: 'src/large.ts', content: 'é'.repeat(8500) } }, ctx);
assert.equal(huge, undefined, 'an oversized benign write is screened in pieces and allowed');
assert.ok(requests().length > beforeHuge.length, 'every piece of an oversized write is sent for screening');
const bad = install({ state: `${home}/audit-bad` });
assert.match((await bad.tool_call({ toolName: 'write', input: { path: 'src/deploy.txt', content: 'ordinary write' } }, ctx)).reason, /AuditUnavailableError/);
const inactive = install({ noHelpers: true, state: `${home}/audit-bad` });
const beforeInactive = requests();
assert.equal(await inactive.tool_call({ toolName: 'bash', input: { command: 'rm -rf fixture' } }, ctx), undefined);
assert.equal(requests(), beforeInactive);
assert.equal((await inactive.tool_call({ toolName: 'write', input: { path: '/etc/hosts', content: 'fixture' } }, ctx)).block, true);
console.log('pretool-policy-ok');
JS
) || fail "pre-tool/audit policy: $out"
  [ "$out" = pretool-policy-ok ] || fail "unexpected pre-tool policy output: $out"
  pass "pre-tool complete credential tails, audit failure and inactive independence"
}
test_claude_node_pretool() {
  local out
  out=$(pre Write '{"file_path":"src/node.ts","content":"sk-live-fixture"}' | "${NODE_TS[@]}" "$ROOT/bin/fm-jev-guard-claude.ts" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1)
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
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const home = process.env.HOME_DIR;
function install(task, host) {
  const handlers = {};
  installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task, host, worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
  return handlers;
}
const claude = install('deadline', 'claude');
const omp = install('deadline-omp', 'omp');
// Both hosts retain the 330-second pre-tool envelope above the 300-second service budget.
async function beforeHostDeadline(handlers, name, event, limitMs) {
  let timer;
  try {
    return await Promise.race([handlers[name](event, { cwd: process.env.WT }), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${limitMs} ms host deadline exceeded`)), limitMs); })]);
  } finally { clearTimeout(timer); }
}
const started = performance.now();
const [slowCall, pre, ompSlowCall, ompPre] = await Promise.all([
  beforeHostDeadline(claude, 'tool_call', { toolName: 'write', input: { path: 'src/deadline.txt', content: 'late-answer' } }, 330000),
  beforeHostDeadline(claude, 'tool_call', { toolName: 'write', input: { path: 'src/deadline.txt', content: 'stall-direct' } }, 330000),
  beforeHostDeadline(omp, 'tool_call', { toolName: 'write', input: { path: 'src/deadline.txt', content: 'late-answer' } }, 330000),
  beforeHostDeadline(omp, 'tool_call', { toolName: 'write', input: { path: 'src/deadline.txt', content: 'stall-direct' } }, 330000),
]);
assert.equal(slowCall, undefined, 'a judge answer arriving after 30 seconds must allow the call');
assert.equal(pre.block, true);
assert.match(pre.reason, /TimeoutError/);
assert.match(pre.reason, /REVIEW_ON_UNAVAILABLE_V1/);
const rows = readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const late = rows.filter(row => row.task === 'deadline' && row.branch === 'policy');
assert.equal(late.length, 1);
for (const row of late) {
  assert.equal(row.error_type, null);
  assert.ok(row.ms >= 30000, `the late answer was actually waited for: ${row.ms}`);
}
const stalled = rows.filter(row => row.task === 'deadline' && row.branch === 'outage');
assert.equal(stalled.length, 1);
for (const row of stalled) {
  assert.equal(row.attempts, 3, 'a dead judge receives all three full tries');
  assert.ok(row.ms >= 270000 && row.ms < 300000, `three 90-second tries and backoff stay inside the decision budget: ${row.ms}`);
}
assert.ok(performance.now() - started >= 270000, 'outage cannot be reported at the old latency deadline');

assert.equal(ompSlowCall, undefined, 'omp pre-tool waits for a judge answer arriving after 30 seconds');
assert.equal(ompPre.block, true);
assert.match(ompPre.reason, /TimeoutError/);
const ompRows = rows.filter(row => row.task === 'deadline-omp');
const ompLate = ompRows.find(row => row.hook === 'tool_call' && row.branch === 'policy');
assert.equal(ompLate.error_type, null);
assert.ok(ompLate.ms >= 30000, `omp pre-tool actually waited for the late answer: ${ompLate.ms}`);
const ompPreRow = ompRows.find(row => row.hook === 'tool_call' && row.branch === 'outage');
assert.equal(ompPreRow.attempts, 3, 'omp pre-tool gives a dead judge all three full tries');
assert.ok(ompPreRow.ms >= 270000 && ompPreRow.ms < 300000, `omp pre-tool row time ${ompPreRow.ms}`);
console.log('deadlines-ok');
JS
) || fail "handler deadlines: $out"
  [ "$out" = deadlines-ok ] || fail "unexpected deadline output: $out"
  pass "actual stalled requests produce typed pre-tool denial before each documented host deadline"
}

test_ledger_privacy() {
  local ledger="$HOME_DIR/state/jev-guard.jsonl" mode
  mode=$(node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o7777).toString(8))' "$ledger")
  [ "$mode" = 600 ] || fail "ledger is not private"
  ! grep -q "$KEY\|fake-openrouter\|provider-private-canary\|private-output-canary\|IGNORE PREVIOUS\|sk-live\|plain text" "$ledger" || fail "sensitive fixture content or provider extensions reached routine logs"
  jq -se 'all(.[]; .kind == "terminal" and has("error_type") and .outage_policy == "REVIEW_ON_UNAVAILABLE_V1" and .policy_version == "FIRSTMATE_JEV_GUARD_V1" and (has("state")|not) and (has("raw")|not) and (has("message")|not) and (has("command")|not) and (has("path")|not)) and any(.[]; .usage.input_tokens == 3 and .cost.source == "unknown") and any(.[]; .error_type == "Error") and any(.[]; .decision == "inactive" and .error_type == null and .cost.source == "not_called")' "$ledger" >/dev/null || fail "terminal audit contract lost error, policy, usage or certainty"
  pass "private terminal audit keeps typed errors and cost certainty without payloads or provider extensions"
}

test_oversize_screening() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const { splitForRoom, MAX_REQUEST_BYTES, MAX_CHUNKS, CHUNK_OVERLAP_BYTES } = await import(pathToFileURL(process.env.REPORT));
const home = process.env.HOME_DIR;
const handlers = {};
installJevGuard({ on: (name, fn) => { handlers[name] = fn; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'oversize', worktree: process.env.WT, data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
const ctx = { cwd: process.env.WT };
const sent = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const rows = n => readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').slice(-n).map(JSON.parse);
const lines = count => Array.from({ length: count }, (_, i) => `L${i}: const answer = compute(${i}); // ordinary source line\n`);
const benign = lines(700).join('');
const write = content => handlers.tool_call({ toolName: 'write', input: { path: 'src/big.ts', content } }, ctx);
const unplannable = content => handlers.tool_call({ toolName: 'write', input: { path: `src/${'p'.repeat(MAX_REQUEST_BYTES)}.ts`, content } }, ctx);
const splice = (marker, at = 350) => [...lines(at), marker + '\n', ...lines(700).slice(at)].join('');

// An oversized benign write is allowed after every part was screened in a request that fits the ceiling.
let before = sent().length;
assert.equal(await write(benign), undefined);
let batch = sent().slice(before).map(r => JSON.parse(r.body));
assert.ok(batch.length >= 3 && batch.length <= MAX_CHUNKS, `pieces: ${batch.length}`);
for (const r of sent().slice(before)) assert.ok(Buffer.byteLength(r.body) <= MAX_REQUEST_BYTES, 'each piece is a request that fits the ceiling');
for (let i = 0; i < 700; i++) assert.ok(batch.some(b => b.state.content.includes(`L${i}:`)), `line ${i} was never screened`);
let [row] = rows(1);
assert.equal(row.decision, 'allow');
assert.equal(row.chunks, batch.length);
assert.equal(row.usage.input_tokens, 3 * batch.length, 'usage totals every piece');
assert.equal(row.attempts, batch.length);

// One blocked piece blocks the whole write and names its part.
let blocked = await write(splice('token = sk-live-fixture'));
assert.equal(blocked.block, true);
assert.match(blocked.reason, /credential/);
assert.match(blocked.reason, /\(part \d+ of \d+\)/);
[row] = rows(1);
assert.equal(row.decision, 'block');
assert.ok(row.chunks >= 3);

// A piece that cannot be screened blocks the write as an outage, with the outage wording.
let outage = await write(splice('fail500'));
assert.equal(outage.block, true);
assert.match(outage.reason, /Review required: Error/);
assert.match(outage.reason, /same call once more/);
[row] = rows(1);
assert.equal(row.error_type, 'Error');
assert.equal(row.request_started, true);
assert.ok(row.chunks >= 3);

// A policy block outranks an outage elsewhere in the same payload.
blocked = await write([...lines(100), 'fail500\n', ...lines(300), 'sk-live-fixture\n', ...lines(300)].join(''));
assert.match(blocked.reason, /credential/);
assert.doesNotMatch(blocked.reason, /Review required/);

// A write whose path leaves no room for content within the request ceiling is refused before anything is sent.
before = sent().length;
const tooBig = await unplannable('ordinary content');
assert.equal(tooBig.block, true);
assert.match(tooBig.reason, /RequestTooLargeError/);
assert.match(tooBig.reason, /guard=FM-JEV-SIZE rule=complete-screening-budget/);
for (const budget of [MAX_CHUNKS, MAX_REQUEST_BYTES, CHUNK_OVERLAP_BYTES]) assert.ok(tooBig.reason.includes(String(budget)));
assert.doesNotMatch(tooBig.reason, /same call once more/, 'size failure must not prescribe a useless identical retry');
[row] = rows(1);
assert.equal(row.error_type, 'RequestTooLargeError');
assert.equal(row.request_started, false);
assert.equal(sent().length, before, 'an uncoverable payload must not send any piece');
const frictionPath = `${home}/state/friction.jsonl`;
const friction = () => readFileSync(frictionPath, 'utf8').trim().split('\n').map(JSON.parse);
const { createHash } = await import('node:crypto');
const taskDigest = 'sha256:' + createHash('sha256').update('oversize').digest('hex');
const sizeEvents = friction().filter(r => r.guard_id === 'FM-JEV-SIZE' && r.task_id === taskDigest);
assert.equal(sizeEvents.length, 1, 'one write denial produces one event');
for (const r of sizeEvents) {
  assert.equal(r.schema, 'fm-friction.v1');
  assert.equal(r.rule_id, 'complete-screening-budget');
  assert.equal(r.execution_kind, 'test');
  assert.equal(r.outcome, 'blocked');
  assert.equal(r.adjudication, 'unknown');
  assert.match(r.subject.identity, /^sha256:[a-f0-9]{64}$/);
}
assert.equal(JSON.stringify(sizeEvents).includes(home), false, 'bridge must not retain input paths');
// Optional friction storage cannot change admission or replace mandatory Jev audit.
const { renameSync, mkdirSync } = await import('node:fs');
renameSync(frictionPath, `${frictionPath}.saved`);
mkdirSync(frictionPath);
const telemetryFailure = await unplannable('ordinary content');
assert.equal(telemetryFailure.block, true);
assert.match(telemetryFailure.reason, /complete-screening-budget/);
assert.doesNotMatch(telemetryFailure.reason, /AuditUnavailableError/);
assert.equal(await write('ordinary bounded report'), undefined);
rmSync(frictionPath, { recursive: true });
renameSync(`${frictionPath}.saved`, frictionPath);
before = sent().length;

// The never-send policy covers the whole payload before the first piece leaves.
writeFileSync(`${home}/config/dispatch-never-send`, 'never-send-canary-value\n');
try {
  const refused = await write(splice('never-send-canary-value', 650));
  assert.equal(refused.block, true);
  [row] = rows(1);
  assert.equal(row.error_type, 'PrivacyWithheldError');
  assert.equal(row.request_started, false);
  assert.equal(sent().length, before, 'a clean piece must not leave beside a refused one');
} finally {
  rmSync(`${home}/config/dispatch-never-send`);
}

// Every short span lies whole inside one piece, and every piece fits its room in escaped bytes.
const room = MAX_REQUEST_BYTES - 900;
const samples = {
  tokens: Array.from({ length: 6000 }, (_, i) => `<${i}>`).join(''),
  escapes: Array.from({ length: 5000 }, (_, i) => `é"\\<${i}>\t`).join(''),
  astral: Array.from({ length: 5000 }, (_, i) => `😀<${i}>`).join(''),
};
for (const [name, text] of Object.entries(samples)) {
  const pieces = splitForRoom(text, room);
  assert.ok(pieces.length >= 3 && pieces.length <= MAX_CHUNKS, `${name}: ${pieces.length}`);
  for (const piece of pieces) assert.ok(Buffer.byteLength(JSON.stringify(piece)) - 2 <= room, `${name}: a piece exceeds its room`);
  for (const token of text.match(/<\d+>/g)) assert.ok(pieces.some(piece => piece.includes(token)), `${name}: ${token} was cut`);
  assert.ok(pieces.every(piece => !/[\ud800-\udfff]/.test(piece.replace(/[\ud800-\udbff][\udc00-\udfff]/g, ''))), `${name}: a surrogate pair was split`);
}
assert.equal(splitForRoom('x', 100), null, 'no room beyond the overlap means no complete cover');

// A span of 1,000 bytes lies whole inside one piece wherever the cut falls, including a cut through the middle of it.
const tight = 2 * CHUNK_OVERLAP_BYTES + 64;
for (const span of ['m'.repeat(1000), '😀'.repeat(250)]) {
  let cutThrough = 0;
  for (let at = tight - 1000; at <= tight; at++) {
    const pieces = splitForRoom('a'.repeat(at) + span + 'b'.repeat(50), tight);
    assert.equal(pieces.length, 2, `span at ${at}`);
    assert.ok(pieces.some(piece => piece.includes(span)), `a 1,000-byte span at ${at} was cut`);
    if (!pieces[0].includes(span)) cutThrough++;
  }
  assert.equal(cutThrough, 1000, 'the cut fell through the span at every offset but one');
}

console.log('oversize-ok');
JS
) || fail "oversize screening: $out"
  [ "${out##*$'\n'}" = oversize-ok ] || fail "oversize screening did not reach its final line: $out"
  pass "bounded pieces preserve policy/outage decisions; unplannable writes and never-send payloads send nothing"
}

test_claude_oversize() {
  local out before big="$TMP_ROOT/claude-big.txt" bad="$TMP_ROOT/claude-big-bad.txt" payload
  awk 'BEGIN { for (i = 0; i < 700; i++) printf "L%d: const answer = compute(%d); // ordinary source line\n", i, i }' > "$big"
  { head -n 350 "$big"; printf 'token = sk-live-fixture\n'; tail -n 350 "$big"; } > "$bad"
  before=$(requests)
  payload=$(jq -cn --arg p "$WT/src/big.ts" --rawfile c "$big" '{file_path:$p,content:$c}')
  claude_hook "$(pre Write "$payload")"
  [ -z "$out" ] || fail "an oversized benign Claude write was denied"
  [ "$(( $(requests) - before ))" -ge 3 ] || fail "an oversized Claude write was not screened in pieces"
  payload=$(jq -cn --arg p "$WT/src/big.ts" --rawfile c "$bad" '{file_path:$p,content:$c}')
  claude_hook "$(pre Write "$payload")"
  denied "$out" || fail "a credential in a late piece of an oversized Claude write was not denied"
  before=$(requests)
  out=$(WT="$WT" node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",cwd:process.env.WT,tool_name:"Write",tool_input:{file_path:process.env.WT+"/huge.txt",content:"x".repeat(262145)},tool_use_id:"size-refusal"}))' \
    | "$ROOT/bin/fm-jev-guard-hook.sh" "$HOME_DIR" "$HOME_DIR/config" "$HOME_DIR/state" t1 "$WT" "$TASK_DATA" firstmate FIRSTMATE_JEV_GUARD_V1) \
    || fail 'Claude large write changed its hook exit contract'
  [ -z "$out" ] || fail 'Claude refused a large benign write'
  [ "$(requests)" -eq $((before + 16)) ] || fail 'Claude did not use its bounded write screening budget'
  pass "Claude hooks retain JSON/exit contracts and admit budget-limited benign writes"
}

test_large_write_budget() {
  local out
  out=$("${NODE_TS[@]}" --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const { MAX_CHUNKS, MAX_REQUEST_BYTES, CHUNK_OVERLAP_BYTES } = await import(pathToFileURL(process.env.REPORT));
const home = process.env.HOME_DIR;
const worktree = `${process.env.WT}/large-report`;
mkdirSync(worktree);
execFileSync('git', ['init', '-q', worktree]);
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 'large-report', worktree,
  data: process.env.TASK_DATA, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
const handlers = {};
installJevGuard({ on(name, handler) { handlers[name] = handler; } }, context);
const ctx = { cwd: worktree };
const path = `${worktree}/report.md`;
const report = 'Ordinary report line with measured observations and no credentials.\n'.repeat(7000).slice(0, 396924);
assert.equal(Buffer.byteLength(report), 396924);
const sent = () => readFileSync(process.env.REQUESTS, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const row = () => JSON.parse(readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
const hook = `${dirname(process.env.GUARD)}/fm-jev-guard-hook.sh`;
async function call(host, content, tool = 'write', target = path) {
  if (host === 'omp') return handlers.tool_call({ toolName: tool,
    input: { path: target, content, new_string: content, old_string: '' } }, ctx);
  const result = execFileSync(hook, [home, context.config, context.state, context.task, worktree,
    context.data, context.project, context.policy], { encoding: 'utf8', input: JSON.stringify({
      hook_event_name: 'PreToolUse', cwd: worktree, tool_name: tool === 'write' ? 'Write' : 'Edit',
      tool_input: { file_path: target, content, new_string: content, old_string: '' },
    }) });
  return result === '' ? undefined : JSON.parse(result).hookSpecificOutput;
}
// A handler timer cannot interrupt synchronous regex work: isolate this case behind a process watchdog.
const hyphenated = 'ordinary-word-'.repeat(100000).slice(0, 1048576);
const boundedScan = execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', '--input-type=module', '-e', `
  import assert from 'node:assert/strict';
  import { readFileSync } from 'node:fs';
  import { pathToFileURL } from 'node:url';
  const { context, content } = JSON.parse(readFileSync(0, 'utf8'));
  const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
  const handlers = {};
  installJevGuard({ on(name, handler) { handlers[name] = handler; } }, context);
  const ctx = { cwd: context.worktree };
  const call = content => handlers.tool_call({ toolName: 'write', input: { path: 'hyphenated.md', content } }, ctx);
  const start = performance.now();
  assert.equal(await call(content), undefined, 'a long hyphenated line must be admitted');
  const denied = await call(content + 'postgres://fixture:FAKE_PASSWORD@localhost/db');
  assert.equal(denied?.block, true, 'a credential URL after a long scheme-character run still blocks');
  const row = JSON.parse(readFileSync(context.state + '/jev-guard.jsonl', 'utf8').trim().split('\\n').at(-1));
  assert.equal(row.branch, 'deterministic');
  assert.equal(row.request_started, false);
  console.log('hyphenated-scan-ok bytes=' + Buffer.byteLength(content) + ' offline_loopback_ms=' + Math.round(performance.now() - start));
`], { input: JSON.stringify({ context, content: hyphenated }), encoding: 'utf8', timeout: 30000, killSignal: 'SIGKILL' });
console.log(boundedScan.trim());
for (const host of ['omp', 'claude']) {
  const before = sent().length;
  const start = performance.now();
  assert.equal(await call(host, report), undefined, `${host}: complete report must be admitted in one write`);
  const elapsed = Math.round(performance.now() - start);
  const requests = sent().slice(before);
  assert.equal(requests.length, MAX_CHUNKS);
  let prefix = '';
  for (const [index, request] of requests.entries()) {
    assert.ok(Buffer.byteLength(request.body) <= MAX_REQUEST_BYTES);
    const piece = JSON.parse(request.body).state.content;
    let overlap = 0;
    let escaped = 0;
    if (index > 0) {
      while (overlap < prefix.length) {
        const bytes = Buffer.byteLength(JSON.stringify(prefix.slice(-overlap - 1, prefix.length - overlap))) - 2;
        if (escaped + bytes > CHUNK_OVERLAP_BYTES) break;
        escaped += bytes;
        overlap++;
      }
      assert.equal(piece.slice(0, overlap), prefix.slice(-overlap));
    }
    prefix += piece.slice(overlap);
  }
  assert.equal(report.slice(0, prefix.length), prefix, 'the measured coverage is the unique prefix, not overlap or framing');
  assert.ok(prefix.length < report.length);
  const expected = { model_screened_bytes: Buffer.byteLength(prefix), local_only_bytes: Buffer.byteLength(report.slice(prefix.length)) };
  assert.deepEqual(row().write_coverage, expected);
  assert.equal(row().decision, 'allow');
  assert.match(row().note, /unscreened remainder.*deterministic/);
  // The host writes only after admission; then its ordinary commit shell call runs without a pre-call judgment.
  writeFileSync(path, report);
  const command = 'git add report.md && git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -qm report';
  assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command } }, ctx), undefined);
  execFileSync('bash', ['-c', command], { cwd: worktree });
  assert.equal(execFileSync('git', ['show', 'HEAD:report.md'], { cwd: worktree }).length, 396924);
  console.log(`${host}: wrote and committed 396924 bytes; requests=${requests.length}; model_screened_bytes=${expected.model_screened_bytes}; local_only_bytes=${expected.local_only_bytes}; offline_loopback_ms=${elapsed}`);
  for (const tool of ['write', 'edit']) {
    for (const [position, at] of [['start', 0], ['middle', 198462], ['end', report.length]]) {
      const fake = '\nghp_FAKECREDENTIALFORTESTSONLY123456\n';
      const payload = report.slice(0, at) + fake + report.slice(at);
      const count = sent().length;
      const denied = await call(host, payload, tool);
      assert.ok(denied?.block || denied?.permissionDecision === 'deny', `${host} ${tool}: credential at ${position}`);
      assert.equal(row().branch, 'deterministic');
      assert.equal(row().request_started, false);
      assert.equal(sent().length, count, 'a local credential refusal must not send any prefix');
    }
  }
  console.log(`${host}: whole-text local credential refusal at start, middle and end for write and edit; zero provider requests`);
  const beforeOutside = sent().length;
  const outside = await call(host, report, 'write', '/etc/large-guard-report');
  assert.ok(outside?.block || outside?.permissionDecision === 'deny');
  assert.equal(sent().length, beforeOutside);
  // Privacy rules cover every piece a model would see, and one refused piece keeps every clean piece home.
  const canary = 'large-report-never-send-canary';
  const entry = Array.from({ length: 480 }, (_, i) => `zq${String(i).padStart(4, '0')}`).join(' ').slice(0, 3299);
  assert.equal(entry.length, 3299);
  writeFileSync(`${home}/config/dispatch-never-send`, canary + '\n' + entry + '\n');
  try {
    for (const at of [1000, expected.model_screened_bytes - 2000]) {
      const denied = await call(host, report.slice(0, at) + '\n' + canary + '\n' + report.slice(at));
      assert.ok(denied?.block || denied?.permissionDecision === 'deny', `${host}: canary at ${at} must be refused`);
      assert.equal(row().error_type, 'PrivacyWithheldError');
      assert.equal(row().request_started, false);
      assert.equal(sent().length, beforeOutside, 'a clean piece must not leave beside a refused one');
    }
    // Pieces are checked one at a time: a value longer than the 1,024-byte overlap that lies whole in one piece is withheld, and one cut across a boundary reaches the model only as fragments.
    const first = JSON.parse(requests[0].body).state.content.length;
    const base = report.slice(0, 4 * first);
    const around = (at) => base.slice(0, at) + '\n' + entry + '\n' + base.slice(at);
    const wholeValue = await call(host, around(1000));
    assert.ok(wholeValue?.block || wholeValue?.permissionDecision === 'deny', `${host}: a long never-send value inside one piece must be refused`);
    assert.equal(row().error_type, 'PrivacyWithheldError');
    assert.equal(row().request_started, false);
    assert.equal(sent().length, beforeOutside);
    assert.equal(await call(host, around(first - 2000)), undefined, `${host}: a never-send value cut across a piece boundary is admitted`);
    assert.equal(row().decision, 'allow');
    const cut = sent().slice(beforeOutside).map(request => JSON.parse(request.body).state.content);
    assert.ok(cut.length > 1);
    assert.ok(cut.every(piece => !piece.includes(entry)), 'no piece holds the whole cut value');
    assert.ok(cut.some(piece => piece.includes(entry.slice(0, 500))) && cut.some(piece => piece.includes(entry.slice(-500))), 'both fragments of the cut value reached the model');
    const afterCut = sent().length;
    // The unscreened remainder never reaches a model, so the never-send policy has nothing to withhold.
    const start = performance.now();
    assert.equal(await call(host, report + '\n' + canary), undefined, `${host}: a canary only in the remainder must not stop the write`);
    assert.equal(row().decision, 'allow');
    assert.ok(sent().slice(afterCut).every(request => !request.body.includes(canary)), 'the remainder must never be sent');
    console.log(`${host}: never-send file present; 396924-byte report admitted in ${Math.round(performance.now() - start)} ms`);
    // The never-send check cost must not grow with the size of the write.
    const megabyte = 'Ordinary report line with measured observations and no credentials.\n'.repeat(16000).slice(0, 1048576);
    const largeStart = performance.now();
    assert.equal(await call(host, megabyte), undefined, `${host}: a 1 MiB write with a never-send file must be admitted`);
    const largeMs = Math.round(performance.now() - largeStart);
    assert.ok(largeMs < 30000, `${host}: a 1 MiB write took ${largeMs} ms with a never-send file`);
    assert.equal(row().decision, 'allow');
    console.log(`${host}: never-send file present; ${Buffer.byteLength(megabyte)}-byte write admitted in ${largeMs} ms`);
  } finally {
    const { unlinkSync } = await import('node:fs');
    unlinkSync(`${home}/config/dispatch-never-send`);
  }
}
// A multi-byte/escaped report also fits every request, keeps code points, and accounts in UTF-8 bytes.
const unicode = ('é"\\😀\n\ud800x\udfff' + String.fromCharCode(...Array.from({ length: 32 }, (_, i) => i))).repeat(12000);
let before = sent().length;
assert.equal(await call('omp', unicode, 'edit'), undefined);
assert.equal(row().write_coverage.model_screened_bytes + row().write_coverage.local_only_bytes, Buffer.byteLength(unicode));
assert.ok(row().write_coverage.local_only_bytes > 0);
for (const request of sent().slice(before)) {
  assert.ok(Buffer.byteLength(request.body) <= MAX_REQUEST_BYTES);
  const piece = JSON.parse(request.body).state.content;
  assert.equal(/\ud83d(?!\ude00)|(?<!\ud83d)\ude00/.test(piece), false, 'a valid astral pair must not be cut');
}
for (const [shape, fake] of [['private-key', '-----BEGIN PRIVATE KEY-----'], ['pgp-private-key', '-----BEGIN PGP PRIVATE KEY BLOCK-----'], ['github-token', 'ghp_FAKECREDENTIALFORTESTSONLY123456'],
  ['github-fine-grained-token', 'github_pat_FAKECREDENTIALFORTESTSONLY123456'], ['aws-key', 'AKIAFAKEFORTESTSONLY'],
  ['slack-token', 'xoxb-FAKECREDENTIALFORTESTS'], ['connection-url', 'postgres://fixture:FAKE_PASSWORD@localhost/db'],
  ['password-only-url', 'redis://:hunter2hunter2@cache:6379']]) {
  before = sent().length;
  assert.equal((await call('omp', report + '\n' + fake))?.block, true, `embedded ${shape} must be refused locally`);
  assert.equal(row().branch, 'deterministic');
  assert.equal(sent().length, before);
}
// Ordinary hyphenated prose, prefix look-alikes inside words, query-string addresses and unanchored credential-like wording are not credentials.
const prose = ['task-specific-guidelines', 'risk-based-assessment', 'disk-backed-storage-layer', 'task-local-logs-and-evidence',
  'Bearer authentication-scheme', 'password = process.env.DATABASE_PASSWORD', 'password: must-be-at-least-sixteen',
  'prefix-ghp_FAKECREDENTIALFORTESTSONLY123456', 'task-AKIAFAKEFORTESTSONLY', 'inbox-xoxb-FAKECREDENTIALFORTESTS',
  'http://localhost:3000?email=foo@bar.com', 'https://example.com:8080?contact=someone@example.com',
  '{"endpoint":"http://localhost:3000","owner":"alice@example.com"}', 'url,http://host:8080,owner,bob@example.com'].join('\n');
for (const host of ['omp', 'claude']) {
  before = sent().length;
  assert.equal(await call(host, report + '\n' + prose), undefined, `${host}: benign prose in a budget-limited write must be admitted`);
  assert.equal(row().decision, 'allow');
  assert.equal(row().branch, 'policy');
  assert.equal(sent().length - before, MAX_CHUNKS);
}
for (const host of ['omp', 'claude']) {
  for (const prefix of ['-', '+', '.', '---.+', '1-']) {
    for (const tool of ['write', 'edit']) {
      before = sent().length;
      const denied = await call(host, report + '\n' + prefix + 'postgres://fixture:FAKE_PASSWORD@localhost/db', tool);
      assert.ok(denied?.block || denied?.permissionDecision === 'deny', `${host}: ${tool} URL after ${prefix} must be refused`);
      assert.equal(row().branch, 'deterministic');
      assert.equal(row().request_started, false);
      assert.equal(sent().length, before, 'punctuation-led URL credentials must not reach the model');
    }
  }
}
console.log('punctuation-led URL credentials: both hosts refuse write/edit locally with zero provider requests');
// An answered policy refusal and a provider outage still stop a partially model-screened write.
for (const marker of ['rm -rf', 'fail500']) {
  const denied = await call('omp', marker + report);
  assert.equal(denied.block, true);
  assert.equal(row().enforcement, 'pretool_deny');
  assert.equal(row().write_coverage, undefined, 'a failed review must not claim complete model coverage of its prefix');
}
console.log('large-write-budget-ok');
JS
) || fail "large report write budget: $out"
  printf '%s\n' "$out"
  [ "${out##*$'\n'}" = large-write-budget-ok ] || fail "large report regression did not finish: $out"
  pass "396924-byte reports write and commit through both guards; anchored credential shapes/roots refuse, never-send covers every model-sent piece without a size stall, and coverage is audited"
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
test_deadlines
test_oversize_screening
test_claude_oversize
test_large_write_budget
test_ledger_privacy
