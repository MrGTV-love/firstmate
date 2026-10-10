import { appendFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const out = resolve(process.env.FM_HOME + "/state/.lab-queue-probe");
const editorLog = resolve(process.env.FM_HOME + "/state/.lab-editor-log");
export default function (pi: { on?: (event: string, handler: (event: any, ctx: any) => unknown) => void }) {
  let ctx: any = null;
  const remember = (_event: unknown, context: unknown) => {
    if (typeof context === "object" && context !== null) ctx = context;
  };
  for (const event of ["session_start", "before_agent_start", "message_start", "agent_end"]) pi.on?.(event, remember);
  let lastEditor = "";
  const timer = setInterval(() => {
    try {
      const editor = String(ctx?.ui?.getEditorText?.() ?? "");
      if (editor !== lastEditor) {
        lastEditor = editor;
        appendFileSync(editorLog, `${Math.floor(Date.now() / 1000)} ${JSON.stringify(editor)}\n`);
      }
    } catch {}
    try {
      writeFileSync(out, `${Math.floor(Date.now() / 1000)} queued=${ctx?.hasPendingMessages?.() === true ? 1 : 0} idle=${ctx?.isIdle?.() === true ? 1 : 0}\n`);
    } catch {}
  }, 100);
  timer.unref();
}
