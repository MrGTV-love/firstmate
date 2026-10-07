import test from "node:test";
import assert from "node:assert/strict";
import { installPipeline, completeCoverage } from "../../extensions/omp-jev-pipeline.mjs";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
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

function clippedView(messages, over = {}) {
  let remaining = 14000, recentTextTruncated = false;
  const recent = [];
  for (const m of messages.slice(-64).reverse()) {
    if (m.role !== "assistant" && m.role !== "toolResult") continue;
    const text = typeof m.content === "string" ? m.content
      : m.content.filter(c => c.type === "text").map(c => c.text).join("\n");
    const limit = Math.min(m.role === "toolResult" ? 512 : 8000, remaining);
    let retained = text;
    if (Buffer.byteLength(text) > limit) {
      recentTextTruncated = true;
      let prefix = "", bytes = 0;
      for (const char of text) {
        const size = Buffer.byteLength(char);
        if (bytes + size > (limit >= 3 ? limit - 3 : limit)) break;
        prefix += char; bytes += size;
      }
      retained = prefix + (limit >= 3 ? "..." : "");
    }
    remaining -= Buffer.byteLength(retained);
    recent.unshift({ role: m.role, text: retained,
      ...(m.role === "toolResult" ? { tool: m.toolName, error: m.isError } : {}) });
  }
  return { state: { userConstraints: [], recent, previousSummary: "", savedArtifacts: [],
    coverage: { omittedUserMessages: 0, olderMessagesOmitted: Math.max(0, messages.length - 64),
      recentTextTruncated, hasImages: false,
      redacted: false, unknownContext: false, transcriptRecoverable: true, ...over } },
  conversationTokens: 50000, checkpointKey: "k", autoCoverage: !recentTextTruncated };
}
const reading = (id, text, extra = {}) => [
  { role: "assistant", content: [{ type: "toolCall", id, name: "read", arguments: { path: "source.txt" } }] },
  { role: "toolResult", toolCallId: id, toolName: "read", isError: false, content: [{ type: "text", text }], ...extra },
];
const longRead = n => Array.from({ length: n }, (_, i) => `ledger row ${i} ${"x".repeat(80)}`).join("\n");
const finalAnswer = { role: "assistant", content: [{ type: "text", text: "DISCOVERY_COMPLETE" }], stopReason: "stop" };
function transcript(...parts) { return [{ role: "user", content: "Read everything." }, ...parts.flat(), finalAnswer]; }
function withHost(f, messages, over, wrap) {
  Object.assign(f.adviser, {
    RECENT_TAIL_MESSAGES: 64, redact: text => ({ text, redacted: false }),
    scrubKnownSecrets: text => ({ text, redacted: false }),
    buildSessionContext: () => ({ messages }),
    snapshot: () => { const view = clippedView(messages, over); return wrap ? wrap(view) : view; },
  });
  f.ctx.sessionManager.getBranch = () => [];
}
async function checkpoint(f) {
  f.ctx.idle = true; f.emit("agent_end", { willContinue: false });
  const work = f.fireTimer();
  return work;
}

test("a long tool-result transcript is attested complete, judged, and then natively compacted", async () => {
  const f = fixture();
  const bodies = [longRead(300), longRead(310), longRead(20)];
  const messages = transcript(...bodies.map((b, i) => reading(`c${i}`, b)));
  let sent;
  withHost(f, messages);
  f.adviser.judge = (state, _key, signal) => {
    sent = state; const call = deferred(); f.evaluations.push({ ...call, signal }); return call.promise;
  };
  f.ctx.idle = true; f.emit("agent_end", { willContinue: false });
  const work = f.fireTimer();
  assert.ok(f.evaluations[0], "the previously rejected checkpoint now produces a Jev request");
  f.evaluations[0].resolve({ finished: true, model: "jev-1.13.0", inputTokens: 1000, outputTokens: 20 });
  await work;
  const tools = sent.recent.filter(m => m.role === "toolResult");
  assert.equal(tools.length, 3);
  for (const [i, entry] of tools.entries()) {
    const digest = createHash("sha256").update(bodies[i]).digest("hex");
    assert.ok(entry.text.includes(`${Buffer.byteLength(bodies[i])} bytes`), "exact size is stated");
    assert.ok(entry.text.includes(`${bodies[i].split("\n").length} lines`), "exact line count is stated");
    assert.ok(entry.text.includes(`sha256 ${digest}`), "digest covers the complete body");
    assert.ok(!entry.text.includes("ledger row"), "bulk body is not sent");
  }
  assert.equal(sent.recent.at(-1).text, "DISCOVERY_COMPLETE");
  assert.equal(sent.coverage.recentTextTruncated, false);
  assert.equal(sent.coverage.recentBulkAttested, 3);
  assert.ok(Buffer.byteLength(JSON.stringify(sent)) < 4000, "bounded view stays far below the request cap");
  assert.equal(f.compactions.length, 1, "a qualifying judgment still requests native compaction");
  const start = f.records.find(row => row.event === "judge-start");
  assert.equal(start.attestedResults, 3);
  assert.ok(f.records.some(row => row.event === "judgment" && row.finished));
  assert.ok(!f.records.some(row => row.event === "coverage-ineligible"));
});

test("original tail-budget clipping of a small successful read is attested before judging and native compaction", async () => {
  for (const blocks of [false, true]) {
    const small = blocks ? "\u{1f642}".repeat(100) : "s".repeat(400);
    const large = blocks ? "€".repeat(400) : longRead(30);
    const encode = text => blocks ? [{ type: "text", text }] : text;
    const reads = [small, ...Array(27).fill(large)].flatMap((body, i) =>
      reading(`budget-${i}`, body, { content: encode(body) }));
    const answer = "Final answer ready";
    const messages = [{ role: "user", content: "Read everything." }, ...reads,
      { role: "assistant", content: encode(answer), stopReason: "stop" }];
    assert.equal(Buffer.byteLength(small), 400);
    assert.equal(Buffer.byteLength(answer), 18);
    const f = fixture();
    let sent;
    withHost(f, messages);
    f.adviser.judge = (state, _key, signal) => {
      sent = state;
      const call = deferred(); f.evaluations.push({ ...call, signal }); return call.promise;
    };
    f.ctx.idle = true; f.emit("agent_end", { willContinue: false });
    const work = f.fireTimer();
    assert.equal(f.evaluations.length, 1, `${blocks ? "blocks" : "strings"}: Jev receives the checkpoint`);
    f.evaluations[0].resolve({ finished: true, model: "jev-1.13.0", inputTokens: 1000, outputTokens: 20 });
    await work;
    assert.equal(sent.recent.length, 57, "all assistant and tool-result entries are retained");
    assert.deepEqual(sent.recent.map(entry => entry.role), messages.slice(1).map(message => message.role));
    const tools = sent.recent.filter(entry => entry.role === "toolResult");
    assert.equal(tools.length, 28);
    const digest = createHash("sha256").update(small).digest("hex");
    assert.ok(tools[0].text === small || tools[0].text.includes(`sha256 ${digest}`),
      "the original 400-byte result is fully present or digest-attested");
    assert.ok(!tools[0].text.includes("\ufffd"), "multibyte boundaries do not produce replacement characters");
    assert.equal(sent.recent.at(-1).text, answer);
    const attested = tools.filter(entry => entry.text.includes("sha256 ")).length;
    assert.equal(attested, 28, "the small originally clipped result is attested with the newer large reads");
    assert.equal(sent.coverage.recentBulkAttested, attested);
    assert.equal(sent.coverage.recentTextTruncated, false);
    assert.equal(f.records.find(row => row.event === "judge-start")?.attestedResults, attested);
    assert.ok(!f.records.some(row => row.event === "coverage-ineligible"));
    assert.equal(f.compactions.length, 1);
    assert.ok(f.records.some(row => row.event === "native-persisted"));
  }
});

test("genuinely incomplete views are still rejected and name their reason", async () => {
  const bigRead = reading("r", longRead(300));
  const cases = {
    "errored read": [transcript(reading("r", longRead(300), { isError: true })), {}, ["recent-text-clipped"]],
    "shell output": [transcript([
      { role: "assistant", content: [{ type: "toolCall", id: "b", name: "bash", arguments: { command: "pytest" } }] },
      { role: "toolResult", toolCallId: "b", toolName: "bash", isError: false, content: [{ type: "text", text: longRead(300) }] },
    ]), {}, ["recent-text-clipped"]],
    "clipped assistant text": [transcript(bigRead, [{ role: "assistant", content: [{ type: "text", text: "y".repeat(9000) }], stopReason: "stop" }]), {}, ["recent-text-clipped"]],
    "clipped user text": [transcript(bigRead), { omittedUserMessages: 1 }, ["user-text-clipped", "recent-text-clipped"]],
    redacted: [transcript(bigRead), { redacted: true }, ["recent-text-clipped", "redacted"]],
    images: [transcript(bigRead), { hasImages: true }, ["recent-text-clipped", "images"]],
    "unknown context": [transcript(bigRead), { unknownContext: true }, ["recent-text-clipped", "unknown-context"]],
    "unrecoverable transcript": [transcript(bigRead), { transcriptRecoverable: false }, ["recent-text-clipped", "transcript-unrecoverable"]],
  };
  for (const [name, [messages, over, reasons]] of Object.entries(cases)) {
    const f = fixture(); withHost(f, messages, over);
    await checkpoint(f);
    assert.equal(f.evaluations.length, 0, `${name}: no Jev request`);
    assert.equal(f.compactions.length, 0, `${name}: no compaction`);
    const rejected = f.records.find(row => row.event === "coverage-ineligible");
    assert.deepEqual(rejected?.reasons, reasons, name);
  }
});

test("original tail-budget clipping still rejects small errors, non-read tools, and assistants", async () => {
  for (const blocks of [false, true]) {
    const encode = text => blocks ? [{ type: "text", text }] : text;
    const small = "s".repeat(400);
    const newer = Array.from({ length: 27 }, (_, i) =>
      reading(`newer-${i}`, longRead(30), { content: encode(longRead(30)) })).flat();
    const cases = {
      "small errored read": reading("early", small, { isError: true, content: encode(small) }),
      "small non-read tool": [
        { role: "assistant", content: [{ type: "toolCall", id: "early", name: "bash", arguments: { command: "pwd" } }] },
        { role: "toolResult", toolCallId: "early", toolName: "bash", isError: false, content: encode(small) },
      ],
      "small earliest assistant": [{ role: "assistant", content: encode(small), stopReason: "stop" }],
    };
    for (const [name, earliest] of Object.entries(cases)) {
      const messages = [{ role: "user", content: "Read everything." }, ...earliest, ...newer,
        { role: "assistant", content: encode("Final answer ready"), stopReason: "stop" }];
      const f = fixture(); withHost(f, messages);
      await checkpoint(f);
      assert.equal(f.evaluations.length, 0, `${name}: no Jev request`);
      assert.equal(f.compactions.length, 0, `${name}: no compaction`);
      assert.deepEqual(f.records.find(row => row.event === "coverage-ineligible")?.reasons,
        ["recent-text-clipped"], name);
    }
  }
});

test("altered non-attested package text cannot authorize a checkpoint", async () => {
  for (const blocks of [false, true]) {
    const small = "unchanged small read";
    const messages = transcript(reading("large", longRead(300)),
      reading("small", small, { content: blocks ? [{ type: "text", text: small }] : small }));
    const f = fixture();
    withHost(f, messages, {}, view => {
      view.state.recent.find(entry => entry.role === "toolResult" && entry.text === small).text = "altered small read";
      return view;
    });
    await checkpoint(f);
    assert.equal(f.evaluations.length, 0, "a mismatched non-attested result never reaches Jev");
    assert.equal(f.compactions.length, 0);
    assert.deepEqual(f.records.find(row => row.event === "coverage-ineligible")?.reasons,
      ["recent-text-clipped"]);
  }
});

test("attestation refuses an unexpected package shape or host", async () => {
  const messages = transcript(reading("r", longRead(300)));
  const variants = {
    "missing host session rebuilder": f => { delete f.adviser.buildSessionContext; },
    "rebuilt window differs from the package window": f => { f.adviser.buildSessionContext = () => ({ messages: [...messages, ...reading("x", "extra")] }); },
    "secrets found while rebuilding": f => { f.adviser.scrubKnownSecrets = text => ({ text, redacted: true }); },
  };
  for (const [name, change] of Object.entries(variants)) {
    const f = fixture(); withHost(f, messages); change(f);
    await checkpoint(f);
    assert.equal(f.evaluations.length, 0, name);
    assert.equal(f.compactions.length, 0, name);
    assert.ok(f.records.some(row => row.event === "coverage-ineligible"), name);
  }
});

test("attestation leaves already complete views and mid-size results untouched", () => {
  const messages = transcript(reading("r", "small result"));
  const f = fixture(); withHost(f, messages, { recentTextTruncated: false },
    view => ({ ...view, autoCoverage: true }));
  const view = completeCoverage(f.adviser, f.ctx, []);
  assert.equal(view.autoCoverage, true);
  assert.equal(view.attested, undefined, "nothing was summarized when nothing was clipped");
});

test("real adviser snapshot over a long read-result transcript is eligible and fits the request cap", {
  skip: !process.env.FM_JEV_ADVISER_DIR && "set FM_JEV_ADVISER_DIR to the dependency-complete adviser package root",
}, async () => {
  const source = resolve(process.env.FM_JEV_ADVISER_DIR);
  const context = await import(pathToFileURL(join(source, "src/context.ts")).href);
  const judge = await import(pathToFileURL(join(source, "src/judge.ts")).href);
  let directory = source, sdk;
  for (;;) {
    const candidate = join(directory, "node_modules/@earendil-works/pi-coding-agent/dist/index.js");
    if (existsSync(candidate)) { sdk = await import(pathToFileURL(candidate).href); break; }
    const parent = dirname(directory);
    assert.notEqual(parent, directory, "pi-coding-agent must be installed beside the adviser package");
    directory = parent;
  }
  const adviser = { ...context, buildSessionContext: sdk.buildSessionContext };
  const work = mkdtempSync(join(tmpdir(), "fm-jev-coverage-"));
  const sessionFile = join(work, "session.jsonl");
  writeFileSync(sessionFile, "");
  let serial = 0, parent = null;
  const entry = message => {
    const row = { type: "message", id: `e${++serial}`, parentId: parent, timestamp: new Date(0).toISOString(),
      message: { ...message, timestamp: 0 } };
    parent = row.id; return row;
  };
  const build = (toolName, isError, text) => [
    entry({ role: "user", content: [{ type: "text", text: "Read the whole file, then stop." }] }),
    ...Array.from({ length: 6 }, (_, i) => [
      entry({ role: "assistant", stopReason: "toolUse", content: [{ type: "toolCall", id: `t${i}`, name: toolName, arguments: toolName === "read" ? { path: "source.txt" } : { command: "cat source.txt" } }] }),
      entry({ role: "toolResult", toolCallId: `t${i}`, toolName, isError, content: [{ type: "text", text }] }),
    ]).flat(),
    entry({ role: "assistant", stopReason: "stop", content: [{ type: "text", text: "DISCOVERY_COMPLETE" }] }),
  ];
  const body = longRead(300);
  try {
    const view = (toolName, isError, text) => {
      const branch = build(toolName, isError, text);
      return completeCoverage(adviser, {
        cwd: work, sessionManager: { getBranch: () => branch, getSessionFile: () => sessionFile },
      }, []);
    };
    const control = view("read", false, body);
    assert.equal(control.attested, 6);
    assert.equal(control.autoCoverage, true, "the bake-off's long read results are now eligible");
    assert.equal(control.state.coverage.recentTextTruncated, false);
    const digest = createHash("sha256").update(body).digest("hex");
    assert.ok(control.state.recent.filter(m => m.role === "toolResult").every(m => m.text.includes(digest)));
    assert.ok(Buffer.byteLength(judge.requestBody(control.state)) <= judge.MAX_REQUEST_BYTES,
      "the attested request is a valid Jev request");
    assert.throws(() => judge.requestBody({ recent: [{ text: body.repeat(10) }] }), "an unbounded view cannot be sent");
    assert.equal(view("bash", false, body).autoCoverage, false, "large shell output is not attested");
    assert.equal(view("read", true, body).autoCoverage, false, "an errored result is not attested");
  } finally { rmSync(work, { recursive: true, force: true }); }
});
