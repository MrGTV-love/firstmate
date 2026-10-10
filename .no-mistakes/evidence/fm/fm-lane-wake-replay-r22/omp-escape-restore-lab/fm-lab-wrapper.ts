import { appendFileSync, existsSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import watchFactory from "./extensions/fm-primary-omp-watch.ts";

export default function (pi: any) {
  const state = `${process.env.FM_HOME}/state`;
  let context: any;
  let captured: string | null = null;
  let queueing = false;
  const file = (name: string) => `${state}/.wake-followup-${name}`;
  const publish = (name: string, value: unknown) => {
    writeFileSync(`${file(name)}.tmp`, `${JSON.stringify(value)}\n`);
    renameSync(`${file(name)}.tmp`, file(name));
  };
  const wrapped = new Proxy(pi, {
    get(target, key) {
      if (key === "on") return (event: string, handler: any) => target.on(event, (value: any, ctx: any) => {
        context = ctx;
        const ui = ctx?.ui;
        if (ui && !ui.__fmLabWrapped) {
          const set = ui.setEditorText.bind(ui);
          ui.setEditorText = (next: string) => {
            appendFileSync(`${state}/.lab-set-editor-log`, JSON.stringify({ t: Date.now(), before: String(ui.getEditorText?.() ?? ""), after: next, event }) + "\n");
            return set(next);
          };
          ui.__fmLabWrapped = true;
        }
        return handler(value, ctx);
      });
      if (key === "sendUserMessage") return (content: string, options?: any) => {
        appendFileSync(`${state}/.lab-send-log`, JSON.stringify({ t: Date.now(), idle: context?.isIdle?.(), deliverAs: options?.deliverAs ?? null, editor: String(context?.ui?.getEditorText?.() ?? ""), content: content.slice(0, 160) }) + "\n");
        if (content.includes("FIRSTMATE WATCHER WAKE:") && existsSync(file("capture-request"))) {
          if (context?.isIdle() !== true || options?.deliverAs !== undefined) {
            publish("error", "production capture was not an idle wake");
            throw new Error("production capture was not an idle wake");
          }
          unlinkSync(file("capture-request"));
          captured = content;
          publish("captured", { content, idle: true });
          return;
        }
        if (content === captured) {
          publish("recovered", {
            content,
            idle: context?.isIdle(),
            deliverAs: options?.deliverAs ?? null,
            editor: context?.ui?.getEditorText(),
          });
        }
        return target.sendUserMessage(content, options);
      };
      return Reflect.get(target, key);
    },
  });
  watchFactory(wrapped);
  const timer = setInterval(async () => {
    if (queueing || !captured || !existsSync(file("queue-request")) || context?.isIdle() !== false) return;
    queueing = true;
    try {
      unlinkSync(file("queue-request"));
      const content = captured;
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
      publish("queued", { content, idle: false });
    } catch (error) {
      publish("error", String(error));
    } finally {
      queueing = false;
    }
  }, 100);
  timer.unref();
  pi.on("session_shutdown", () => clearInterval(timer));
}
