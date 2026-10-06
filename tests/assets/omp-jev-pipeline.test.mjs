import test from "node:test";
import assert from "node:assert/strict";
import { installPipeline } from "../../extensions/omp-jev-pipeline.mjs";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const handlers = new Map();
  const timers = new Map();
  const intervals = new Map();
  const records = [];
  const evaluations = [];
  const compactions = [];
  let clock = 1000, serial = 0;
  const config = { version: 1, mode: "auto", autoAcknowledged: true, minContextTokens: 40000 };
  const ctx = {
    idle: false, pending: false, leaf: "leaf-a", session: "session-a",
    usage: { tokens: 50000, contextWindow: 272000 },
    model: { provider: "fixture", id: "model-a" }, cwd: "/synthetic",
    sessionManager: { getSessionId: () => ctx.session, getLeafId: () => ctx.leaf, getBranch: () => [] },
    ui: { getEditorText: () => "" },
    getContextUsage: () => ctx.usage, isIdle: () => ctx.idle, hasPendingMessages: () => ctx.pending,
    setTimeout: callback => { timers.set(++serial, callback); return serial; },
    setInterval: callback => { intervals.set(++serial, callback); return serial; },
    clearTimer: id => { timers.delete(id); intervals.delete(id); },
    compact: async options => {
      compactions.push(options);
      emit("session_before_compact");
      emit("session_compact", { compactionEntry: { tokensBefore: 50000, tokensAfter: 20000, method: "remote" }, fromExtension: false });
      options.onComplete();
    },
  };
  const adviser = {
    resolveTypesafeApiKey: () => ({ value: "synthetic-key" }),
    typesafeEndpoint: () => "https://api.typesafe.ai/v1/systemone",
    parseProfile: () => undefined,
    lastResponse: () => ({ message: { stopReason: "stop" } }),
    snapshot: () => ({ state: {}, conversationTokens: 50000, autoCoverage: true }),
    qualifies: result => result.finished,
    judge: (_state, _key, signal) => {
      const call = deferred();
      evaluations.push({ ...call, signal });
      return call.promise;
    },
  };
  installPipeline({ on: (name, handler) => handlers.set(name, handler) }, adviser, {
    store: { read: () => ({ ...config }) }, now: () => clock,
    record: row => records.push(row),
  });
  function emit(name, fields = {}) {
    return handlers.get(name)?.({ type: name, signal: new AbortController().signal,
      messages: [{ role: "assistant", stopReason: "stop" }], ...fields }, ctx);
  }
  async function fireTimer() {
    const first = timers.entries().next().value;
    if (!first) return;
    timers.delete(first[0]);
    return first[1]();
  }
  async function judge(finished) {
    ctx.idle = true;
    emit("agent_end", { willContinue: false });
    const work = fireTimer();
    const call = evaluations.at(-1);
    assert.ok(call, "a genuine idle checkpoint is judged");
    call.resolve({ finished, model: "jev-1.13.0", inputTokens: 1000, outputTokens: 20 });
    await work;
  }
  function automatic(reason) { emit("auto_compaction_start", { reason }); return emit("session_before_compact"); }
  return { ctx, config, adviser, records, timers, evaluations, compactions, emit, fireTimer, judge, automatic,
    intervals, tickGuard: () => { for (const callback of [...intervals.values()]) callback(); },
    advance: ms => { clock += ms; } };
}

test("terminal event defers to genuine idle and continuation never judges", async () => {
  const f = fixture();
  f.emit("agent_end", { willContinue: true });
  assert.equal(f.timers.size, 0);
  f.emit("agent_end", { willContinue: false });
  await f.fireTimer();
  assert.equal(f.evaluations.length, 0);
  f.ctx.idle = true;
  const work = f.fireTimer();
  f.evaluations[0].resolve({ finished: true, model: "jev-1.13.0", inputTokens: 100, outputTokens: 10 });
  await work;
  assert.equal(f.compactions.length, 1);
  assert.equal(f.records.find(row => row.event === "native-persisted").fromExtension, false);
});

test("automatic unfinished checkpoints veto once; manual and overflow are immediate", async () => {
  for (const reason of ["idle", "threshold"]) {
    const f = fixture(); await f.judge(false);
    assert.deepEqual(f.automatic(reason), { cancel: true });
    assert.equal(f.automatic(reason), undefined, "a second native attempt can recover");
  }
  for (const reason of ["overflow", "incomplete", undefined]) {
    const f = fixture(); await f.judge(false);
    assert.equal(reason ? f.automatic(reason) : f.emit("session_before_compact"), undefined);
  }
});

test("healthy timing policy defers busy work once and never near the context limit", async () => {
  const f = fixture(); await f.judge(false);
  f.emit("input"); f.emit("agent_start"); f.emit("turn_start");
  f.ctx.idle = false; f.ctx.leaf = "leaf-b";
  assert.deepEqual(f.automatic("threshold"), { cancel: true });
  f.emit("turn_start");
  assert.equal(f.automatic("threshold"), undefined, "tool rounds cannot extend the deferral");
  f.emit("agent_start"); f.ctx.usage.tokens = 260000;
  assert.equal(f.automatic("threshold"), undefined);
  f.ctx.usage.tokens = 50000; f.advance(60001);
  assert.equal(f.automatic("threshold"), undefined, "expired availability never cancels native recovery");
});

test("a failed terminal turn cannot borrow an older persisted successful answer", async () => {
  const f = fixture(); f.ctx.idle = true;
  f.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error" }] });
  await f.fireTimer();
  assert.equal(f.evaluations.length, 0);
  assert.equal(f.compactions.length, 0);
  assert.equal(f.automatic("overflow"), undefined);
});

test("each input, turn, navigation, compaction and shutdown boundary aborts stale judgment", async () => {
  for (const event of ["input", "before_agent_start", "agent_start", "turn_start", "session_start",
    "session_before_switch", "session_switch", "session_before_branch", "session_branch",
    "session_before_tree", "session_tree", "session_before_compact", "session_compact", "session_shutdown"]) {
    const f = fixture(); f.ctx.idle = true; f.emit("agent_end");
    const work = f.fireTimer(); const call = f.evaluations[0];
    f.emit(event, event === "session_compact"
      ? { compactionEntry: { tokensBefore: 50000, tokensAfter: 20000 }, fromExtension: false } : {});
    assert.equal(call.signal.aborted, true, event);
    call.resolve({ finished: true, model: "jev-1.13.0", inputTokens: 100, outputTokens: 5 });
    await work;
    assert.equal(f.compactions.length, 0, event);
  }
});

test("a native model change without a lifecycle hook cancels the pending request", async () => {
  const f = fixture(); f.ctx.idle = true; f.emit("agent_end");
  const work = f.fireTimer(); const call = f.evaluations[0];
  f.ctx.model.id = "model-b";
  f.tickGuard();
  assert.equal(call.signal.aborted, true);
  assert.equal(f.intervals.size, 0, "the request guard must retire after cancellation");
  call.resolve({ finished: true, model: "jev-1.13.0", inputTokens: 100, outputTokens: 5 });
  await work;
  assert.equal(f.compactions.length, 0);
});

test("silent identity changes and changed consent reject an otherwise qualifying result", async () => {
  for (const change of [f => { f.ctx.leaf = "other"; }, f => { f.ctx.session = "other"; },
    f => { f.ctx.model.id = "other"; }, f => { f.config.autoAcknowledged = false; },
    f => { f.ctx.pending = true; }, f => { f.ctx.idle = false; }]) {
    const f = fixture(); f.ctx.idle = true; f.emit("agent_end"); const work = f.fireTimer();
    change(f);
    f.evaluations[0].resolve({ finished: true, model: "jev-1.13.0", inputTokens: 100, outputTokens: 5 });
    await work;
    assert.equal(f.compactions.length, 0);
  }
});

test("unavailable Jev preserves native automatic, manual and overflow behavior", async () => {
  const f = fixture(); f.ctx.idle = true; f.emit("agent_end"); const work = f.fireTimer();
  f.evaluations[0].reject(new Error("synthetic timeout with secret text")); await work;
  for (const reason of ["threshold", "idle", "overflow", "incomplete"]) {
    assert.equal(f.automatic(reason), undefined);
    f.emit("auto_compaction_end");
  }
  assert.equal(f.emit("session_before_compact"), undefined);
  assert.equal(f.compactions.length, 0);
  assert.ok(!JSON.stringify(f.records).includes("secret text"));
});

test("missing consent or incomplete redacted coverage prevents eager compaction", async () => {
  for (const change of [f => { f.config.mode = "off"; }, f => { f.config.autoAcknowledged = false; },
    f => { f.adviser.snapshot = () => ({ conversationTokens: 50000, autoCoverage: false }); }]) {
    const f = fixture(); change(f); f.ctx.idle = true; f.emit("agent_end"); await f.fireTimer();
    assert.equal(f.evaluations.length, 0);
    assert.equal(f.compactions.length, 0);
    assert.equal(f.automatic("threshold"), undefined);
  }
});

test("snapshot scrubs escaped and nested saved-key JSON fields before any Jev request", {
  skip: !process.env.FM_JEV_ADVISER_DIR && "set FM_JEV_ADVISER_DIR to the dependency-complete adviser package root",
}, async () => {
  const source = resolve(process.env.FM_JEV_ADVISER_DIR);
  const { snapshot } = await import(pathToFileURL(join(source, "src/context.ts")).href);
  const directory = mkdtempSync(join(tmpdir(), "fm-jev-snapshot-"));
  const sessionFile = join(directory, "session.jsonl");
  writeFileSync(sessionFile, "");
  try {
    for (const text of [
      '{"namespace\\u002etypesafeApiKey":"SENTINEL_ESCAPED","safe":"preserved"}',
      '{"nested":{"typesafeApiKey":"SENTINEL_NESTED"},"safe":"preserved"}',
      '{"typesafeApiKey":"SENTINEL_PLAIN","safe":"preserved"}',
    ]) {
      const branch = [{ type: "message", id: "u1", parentId: null, timestamp: new Date(0).toISOString(),
        message: { role: "user", content: [{ type: "text", text }], timestamp: 0 } }];
      const view = snapshot({
        cwd: directory,
        sessionManager: { getBranch: () => branch, getSessionFile: () => sessionFile },
      }, [], "omp");
      const outgoing = JSON.stringify(view.state);
      assert.ok(!outgoing.includes("SENTINEL_"), "unknown saved-key values must never leave the snapshot");
      assert.ok(outgoing.includes("preserved"), "nonsecret settings retain their meaning");
      assert.equal(view.state.coverage.redacted, true);
      assert.equal(view.autoCoverage, false, "redacted context cannot authorize eager compaction");
    }
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
