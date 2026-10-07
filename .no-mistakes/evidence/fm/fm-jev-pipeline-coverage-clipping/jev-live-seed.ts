// Disposable Bun seed: actual SDK SessionManager, not handwritten session JSON.
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { SessionManager, buildSessionContext } from "../.fm-adviser-root/node_modules/@earendil-works/pi-coding-agent/dist/index.js";
import type { AssistantMessage, ToolResultMessage, UserMessage } from "../.fm-adviser-root/node_modules/@earendil-works/pi-ai/dist/types.js";

const names = ["large-read", "ascii-cumulative", "utf8-36", "utf8-37", "small-read", "utf8-36-x", "utf8-37-x", "small-error", "small-bash", "large-error", "large-bash", "assistant-clipped", "user-clipped", "redacted", "image", "unknown-context", "session-removed", "missing-host", "no-credentials"];
const [scenario, outputDir] = process.argv.slice(2);
if (!names.includes(scenario) || !outputDir) throw new Error(`Usage: bun jev-live-seed.ts <${names.join("|")}> <directory>`);
const directory = resolve(outputDir);
mkdirSync(join(directory, "sessions"), { recursive: true });
const sm = SessionManager.create(directory, join(directory, "sessions"));
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const assistant = (text: string, extra: Partial<AssistantMessage> = {}): AssistantMessage => ({ role: "assistant", api: "jev-live-fixture", provider: "jev-live-fixture", model: "local", timestamp: Date.now(), content: [{ type: "text", text }], stopReason: "stop", usage, ...extra });
const user = (text: string): UserMessage => ({ role: "user", content: [{ type: "text", text }], timestamp: Date.now() });
sm.appendModelChange("jev-live-fixture", "local");
sm.appendMessage(user("Read everything."));
sm.appendMessage(assistant("o".repeat(100000)));
for (let i = 0; i < 65; i++) sm.appendMessage(assistant(""));
const reads: { id: string; tool: string; path?: string; text: string; bytes: number; lines: number; sha256: string; error: boolean }[] = [];
function reading(id: string, text: string, tool = "read", error = false, earlierText: string | undefined = undefined) {
  // Actual omp supersedes older reads of the same path before checkpointing.
  // Distinct fixture files keep every requested body present in the native context.
  const path = `source-${id}.txt`;
  if (tool === "read") writeFileSync(join(directory, path), text, { mode: 0o600 });
  sm.appendMessage(assistant(earlierText ?? "", { stopReason: "toolUse", content: [
    ...(earlierText !== undefined ? [{ type: "text" as const, text: earlierText }] : []),
    { type: "toolCall", id, name: tool, arguments: tool === "read" ? { path } : { command: "pwd" } },
  ] }));
  const message: ToolResultMessage = { role: "toolResult", timestamp: Date.now(), toolCallId: id, toolName: tool, isError: error, content: [{ type: "text", text }] };
  sm.appendMessage(message);
  reads.push({ id, tool, ...(tool === "read" ? { path } : {}), text, bytes: Buffer.byteLength(text), lines: text === "" ? 0 : text.split("\n").length, sha256: createHash("sha256").update(text).digest("hex"), error });
}
const longRead = (n: number) => Array.from({ length: n }, (_, i) => `ledger row ${i} ${"x".repeat(80)}`).join("\n");
const cumulative = ["ascii-cumulative", "small-error", "small-bash"].includes(scenario);
const unicode = scenario.startsWith("utf8-");
if (cumulative) {
  reading("early", "s".repeat(400), scenario === "small-bash" ? "bash" : "read", scenario === "small-error");
  for (let i = 0; i < 27; i++) reading(`budget-${i}`, longRead(30));
} else if (unicode) {
  reading("early", "🙂".repeat(100), "read", false, scenario.endsWith("-x") ? "x" : "");
  for (let i = 0; i < 27; i++) reading(`unicode-${i}`, "€".repeat(4000));
  sm.appendMessage(assistant("h".repeat(scenario.includes("36") ? 18 : 19)));
} else if (scenario === "small-read") {
  reading("small", "small result");
} else if (scenario === "large-error" || scenario === "large-bash") {
  reading("large", longRead(300), scenario === "large-bash" ? "bash" : "read", scenario === "large-error");
} else {
  for (let i = 0; i < 6; i++) reading(`t${i}`, longRead(300));
}
if (scenario === "assistant-clipped") sm.appendMessage(assistant("y".repeat(9000)));
if (scenario === "user-clipped") sm.appendMessage(user("u".repeat(9000)));
if (scenario === "redacted") sm.appendMessage(user('{"typesafeApiKey":"SENTINEL_FIXTURE_NOT_A_SECRET","safe":"preserved"}'));
if (scenario === "image") sm.appendMessage({ role: "user", timestamp: Date.now(), content: [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII=" }] });
if (scenario === "unknown-context") sm.appendCustomMessageEntry("jev-fixture-unknown", "Unknown fixture custom context.", false);
const expectedMessages = [...buildSessionContext(sm.getBranch()).messages, user("Finish fixture turn."), assistant("Final answer ready")];
const expectedRecent = expectedMessages.slice(-64).filter(m => m.role === "assistant" || m.role === "toolResult").map(m => ({ role: m.role, ...(m.role === "toolResult" ? { tool: m.toolName, error: m.isError } : {}) }));
const positive = ["large-read", "ascii-cumulative", "utf8-36", "utf8-37", "small-read"].includes(scenario);
const manifest = { scenario, fixture: true, classification: "fixture-assisted real omp runtime; not real Jev evaluation", directory,
  sessionFile: sm.getSessionFile(), positive, nativeOnly: scenario === "no-credentials", removeSession: scenario === "session-removed",
  missingHost: scenario === "missing-host", expectedAttested: positive ? scenario === "small-read" ? 0 : cumulative || unicode ? 28 : 6 : 0,
  expectedRecent, reads, finalAnswer: "Final answer ready", finalAnswerBytes: 18,
  seedEntries: sm.getBranch().length, olderAssistantCharacters: 100000, olderEmptyAssistants: 65 };
writeFileSync(join(directory, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", { mode: 0o600 });
writeFileSync(join(directory, "seed-native-entries.json"), JSON.stringify(sm.getBranch(), null, 2) + "\n", { mode: 0o600 });
console.log(JSON.stringify({ manifest: join(directory, "manifest.json"), sessionFile: sm.getSessionFile() }));
