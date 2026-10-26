# T5 test round 3 (HEAD 603d4edbc), macOS Mac-Studio.local, 2026-10-26

Disposable lab: FM_HOME from bin/fm-lab-home.sh create under /private/tmp/fm-lab.XGfLMG/home,
HOME=<lab>/user-home with no ~/.claude before the first spawn, private tmux socket from
fm-lab-home.sh tmux-dir, real treehouse with an in-project pool (TREEHOUSE_ROOT=.claude/worktrees),
lab-local bare origin. Real bin/fm-spawn.sh and bin/fm-control.sh from the gate worktree.
Model CLIs were model-free stand-ins on PATH (r3-lab-standin-claude-final.sh); the stand-in also
ran the real Claude CLI 2.1.310 for local `/cost` (no model call, $0.0000). Lab removed after the run.

| File | What it shows |
|---|---|
| r3-fm-write-confinement.test.log | tests/fm-write-confinement.test.sh passed: T5 a-e and per-asset refusals under real sandbox-exec, omp and Claude profiles, with unconfined baseline |
| r3-fm-spawn-worktree-settle.test.log | tests/fm-spawn-worktree-settle.test.sh passed (63 ok): confined launches, 0700 session folders, raw-launch refusals and bracket acceptances |
| r3-raw-launch-cases.txt | bin/fm-raw-launch.py render-claude: accepted, forked and refused forms incl. lone [ / [[ vs closed [ab] |
| r3-live-lab-run1-t5lab1.txt | fresh config root: spawn created session-env/file-history/tasks/projects/<slug> at 0700; own session writes ok, foreign refused; real claude /cost under confinement exit 0 and wrote its own transcript |
| r3-live-lab-run2-t5-a-e.txt | attacker t5lab2 vs real other task t5lab1: T5 a, b, c, e refused, d ok; unconfined control shows every attack works without the sandbox; delegated-write residual reproduced via tmux run-shell |
| r3-live-lab-relaunch-fresh-root.txt | fm-control relaunch on an absent config root recreated folders 0700 with a new session id; old and foreign ids refused |
| r3-live-lab-raw-spawns.txt | raw spawns: --session-id, $FLAGS, --x=[ab] refused at spawn; claude --resume gets --session-id <uuid> --fork-session; `[ -d src ] && ...; claude` and `true && claude` launch UNCONFINED (harness=[ / true) |
| r3-live-lab-codex-unconfined.txt | codex stays unconfined-macos-codex (unchanged) |
| r3-live-profile-t5lab1.sb | generated profile for t5lab1 |
