// Firstmate semantic busy-state events + turn-end notification for omp (Oh My
// Pi); written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_end" -> idle only when event.willContinue is not true. omp has no
// agent_settled at all (verified, omp 18.1.2 and 18.1.11: zero occurrences in
// the binary); agent_end is its loop boundary and willContinue is the reliable
// "another loop is coming" flag, covering auto-retries, compaction retries,
// queued follow-ups, and a session_stop-forced continuation. ctx.isIdle() is
// deliberately NOT consulted: at a natural TUI agent_end it still reads false
// because session_stop is awaited before the session settles, so gating on it
// would leave every completed turn recorded busy. "turn_end" fires at every
// inner turn boundary and stays a wake NOTIFICATION touch for the watcher,
// never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48Z9Z3HQ68ZTKMVC9XJB2G6/bin/fm-busy-event.sh", [
      "apply", "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48Z9Z3HQ68ZTKMVC9XJB2G6/.test-herdr-recovery-home/state", "hraway", state,
      "--gen", "g1791307275.12063.20711", "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_end", (event: any) => {
    if (event && event.willContinue === true) return;
    return busyEvent("idle", "agent-end");
  });
  pi.on("turn_end", () => execFile("touch", ["/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48Z9Z3HQ68ZTKMVC9XJB2G6/.test-herdr-recovery-home/state/hraway.turn-ended"]));
}
