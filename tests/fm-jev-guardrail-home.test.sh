#!/usr/bin/env bash
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(TMPDIR="$ROOT" fm_test_tmproot fm-jev-guardrail-home)
unset LAVISH_AXI_HOST TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE

if command -v bun >/dev/null 2>&1; then
  TS_RUNNER=("$(command -v bun)")
else
  TS_RUNNER=("$(command -v node)" --experimental-strip-types)
fi

fm_git_worktree "$TMP_ROOT/source" "$TMP_ROOT/code" guardrail-source
CODE="$TMP_ROOT/code"
cp -R "$ROOT/bin" "$CODE/"
mkdir -p "$CODE/.omp/extensions" "$CODE/.claude" "$CODE/.agents/skills"
cp "$ROOT/.omp/fm-worker-overlay.yml" "$CODE/.omp/"
cp "$ROOT/.omp/fm-session-overlay.yml" "$CODE/.omp/"
cp "$ROOT/.omp/extensions/fm-jev-guardrail.ts" "$CODE/.omp/extensions/"
cp "$ROOT/.claude/settings.json" "$CODE/.claude/"
DRIVER="$TMP_ROOT/consumer.mjs"
cat > "$DRIVER" <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const [mode, artifact, home, config, state, transport, code, posture] = process.argv.slice(2);
const ledger = resolve(state, 'jev-guardrail.jsonl');
const rows = path => existsSync(path) ? readFileSync(path, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
const before = rows(ledger).length;
const requestBefore = rows(transport).length;
if (posture === 'filtered') {
  assert.equal(process.env.FM_HOME, undefined);
  assert.equal(process.env.FM_CONFIG_OVERRIDE, undefined);
  assert.equal(process.env.FM_STATE_OVERRIDE, undefined);
}
if (mode.startsWith('tracked')) {
  assert.equal(process.env.FM_HOME, home, 'secondmate launch must select its own home');
  assert.equal(process.env.FM_CONFIG_OVERRIDE, '');
  assert.equal(process.env.FM_STATE_OVERRIDE, '');
  assert.equal(process.env.FM_TASK_ID, undefined);
}
let invoke;
if (mode.endsWith('claude')) {
  const settings = JSON.parse(readFileSync(artifact, 'utf8'));
  assert.equal(settings.hooks.PostToolUse, undefined);
  assert.equal(settings.hooks.PostToolUseFailure, undefined);
  const hooks = settings.hooks.PreToolUse.filter(entry => entry.matcher === '^(Bash|Read)$');
  assert.equal(hooks.length, 1);
  assert.equal(hooks[0].hooks.length, 1);
  invoke = async command => {
    const result = spawnSync('/bin/sh', ['-c', hooks[0].hooks[0].command], {
      env: { ...process.env, CLAUDE_PROJECT_DIR: home },
      input: JSON.stringify({ tool_name: 'Bash', tool_input: { command }, tool_use_id: 'synthetic-call' }),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
  };
} else {
  const registrations = new Map();
  const api = { on(name, handler) {
    const handlers = registrations.get(name) || [];
    handlers.push(handler); registrations.set(name, handlers);
  }};
  const shared = await import(pathToFileURL(resolve(code, '.omp/extensions/fm-jev-guardrail.ts')).href);
  if (mode === 'generated-omp') {
    process.env.FM_TASK_ID = 'synthetic-worker';
    shared.default(api);
    assert.equal(registrations.size, 0, 'task auto-discovery must defer to its generated owner');
    const generated = await import(pathToFileURL(artifact).href);
    generated.default(api);
    generated.default(api);
    shared.default(api);
  } else {
    const tracked = await import(pathToFileURL(artifact).href);
    tracked.default(api);
    tracked.default(api);
  }
  assert.equal(registrations.get('tool_call')?.length, 1, 'screen registration must be idempotent');
  assert.equal(registrations.has('tool_result'), false, 'ordinary and failed results must not install outcome accounting');
  invoke = async command => {
    const event = { toolName: 'bash', input: { command }, toolCallId: 'synthetic-call' };
    const snapshot = JSON.stringify(event);
    assert.equal(await registrations.get('tool_call')[0](event), undefined);
    assert.equal(JSON.stringify(event), snapshot, 'advisory callback must not change input');
  };
}
await invoke('cat README.md');
assert.equal(rows(ledger).at(-1).status, 'excluded');
assert.equal(rows(transport).length, requestBefore);
await invoke('rm -rf /production/synthetic-safe-input');
assert.equal(rows(ledger).at(-1).status, 'judged', 'owner .env key must enable transport');
const sent = rows(transport).at(-1);
assert.equal(sent.header, `Authorization: Bearer ${mode.startsWith('tracked') ? 'synthetic-secondmate-key' : 'synthetic-owner-key'}\n`);
assert.deepEqual(sent.request.state.operations, [{ operation: 'delete', scope: 'production', recursive: true, force: true }]);
assert.equal(rows(transport).length, requestBefore + 1);
await invoke('rm -f owner-private-token');
assert.equal(rows(ledger).at(-1).status, 'withheld', 'effective owner config must withhold before transport');
assert.equal(rows(transport).length, requestBefore + 1);
await invoke('rm -f parent-only-private-token');
assert.equal(rows(ledger).at(-1).status, 'judged', 'ambient or primary policy must not replace owner policy');
assert.equal(rows(transport).length, requestBefore + 2);
process.env.FM_TEST_REPLY = 'failure';
await invoke('cat .env');
delete process.env.FM_TEST_REPLY;
assert.equal(rows(ledger).at(-1).status, 'timeout', 'transport failure must remain advisory');
assert.equal(rows(transport).length, requestBefore + 3);
const added = rows(ledger).slice(before);
assert.deepEqual(added.filter(row => row.event === 'result').map(row => row.status), ['excluded', 'judged', 'withheld', 'judged', 'timeout']);
assert.ok(added.every(row => ['attempt', 'result'].includes(row.event)));
assert.equal(statSync(ledger).mode & 0o777, 0o600);
const text = readFileSync(ledger, 'utf8');
for (const secret of ['synthetic-owner-key', 'synthetic-secondmate-key', 'owner-private-token', 'parent-only-private-token', 'synthetic-safe-input', 'synthetic-call']) assert.ok(!text.includes(secret));
if (mode.startsWith('generated')) assert.equal(existsSync(resolve(home, 'state/jev-guardrail.jsonl')), false, 'explicit state must replace home/state');
assert.equal(existsSync(resolve(code, 'state/jev-guardrail.jsonl')), false, 'shared code root must not own the worker ledger');
console.log(`ok - ${mode} ${posture}: owner key, policy, private ledger and advisory behavior`);
JS

make_transport() {
  cat > "$1/curl" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) process.exit(9);
const assert = require('node:assert/strict');
assert.equal(process.argv[2], '-q');
assert.ok(process.argv.some((arg, index) => arg === '-H' && process.argv[index + 1] === '@-'));
const request = JSON.parse(process.argv[process.argv.indexOf('--data-binary') + 1]);
const header = fs.readFileSync(0, 'utf8');
assert.ok(!process.argv.some(arg => arg.includes(header.trim().slice('Authorization: Bearer '.length))));
fs.appendFileSync(process.env.FM_TEST_TRANSPORT, JSON.stringify({ request, header }) + '\n', { mode: 0o600 });
if (process.env.FM_TEST_REPLY === 'failure') process.exit(28);
process.stdout.write(JSON.stringify({ model: 'jev-1.13.0', usage: { input_tokens: 100, output_tokens: 1 }, answers: { risk: { type: 'choice', choice: 'risky', confidence: 0.9, probabilities: { risky: 0.9, routine: 0.05, uncertain: 0.05 } } } }) + '\n200');
JS
  chmod +x "$1/curl"
}

spawn_world() {
  CASE="$TMP_ROOT/$1"
  OWNER="$CASE/owner's \"home\""
  CONFIG_DIR="$CASE/effective \"config\"\\tail"
  STATE_DIR="$CASE/effective-state"
  fm_test_spawn_home "$OWNER" "$2"
  fm_test_spawn_brief "$OWNER" "$1"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$CASE/pane-home"
  cp "$OWNER/config/crew-harness" "$CONFIG_DIR/crew-harness"
  touch "$STATE_DIR/.last-watcher-beat"
  printf 'FM_TEST_TRANSPORT\n' > "$CONFIG_DIR/launch-env-allowlist"
  printf 'owner-private-token\n' > "$CONFIG_DIR/dispatch-never-send"
  printf 'parent-only-private-token\n' > "$OWNER/config/dispatch-never-send"
  printf 'TYPESAFE_API_KEY=synthetic-owner-key\n' > "$OWNER/.env"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake" claude omp)
  make_transport "$FAKEBIN"
  fm_git_worktree "$CASE/project" "$CASE/wt" "wt-$1"
  TRANSPORT="$CASE/transport.jsonl"
  LAUNCH="$CASE/launch.log"
}

emit_spawn() {
  local id=$1 project=$2
  shift 2
  local out
  out=$(cd "$CASE" && FM_ROOT_OVERRIDE='' FM_HOME="$OWNER" HOME="$CASE/pane-home" \
    CLAUDE_CONFIG_DIR='' FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$OWNER/data" \
    FM_PROJECTS_OVERRIDE="$OWNER/projects" FM_CONFIG_OVERRIDE="${CONFIG_DIR#"$CASE/"}" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_FAKE_PANE_PATH="$CASE/wt" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH" TMUX=fake,1,0 PATH="$FAKEBIN:$PATH" \
    "$CODE/bin/fm-spawn.sh" "$id" "$project" "$@" 2>&1) || fail "spawn failed: $out"
}

install_consumer() {
  local harness=$1 mode=$2 artifact=$3 home=$4 config=$5 state=$6 posture=$7
  {
    printf '#!/usr/bin/env bash\nexec '
    printf '%q ' "${TS_RUNNER[@]}" "$DRIVER" "$mode" "$artifact" "$home" "$config" "$state" "$TRANSPORT" "$CODE" "$posture"
    printf '\n'
  } > "$FAKEBIN/$harness"
  chmod +x "$FAKEBIN/$harness"
}

for harness in claude omp; do
  id="worker-$harness"
  spawn_world "$id" "$harness"
  emit_spawn "$id" "$CASE/project" --mode no-mistakes --yolo off
  if [ "$harness" = claude ]; then
    artifact="$CASE/wt/.claude/settings.local.json"
    jq -e '.hooks.Stop[0].hooks[1] | .timeout == 25 and (.command | contains("fm-jev-belay-hook.sh") and contains("FM_HOME="))' "$artifact" >/dev/null \
      || fail "claude worker settings lost the jev-belay Stop hook"
    ! grep -q 'synthetic-owner-key' "$artifact" || fail "claude worker settings hold the key"
  else
    artifact="$STATE_DIR/$id.omp-ext.ts"
  fi
  install_consumer "$harness" "generated-$harness" "$artifact" "$OWNER" "$CONFIG_DIR" "$STATE_DIR" filtered
  env -i HOME="$CASE/pane-home" PATH="$FAKEBIN:$PATH" TERM=xterm TMUX=synthetic-pane \
    FM_HOME="$CASE/hostile-home" FM_CONFIG_OVERRIDE="$OWNER/config" FM_STATE_OVERRIDE="$CASE/hostile-state" \
    FM_TEST_TRANSPORT="$TRANSPORT" /bin/sh -c "$(cat "$LAUNCH")" || fail "$harness filtered launch consumer failed"
  env -i HOME="$CASE/pane-home" PATH="$FAKEBIN:$PATH" \
    FM_HOME="$CASE/hostile-home" FM_CONFIG_OVERRIDE="$OWNER/config" FM_STATE_OVERRIDE="$CASE/hostile-state" \
    FM_TEST_TRANSPORT="$TRANSPORT" "${TS_RUNNER[@]}" "$DRIVER" "generated-$harness" \
    "$artifact" "$OWNER" "$CONFIG_DIR" "$STATE_DIR" "$TRANSPORT" "$CODE" hostile \
    || fail "$harness hostile ambient consumer failed"
  [ ! -e "$CASE/hostile-state/jev-guardrail.jsonl" ] || fail "$harness wrote the hostile ledger"
done

for harness in claude omp; do
  id="secondmate-$harness"
  spawn_world "$id" "$harness"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/data" "$sm/projects" "$sm/state" "$sm/config"
  cp -R "$CODE/bin" "$CODE/.omp" "$CODE/.claude" "$sm/"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  printf 'parent-only-private-token\n' > "$CONFIG_DIR/dispatch-never-send"
  emit_spawn "$id" "$sm" --secondmate
  printf 'TYPESAFE_API_KEY=synthetic-secondmate-key\n' > "$sm/.env"
  printf 'owner-private-token\n' > "$sm/config/dispatch-never-send"
  if [ "$harness" = claude ]; then
    artifact="$sm/.claude/settings.json"
  else
    artifact="$sm/.omp/extensions/fm-jev-guardrail.ts"
  fi
  install_consumer "$harness" "tracked-$harness" "$artifact" "$sm" "$sm/config" "$sm/state" own-home
  env -i HOME="$CASE/pane-home" PATH="$FAKEBIN:$PATH" TERM=xterm TMUX=synthetic-pane \
    FM_HOME="$OWNER" FM_CONFIG_OVERRIDE="$OWNER/config" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_TEST_TRANSPORT="$TRANSPORT" /bin/sh -c "$(cat "$LAUNCH")" || fail "$harness secondmate consumer failed"
  [ ! -e "$STATE_DIR/jev-guardrail.jsonl" ] || fail "$harness secondmate wrote primary ledger"
  [ ! -e "$OWNER/state/jev-guardrail.jsonl" ] || fail "$harness secondmate wrote primary default ledger"
done
