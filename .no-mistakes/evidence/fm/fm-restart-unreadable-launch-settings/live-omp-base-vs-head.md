# Live native-restore check (real herdr lab + real omp), base 9d516486d vs head 65ec1c7b5

Driver: tests/fm-omp-reboot-live-e2e.test.sh with FM_OMP_REBOOT_LIVE=1, run in disposable copies of each
revision. Real herdr named lab session (fm-lab-omp-reboot-*), real omp native `--resume` (no launch pin),
non-submitting fixture key. Guarded teardown ran each time.

Workaround: on BOTH base and head the unmodified test fails "inspection or refusal created lifecycle state"
because the native omp process loads the repo's .omp extensions and writes
state/.omp-turnend-extension-loaded, state/.omp-watch-extension-loaded and
state/extensions/omp-primary-watch/lifecycle.log. Same on base: pre-existing, not this change.
The debug copies excluded only those 3 paths from the state snapshot; every other guard check
(PID, composer, screen, meta cksum, HEAD, no control-relaunch/control-exit files) stayed.

| consumer | base text | head text |
|---|---|---|
| interrupt/exit | cannot positively attribute ...; refusing lifecycle input | same + ": live omp agent carries no launch pin matching this record (a native resume or restore) ... stop it by hand in its pane and then relaunch ..." |
| relaunch | ... refusing relaunch before checkpoint or lifecycle input | same + named cause + next action |
| relaunch --recover-launch | recovery-skipped <id> launch=unmanaged; no lifecycle action taken | recovery-skipped <id> launch=unmanaged: live omp agent carries no launch pin ...; no lifecycle action taken; ... next action |
| fm-reboot-recover.sh recover | REBOOT_RECOVERY: <id>: live launch is unmanaged; no lifecycle action taken | REBOOT_RECOVERY: <id>: live omp agent carries no launch pin ...; next action |

Both: exit 0, "ok - native omp: task and local secondmate remain unmanaged and unchanged for
empty/pending interrupt, exit, relaunch, direct recovery and reboot sweep".
Logs: live-omp-native-restore-head.log, live-omp-native-restore-base.log, live-omp-reboot-e2e.log (unmodified head run).
