# Live evidence: turn-end guard bookkeeping and one liveness predicate

Target head 068ee0d01384756a38816f8271f20eaa8fef3734, base ec8b5ccfca57e3dbee4683ee67372b2788023c2b.
Every tree is a plain-checkout copy with a tree hash equal to the commit's (printed at the top of each log), under a marked `bin/fm-lab-home.sh` lab home.
The gate worktree itself is exempt from the guard because it is a linked worktree, so a plain copy is what makes the hook apply.

| Artifact | What it shows |
| --- | --- |
| `suite-fm-turnend-guard.log`, `suite-fm-guard-stale-banner.log` | Canonical suites at the exact root and head under `bin/fm-proc-budget.sh`. |
| `suite-fm-busy-adapter-wiring.log`, `suite-fm-secondmate-harness.log` | Other test files this branch changed. |
| `suite-fm-turnend-guard-simulated-omp.log` | Same suite under a SIMULATED omp ancestor (symlink named omp), not a real omp session. |
| `guard-smoke.sh`, `guard-smoke.log` | Real hook and pull guard, S1 to S7, base versus head. |
| `live-claude.sh` | Driver for real Claude Code 2.1.316 primaries on a private tmux socket. |
| `live-absent.*` | Real Claude, auto-arm hook removed: three blocks, then the loud diagnostic. |
| `live-unwritable.*` | Real Claude, budget path is a directory: no block, one repair warning, one warn event. |
| `live-supervised.*` | Real Claude, real watcher, failure-notice path obstructed: turn ends in 2 seconds, no block. |
| `live-stock.*`, `live-stock-handling.*` | Real Claude, stock hooks. No deny event. Rewakes repeat because the fixture's overdue open-loop row refuses the ack. |
| `live-stock-broken-watcher.*`, `live-base-broken.*`, `live-target-broken.*` | Real Claude, stock hooks, `fm-watch.sh` replaced by `exit 1`: uncapped rewake loop on both base and head. |
