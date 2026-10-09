import { existsSync, readFileSync, writeFileSync, unlinkSync, appendFileSync } from "node:fs";
import watchFactory from "./.omp/extensions/fm-primary-omp-watch.ts";

export default function (pi: any) {
  const state = `${process.env.FM_HOME}/state`;
  const log = (kind: string, data: any) => appendFileSync(`${state}/probe.jsonl`, JSON.stringify({ time: Date.now(), kind, ...data }) + "\n");
  let context: any;
  let captured: string | undefined;
  let busy = false;
  const wrapContext = (ctx: any) => {
    context = ctx;
    if (!ctx?.ui) return ctx;
    const ui = new Proxy(ctx.ui, {
      get(target, key) {
        if (key === "getEditorText") return () => {
          const text = target.getEditorText();
          if (captured && text.includes("FIRSTMATE WATCHER WAKE:")) log("editor-observed", { text, idle: ctx.isIdle(), pending: ctx.hasPendingMessages() });
          return text;
        };
        if (key === "setEditorText") return (text: string) => {
          log("editor-write", { before: target.getEditorText(), text, idle: ctx.isIdle(), pending: ctx.hasPendingMessages() });
          target.setEditorText(text);
          log("editor-after", { text: target.getEditorText() });
        };
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    return new Proxy(ctx, { get(target, key) { return key === "ui" ? ui : Reflect.get(target, key); } });
  };
  pi.on("session_start", async (_event: any, ctx: any) => {
    context = ctx;
    const result = await pi.exec("bash", ["bin/fm-lock.sh"]);
    log("lock", { result, pid: process.pid, hasUI: ctx.hasUI });
    if (result.code !== 0) throw new Error(`primary lock failed: ${result.stderr}`);
  });
  const wrapped = new Proxy(pi, {
    get(target, key) {
      if (key === "on") return (event: string, handler: any) => target.on(event, (value: any, ctx: any) => handler(value, wrapContext(ctx)));
      if (key === "sendUserMessage") return (content: string, options?: any) => {
        log("production-send", { content, options: options ?? null, idle: context?.isIdle(), pending: context?.hasPendingMessages(), editor: context?.ui?.getEditorText() });
        if (content.includes("FIRSTMATE WATCHER WAKE:") && existsSync(`${state}/capture-request`)) {
          unlinkSync(`${state}/capture-request`);
          captured = content;
          writeFileSync(`${state}/captured.json`, JSON.stringify({ content, idle: context?.isIdle(), options: options ?? null }));
          return;
        }
        return target.sendUserMessage(content, options);
      };
      return Reflect.get(target, key);
    },
  });
  watchFactory(wrapped);
  pi.on("agent_end", (_event: any, ctx: any) => log("agent-end", { idle: ctx.isIdle(), pending: ctx.hasPendingMessages(), editor: ctx.ui.getEditorText() }));
  pi.on("message_start", (event: any) => { if (event.message?.role === "user") log("user-message", { content: event.message.content }); });
  const timer = setInterval(async () => {
    if (busy || !captured || !existsSync(`${state}/queue-request`) || context?.isIdle() !== false) return;
    busy = true;
    try {
      unlinkSync(`${state}/queue-request`);
      await pi.sendUserMessage(captured, { deliverAs: "followUp" });
      log("vendor-queued", { content: captured, idle: context.isIdle(), pending: context.hasPendingMessages(), editor: context.ui.getEditorText() });
      writeFileSync(`${state}/queued.json`, JSON.stringify({ content: captured }));
    } catch (error) { log("probe-error", { error: String(error) }); }
    finally { busy = false; }
  }, 100);
  timer.unref();
  pi.on("session_shutdown", () => clearInterval(timer));
}
