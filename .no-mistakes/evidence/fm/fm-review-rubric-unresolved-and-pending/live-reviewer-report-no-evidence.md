VERDICT: FAIL head=0266689a2a920af7582a1f180e7783dbb8e303a3

## DoD mandatory items

| ID | Grade | Evidence |
|---|---|---|
| V1 | **unresolved: blocks** | No one ran the CLI, and firstmate gave no execution record. The diff shows that `--version` prints `require('./package.json').version`. But the diff does not include `package.json`, so it does not show that the version is `1.2.3`. The negative case looks safe: the `if (a.length)` error line still comes after the new line, so an unknown flag still goes to `unknown flag: ...` with exit code `2`. But that was also not run. The evidence place is the PR body, and no PR body was supplied. This item can be checked now, so the missing evidence blocks. |
| V2 | **pending** | This needs a release first. Still owed: the output of `npx demo@latest --version` showing `1.2.3`, recorded in the release log. Authority: gate. Pending does not block by itself. |

## Hard gates and scope

| Check | Result | Evidence |
|---|---|---|
| No test removed | pass | The diff changes only `cli.js`. No test file changes. |
| Out of scope: release workflow | pass | The diff does not touch any release workflow file. |
| Guard widened | none | The unknown-flag error path stays the same. |

## Findings

1. **V1 evidence missing: block.** To fix, run these three commands and put their output in the PR body:
   - `demo --version`. Expected: prints `1.2.3`, exit code `0`.
   - `demo --bogus`. Expected: prints `unknown flag: --bogus` to stderr, exit code `2`.
   - Show `package.json` at this head with `"version": "1.2.3"`.
2. **V2 pending.** Leave it open until the release log shows `npx demo@latest --version` printing `1.2.3`.
3. **No test covers `--version`: follow-up note, not a block.** The DoD does not ask for a test. A test for `--version` and for the unknown-flag error would help.
4. **`demo --version extra` prints the version and ignores `extra`: follow-up note, not a block.** `--help` does the same thing, so the behaviour is consistent. No DoD item covers it.
5. **Help text change: no issue.** `usage: demo [--help|--version]` now matches the new flag.
6. **Code is correct as written.** `require('./package.json')` resolves relative to `cli.js`, and npm always ships `package.json`. I found no defect in the diff.

## Not verified

- I ran nothing, because the brief says to review only from the supplied material.
- I did not see `package.json` at this head.
- I did not see a PR body.

## What to do now

Get the V1 run output (finding 1) into the PR body. Then send it back for review. With that evidence, the verdict can become PASS, with V2 still pending.
