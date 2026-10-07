// Disposable fixture provider for the actual omp TUI. No fetch replacement or compaction override.
import { appendFileSync, unlinkSync } from "node:fs";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const FINAL = "Final answer ready";
const SUMMARY = "Native fixture summary: older exploration completed; read results were received in full. Final answer ready. This summary was generated through the real host's compaction provider call.";
export default function liveRuntime(api: ExtensionAPI) {
  const log = (value: unknown) => appendFileSync(process.env.JEV_LIVE_EVENTS!, JSON.stringify(value) + "\n", { mode: 0o600 });
  api.registerProvider("jev-live-fixture", {
    baseUrl: "http://127.0.0.1:1", apiKey: "fixture-provider-not-a-secret", api: "jev-live-fixture",
    models: [{ id: "local", name: "Jev live fixture provider", reasoning: false, input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 272000, maxTokens: 2048 }],
    streamSimple: (model, context) => {
      const last = context.messages.at(-1);
      const lastText = typeof last?.content === "string" ? last.content : last?.content.filter(p => p.type === "text").map(p => p.text).join("\n") ?? "";
      const summary = lastText !== "Finish fixture turn." &&
        /summari[sz]|summary|handoff document|compact/i.test((context.systemPrompt ?? "") + "\n" + lastText);
      if (!summary && lastText !== "Finish fixture turn.") throw new Error("Unexpected fixture provider request; refusing an invented response");
      const text = summary ? SUMMARY : FINAL;
      log({ event: "provider", fixture: true, summary, context, responseText: text });
      const message: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
        timestamp: Date.now(), stopReason: "stop", content: [{ type: "text", text }],
        usage: { input: 45000, output: summary ? 40 : 4, cacheRead: 0, cacheWrite: 0,
          totalTokens: 45000 + (summary ? 40 : 4), cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        stream.push({ type: "start", partial: message });
        stream.push({ type: "text_start", contentIndex: 0, partial: message });
        stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: message });
        stream.push({ type: "text_end", contentIndex: 0, content: text, partial: message });
        stream.push({ type: "done", reason: "stop", message }); stream.end();
      });
      return stream;
    },
  });
  api.on("session_start", (_event, ctx) => log({ event: "runtime-start", fixture: true, mode: ctx.mode, sessionFile: ctx.sessionManager.getSessionFile() }));
  api.on("agent_end", (_event, ctx) => {
    log({ event: "native-branch-before-checkpoint", entries: ctx.sessionManager.getBranch() });
    if (process.env.JEV_LIVE_REMOVE_SESSION === "1") {
      const path = ctx.sessionManager.getSessionFile();
      if (!path) throw new Error("Removal scenario has no loaded native session file");
      unlinkSync(path);
      log({ event: "session-file-removed-after-load", path });
    }
  });
  api.on("session_compact", (event, ctx) => log({ event: "runtime-native-compaction", compactionEntry: event.compactionEntry, entries: ctx.sessionManager.getBranch() }));
}
