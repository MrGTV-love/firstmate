# T5 live lab run (macOS, Mac-Studio.local, 2026-10-26)

Lab: disposable FM_HOME made by bin/fm-lab-home.sh create under /private/tmp/fmt5.RDQ2Ik/home,
HOME=<lab>/user-home, private tmux socket dir from fm-lab-home.sh tmux-dir, real treehouse with an
in-project pool (TREEHOUSE_ROOT=.claude/worktrees), lab-private git origin. Real bin/fm-spawn.sh from
the gate worktree spawned 6 tasks. The model CLIs were model-free stand-ins (stub claude/omp/codex on
PATH) that run a write-attack probe; no provider call was made. Lab removed after the run.

| Task | Harness | Result |
|---|---|---|
| t5o6604e11c | claude | "other" task; confined (seatbelt-v1), session id recorded |
| t5w6604e11c | claude | attacker; T5 a-e all hold (live-probe-t5w6604e11c.json) |
| t5r6604e11c | raw `claude --resume=<id> --model opus` | confined; argv `--session-id <uuid> --fork-session --resume=<id> --model opus` |
| t5x6604e11c | raw `claude --print "$(cat prompt.md)"` | spawn exit 1, construct-specific refusal, no window |
| t5m6604e11c | omp | confined; T5 a-e all hold (live-probe-t5m6604e11c.json) |
| t5c6604e11c | codex | unconfined-macos-codex; foreign state write succeeded (unchanged behaviour) |

Delegated-write residual (named in docs/configuration.md:2550) reproduced: the confined worker ran
`tmux -S <lab socket> run-shell 'touch <lab>/config/residual-proof'`; the already-running unconfined
tmux server wrote into the protected config dir.

Extra probe with the same generated Claude profile: in a fresh config root without
`session-env/`, `file-history/`, `tasks/` or `projects/` parent folders, the worker's own
`session-env/<own uuid>`, `file-history/<own uuid>`, `tasks/<own uuid>` and
`projects/<slug>/<own uuid>.jsonl` writes are refused. After those parents exist (as on any
used Claude install), each write succeeds and a foreign session id stays refused.
