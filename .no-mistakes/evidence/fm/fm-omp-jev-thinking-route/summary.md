# Live lab: omp direct judge route, firstmate-only scope, no-helper workers

Run 2026-10-12, omp 18.9.2, macOS arm64, branch fm/fm-omp-jev-thinking-route at 8f3aaf32.

## Setup (all disposable, removed after the run)

- Lab home made with `bin/fm-lab-home.sh create`; private tmux socket from `fm-lab-home.sh tmux-dir`; tmux server started from `env -i` through `bin/fm-proc-budget.sh`.
- Real `bin/fm-spawn.sh` and `bin/fm-control.sh` from the gate worktree, `FM_HOME=<lab>`, tmux backend, `TREEHOUSE_ROOT` inside the lab.
- Two lab projects: `projects/firstmate` (resolves to guard project `firstmate`) and `projects/vernant`.
- Fake keys only: lab `.env` holds `TYPESAFE_API_KEY=fake-lab-typesafe-primary` and `OPENROUTER_API_KEY=fake-lab-openrouter-trap`; the tmux environment also carries the fake OpenRouter key, so OpenRouter is credentialed everywhere.
- Isolated omp agent dir (`PI_CODING_AGENT_DIR`) with ambient `retry.fallbackChains.judge=[openrouter/~typesafe/jev-latest]`, `speech.enabled/enhanced=true`, `modelRoles.tiny=secondary/tiny` (see `lab-ambient-omp-config.yml`, `lab-models.yml`).
- `driver/lab-services.mjs`: scripted primary model `fixture/main` and a `secondary/tiny` trap on loopback; an HTTPS proxy with a lab-only CA that intercepts the production hosts `api.typesafe.ai` (fake answers) and `openrouter.ai` (always 503 trap) and refuses every other host. No lab request left the machine. Requests are logged with a credential label, never a value.

## Per-worker request counts (from each `*/requests.jsonl`)

| Run | find.enabled | omp_no_helpers | TypeSafe judgment POSTs | TypeSafe GETs | OpenRouter POSTs | OpenRouter GETs | Secondary-model POSTs | Primary fixture POSTs |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lab-fs firstmate, high | on | 0 | 5 | 0 | 0 | 0 | 27 | 5 |
| lab-fa firstmate, ambient auto thinking | on | 0 | 4 | 0 | 0 | 0 | 27 | 5 |
| lab-fu firstmate, high, TypeSafe 503 | on | 0 | 9 | 1 | 0 | 6 | 40 | 6 |
| lab-ve vernant, high | off | 0 | 0 | 0 | 0 | 0 | 32 | 4 |
| lab-va vernant, ambient auto thinking | off | 0 | 0 | 1 | 0 | 6 | 40 | 5 |
| lab-nh firstmate, --omp-no-helpers (+ relaunch) | off | 1 | 0 | 0 | 0 | 0 | 0 | 6 |

- Every TypeSafe POST carried the fake primary-home key (`lab-typesafe-key`), resolved by the `!bash` command credential; no worker process argv or environment contained the key (lab-fs process-tree check).
- The GETs in lab-fu and lab-va are free model-catalog listings by the spawn-time `omp models --json` validation, not by the worker: they precede the worker process start (lab-fu: GETs 22:50:38, worker log starts 22:50:45; `lab-fu/spawn-time-omp-models.log`). That omp runs with cwd = FM_HOME and Bun auto-loads `FM_HOME/.env`; a control run showed a cwd without `.env` makes no TypeSafe GET. This validator is unchanged by this branch.
- Secondary-model POSTs in ordinary workers are omp's ambient `@tiny` helper (unchanged behavior); the no-helper worker made none.
- Vernant auto thinking: worker log `auto-thinking: classification failed; using fallback level` / `every judge candidate failed: no API key for typesafe/jev-latest` (`lab-va/omp-auto-thinking-log.txt`), with zero OpenRouter POSTs although OpenRouter was credentialed and the ambient judge chain named it.
- Guard ledgers: firstmate runs record `provider: typesafe`; vernant and no-helper runs record only `error` events (withheld, fail-open).

## Adversarial checks

- Vernant worker started in a folder whose `.env` holds a TypeSafe key: judge still `no API key for typesafe/jev-latest` (the `!false` credential wins), zero TypeSafe requests (`adversarial/`).
- The same print-mode session sent 4 title-generation POSTs to OpenRouter `anthropic/claude-haiku-5.5` with the ambient OpenRouter key, with or without the `.env`; this is omp's title helper for an ordinary worker (not a judge route) and does not occur with `--omp-no-helpers` (`--no-title`).
- `fm-control.sh lab-nh relaunch --harness claude`: refused with the omp_no_helpers message, exit 1, same omp pid alive, meta byte-identical, no relaunch transaction (`lab-nh/relaunch-onto-claude-refused.log`).
- `fm-control.sh lab-nh relaunch` (same harness): relaunched; new omp argv still has the no-helper overlay, `--no-title --no-extensions --no-skills --no-rules`, the 8-tool list and `--thinking high`; meta keeps `omp_no_helpers=on` (`lab-nh/omp-argv-flags-after-relaunch.txt`).
- `fm-spawn ... --harness claude --omp-no-helpers`: refused before publishing task state or opening a window (`lab-nx/spawn-refused.log`).
