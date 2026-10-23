// Native Cordis primary adapter. Reuses the shared startup, watcher, ownership
// and turn-end predicates; no external daemon or second supervision model.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';

export const name = 'firstmate-primary';
const instances = new Map();
const message = text => Object.freeze({id: randomUUID(), role: 'user',
  source: Object.freeze({kind: 'user'}),
  content: Object.freeze([Object.freeze({type: 'text', text})])});
const aborted = signal => new Promise(accept => {
  if (signal.aborted) accept();
  else signal.addEventListener('abort', accept, {once: true});
});

export function apply(ctx, config) {
  const root = resolve(config.root);
  const home = resolve(config.home);
  const state = join(home, 'state');
  // Every native tool call must inherit this primary's home, never the
  // launching parent's home (especially for secondmates).
  Object.assign(process.env, {FM_HOME: home, FM_ROOT_OVERRIDE: home,
    FM_STATE_OVERRIDE: state, FM_CONFIG_OVERRIDE: join(home, 'config'),
    FM_DATA_OVERRIDE: join(home, 'data'), FM_PROJECTS_OVERRIDE: join(home, 'projects')});
  const env = {...process.env};
  let disposed = false;
  let agent;
  let arm;
  let checking = false;
  let checkAgain = false;
  let failedArm = false;
  let guardNudged = false;
  let started = false;
  let leading;
  let launchInput = false;
  let holding;
  let holdingIds;
  let generation = 0;
  const ownMessages = new Set();
  const wakeMessages = new Set();
  const pendingRows = new Set();
  let wakeConsumed = false;
  const rowKeys = text => text.trim().split('\n').filter(Boolean).map(line => line.split('\t').slice(0, 2).join('\t'));
  const children = new Set();
  const previous = instances.get(home);
  previous?.();
  mkdirSync(state, {recursive: true});
  const events = join(state, '.dsh-primary-events.jsonl');
  const log = (event, fields = {}) => {
    appendFileSync(events, JSON.stringify({at: Date.now(), pid: process.pid, event, ...fields}) + '\n');
    const rows = readFileSync(events, 'utf8').split('\n').filter(Boolean);
    if (rows.length > 600) {
      const temporary = `${events}.tmp.${process.pid}`;
      writeFileSync(temporary, rows.slice(-400).join('\n') + '\n');
      renameSync(temporary, events);
    }
  };
  const command = (script, args = [], input = '') => new Promise((accept, reject) => {
    const child = spawn('nice', ['-n', '20', 'bash', join(root, 'bin', script), ...args],
      {cwd: home, env, stdio: ['pipe', 'pipe', 'pipe']});
    children.add(child);
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => { children.delete(child); accept({code, stdout, stderr}); });
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
  const send = (text, kind) => {
    if (disposed || !agent) return;
    const input = message(text);
    ownMessages.add(input.id);
    if (kind === 'watcher') wakeMessages.add(input.id);
    try {
      agent.followup(input);
      log('followup', {kind, id: input.id});
    } catch (error) {
      ownMessages.delete(input.id);
      throw error;
    }
  };
  const failed = error => `Firstmate DSH primary supervision failed: ${String(error)}. Run bin/fm-wake-drain.sh first and follow the emitted recovery protocol.`;
  const failure = error => {
    log('error', {detail: String(error)});
    if (!guardNudged) {
      guardNudged = true;
      send(failed(error), 'guard');
    }
  };
  const guard = async () => {
    const result = await command('fm-turnend-guard.sh', [], '{}');
    log('turnend-guard', {code: result.code});
    if (result.code !== 0 && result.code !== 2) throw new Error(`turn-end check failed: ${result.stderr || result.stdout}`);
    return result;
  };
  const repair = async detail => {
    const result = await guard();
    if (result.code === 2 && !guardNudged) {
      guardNudged = true;
      send(`Firstmate supervision needs repair. ${detail}\n${result.stderr || result.stdout}\nRun bin/fm-wake-drain.sh first, then follow the emitted DSH supervision protocol.`, 'guard');
    }
  };
  const startArm = mode => {
    if (disposed || arm || failedArm) return;
    const child = spawn('nice', ['-n', '20', 'bash', '-c', '. "$1"; shift; fm_exec_owned "$@"',
      'fm-dsh-primary-watch', join(root, 'bin', 'fm-timeout-lib.sh'), env.FM_WATCHER_CLEANUP_LOCK_BOUND || '2',
      'bash', join(root, 'bin', mode === 'host' ? 'fm-supervision-host.sh' : 'fm-watch-arm.sh'), ...(mode === 'host' ? ['park'] : [])],
      {cwd: home, env: {...env, FM_EXEC_TIMED_OWNER_PID: String(process.pid)}, detached: true, stdio: ['ignore', 'pipe', 'pipe']});
    arm = child;
    let output = '';
    let readiness = false;
    const receive = chunk => {
      output += chunk;
      if (!readiness && /watcher: (?:started|attached)\b/.test(output)) {
        readiness = true;
        log('watcher-ready', {arm: child.pid});
        void guard().catch(failure);
      }
    };
    child.stdout.on('data', receive);
    child.stderr.on('data', receive);
    child.on('error', error => { log('arm-error', {detail: String(error)}); });
    child.on('close', async code => {
      if (arm !== child || disposed) return;
      arm = undefined;
      log('watcher-close', {code});
      try {
        if (code !== 0 || /watcher: FAILED/.test(output)) {
          failedArm = true;
          await repair(output);
          return;
        }
        // Read-only, sequence-preserving queue query. Never present or ack on
        // the model's behalf, and never replay a stale close's headline.
        const queued = await command('fm-wake-drain.sh', ['--queued']);
        if (queued.code !== 0) throw new Error(`wake queue unreadable: ${queued.stderr || queued.stdout}`);
        const keys = rowKeys(queued.stdout);
        const fresh = keys.filter(key => !pendingRows.has(key));
        const notes = output.split('\n').filter(line => line.startsWith('supervision-host:')).join('\n');
        if (fresh.length || notes) {
          for (const key of keys) pendingRows.add(key);
          guardNudged = false;
          wakeConsumed = false;
          log('wake-delivery', {rows: fresh});
          send(`Firstmate watcher notification: durable work may be waiting. Run bin/fm-wake-drain.sh first, handle every presented item, then run its exact WAKE_ACK_REQUIRED command. Follow the emitted DSH protocol.\n${notes}`, 'watcher');
        } else if (!pendingRows.size) {
          await ensure();
        }
      } catch (error) { failure(error); }
    });
  };
  async function ensure() {
    if (disposed || !agent) return;
    if (checking) { checkAgain = true; return; }
    checking = true;
    try {
      const inspect = await command('fm-dsh-primary.sh', ['inspect', home]);
      if (inspect.code === 3 || inspect.code === 4) {
        log('read-only', {code: inspect.code});
        return;
      }
      if (inspect.code !== 0) throw new Error(`primary ownership check failed: ${inspect.stderr || inspect.stdout}`);
      const verdict = inspect.stdout.trim();
      if (!['idle', 'watch', 'host'].includes(verdict)) throw new Error(`unrecognized primary inspection: ${verdict}`);
      if (pendingRows.size) {
        const queued = await command('fm-wake-drain.sh', ['--queued']);
        if (queued.code !== 0) throw new Error(`wake queue unreadable: ${queued.stderr || queued.stdout}`);
        const present = new Set(rowKeys(queued.stdout));
        for (const key of pendingRows) if (!present.has(key)) pendingRows.delete(key);
        if (pendingRows.size) {
          if (wakeConsumed) await repair('The delivered wake still needs its generation-bound acknowledgement.');
          return;
        }
        wakeConsumed = false;
      }
      await guard();
      if (verdict !== 'idle') startArm(verdict);
    } finally {
      checking = false;
      if (checkAgain) { checkAgain = false; void ensure().catch(failure); }
    }
  }
  const stop = () => {
    if (disposed) return;
    disposed = true;
    if (arm?.pid) {
      // This adapter created this private process group. Never signal a
      // watcher or endpoint discovered by name or belonging to another home.
      try { process.kill(-arm.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') log('cleanup-error', {detail: String(error)}); }
    }
    arm = undefined;
    for (const child of children) child.kill('SIGTERM');
    if (instances.get(home) === stop) instances.delete(home);
    log('disposed');
  };
  instances.set(home, stop);
  ctx.effect(() => stop);
  ctx.on('agent/created', async ({agent: created}) => {
    const header = created.session.header;
    if (disposed || agent === created || typeof header.cwd !== 'string'
      || resolve(header.cwd) !== home || header.origin === 'subagent' || (header.delegationDepth ?? 0) > 0) return;
    const activation = ++generation;
    agent = created;
    ownMessages.clear();
    wakeMessages.clear();
    guardNudged = false;
    failedArm = false;
    wakeConsumed = pendingRows.size > 0;
    const source = started ? 'clear' : 'startup';
    // The installed DSH awaits this callback before it publishes the session
    // and submits the positional opening prompt; a runtime that does not is
    // covered too: the first pre-step of a fresh process holds until this
    // resolves, so the digest enters that step ahead of the opening prompt.
    let lead;
    leading = undefined;
    holding = undefined;
    holdingIds = undefined;
    launchInput = source === 'startup';
    if (launchInput) leading = new Promise(accept => { lead = input => accept(input ? [input] : []); });
    const own = text => {
      const input = message(text);
      ownMessages.add(input.id);
      return input;
    };
    try {
      log('startup', {session: created.id});
      const result = await command('fm-sessionstart-run.sh', ['--source', source]);
      if (disposed || activation !== generation) return lead?.();
      started = true;
      if (result.code !== 0) throw new Error(`DSH primary session start failed: ${result.stderr || result.stdout}`);
      if (!result.stdout.trim()) throw new Error('DSH primary session start supplied no digest; primary scope or startup transport is missing');
      if (lead) {
        lead(own(result.stdout));
        lead = undefined;
      } else {
        agent.inject(own(result.stdout));
      }
      await ensure();
    } catch (error) {
      if (disposed || activation !== generation) return lead?.();
      if (!lead) return failure(error);
      log('error', {detail: String(error)});
      guardNudged = true;
      lead(own(failed(error)));
    }
  });
  // The held step's claimed launch input is this adapter's own, so it never
  // resets the failure budget. The downstream pre-step runs first: DSH's
  // checkpoint there makes the open turn durable before the digest wait.
  // DSH drops a cancelled or failed step's claimed batch without restoring it
  // (a non-user cancel also clears the inbox), so the digest and that batch
  // stay held until one of them is logged; a turn that ends first hands them
  // to the next step.
  ctx.on('agent/pre-step', async (payload, next) => {
    if (payload.agent !== agent || !leading) return next();
    const pending = leading;
    leading = undefined;
    if (launchInput) for (const input of payload.messages) ownMessages.add(input.id);
    launchInput = false;
    const ids = new Set(payload.messages.map(input => input.id));
    holding = pending.then(held => [...held, ...payload.messages]);
    holdingIds = ids;
    void pending.then(held => { for (const input of held) ids.add(input.id); });
    const decision = await next();
    if (decision.kind !== 'enter') {
      holding = undefined;
      holdingIds = undefined;
      leading = pending;
      return decision;
    }
    const first = await Promise.race([pending, aborted(payload.signal)]);
    if (payload.signal.aborted) return decision;
    return {kind: 'enter', messages: [...first, ...decision.messages]};
  });
  ctx.on('session/event', (session, event) => {
    if (session !== agent?.session) return;
    if (event.type === 'user/message') {
      const id = event.data?.id;
      if (holdingIds?.has(id)) { holding = undefined; holdingIds = undefined; }
      if (wakeMessages.delete(id)) wakeConsumed = true;
      // DSH also logs its own runtime context as user/message; only real
      // user input reopens the bounded follow-up budget.
      if (!ownMessages.delete(id) && event.data?.source?.kind === 'user') { guardNudged = false; failedArm = false; }
    }
    if (event.type === 'turn/end') {
      if (holding) { leading = holding; holding = undefined; holdingIds = undefined; }
      failedArm = false;
      log('turn-end', {seq: event.seq});
      queueMicrotask(() => { void ensure().catch(failure); });
    }
  });
  ctx.on('agent/disposed', ({agent: removed}) => {
    if (removed !== agent) return;
    agent = undefined;
  });
}
