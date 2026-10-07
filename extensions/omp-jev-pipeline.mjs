// Experimental bake-off controller; omp-jev-entry.mjs owns explicit loading.
// Reuse adviser helpers without invoking its factory or accessing private host state.
// See docs/configuration.md for opt-in configuration, endpoint safety, metrics
// and the timing-only bake-off contract.
import { appendFileSync } from "node:fs";
import { createHash } from "node:crypto";

const HEALTH_MS = 60000;
const RETRY_MS = 60000;
const IDLE_WAIT_MS = 2000;
const INPUT_PRICE_PER_MILLION = 0.042;
// Keep these limits aligned with the adviser's snapshot clipping budgets.
const TOOL_RESULT_BYTES = 512;
const TAIL_BYTES = 14000;
const ASSISTANT_BYTES = 8000;
// Only file-content retrieval can be attested: the body is data the assistant asked
// for and cannot carry a failure signal that "finished" depends on. Shell output,
// errors and every other tool must still arrive verbatim.
const ATTESTED_TOOLS = new Set(["read"]);

const textOf = message => typeof message.content === "string" ? message.content :
  message.content.filter(part => part.type === "text").map(part => part.text).join("\n");

// See docs/configuration.md, "Experimental omp-native Jev bake-off", for the
// coverage eligibility and attestation contract.
export function completeCoverage(adviser, ctx, secrets) {
  const base = adviser.snapshot(ctx, secrets, "omp");
  if (base.autoCoverage) return base;
  const coverage = base.state?.coverage;
  if (!coverage || coverage.recentTextTruncated !== true || coverage.omittedUserMessages !== 0 ||
      coverage.hasImages || coverage.redacted || coverage.unknownContext ||
      coverage.transcriptRecoverable !== true) return base;
  const { buildSessionContext, redact, scrubKnownSecrets, RECENT_TAIL_MESSAGES } = adviser;
  if (typeof buildSessionContext !== "function" || typeof redact !== "function" ||
      typeof scrubKnownSecrets !== "function" || !Number.isInteger(RECENT_TAIL_MESSAGES)) return base;
  const messages = buildSessionContext(ctx.sessionManager.getBranch()).messages;
  const original = base.state.recent;
  if (!Array.isArray(original)) return base;
  const recent = [], bulk = [];
  let budget = TAIL_BYTES, originalBudget = TAIL_BYTES, attestedBytes = 0;
  for (let i = messages.length - 1; i >= messages.length - RECENT_TAIL_MESSAGES && i >= 0; i--) {
    const message = messages[i];
    if (message.role !== "assistant" && message.role !== "toolResult") continue;
    const first = original[original.length - recent.length - 1];
    if (!first) return base;
    const cleaned = redact(textOf(message));
    const scrubbed = scrubKnownSecrets(cleaned.text, secrets);
    if (cleaned.redacted || scrubbed.redacted) return base;
    const text = scrubbed.text;
    const bytes = Buffer.byteLength(text);
    const isTool = message.role === "toolResult";
    let kept = text, summarized = false;
    if (bytes > Math.min(budget, originalBudget, isTool ? TOOL_RESULT_BYTES : ASSISTANT_BYTES)) {
      if (!isTool || message.isError || !ATTESTED_TOOLS.has(message.toolName)) return base;
      const lines = text === "" ? 0 : text.split("\n").length;
      kept = `[${message.toolName} result fully received, body not sent: ${bytes} bytes, ` +
        `${lines} lines, sha256 ${createHash("sha256").update(text).digest("hex")}]`;
      if (Buffer.byteLength(kept) > budget) return base;
      summarized = true;
      attestedBytes += bytes;
    }
    budget -= Buffer.byteLength(kept);
    // Split UTF-8 sequences can expand the adviser's retained text beyond its
    // slice budget; clamp at zero to preserve its original-tail accounting.
    originalBudget = Math.max(0, originalBudget - Buffer.byteLength(first.text));
    recent.push({
      role: message.role, text: kept,
      ...(isTool ? { tool: message.toolName, error: message.isError } : {}),
    });
    bulk.push(summarized);
  }
  recent.reverse();
  bulk.reverse();
  const attested = bulk.filter(Boolean).length;
  // Defensive: the rebuilt window must match the package's own, entry for entry,
  // except where a bulk body was attested.
  if (!attested || recent.length !== original.length) return base;
  for (let i = 0; i < recent.length; i++) {
    const kept = recent[i], first = original[i];
    if (kept.role !== first.role || kept.tool !== first.tool || (!bulk[i] && kept.text !== first.text)) return base;
  }
  return {
    ...base, autoCoverage: true,
    state: { ...base.state, recent, coverage: { ...coverage, recentTextTruncated: false,
      recentBulkAttested: attested } },
    attested, attestedBytes,
  };
}

// Categorical, text-free reasons a view cannot authorize a Jev request.
function coverageReasons(view) {
  const coverage = view.state?.coverage ?? {};
  const reasons = [];
  if (view.conversationTokens <= 20000) reasons.push("small-conversation");
  if (!view.autoCoverage) {
    if (coverage.omittedUserMessages) reasons.push("user-text-clipped");
    if (coverage.recentTextTruncated) reasons.push("recent-text-clipped");
    if (coverage.hasImages) reasons.push("images");
    if (coverage.redacted) reasons.push("redacted");
    if (coverage.unknownContext) reasons.push("unknown-context");
    if (coverage.transcriptRecoverable === false) reasons.push("transcript-unrecoverable");
  }
  return reasons;
}

function identity(ctx) {
  return JSON.stringify([
    ctx.sessionManager.getSessionId(), ctx.sessionManager.getLeafId(),
    ctx.model?.provider, ctx.model?.id,
  ]);
}

// Exported for behavioral regression through the same handler API as omp.
export function installPipeline(api, adviser, options) {
  const now = options.now ?? Date.now;
  let generation = 0;
  let timer;
  let timerContext;
  let request;
  let requestTimer;
  let requestContext;
  let decision;
  let automaticReason;
  let ownCompaction = false;
  let deferredThisUnit = false;
  let lastSuccess = -Infinity;
  let retryAfter = 0;
  let judgedIdentity;

  function record(event, fields = {}) {
    try { options.record?.({ event, at: now(), ...fields }); } catch {
      // Evidence I/O must not change compaction or recovery behavior.
    }
  }
  function invalidate() {
    generation++;
    if (timer !== undefined) timerContext.clearTimer(timer);
    timer = undefined;
    if (requestTimer !== undefined) requestContext.clearTimer(requestTimer);
    requestTimer = undefined;
    if (request) {
      record("pending-invalidated");
      request.abort();
    }
    request = undefined;
    decision = undefined;
    judgedIdentity = undefined;
  }
  function configuration(ctx) {
    const config = options.store.read();
    const key = adviser.resolveTypesafeApiKey(process.env, ctx.cwd, config.typesafeApiKey).value;
    if (config.mode !== "auto" || !config.autoAcknowledged || !key) return undefined;
    const endpoint = adviser.typesafeEndpoint(process.env.TYPESAFE_BASE);
    if (!endpoint) return undefined;
    return { config, key, endpoint, profile: adviser.parseProfile(config.profile) };
  }
  function contextReady(ctx, config) {
    const usage = ctx.getContextUsage();
    return ctx.model && ctx.isIdle() && !ctx.hasPendingMessages() &&
      !ctx.ui?.getEditorText?.().trim() && !ownCompaction &&
      usage && Number.isFinite(usage.tokens) && Number.isFinite(usage.contextWindow) &&
      usage.contextWindow > 0 && usage.tokens >= config.minContextTokens;
  }
  async function evaluate(ctx, epoch) {
    if (generation !== epoch || now() < retryAfter) return;
    let selected;
    try { selected = configuration(ctx); } catch { record("configuration-unavailable"); return; }
    if (!selected || !contextReady(ctx, selected.config) || request) {
      record("checkpoint-ineligible", {
        reason: !selected ? "configuration" : request ? "inflight" : "context",
        contextTokens: ctx.getContextUsage()?.tokens ?? null,
      });
      return;
    }
    const id = identity(ctx);
    if (judgedIdentity === id) return;
    const last = adviser.lastResponse(ctx.sessionManager.getBranch());
    if (last?.message.stopReason !== "stop") { record("nonterminal-answer"); return; }
    let view;
    try { view = completeCoverage(adviser, ctx, [selected.key, selected.config.typesafeApiKey]); }
    catch { record("snapshot-unavailable"); return; }
    if (view.conversationTokens <= 20000 || !view.autoCoverage) {
      record("coverage-ineligible", { reasons: coverageReasons(view) });
      return;
    }
    const controller = new AbortController();
    request = controller;
    judgedIdentity = id;
    // omp has no extension-facing model-change notification. A managed guard
    // observes public identity/idle getters only while a request is pending.
    const guard = ctx.setInterval(() => {
      if (identity(ctx) !== id || !ctx.isIdle() || ctx.hasPendingMessages()) invalidate();
    }, 25);
    requestTimer = guard;
    requestContext = ctx;
    const started = now();
    record("judge-start", { attestedResults: view.attested ?? 0, attestedBytes: view.attestedBytes ?? 0 });
    try {
      const result = await adviser.judge(view.state, selected.key, controller.signal,
        undefined, 2000, selected.profile, selected.endpoint);
      ctx.clearTimer(guard);
      if (requestTimer === guard) requestTimer = undefined;
      if (request === controller) request = undefined;
      const model = /^jev-\d+(?:\.\d+)*$/.test(result.model) ? result.model : null;
      record("judge-result", {
        apiMs: now() - started, inputTokens: result.inputTokens, outputTokens: result.outputTokens,
        estimatedCostUsd: result.inputTokens * INPUT_PRICE_PER_MILLION / 1000000,
        inputUsdPerMillion: INPUT_PRICE_PER_MILLION, model,
      });
      if (controller.signal.aborted || generation !== epoch || identity(ctx) !== id) {
        record("stale-result");
        return;
      }
      const latest = configuration(ctx);
      if (!latest || JSON.stringify(latest.config) !== JSON.stringify(selected.config) ||
          latest.key !== selected.key || latest.endpoint !== selected.endpoint ||
          !contextReady(ctx, latest.config)) return;
      lastSuccess = now();
      const usage = ctx.getContextUsage();
      const finished = adviser.qualifies(result, usage.tokens / usage.contextWindow, selected.profile);
      decision = { id, finished };
      record("judgment", { finished });
      if (!finished) return;
      // No asynchronous boundary between final identity/idle checks and native compact().
      ownCompaction = true;
      const compactStarted = now();
      record("checkpoint-compact", { contextTokens: usage.tokens });
      try {
        await ctx.compact({
          suppressContinuation: true,
          onComplete: () => record("checkpoint-complete", { elapsedMs: now() - compactStarted }),
          onError: () => { retryAfter = now() + RETRY_MS; record("checkpoint-error"); },
        });
      } catch {
        retryAfter = now() + RETRY_MS;
        record("checkpoint-error");
      } finally { ownCompaction = false; }
    } catch {
      if (generation === epoch && !controller.signal.aborted) {
        lastSuccess = -Infinity;
        retryAfter = now() + RETRY_MS;
        record("judge-unavailable", { apiMs: now() - started });
      }
    } finally {
      ctx.clearTimer(guard);
      if (requestTimer === guard) requestTimer = undefined;
      if (request === controller) request = undefined;
    }
  }
  function settled(event, ctx) {
    if (event.willContinue) return;
    // Empty failed turns may be omitted from persisted history; never mistake
    // an older successful answer in that history for this turn's checkpoint.
    const answer = event.messages?.findLast(message => message.role === "assistant");
    if (answer?.stopReason !== "stop") return;
    const epoch = generation;
    const checkpointIdentity = identity(ctx);
    const started = now();
    const check = () => {
      timer = undefined;
      if (generation !== epoch || ctx.hasPendingMessages()) return;
      if (identity(ctx) !== checkpointIdentity) { invalidate(); return; }
      if (!ctx.isIdle()) {
        if (now() - started < IDLE_WAIT_MS) schedule(10);
        return;
      }
      record("settled-idle", { waitMs: now() - started });
      return evaluate(ctx, epoch);
    };
    const schedule = ms => {
      timerContext = ctx;
      timer = ctx.setTimeout(check, ms);
    };
    if (timer !== undefined) timerContext.clearTimer(timer);
    schedule(0);
  }
  api.on("agent_end", settled);
  for (const name of ["input", "before_agent_start", "agent_start", "turn_start",
    "session_start", "session_before_switch", "session_switch", "session_before_branch",
    "session_branch", "session_before_tree", "session_tree", "session_shutdown"]) {
    api.on(name, () => {
      invalidate();
      if (name === "agent_start" || name.startsWith("session_")) {
        deferredThisUnit = false;
        automaticReason = undefined;
      }
      if (name === "session_shutdown" || name === "session_start" || name === "session_switch" ||
          name === "session_branch" || name === "session_tree") {
        lastSuccess = -Infinity;
        retryAfter = 0;
      }
    });
  }
  api.on("auto_compaction_start", event => { automaticReason = event.reason; });
  api.on("auto_compaction_end", () => { automaticReason = undefined; });
  api.on("session_before_compact", (event, ctx) => {
    const reason = automaticReason;
    const prior = decision;
    const currentIdentity = identity(ctx);
    invalidate();
    // Unknown trigger is manual; absent custom instructions never means automatic.
    if (ownCompaction || (reason !== "threshold" && reason !== "idle") || event.signal.aborted) {
      record("native-precedence", { reason: reason ?? "manual" });
      return;
    }
    let selected;
    try { selected = configuration(ctx); } catch { return; }
    const usage = ctx.getContextUsage();
    // Near the window limit, host recovery takes precedence over advisory deferral.
    if (!selected || now() < retryAfter || !usage || !Number.isFinite(usage.tokens) ||
        !Number.isFinite(usage.contextWindow) || usage.contextWindow <= 0 ||
        usage.tokens >= usage.contextWindow * 0.9 || deferredThisUnit) return;
    const unfinished = prior?.id === currentIdentity && !prior.finished;
    const midUnit = !ctx.isIdle() || ctx.hasPendingMessages();
    // A healthy Jev-backed policy can defer a busy unit once, never indefinitely.
    // Without a successful recent judgment, preserve all native automatic behavior.
    if (unfinished || (midUnit && now() - lastSuccess < HEALTH_MS)) {
      deferredThisUnit = true;
      record("native-deferred", { reason, midUnit });
      return { cancel: true };
    }
  });
  api.on("session_compact", event => {
    invalidate();
    deferredThisUnit = false;
    retryAfter = now() + RETRY_MS;
    const entry = event.compactionEntry;
    record("native-persisted", {
      tokensBefore: entry.tokensBefore, tokensAfter: entry.tokensAfter ?? null,
      fromExtension: event.fromExtension,
      method: ["remote", "soft", "snapcompact", "handoff", "context-full", "shake"].includes(entry.method)
        ? entry.method : null,
    });
  });
  record("pipeline-loaded");
}

export function startPipeline(api, adviser) {
  if (process.env.FM_JEV_OMP_PIPELINE !== "1") return;
  const directory = process.env.FM_JEV_PIPELINE_AGENT_DIR || api.pi.getAgentDir();
  const metrics = process.env.FM_JEV_PIPELINE_METRICS;
  installPipeline(api, adviser, {
    store: new adviser.ConfigStore(directory),
    record: metrics ? row => appendFileSync(metrics, JSON.stringify(row) + "\n", { mode: 0o600 }) : undefined,
  });
}
