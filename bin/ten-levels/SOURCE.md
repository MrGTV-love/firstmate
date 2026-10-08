# Source

This directory holds the level 6 jev-guard from disler's ten-levels-of-jev, vendored from upstream.

- Repository: https://github.com/disler/ten-levels-of-jev
- Path: `apps/ten-levels` (the `LICENSE` file comes from the repository root)
- Commit: `777adaf47d37ae0553220d35b2f15b3a3a063305` (committed 2026-09-27)
- Vendored: 2026-10-07
- License: MIT, see `LICENSE` in this directory.

The upstream paths under `apps/ten-levels` are kept, so every relative import resolves unchanged.

## Unmodified copies

These files are byte-for-byte copies of the upstream files at the same paths:

- `extensions/jev-guard.ts`
- `src/levels/level06/index.ts`, `bash-gate.ts`, `write-gate.ts` and `result-screen.ts`
- `src/core/client.ts`, `helpers.ts`, `mock.ts` and `types.ts`
- `tests/level06.test.ts`
- `LICENSE`

The questions, thresholds, block and banner wording, content trimming, the client's provider snapshot, retries and 30-second budget, and the allow-on-error behavior all run as upstream wrote them.

## Changed copy: `extensions/report.ts`

Upstream's `report.ts` is the lab's side channel, so it is the one upstream file Firstmate changes.
Each change and its reason:

- `extensions/report.ts:58-77`: the client calls TypeSafe direct first, instead of upstream's single `openrouter` client, and only when that call is unavailable or fails asks one OpenRouter client.
  This is the captain-ordered Firstmate rule in `.agents/skills/hyper-jev/FIRSTMATE.md`, and it overrides upstream's one-provider snapshot with no switch after a failed call.
  `seam` reads a loopback test endpoint only when `FM_TEST_SEAM=1`.
- `extensions/report.ts:34-48`: both keys are read at call time through `bin/fm-typesafe-lib.sh` (`fm_typesafe_key`, `fm_openrouter_key`), because upstream reads them from the process environment, which Firstmate keeps free of keys.
- `extensions/report.ts:50-56` and `:107`: `decide` first checks the request against `config/dispatch-never-send` through `fm_typesafe_permitted`, the existing rule for what may leave the machine in a Jev request.
  A withheld request throws, so upstream's own error path allows the tool call.
- `extensions/report.ts:26-32`: `configure` names the owning home, its config and state, and the task, because one shared code root serves many homes and workers.
- `extensions/report.ts:87-90`: each event goes to the owning home's private `state/jev-guard.jsonl` instead of the lab's `JEV_EVENT` stderr stream, which has no reader in Firstmate and would draw over omp's terminal interface.
  The ledger row omits the request body (`state`) and the fixed `questions` so a long-lived log does not collect file contents; the session entry keeps the full upstream payload.
- `extensions/report.ts:111`: the `jev` event also names the answering provider, so fallback use is measurable.

## Firstmate glue outside this directory

- `bin/fm-jev-guard.ts:34-48`: installs the unchanged upstream extension for one worker.
  `:35-41` gives the write gate the root that holds the target path, out of the worktree, the task's `data/<task>` directory and the system temporary directory, because upstream's single-root check would block a scout's report and harness scratch files written by design outside the worktree.
- `bin/fm-jev-guard-claude.ts:31-48`: Claude has no pi extension API, so the adapter maps Claude's `PreToolUse` and `PostToolUse` payloads to the pi events the upstream handlers read (`file_path` to `path`, `tool_response` to text content).
  `:37` turns an upstream block into a Claude `deny`.
  `:47` delivers the banner as `additionalContext`, because a Claude hook cannot replace a built-in tool's output.
- `bin/fm-jev-guard-hook.sh:15-19`: runs the TypeScript adapter with bun, or node with type stripping, so no build step is needed.
- `bin/fm-spawn.sh:4786-4788` registers the Claude hooks in the worker's `.claude/settings.local.json`, with a 70-second hook timeout that covers upstream's 30-second client budget for each of the two providers; `bin/fm-spawn.sh:4951` and `:4960` install the guard in the generated omp worker extension.
