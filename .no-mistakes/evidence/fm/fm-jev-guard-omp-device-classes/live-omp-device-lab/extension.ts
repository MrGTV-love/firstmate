import { installJevGuard } from "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5RB8318NTGZQW57YSPVBH7K/bin/fm-jev-guard.ts";
export default function (pi: any) {
  const lab = "/Users/charlesabrooker/tmp/fm-jev-dev-lab.Eh3uS2";
  installJevGuard(pi, { home: `${lab}/home`, config: `${lab}/home/config`, state: `${lab}/home/state`,
    task: "devlab", data: `${lab}/home/data`, worktree: `${lab}/worktree`, project: "firstmate", noHelpers: false,
    policy: "FIRSTMATE_JEV_GUARD_V1" });
}
