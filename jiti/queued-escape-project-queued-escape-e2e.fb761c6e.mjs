"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.default = _default;var _nodeFs = await jitiImport("node:fs");
var _piAi = await jitiImport("@earendil-works/pi-ai");

var _typebox = await jitiImport("typebox");
var _fmOperationalInput = await jitiImport("./.pi/extensions/lib/fm-operational-input.ts");

let label = "";

function lastUserText(messages) {
  const user = [...messages].reverse().find((message) => message.role === "user");
  if (!user) return "";
  if (typeof user.content === "string") return user.content;
  return user.content.
  filter((block) => block.type === "text").
  map((block) => block.text ?? "").
  join("\n");
}

function _default(pi) {
  const faux = (0, _piAi.createFauxCore)({
    api: "queued-escape-e2e-api",
    provider: "queued-escape-e2e",
    models: [{
      id: "deterministic",
      name: "Calm queued-row Escape E2E",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    }],
    tokenSize: { min: 1, max: 1 }
  });
  // The captain prompt holds the turn in a tool; a monitoring notification gets its own reply.
  const respond = (context) => {
    const text = lastUserText(context.messages);
    if (text.includes(`MONITOR_${label}`)) return (0, _piAi.fauxAssistantMessage)([(0, _piAi.fauxText)(`MONITOR_HANDLED_${label}`)]);
    if (context.messages[context.messages.length - 1]?.role === "user") {
      return (0, _piAi.fauxAssistantMessage)([(0, _piAi.fauxToolCall)("hold_turn", {}, { id: `hold_${label}` })], { stopReason: "toolUse" });
    }
    return (0, _piAi.fauxAssistantMessage)([(0, _piAi.fauxText)(`CAPTAIN_ANSWER_${label}`)]);
  };
  pi.registerProvider("queued-escape-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple
  });
  pi.registerTool({
    name: "hold_turn",
    label: "hold_turn",
    description: "Hold the turn open until it is aborted.",
    parameters: _typebox.Type.Object({}),
    async execute(_id, _params, signal) {
      await pi.sendUserMessage(
        (0, _fmOperationalInput.encodeFirstmateOperationalInput)("watcher", `MONITOR_${label}_ONE`),
        { deliverAs: "followUp" }
      );
      (0, _nodeFs.writeFileSync)(process.env.QUEUED_ESCAPE_HELD, label);
      await new Promise((resolve) => signal?.addEventListener("abort", () => resolve(), { once: true }));
      return { content: [{ type: "text", text: "released" }], details: {} };
    }
  });
  pi.registerCommand("queued-escape-e2e", {
    description: "Hold one captain turn open while a monitoring notification queues.",
    handler: async (args, ctx) => {
      label = args.trim();
      const model = ctx.modelRegistry.find("queued-escape-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("queued-escape E2E model unavailable");
      faux.setResponses(Array.from({ length: 8 }, () => respond));
      pi.sendUserMessage(`CAPTAIN_PROMPT_${label}`);
    }
  });
} /* v9-63335c5e8e16e8d7 */
