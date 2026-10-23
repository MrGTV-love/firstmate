#!/usr/bin/env bash
# Portable native-plugin lifecycle edges; vendor callbacks are separately
# exercised by fm-dsh-primary-live-e2e.test.sh against real dsh-tui.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
node --input-type=module - "$ROOT" "$TMP" <<'JS'
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
const [root, tmp] = process.argv.slice(2);
const {apply} = await import(pathToFileURL(join(root, '.dsh/fm-primary.mjs')));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) {
  const deadline = Date.now() + 60000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('native primary lifecycle did not settle');
    await delay(25);
  }
}
function setup(name, {failArm = false, failStart = false} = {}) {
  const dir = join(tmp, name);
  const bin = join(dir, 'bin');
  const home = join(dir, 'home');
  mkdirSync(bin, {recursive: true});
  mkdirSync(join(home, 'state'), {recursive: true});
  symlinkSync(join(root, 'bin/fm-timeout-lib.sh'), join(bin, 'fm-timeout-lib.sh'));
  const executable = (name, body) => writeFileSync(join(bin, name), '#!/usr/bin/env bash\nset -eu\n' + body + '\n', {mode: 0o700});
  executable('fm-sessionstart-run.sh', failStart ? "echo 'fixture startup fault' >&2; exit 1" : "printf 'SESSION START - fixture\\n'");
  executable('fm-dsh-primary.sh', "printf 'watch\\n'");
  executable('fm-turnend-guard.sh', "if [ -f \"$FM_HOME/state/ready\" ]; then exit 0; fi; echo 'no live supervisor' >&2; exit 2");
  executable('fm-wake-drain.sh', 'cat "$FM_HOME/state/queue"');
  executable('fm-watch-arm.sh', failArm ? "echo 'watcher: FAILED - fixture fault'; exit 1" : `
    printf '%s\\n' "\${BASHPID:-$$}" > "$FM_HOME/state/arm-pid"
    touch "$FM_HOME/state/ready"
    trap 'rm -f "$FM_HOME/state/ready"; exit 0' TERM INT
    echo 'watcher: started pid=fixture (beacon fresh)'
    while [ ! -f "$FM_HOME/state/close" ]; do sleep 0.05; done
    rm "$FM_HOME/state/ready" "$FM_HOME/state/close"
    echo 'check: fixture wake'
  `);
  writeFileSync(join(home, 'state/queue'), '');
  const handlers = new Map();
  const stops = [];
  const ctx = {on(event, fn) {handlers.set(event, fn);}, effect(fn) {stops.push(fn());}};
  const followups = [];
  const injected = [];
  const agent = {id: name, session: {header: {cwd: home}}, inject(value) {injected.push(value);}, followup(value) {followups.push(value);}};
  apply(ctx, {root: dir, home});
  const emit = (type, payload) => handlers.get(type)?.(payload);
  const step = messages => handlers.get('agent/pre-step')({agent, messages, turn: 1, step: 1, signal: new AbortController().signal},
    async () => ({kind: 'enter', messages}));
  const end = () => handlers.get('session/event')(agent.session, {type: 'turn/end', seq: 1});
  const consume = input => handlers.get('session/event')(agent.session, {type: 'user/message', data: input});
  const stop = () => {for (const fn of stops) fn();};
  return {home, agent, followups, injected, emit, step, end, consume, stop};
}
// DSH submits the positional brief at once and does not await agent/created.
// The awaited pre-step of the first step must enter the digest ahead of it.
const brief = {id: 'brief', role: 'user', source: {kind: 'user'}, content: [{type: 'text', text: 'opening brief'}]};
const opened = setup('startup-order');
const openedStart = opened.emit('agent/created', {agent: opened.agent});
const first = await opened.step([brief]);
assert.equal(first.kind, 'enter');
assert.deepEqual(first.messages.map(input => input.content[0].text), ['SESSION START - fixture\n', 'opening brief'], 'the first step must carry the digest ahead of the brief');
assert.deepEqual((await opened.step([brief])).messages, [brief], 'later steps must pass through unchanged');
await openedStart;
assert.equal(opened.followups.length + opened.injected.length, 0, 'startup must not queue a second turn or park the digest');
opened.stop();
const broken = setup('startup-failure', {failStart: true});
const brokenStart = broken.emit('agent/created', {agent: broken.agent});
const failedStep = await broken.step([brief]);
assert.match(failedStep.messages[0].content[0].text, /session start failed: fixture startup fault/, 'a failed startup must report the fault in the first step');
assert.equal(failedStep.messages[1], brief, 'a failed startup must keep the brief');
await brokenStart;
assert.equal(broken.followups.length, 0, 'a failed startup must not queue another turn');
assert.match(readFileSync(join(broken.home, 'state/.dsh-primary-events.jsonl'), 'utf8'), /"event":"error"/, 'a failed startup must be recorded');
broken.stop();
const fail = setup('failed-arm', {failArm: true});
await fail.emit('agent/created', {agent: fail.agent});
await until(() => fail.followups.length === 1);
// DSH commits UserMessage directly as event.data, including synthetic input.
// Consuming the forced continuation must not classify it as a new human turn.
fail.consume(fail.followups[0]);
fail.end();
await delay(1000);
fail.end();
await delay(1000);
assert.equal(fail.followups.length, 1, 'one failed episode must not force an endless series of model turns');
assert.match(fail.followups[0].content[0].text, /no live supervisor/);
fail.consume({id: 'external-user-turn', role: 'user', source: {kind: 'user'}, content: [{type: 'text', text: 'Try the recovery again.'}]});
fail.end();
await until(() => fail.followups.length === 2);
fail.consume(fail.followups[1]);
fail.end();
await delay(500);
assert.equal(fail.followups.length, 2, 'a real new user turn grants one fresh continuation, not unlimited synthetic continuations');
fail.stop();

const wake = setup('wake');
await wake.emit('agent/created', {agent: wake.agent});
await until(() => existsSync(join(wake.home, 'state/ready')));
const firstPid = readFileSync(join(wake.home, 'state/arm-pid'), 'utf8');
wake.end(); wake.end();
await delay(500);
assert.equal(readFileSync(join(wake.home, 'state/arm-pid'), 'utf8'), firstPid, 'repeated turn ends must retain one arm');
writeFileSync(join(wake.home, 'state/queue'), '100\t1\tcheck\tfixture\tnotice\n');
writeFileSync(join(wake.home, 'state/close'), '');
await until(() => wake.followups.length === 1);
wake.end();
await delay(500);
assert.equal(wake.followups.length, 1, 'an accepted but unconsumed notification must not be delivered twice');
assert.equal(existsSync(join(wake.home, 'state/ready')), false, 'unacknowledged rows must not spin new watcher cycles');
wake.consume(wake.followups[0]);
wake.end();
await until(() => wake.followups.length === 2);
assert.match(wake.followups[1].content[0].text, /generation-bound acknowledgement/, 'a consumed but unacknowledged wake requires the bounded guard continuation');
wake.consume(wake.followups[1]);
wake.end();
await delay(500);
assert.equal(wake.followups.length, 2, 'consuming the synthetic guard continuation must not reset its budget');
writeFileSync(join(wake.home, 'state/queue'), '');
wake.end();
await until(() => existsSync(join(wake.home, 'state/ready')));
const replacementPid = Number(readFileSync(join(wake.home, 'state/arm-pid'), 'utf8').trim());
assert.notEqual(String(replacementPid), firstPid.trim(), 'acknowledgement should permit the next cycle');
// A delegated child in the same directory must never take primary ownership.
await wake.emit('agent/created', {agent: {...wake.agent, id: 'subagent', session: {header: {cwd: wake.home, origin: 'subagent', delegationDepth: 1}}, inject() {throw new Error('child must not receive startup');}}});
wake.stop();
await until(() => {try {process.kill(replacementPid, 0); return false;} catch {return true;}});
const before = wake.followups.length;
wake.end();
await delay(100);
assert.equal(wake.followups.length, before, 'disposed callbacks must not wake the retired session');
// SIGKILL does not invoke Cordis disposal. The shared watchdog must retire
// the watcher and its TERM-resistant descendant without an arbitrary deadline.
const crash = setup('native-crash');
const crashRoot = join(tmp, 'native-crash');
writeFileSync(join(crashRoot, 'bin/fm-watch-arm.sh'), `#!/usr/bin/env bash
set -eu
printf '%s\\n' "\${BASHPID:-$$}" > "$FM_HOME/state/arm-pid"
bash -c 'trap "" TERM; echo "\${BASHPID:-$$}" > "$FM_HOME/state/descendant-pid"; while :; do sleep 1; done' &
trap 'rm -f "$FM_HOME/state/ready"; exit 0' TERM INT
touch "$FM_HOME/state/ready"
echo 'watcher: started pid=fixture (beacon fresh)'
while :; do sleep 0.05; done
`, {mode: 0o700});
const owner = spawn(process.execPath, ['--input-type=module', '-e', `
  const {apply} = await import(${JSON.stringify(pathToFileURL(join(root, '.dsh/fm-primary.mjs')).href)});
  const handlers = new Map();
  apply({on: (event, fn) => handlers.set(event, fn), effect() {}}, ${JSON.stringify({root: crashRoot, home: crash.home})});
  await handlers.get('agent/created')({agent: {id: 'crash', session: {header: {cwd: ${JSON.stringify(crash.home)}}}, inject() {}, followup() {}}});
  setInterval(() => {}, 1000);
`], {stdio: 'ignore'});
const ownerExit = new Promise(resolve => owner.once('exit', resolve));
const gone = pid => {try {process.kill(pid, 0); return false;} catch (error) {if (error.code === 'ESRCH') return true; throw error;}};
let ownedPids = [];
try {
  await until(() => existsSync(join(crash.home, 'state/ready')) && existsSync(join(crash.home, 'state/descendant-pid')));
  ownedPids = ['arm-pid', 'descendant-pid'].map(file => Number(readFileSync(join(crash.home, 'state', file), 'utf8').trim()));
  assert(ownedPids.every(pid => !gone(pid)), 'both owned processes must be alive before the native crash');
  owner.kill('SIGKILL');
  await ownerExit;
  await until(() => ownedPids.every(gone));
} finally {
  owner.kill('SIGKILL');
  for (const pid of ownedPids) {try {process.kill(pid, 'SIGKILL');} catch {}}
  crash.stop();
}
console.log('ok - DSH primary enters its digest ahead of the brief in the first step, reports startup failure there, bounds guard follow-ups, preserves wake acknowledgement, excludes children, and retires watcher descendants on disposal and native SIGKILL');
JS
