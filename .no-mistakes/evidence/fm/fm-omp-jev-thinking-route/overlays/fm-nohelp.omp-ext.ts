// Firstmate semantic busy-state events for omp (Oh My
// Pi); written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_end" -> idle only when event.willContinue is not true. omp has no
// agent_settled at all (verified, omp 18.1.2 and 18.1.11: zero occurrences in
// the binary); agent_end is its loop boundary and willContinue is the reliable
// "another loop is coming" flag, covering auto-retries, compaction retries,
// queued follow-ups, and a session_stop-forced continuation. ctx.isIdle() is
// deliberately NOT consulted: at a natural TUI agent_end it still reads false
// because session_stop is awaited before the session settles, so gating on it
// would leave every completed turn recorded busy.
import { execFile } from "node:child_process";
import { installJevGuard } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/bin/fm-jev-guard.ts";
import { installTypesafeJudge } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/bin/fm-omp-jev.ts";
import { installTaskSessionProof } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/.omp/extensions/lib/fm-task-session.ts";
import { installLiveModelPublisher } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/bin/fm-omp-live-model.ts";
import { appendFileSync, readFileSync } from "node:fs";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/bin/fm-busy-event.sh", [
      "apply", "/private/tmp/fm-lab.DKt9pt/state", "fm-nohelp", state,
      "--gen", "g1791925406.79284.18941", "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  const guardContext = {"home":"/tmp/fm-lab.DKt9pt","config":"/tmp/fm-lab.DKt9pt/config","state":"/private/tmp/fm-lab.DKt9pt/state","task":"fm-nohelp","worktree":"/tmp/fmlive.9rLnPC/wt-fm2","data":"/tmp/fm-lab.DKt9pt/data/fm-nohelp","project":"firstmate","noHelpers":true};
  installTypesafeJudge(pi, guardContext);
  installJevGuard(pi, guardContext);
  installTaskSessionProof(pi, "/private/tmp/fm-lab.DKt9pt/state", "fm-nohelp");
  // The model serving this task now, for bin/fm-crew-state.sh's drift note.
  installLiveModelPublisher(pi, "/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.live-model");
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_end", (event: any) => {
    if (event && event.willContinue === true) return;
    const last = event?.messages?.filter((m: any) => m.role === "assistant").at(-1);
    const exhausted = last?.stopReason === "error" &&
      /usage_limit_reached|usage limit|quota.*exhaust/i.test(last.errorMessage ?? "");
    return busyEvent("idle", exhausted ? "quota-exhausted" : "agent-end");
  });
  pi.on("turn_end", () => execFile("touch", ["/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.turn-ended"]));
  pi.on("retry_fallback_succeeded", (event: any) => {
    try {
      if (readFileSync("/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.busy-gen", "utf8").trim() !== "g1791925406.79284.18941") return;
    } catch (error: any) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    const model = String(event.model ?? "").replace(/[\r\n\t]/g, " ");
    appendFileSync("/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.status",
      "note [at=" + Math.floor(Date.now() / 1000) + "]: model-matrix fallback served " + model + "\n");
  });
}
