#!/usr/bin/env bash
# Portable native-plugin lifecycle edges, including supervision-host mode
# through the real inspect verdict against a stub host; vendor callbacks are
# separately exercised by fm-dsh-primary-live-e2e.test.sh against real dsh-tui.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
node --input-type=module - "$ROOT" "$TMP" <<'JS'
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync, readdirSync, rmSync} from 'node:fs';
import {spawn, execFileSync} from 'node:child_process';
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
function setup(name, {failArm = false, failStart = false, slowStart = false} = {}) {
  const dir = join(tmp, name);
  const bin = join(dir, 'bin');
  const home = join(dir, 'home');
  mkdirSync(bin, {recursive: true});
  mkdirSync(join(home, 'state'), {recursive: true});
  symlinkSync(join(root, 'bin/fm-timeout-lib.sh'), join(bin, 'fm-timeout-lib.sh'));
  const executable = (name, body) => writeFileSync(join(bin, name), '#!/usr/bin/env bash\nset -eu\n' + body + '\n', {mode: 0o700});
  executable('fm-sessionstart-run.sh', failStart ? "echo 'fixture startup fault' >&2; exit 1" : `${slowStart ? 'sleep 1; ' : ''}printf 'SESSION START - fixture\\n'`);
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
  // DSH's own step: claim the whole inbox (announcing each claim), assemble
  // the system prompt, run the waterfall, then drop the batch if the turn was
  // cancelled meanwhile.
  const run = async (inbox, signal, owner = agent, downstream = () => {}, assemble = async () => {}) => {
    const claimed = inbox.splice(0);
    for (const message of claimed) handlers.get('agent/inbox/claimed')?.({agent: owner, message, turn: 1});
    await assemble();
    signal.throwIfAborted();
    const decision = await handlers.get('agent/pre-step')({agent: owner, messages: claimed, turn: 1, step: 1, signal},
      async () => { downstream(); return {kind: 'enter', messages: claimed}; });
    signal.throwIfAborted();
    return decision.kind === 'enter' ? decision.messages : [];
  };
  const end = () => handlers.get('session/event')(agent.session, {type: 'turn/end', seq: 1});
  const consume = input => handlers.get('session/event')(agent.session, {type: 'user/message', data: input});
  const stop = () => {for (const fn of stops) fn();};
  return {home, agent, followups, injected, emit, step, run, end, consume, stop};
}
// DSH logs its own request context as user/message events with these source
// kinds, beside the real user input.
const contextKinds = ['agent-instructions', 'runtime-context', 'skill-catalog', 'time-context'];
const context = label => contextKinds.map(kind => ({id: `${label}-${kind}`, role: 'user', source: {kind}, content: [{type: 'text', text: kind}]}));
// A runtime may submit the positional brief before agent/created settles.
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
// A non-user cancel of the held first step drops its claimed batch and clears
// the inbox, as DSH does. The digest and the claimed brief must lead the next
// step once.
const cancelled = setup('startup-cancel', {slowStart: true});
const cancelledStart = cancelled.emit('agent/created', {agent: cancelled.agent});
const inbox = [brief];
const interrupt = new AbortController();
const interrupted = cancelled.run(inbox, interrupt.signal);
await delay(100);
interrupt.abort();
inbox.length = 0;
await assert.rejects(interrupted, {name: 'AbortError'}, 'the cancelled step must enter nothing');
cancelled.end();
await cancelledStart;
const typed = {id: 'typed', role: 'user', source: {kind: 'user'}, content: [{type: 'text', text: 'continue'}]};
inbox.push(typed);
const resumed = await cancelled.run(inbox, new AbortController().signal);
assert.deepEqual(resumed.map(input => input.content[0].text), ['SESSION START - fixture\n', 'opening brief', 'continue'], 'the next step must carry the digest, then the brief, then new input');
assert.equal(new Set(resumed.map(input => input.id)).size, resumed.length, 'nothing may be delivered twice');
for (const input of resumed) cancelled.consume(input);
cancelled.end();
inbox.push(typed);
assert.deepEqual(await cancelled.run(inbox, new AbortController().signal), [typed], 'the held messages must be delivered only once');
cancelled.stop();
// The installed DSH awaits agent/created, so the digest is ready before the
// first step; the real cancel windows are later. DSH drops a claimed batch
// without restoring it when the step is cancelled or fails while assembling
// the system prompt (before this waterfall), when a downstream pre-step throws
// on abort, or when it aborts after the waterfall returns but before the step
// starts.
for (const window of ['assemble-abort', 'assemble-throw', 'downstream-throw', 'aborted-before-step-start']) {
  const held = setup(`startup-${window}`);
  await held.emit('agent/created', {agent: held.agent});
  const queue = [brief];
  const cancel = new AbortController();
  if (window === 'assemble-abort') {
    await assert.rejects(held.run(queue, cancel.signal, held.agent, undefined, async () => { cancel.abort(); }), {name: 'AbortError'});
  } else if (window === 'assemble-throw') {
    await assert.rejects(held.run(queue, cancel.signal, held.agent, undefined, async () => { throw new Error('assembly failed'); }), /assembly failed/);
  } else if (window === 'downstream-throw') {
    await assert.rejects(held.run(queue, cancel.signal, held.agent, () => { cancel.abort(); cancel.signal.throwIfAborted(); }), {name: 'AbortError'});
  } else {
    const entered = await held.step(queue.splice(0));
    assert.equal(entered.messages.length, 2, 'the waterfall must offer the digest and the brief');
  }
  held.end();
  queue.push(typed);
  const next = await held.run(queue, new AbortController().signal);
  assert.deepEqual(next.map(input => input.content[0].text), ['SESSION START - fixture\n', 'opening brief', 'continue'], `${window}: the next step must restore the digest and the brief`);
  for (const input of next) held.consume(input);
  held.end();
  queue.push(typed);
  assert.deepEqual(await held.run(queue, new AbortController().signal), [typed], `${window}: restored messages must be delivered once`);
  held.stop();
}
// Escape cancels with keepInbox: input queued during the held step survives
// and enters after the held digest and brief.
const escaped = setup('startup-escape', {slowStart: true});
const escapedStart = escaped.emit('agent/created', {agent: escaped.agent});
const kept = [brief];
const escape = new AbortController();
// DSH's own checkpoint runs downstream in this waterfall; it must make the
// open turn durable while the digest is still held.
let checkpointed = false;
const escapedStep = escaped.run(kept, escape.signal, escaped.agent, () => { checkpointed = true; });
await delay(100);
assert.equal(checkpointed, true, 'the downstream checkpoint must run before the digest wait');
const early = {id: 'early', role: 'user', source: {kind: 'user'}, content: [{type: 'text', text: 'queued during the hold'}]};
kept.push(early);
escape.abort();
await assert.rejects(escapedStep, {name: 'AbortError'}, 'the escaped step must enter nothing');
escaped.end();
await escapedStart;
const afterEscape = await escaped.run(kept, new AbortController().signal);
assert.deepEqual(afterEscape.map(input => input.content[0].text), ['SESSION START - fixture\n', 'opening brief', 'queued during the hold'], 'the kept inbox must follow the held digest and brief');
assert.equal(new Set(afterEscape.map(input => input.id)).size, afterEscape.length, 'nothing may be delivered twice after Escape');
escaped.stop();
// A same-process session replacement must not inherit the old session's
// parked startup digest or launch brief.
const replaced = setup('startup-replaced', {slowStart: true});
const replacedStart = replaced.emit('agent/created', {agent: replaced.agent});
const replacedInbox = [brief];
const replacedCancel = new AbortController();
const replacedStep = replaced.run(replacedInbox, replacedCancel.signal);
await delay(100);
replacedCancel.abort();
replacedInbox.length = 0;
await assert.rejects(replacedStep, {name: 'AbortError'});
await replacedStart;
const fresh = {id: 'fresh', session: {header: {cwd: replaced.home}}, inject(value) {replaced.injected.push(value);}, followup(value) {replaced.followups.push(value);}};
await replaced.emit('agent/created', {agent: fresh});
assert.equal(replaced.injected.length, 1, 'the replacement session must receive its own clear digest');
replacedInbox.push(typed);
assert.deepEqual(await replaced.run(replacedInbox, new AbortController().signal, fresh), [typed], 'the replacement must not receive the old digest or brief');
replaced.stop();
const broken = setup('startup-failure', {failStart: true, failArm: true});
const brokenStart = broken.emit('agent/created', {agent: broken.agent});
const failedStep = await broken.step([brief]);
assert.match(failedStep.messages[0].content[0].text, /session start failed: fixture startup fault/, 'a failed startup must report the fault in the first step');
assert.equal(failedStep.messages[1], brief, 'a failed startup must keep the brief');
await brokenStart;
assert.equal(broken.followups.length, 0, 'a failed startup must not queue another turn');
assert.match(readFileSync(join(broken.home, 'state/.dsh-primary-events.jsonl'), 'utf8'), /"event":"error"/, 'a failed startup must be recorded');
// DSH logs each entered message. The launch brief is not new external input,
// so it must not reopen the failure budget the startup notice used.
for (const input of [...failedStep.messages, ...context('failed-start')]) broken.consume(input);
broken.end();
await delay(1000);
assert.equal(broken.followups.length, 0, 'the launch brief and DSH context must not reset the startup failure budget');
broken.consume({id: 'external-after-failure', role: 'user', source: {kind: 'user'}, content: [{type: 'text', text: 'Retry.'}]});
broken.end();
await until(() => broken.followups.length === 1);
broken.stop();
const fail = setup('failed-arm', {failArm: true});
await fail.emit('agent/created', {agent: fail.agent});
await until(() => fail.followups.length === 1);
// DSH commits UserMessage directly as event.data, including synthetic input.
// Consuming the forced continuation must not classify it as a new human turn.
fail.consume(fail.followups[0]);
for (const input of context('failed-arm')) fail.consume(input);
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
for (const input of context('wake')) wake.consume(input);
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
// Supervision-host mode. The owner is a separate node process whose argv is
// `node <dir>/dsh-tui`, the shape bin/fm-dsh-lib.sh recognizes, so the real
// bin/fm-dsh-primary.sh inspect proves this session owns the home's lock and
// decides host or watch from the real config gate. Only the arm, the host, the
// session start, the turn-end guard and the queue read are stubs.
const stripped = ['CLAUDECODE', 'PI_CODING_AGENT', 'GROK_AGENT', 'FM_PI_HARNESS', 'FM_OMP_HARNESS', 'GEMINI_CLI',
  'CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'ATLASSIAN_AGENT_TYPE', 'ROVODEV_CLI', 'FM_TEST_SEAM', 'FM_TEST_HARNESS'];
function hostFixture(name, {config = [], lock = 'self'} = {}) {
  const dir = join(tmp, name);
  const bin = join(dir, 'bin');
  const home = join(dir, 'home');
  mkdirSync(bin, {recursive: true});
  for (const entry of readdirSync(join(root, 'bin'))) symlinkSync(join(root, 'bin', entry), join(bin, entry));
  const stub = (file, body) => {
    rmSync(join(bin, file));
    writeFileSync(join(bin, file), '#!/usr/bin/env bash\nset -eu\n' + body + '\n', {mode: 0o700});
  };
  stub('fm-sessionstart-run.sh', "printf 'SESSION START - fixture\\n'");
  stub('fm-turnend-guard.sh', 'exit 0');
  stub('fm-wake-drain.sh', ': > "$FM_HOME/state/queue-read"');
  stub('fm-watch-arm.sh', `
    printf 'arm pid=%s\\n' "\${BASHPID:-$$}" >> "$FM_HOME/state/runs"
    trap 'exit 0' TERM INT
    echo 'watcher: started pid=fixture (beacon fresh)'
    while :; do sleep 0.05; done
  `);
  stub('fm-supervision-host.sh', `
    . "$(dirname "$0")/fm-supervision-engine-lib.sh"
    printf 'host pid=%s args=%s home=%s cwd=%s primary=%s\\n' "\${BASHPID:-$$}" "$*" "$FM_HOME" "$(pwd -P)" "\${FM_SUPERVISION_HOST_PRIMARY:-$(fm_supervision_host_primary)}" >> "$FM_HOME/state/runs"
    trap 'exit 0' TERM INT
    echo 'watcher: started pid=fixture (beacon fresh)'
    while [ ! -f "$FM_HOME/state/close" ]; do sleep 0.05; done
    rm "$FM_HOME/state/close"
    echo 'check: fixture wake'
    echo 'supervision-host: outcome 1 for demo [captain]: fixture'
  `);
  mkdirSync(join(home, 'bin'), {recursive: true});
  mkdirSync(join(home, 'state'), {recursive: true});
  mkdirSync(join(home, 'config'), {recursive: true});
  execFileSync('git', ['init', '-q', home]);
  writeFileSync(join(home, 'AGENTS.md'), 'fixture\n');
  // An in-flight task is what makes this home need supervision at all.
  writeFileSync(join(home, 'state/demo.meta'), 'fixture\n');
  for (const file of config) writeFileSync(join(home, 'config', file), '');
  const launcher = join(dir, 'dsh-tui');
  writeFileSync(launcher, `(async () => {
    const {appendFileSync, existsSync, rmSync, writeFileSync} = require('node:fs');
    const {apply} = await import(${JSON.stringify(pathToFileURL(join(root, '.dsh/fm-primary.mjs')).href)});
    const home = ${JSON.stringify(home)};
    writeFileSync(home + '/state/.lock', ${lock === 'self' ? 'String(process.pid)' : JSON.stringify(lock)});
    const handlers = new Map();
    const stops = [];
    apply({on: (event, fn) => handlers.set(event, fn), effect: fn => stops.push(fn())}, ${JSON.stringify({root: dir, home})});
    const agent = {id: 'host', session: {header: {cwd: home}}, inject() {},
      followup: input => appendFileSync(home + '/state/followups', JSON.stringify(input.content[0].text) + '\\n')};
    process.on('SIGTERM', () => { for (const stop of stops) stop(); process.exit(0); });
    setInterval(() => {
      if (existsSync(home + '/state/dispose')) { rmSync(home + '/state/dispose'); for (const stop of stops) stop(); }
      if (!existsSync(home + '/state/turn-end')) return;
      rmSync(home + '/state/turn-end');
      handlers.get('session/event')(agent.session, {type: 'turn/end', seq: 1});
    }, 50);
    await handlers.get('agent/created')({agent});
  })();
`);
  const env = {...process.env, FM_DSH_HARNESS: 'dsh'};
  for (const key of stripped) delete env[key];
  const child = spawn(process.execPath, [launcher], {env, stdio: 'ignore'});
  const exited = new Promise(resolve => child.once('exit', resolve));
  const runs = () => existsSync(join(home, 'state/runs')) ? readFileSync(join(home, 'state/runs'), 'utf8').split('\n').filter(Boolean) : [];
  const followups = () => existsSync(join(home, 'state/followups')) ? readFileSync(join(home, 'state/followups'), 'utf8').split('\n').filter(Boolean).map(row => JSON.parse(row)) : [];
  const events = () => existsSync(join(home, 'state/.dsh-primary-events.jsonl')) ? readFileSync(join(home, 'state/.dsh-primary-events.jsonl'), 'utf8') : '';
  const pidOf = row => Number(row.replace(/^\w+ pid=([0-9]+).*/, '$1'));
  const retire = async () => { child.kill('SIGTERM'); await exited; };
  return {home: execFileSync('pwd', ['-P'], {cwd: home, encoding: 'utf8'}).trim(), runs, followups, events, pidOf, retire, child};
}
const alive = pid => {try {process.kill(pid, 0); return true;} catch (error) {if (error.code === 'ESRCH') return false; throw error;}};
// An opted-in home parks the supervision host in the arm's place, scoped to
// this home, and relays the host's own lines when it closes.
const hosted = hostFixture('host-mode', {config: ['supervision-host']});
let hostPids = [];
try {
  await until(() => hosted.runs().length === 1);
  const [parked] = hosted.runs();
  assert.match(parked, /^host /, `an opted-in home must park the supervision host, not the plain arm: ${parked}`);
  assert.match(parked, / args=park home=/, `the host must run as a plain park: ${parked}`);
  assert.ok(parked.includes(` home=${join(tmp, 'host-mode', 'home')} cwd=${hosted.home} `), `the host must be scoped to the primary's home: ${parked}`);
  assert.match(parked, / primary=dsh$/, `the host must resolve this primary as dsh: ${parked}`);
  hostPids.push(hosted.pidOf(parked));
  writeFileSync(join(hosted.home, 'state/close'), '');
  await until(() => hosted.followups().length === 1);
  const [relay] = hosted.followups();
  assert.match(relay, /Firstmate watcher notification/, `a host close must reach the session as a watcher notification: ${relay}`);
  assert.ok(relay.includes('supervision-host: outcome 1 for demo [captain]: fixture'), `the notification must carry the host line: ${relay}`);
  assert.ok(!relay.includes('check: fixture wake'), `the notification must not replay the close headline: ${relay}`);
  assert.equal(alive(hostPids[0]), false, 'the closed host must have exited');
  // The next turn end parks a fresh host. Plugin disposal retires it while
  // the owner process lives on; owner exit alone would hide a disposal leak
  // behind the owner-bound watchdog the native-crash case covers.
  writeFileSync(join(hosted.home, 'state/turn-end'), '');
  await until(() => hosted.runs().length === 2);
  const reparked = hosted.runs()[1];
  assert.match(reparked, /^host .* args=park home=/, `a turn end must park the host again: ${reparked}`);
  hostPids.push(hosted.pidOf(reparked));
  assert.equal(alive(hostPids[1]), true, 'the re-parked host must be running before disposal');
  writeFileSync(join(hosted.home, 'state/dispose'), '');
  await until(() => !alive(hostPids[1]));
  assert.equal(hosted.child.exitCode, null, 'disposal, not owner exit, must retire the host');
  await hosted.retire();
  assert.equal(hosted.runs().filter(row => row.startsWith('arm ')).length, 0, 'a host home must never park the plain arm');
} finally {
  hosted.child.kill('SIGKILL');
  for (const pid of hostPids) {try {process.kill(pid, 'SIGKILL');} catch {}}
}
// The attended boundary: with no supervision-host file, or with the opt-out
// beside it, the same owner parks only the plain arm.
for (const [label, config] of [['none', []], ['off', ['supervision-host', 'supervision-host-off']]]) {
  const plain = hostFixture(`host-gate-${label}`, {config});
  let armPid;
  try {
    await until(() => plain.runs().length === 1);
    const [row] = plain.runs();
    assert.match(row, /^arm /, `${label}: a home that does not run the host must park the plain arm: ${row}`);
    armPid = plain.pidOf(row);
    await plain.retire();
    await until(() => !alive(armPid));
    assert.equal(plain.runs().length, 1, `${label}: the plain home must never start the host`);
  } finally {
    plain.child.kill('SIGKILL');
    if (armPid) {try {process.kill(armPid, 'SIGKILL');} catch {}}
  }
}
// A home whose session lock this owner does not hold stays read-only: the
// inspect refuses ownership and neither the host nor the arm parks.
const foreign = hostFixture('host-foreign-lock', {config: ['supervision-host'], lock: '1'});
try {
  await until(() => /"event":"read-only"/.test(foreign.events()));
  assert.deepEqual(foreign.runs(), [], 'a home this session does not own must not park the host');
  await foreign.retire();
} finally {
  foreign.child.kill('SIGKILL');
}
console.log('ok - DSH primary enters its digest ahead of the brief in the first step, reports startup failure there, bounds guard follow-ups, preserves wake acknowledgement, excludes children, retires watcher descendants on disposal and native SIGKILL, and parks the supervision host only on an opted-in home it owns');
JS
