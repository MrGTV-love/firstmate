# Live test: omp direct Jev route, no OpenRouter, per-worker no-helpers (omp 18.9.2, 2026-10-13)

Setup: marked lab home (`bin/fm-lab-home.sh create`), real `bin/fm-spawn.sh` / `bin/fm-control.sh` from the gate worktree,
real omp 18.9.2 TUI in panes on the lab's private `fm-lab` tmux socket, isolated HOME and PI_CODING_AGENT_DIR,
fake keys only, loopback fake endpoints (`server.mjs`). fm-spawn's tmux backend calls went to the suite's tmux stub,
which records the staged launch; that exact staged launch was then sourced in a real fm-lab pane.
Only change to the launch: `-e` points at a wrapper (`run.sh`) that loads the generated extension unchanged, registers the
fake fixture/OpenRouter/secondary providers, and moves the registered TypeSafe base URL to loopback (credential command kept).
Ambient operator config (`ambient-omp-agent-config.yml`) is the incident shape: judge role and judge fallback on
`openrouter/~typesafe/jev-latest`, smol/tiny on a credentialed OpenRouter model, find on, auto thinking, enhanced speech on, skillful on.

Counts per scenario: `request-counts.txt` (from `requests.jsonl`). Screens: `panes/`. Session facts: `starts/`.
`fm-healthy` / `fm-find-ok` reused omp's cached semantic result (same query) so show 0 native calls; round 1
(`requests-round1-before-guard-path-fix.jsonl`) and `fm-find-ok2` (fresh query) show 3 direct TypeSafe calls.
`ctl-title` row 1 OpenRouter call is a late speech retry from the still-open `ctl-nopins` control session; `ctl-title2`
re-ran after closing it: 0 OpenRouter.
