import { appendFileSync } from "node:fs";
import { installJevGuard } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BRZHD65NVA5M74B571ND3A/bin/fm-jev-guard.ts";
export default function (pi: any) {
  pi.on("tool_call", (event: any) => {
    appendFileSync("/Users/charlesabrooker/tmp/jev-live.1BYYJw/omp-events.jsonl", JSON.stringify({ tool: event.toolName, inputKeys: Object.keys(event.input ?? {}), contentBytes: Buffer.byteLength(String(event.input?.content ?? event.input?.new_string ?? "")) }) + "\n");
  });
  installJevGuard(pi, { home: "/Users/charlesabrooker/tmp/jev-live.1BYYJw/rhome", config: "/Users/charlesabrooker/tmp/jev-live.1BYYJw/rhome/config", state: "/Users/charlesabrooker/tmp/jev-live.1BYYJw/rhome/state", task: "t1", worktree: "/Users/charlesabrooker/tmp/jev-live.1BYYJw/rwt", data: "/Users/charlesabrooker/tmp/jev-live.1BYYJw/rhome/data/t1", project: "firstmate", policy: "FIRSTMATE_JEV_GUARD_V1" });
}
