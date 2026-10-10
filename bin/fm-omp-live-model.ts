// Live-model record for an omp (Oh My Pi) session, published to a small file
// bin/fm-crew-state.sh reads. A session whose provider path fails moves to
// another model on its own (omp's retry.fallbackChains), so the model recorded
// at launch stops being the model that is serving; the supervisor learns the
// difference from this record and never from a quiet pane.
//
// Record format (key=value lines, rewritten atomically):
//   model=<provider>/<id>   the model serving the session now
//   since=<epoch seconds>   when that model became the live one
//   error=<one line>        only when the last run ended in an error that no
//                           retry or fallback recovered, cleared by the next run
//
// Events used (verified on omp 18.8.1, tests/fm-omp-fallback-chain-live-e2e.test.sh):
//   session_start, agent_start, agent_end, retry_fallback_applied; every handler
//   receives ctx.model, so the record follows the model whatever moved it:
//   a fallback, a restore to the primary, or an operator's /model.
// A write failure never reaches omp.
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

type ModelRef = { provider?: string; id?: string } | undefined;

const selector = (model: ModelRef): string =>
  model?.provider && model?.id ? `${model.provider}/${model.id}` : "";

// The last assistant message of a finished run, when it ended in an error that
// omp will not retry (willContinue is not true).
function unrecoveredError(event: any): string {
  if (!event || event.willContinue === true || !Array.isArray(event.messages)) return "";
  for (let i = event.messages.length - 1; i >= 0; i -= 1) {
    const message = event.messages[i];
    if (message?.role !== "assistant") continue;
    if (message.stopReason !== "error") return "";
    return String(message.errorMessage ?? "error").replace(/\s+/g, " ").trim().slice(0, 200);
  }
  return "";
}

export function installLiveModelPublisher(
  pi: any,
  file: string,
  eligible: () => boolean = () => true,
): void {
  let model = "";
  let since = 0;
  let error = "";
  let written = "";

  const publish = (): void => {
    if (!model) return;
    try {
      if (!eligible()) return;
      const body = `model=${model}\nsince=${since}\n${error ? `error=${error}\n` : ""}`;
      if (body === written) return;
      mkdirSync(dirname(file), { recursive: true });
      const staging = `${file}.${process.pid}.tmp`;
      writeFileSync(staging, body);
      renameSync(staging, file);
      written = body;
    } catch {
    }
  };

  const observe = (ctx: any): void => {
    const live = selector(ctx?.model);
    if (!live) return;
    if (live !== model) {
      model = live;
      since = Math.floor(Date.now() / 1000);
    }
  };

  pi.on("session_start", (_event: any, ctx: any) => {
    error = "";
    observe(ctx);
    publish();
  });
  pi.on("agent_start", (_event: any, ctx: any) => {
    error = "";
    observe(ctx);
    publish();
  });
  pi.on("retry_fallback_applied", (_event: any, ctx: any) => {
    observe(ctx);
    publish();
  });
  pi.on("agent_end", (event: any, ctx: any) => {
    observe(ctx);
    error = unrecoveredError(event);
    publish();
  });
}
