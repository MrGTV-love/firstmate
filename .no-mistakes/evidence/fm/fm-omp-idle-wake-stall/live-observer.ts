import { appendFileSync } from 'node:fs';
export default function (pi: any) {
  let ctx: any = null;
  let previous = '';
  const record = (event: string, detail?: any) => {
    if (!ctx) return;
    try {
      const row = { time: Date.now()/1000, event, idle: ctx.isIdle(), pending: ctx.hasPendingMessages(), editor: ctx.hasUI ? ctx.ui.getEditorText() : null, detail };
      const signature = JSON.stringify([row.idle, row.pending, row.editor]);
      if (event === 'poll' && signature === previous) return;
      previous = signature;
      appendFileSync(process.env.LAB_OBSERVATION!, JSON.stringify(row) + '\n');
    } catch {}
  };
  for (const event of ['session_start', 'agent_start', 'agent_end', 'message_start', 'tool_execution_start', 'tool_execution_end']) {
    pi.on(event, (data: any, context: any) => { ctx = context; record(event, event === 'message_start' ? data.message : undefined); });
  }
  const timer = setInterval(() => record('poll'), 100);
  timer.unref();
  pi.on('session_shutdown', () => clearInterval(timer));
}
