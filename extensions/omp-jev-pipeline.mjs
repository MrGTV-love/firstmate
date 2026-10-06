// Experimental bake-off controller; omp-jev-entry.mjs owns explicit loading.
// Opt in with FM_JEV_OMP_PIPELINE=1 after installing the dependency-complete adviser.
// Reuses the dependency-complete adviser's judge, snapshot/redaction, profile,
// key resolution and read-only ConfigStore, without invoking its factory.
// Requires mode=auto and autoAcknowledged=true in the existing adviser config.
// FM_JEV_PIPELINE_AGENT_DIR optionally selects an isolated existing adviser
// config directory; otherwise omp's public getAgentDir() selects it.
// FM_JEV_PIPELINE_METRICS optionally appends secret-free numeric JSONL evidence.
// TYPESAFE_BASE follows compact-adviser's https/loopback-only endpoint policy.
// Native retention and summaries remain untouched. Manual/overflow/incomplete
// compactions never wait for Jev. No plugin factory or private host state is used.
import { appendFileSync } from "node:fs";

const HEALTH_MS = 60000;
const RETRY_MS = 60000;
const IDLE_WAIT_MS = 2000;
const INPUT_PRICE_PER_MILLION = 0.042;

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
    try { view = adviser.snapshot(ctx, [selected.key, selected.config.typesafeApiKey], "omp"); }
    catch { record("snapshot-unavailable"); return; }
    if (view.conversationTokens <= 20000 || !view.autoCoverage) {
      record("coverage-ineligible");
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
    record("judge-start");
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
