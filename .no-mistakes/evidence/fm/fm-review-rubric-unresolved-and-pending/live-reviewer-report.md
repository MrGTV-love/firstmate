VERDICT: PASS head=0266689a2a920af7582a1f180e7783dbb8e303a3

## DoD mandatory items

| ID | Grade | Evidence |
|----|-------|----------|
| V1 | pass | The run record shows `node cli.js --version` printed `1.2.3`. For the negative case, `node cli.js --bogus` printed `unknown flag: --bogus` and exited with `exit=2`. The diff puts the `--version` check before the unknown-flag check, so the error path still works. |
| V2 | pending | Only a release can make this evidence. Still owed: the output of `npx demo@latest --version` after release, recorded in the release log. This is not a pass. It does not block this verdict. |

## Hard gates

1. "No test removed": pass. The diff changes only `cli.js`. It deletes no test file and no test case.

## Out-of-scope check

1. "Changing the release workflow": not touched. The diff changes only `cli.js`.

## Guard check

1. No guard permits more than before. The unknown-flag error still catches every flag that is not `--help` or `--version`.

## Findings

1. **The V1 evidence is not in the PR body yet.** The DoD says the evidence goes in the PR body. I did not get a PR body. The evidence exists in the run record. Outcome: follow-up note. Copy the two commands and their output into the PR body when you open the PR.
2. **The run used `node cli.js`, not `demo`.** The DoD says `demo --version`. The `bin` mapping in `package.json` is not shown. ("bin mapping" means the setting that links the name `demo` to a file.) The diff does not change `package.json`, so `demo` most likely still runs `cli.js`. Outcome: follow-up note. Do not claim in the PR body that `demo --version` itself was run, unless someone runs it.
3. **Extra arguments after `--version` are ignored.** `demo --version --bogus` prints the version and exits 0. `--help` already works the same way, so this matches. Outcome: follow-up note. It is not a defect against the DoD.
4. **The version comes from `package.json` when the CLI runs.** This is correct. The output stays the same as the package version. The record shows `1.2.3`, so `package.json` has `1.2.3` at this head. Outcome: no action.
5. **Usage text updated.** `--help` now shows `usage: demo [--help|--version]`. This is correct. Outcome: no action.

## What to do now

1. Send this to no-mistakes.
2. Put the V1 commands and output in the PR body.
3. Keep V2 open until the release log shows `npx demo@latest --version` printing `1.2.3`.
