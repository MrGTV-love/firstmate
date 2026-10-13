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
import { installJevGuard } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4RRMFE4ZTZ15F0R827J0ZK1/bin/fm-jev-guard.ts";
import { installTypesafeJudge } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4RRMFE4ZTZ15F0R827J0ZK1/bin/fm-omp-jev.ts";
import { installTaskSessionProof } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4RRMFE4ZTZ15F0R827J0ZK1/.omp/extensions/lib/fm-task-session.ts";
import { installLiveModelPublisher } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4RRMFE4ZTZ15F0R827J0ZK1/bin/fm-omp-live-model.ts";
import { appendFileSync, readFileSync } from "node:fs";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4RRMFE4ZTZ15F0R827J0ZK1/bin/fm-busy-event.sh", [
      "apply", "/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state", "lab-fs", state,
      "--gen", "g1791844890.25336.10644", "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  const guardContext = {"home":"/Users/charlesabrooker/tmp/fm-lab.k62xWq/home","config":"/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/config","state":"/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state","task":"lab-fs","worktree":"/Users/charlesabrooker/tmp/fm-lab.k62xWq/treehouse/.treehouse/firstmate-f1fef2/1/firstmate","data":"/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/data/lab-fs","project":"firstmate","noHelpers":false};
  installTypesafeJudge(pi, guardContext);
  installJevGuard(pi, guardContext);
  installTaskSessionProof(pi, "/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state", "lab-fs");
  // The model serving this task now, for bin/fm-crew-state.sh's drift note.
  installLiveModelPublisher(pi, "/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state/lab-fs.live-model");
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_end", (event: any) => {
    if (event && event.willContinue === true) return;
    const last = event?.messages?.filter((m: any) => m.role === "assistant").at(-1);
    const exhausted = last?.stopReason === "error" &&
      /usage_limit_reached|usage limit|quota.*exhaust/i.test(last.errorMessage ?? "");
    return busyEvent("idle", exhausted ? "quota-exhausted" : "agent-end");
  });
  pi.on("turn_end", () => execFile("touch", ["/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state/lab-fs.turn-ended"]));
  pi.on("retry_fallback_succeeded", (event: any) => {
    try {
      if (readFileSync("/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state/lab-fs.busy-gen", "utf8").trim() !== "g1791844890.25336.10644") return;
    } catch (error: any) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    const model = String(event.model ?? "").replace(/[\r\n\t]/g, " ");
    appendFileSync("/Users/charlesabrooker/tmp/fm-lab.k62xWq/home/state/lab-fs.status",
      "note [at=" + Math.floor(Date.now() / 1000) + "]: model-matrix fallback served " + model + "\n");
  });
}
