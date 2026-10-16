# Jev guard local product evidence

Scope: current worktree guard source in installed OMP and Claude clients; synthetic loopback model/Jev providers only. No model-accuracy, producer-authentication, deployment-protection or paid-trial claim.

## Native read matrix

| Host | Condition | Read | Jev calls | Actual next-model result |
| --- | --- | --- | ---: | --- |
| omp | normal | launch | 0 | [source visible; notice: none](native/omp/normal-launch/model.jsonl) |
| omp | normal | inbox | 0 | [source visible; notice: none](native/omp/normal-inbox/model.jsonl) |
| omp | normal | copy | 1 | [source withheld; notice: flag](native/omp/normal-copy/model.jsonl) |
| omp | normal | changed | 1 | [source withheld; notice: flag](native/omp/normal-changed/model.jsonl) |
| omp | privacy | launch | 0 | [source visible; notice: none](native/omp/privacy-launch/model.jsonl) |
| omp | privacy | inbox | 0 | [source visible; notice: none](native/omp/privacy-inbox/model.jsonl) |
| omp | privacy | copy | 0 | [source withheld; notice: PrivacyWithheldError](native/omp/privacy-copy/model.jsonl) |
| omp | privacy | changed | 0 | [source withheld; notice: PrivacyWithheldError](native/omp/privacy-changed/model.jsonl) |
| omp | credentials | launch | 0 | [source visible; notice: none](native/omp/credentials-launch/model.jsonl) |
| omp | credentials | inbox | 0 | [source visible; notice: none](native/omp/credentials-inbox/model.jsonl) |
| omp | credentials | copy | 0 | [source withheld; notice: CredentialUnavailableError](native/omp/credentials-copy/model.jsonl) |
| omp | credentials | changed | 0 | [source withheld; notice: CredentialUnavailableError](native/omp/credentials-changed/model.jsonl) |
| omp | provider | launch | 0 | [source visible; notice: none](native/omp/provider-launch/model.jsonl) |
| omp | provider | inbox | 0 | [source visible; notice: none](native/omp/provider-inbox/model.jsonl) |
| omp | provider | copy | 1 | [source withheld; notice: requires review (Error)](native/omp/provider-copy/model.jsonl) |
| omp | provider | changed | 1 | [source withheld; notice: requires review (Error)](native/omp/provider-changed/model.jsonl) |
| omp | audit | launch | 0 | [source visible; notice: AuditUnavailableError](native/omp/audit-launch/model.jsonl) |
| omp | audit | inbox | 0 | [source visible; notice: AuditUnavailableError](native/omp/audit-inbox/model.jsonl) |
| omp | audit | copy | 1 | [source withheld; notice: AuditUnavailableError](native/omp/audit-copy/model.jsonl) |
| omp | audit | changed | 1 | [source withheld; notice: AuditUnavailableError](native/omp/audit-changed/model.jsonl) |
| claude | normal | launch | 0 | [source visible; notice: none](native/claude/normal-launch/model.jsonl) |
| claude | normal | inbox | 0 | [source visible; notice: none](native/claude/normal-inbox/model.jsonl) |
| claude | normal | copy | 1 | [source visible; notice: flag](native/claude/normal-copy/model.jsonl) |
| claude | normal | changed | 1 | [source visible; notice: flag](native/claude/normal-changed/model.jsonl) |
| claude | privacy | launch | 0 | [source visible; notice: none](native/claude/privacy-launch/model.jsonl) |
| claude | privacy | inbox | 0 | [source visible; notice: none](native/claude/privacy-inbox/model.jsonl) |
| claude | privacy | copy | 0 | [source visible; notice: PrivacyWithheldError](native/claude/privacy-copy/model.jsonl) |
| claude | privacy | changed | 0 | [source visible; notice: PrivacyWithheldError](native/claude/privacy-changed/model.jsonl) |
| claude | credentials | launch | 0 | [source visible; notice: none](native/claude/credentials-launch/model.jsonl) |
| claude | credentials | inbox | 0 | [source visible; notice: none](native/claude/credentials-inbox/model.jsonl) |
| claude | credentials | copy | 0 | [source visible; notice: CredentialUnavailableError](native/claude/credentials-copy/model.jsonl) |
| claude | credentials | changed | 0 | [source visible; notice: CredentialUnavailableError](native/claude/credentials-changed/model.jsonl) |
| claude | provider | launch | 0 | [source visible; notice: none](native/claude/provider-launch/model.jsonl) |
| claude | provider | inbox | 0 | [source visible; notice: none](native/claude/provider-inbox/model.jsonl) |
| claude | provider | copy | 1 | [source visible; notice: requires review (Error)](native/claude/provider-copy/model.jsonl) |
| claude | provider | changed | 1 | [source visible; notice: requires review (Error)](native/claude/provider-changed/model.jsonl) |
| claude | audit | launch | 0 | [source visible; notice: AuditUnavailableError](native/claude/audit-launch/model.jsonl) |
| claude | audit | inbox | 0 | [source visible; notice: AuditUnavailableError](native/claude/audit-inbox/model.jsonl) |
| claude | audit | copy | 1 | [source visible; notice: AuditUnavailableError](native/claude/audit-copy/model.jsonl) |
| claude | audit | changed | 1 | [source visible; notice: AuditUnavailableError](native/claude/audit-changed/model.jsonl) |

## Publication and replay

The real publisher emitted 139-, 159- and 197-byte carriers for 6-, 26- and 64-character IDs respectively (excluding newline; longest is 198 including newline). Two records per task replayed in numeric order without altering write-time receipts. Exact delivered bytes passed the executable hook without inference. An unannounced sibling and a foreign native session were screened. Moving records into handled removed them from replay; the next publication was 003.msg. Hostile task-name carriers executed with empty stdout/stderr and exit 0 in sh, bash and zsh.

See [emitted carriers and replay state](publication-replay.json), [hook responses and terminal records](cli-hook-transcript.json), [synthetic request payloads](cli-provider-requests.json), and [minimized terminal audit](cli-terminal-audit.jsonl).

## Policy and egress

Executable hook responses demonstrated shell denial, allowed read-only shell, deterministic out-of-root denial without egress, credential insertion detected beyond the old prefix, inactive/missing project scopes without egress, launch-policy opt-out, exact .20/.80 threshold boundaries with review between, malformed-answer ContractError, complete result-tail transmission, oversize RequestTooLargeError before missing credentials, and PrivacyWithheldError before missing credentials. The retained terminal audit contains error_type in every record and omits synthetic source/prompt/credential canaries.

## Limits

The provider is scripted: these observations prove runtime transport, byte consistency and enforcement behavior, not the accuracy of Jev classification or agent obedience. Claude retains its original Read result and receives an advisory explicitly saying no protection. A same-user process deliberately forging the recorded digest can pass; this remains consistency, not producer authentication. The frozen paid calibration was not rerun. No production lifecycle or Herdr session was touched.


## Native scope and launch-policy boundary

Four additional installed-OMP sessions consumed actual built-in Read results. Active Firstmate made one loopback Jev request and withheld untrusted source; another project, explicit no-helper Firstmate, and pre-cutover Firstmate each made zero Jev requests and preserved the source. See [native scope commands and results](native-scope-summary.json).

## Supplementary targeted regressions and setup repair

The guard, task-inbox and operational-input suites passed in the assigned worktree. The focused `bash tests/fm-control-relaunch.test.sh --jev-guard` run passed, including its mandatory lifecycle preamble, survivor announcements and legacy/current launch-only cutover. These transport/consumer fixtures supplement, rather than replace, the installed-client observations above.

The supplementary busy-adapter wiring suite initially rejected a secondmate fixture inside the source root. A byte-for-byte disposable source copy and sibling fixture root kept both inside the assigned worktree while satisfying that product boundary. The first separated-root run exposed a driver mistake: inherited `FM_HOME` overrode the per-case secondmate home and made the Stop guard stand down. Unsetting that driver override resolved it; the complete selected wiring suite then exited 0. No product or permanent test change was needed. Initial diagnostics remain in `targeted-regressions.log` and `wiring-isolated-rerun.log`; the corrected result is in [wiring-clean-environment.log](wiring-clean-environment.log).

Final results: both maintained native entrypoints passed, all four additional native scope sessions passed, executable publisher/hook smoke passed, all three guard/inbox/publisher regression suites passed, focused relaunch passed, and the corrected wiring run passed. No complete repository suite, lint, formatter, static analysis, pipeline control, production activation or additional paid calibration was run. The surface is headless CLI/hooks, so retained evidence consists of native request/context data, emitted carriers, executable hook responses and terminal records rather than screenshots.
