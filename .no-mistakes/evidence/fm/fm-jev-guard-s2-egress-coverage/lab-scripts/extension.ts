import { installJevGuard } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5V29PD99JFK5BG4M7JKKY14/bin/fm-jev-guard.ts";
// Same ompSetting wiring fm-spawn.sh generates for workers.
const ompSetting = await Promise.all([import("@oh-my-pi/pi-coding-agent/config/settings"), import("@oh-my-pi/pi-coding-agent/config/registry")])
  .then(([{ settings }, { lookup }]) => (id: string) => lookup(id)?.get(settings), () => undefined);
export default function (pi: any) {
  const lab = "/Users/charlesabrooker/tmp/fm-t4-lab.PtjvJJ";
  installJevGuard(pi, { home: `${lab}/home`, config: `${lab}/home/config`, state: `${lab}/home/state`,
    task: "native", data: `${lab}/home/data`, worktree: `${lab}/worktree`, project: "firstmate",
    policy: "FIRSTMATE_JEV_GUARD_V1", ompSetting });
}
