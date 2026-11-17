# Live validation summary (gate run 01M7MPJSRYMH2DNEGFVNKTR2WD)
Driver: live-driver.sh (real bin/fm-control.sh, marked lab home via bin/fm-lab-home.sh env, real fm-lock.sh lock owned by this agent's real Claude Code process, real git project, real tmux on the lab private socket, real claude in task windows for live-agent cases).

## head 936a73e0
-- vernant shape: phase=failed:launching rollback=prior-record-kept, no agent window (lab-vernant)
  agent_state=missing
  PASS: vernant: exit 0
  PASS: vernant: worktree= now /Users/charlesabrooker/tmp/fm-lab-work.1Bf9yU/lab-vernant-new
  PASS: vernant: active journal path retired
  PASS: vernant: archive name lab-vernant.control-relaunch.archived-2026-11-17T123251Z.0 (UTC stamp + counter)
  PASS: vernant: archive sha256 95818c3c0b083618ea46072d3c68b71da9880f931a00ae2f1dbb226587c6bbca == journal-before sha256
  PASS: vernant: note written into brief
-- vernant: reassociate back to the old copy (archive must not block)
  PASS: vernant-again: exit 0
  PASS: vernant-again: archive kept, unchanged, no new archive
-- phase=complete journal (lab-complete)
  PASS: complete: exit 0
  PASS: complete: journal untouched in place
  PASS: complete: no archive made
-- archive counter: earlier archives already hold the .0 name for the next seconds (lab-counter)
  PASS: counter: exit 0
  new archive: lab-counter.control-relaunch.archived-2026-11-17T123331Z.1
  PASS: counter: new archive took counter .1 (no collision)
  PASS: counter: new archive is byte-exact
  PASS: counter: all 21 pre-existing archives byte-unchanged
-- refusal: none-new-agent-confirmed (lab-r1)
  PASS: none-new-agent-confirmed: refused (exit 1)
  PASS: none-new-agent-confirmed: reason contains 'unfinished relaunch transaction'
  PASS: none-new-agent-confirmed: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r1
  PASS: none-new-agent-confirmed: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: none-new-record-kept (lab-r2)
  PASS: none-new-record-kept: refused (exit 1)
  PASS: none-new-record-kept: reason contains 'unfinished relaunch transaction'
  PASS: none-new-record-kept: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r2
  PASS: none-new-record-kept: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: no-rollback (lab-r3)
  PASS: no-rollback: refused (exit 1)
  PASS: no-rollback: reason contains 'unfinished relaunch transaction'
  PASS: no-rollback: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r3
  PASS: no-rollback: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: mode000 (lab-r4)
  PASS: mode000: refused (exit 1)
  PASS: mode000: reason contains 'unfinished relaunch transaction'
  PASS: mode000: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r4
  PASS: mode000: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: directory (lab-r5)
  PASS: directory: refused (exit 1)
  PASS: directory: reason contains 'unfinished relaunch transaction'
  PASS: directory: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r5
  PASS: directory: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: symlink (lab-r6)
  PASS: symlink: refused (exit 1)
  PASS: symlink: reason contains 'unfinished relaunch transaction'
  PASS: symlink: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r6
  PASS: symlink: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: foreign-task (lab-r7)
  PASS: foreign-task: refused (exit 1)
  PASS: foreign-task: reason contains 'unfinished relaunch transaction'
  PASS: foreign-task: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r7
  PASS: foreign-task: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: empty-task (lab-r8)
  PASS: empty-task: refused (exit 1)
  PASS: empty-task: reason contains 'unfinished relaunch transaction'
  PASS: empty-task: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r8
  PASS: empty-task: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: malformed-prior (lab-r9)
  PASS: malformed-prior: refused (exit 1)
  PASS: malformed-prior: reason contains 'unfinished relaunch transaction'
  PASS: malformed-prior: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r9
  PASS: malformed-prior: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: malformed-instructions (lab-r10)
  PASS: malformed-instructions: refused (exit 1)
  PASS: malformed-instructions: reason contains 'unfinished relaunch transaction'
  PASS: malformed-instructions: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r10
  PASS: malformed-instructions: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: phase-launching (lab-r11)
  PASS: phase-launching: refused (exit 1)
  PASS: phase-launching: reason contains 'unfinished relaunch transaction'
  PASS: phase-launching: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r11
  PASS: phase-launching: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- refusal: bad-state-suffix (lab-r12)
  PASS: bad-state-suffix: refused (exit 1)
  PASS: bad-state-suffix: reason contains 'unfinished relaunch transaction'
  PASS: bad-state-suffix: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-r12
  PASS: bad-state-suffix: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- instructions-restored-agent-alive with a REAL claude in fmlab:fm-lab-gated (lab-gated)
  agent_state=alive; windows: fmlab:placeholder zsh;fmlab:fm-lab-gated 2.1.326;
  PASS: gated-alive(live claude): refused (exit 1)
  PASS: gated-alive(live claude): reason contains 'agent is not proven stopped'
  PASS: gated-alive(live claude): state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-gated
  PASS: gated-alive(live claude): tmux endpoints unchanged (fmlab:placeholder zsh;fmlab:fm-lab-gated 2.1.326;)
  agent_state=dead
  PASS: gated-alive(agent dead): exit 0
  PASS: gated-alive(agent dead): worktree= now /Users/charlesabrooker/tmp/fm-lab-work.1Bf9yU/lab-gated-new
  PASS: gated-alive(agent dead): active journal path retired
  PASS: gated-alive(agent dead): archive name lab-gated.control-relaunch.archived-2026-11-17T123752Z.0 (UTC stamp + counter)
  PASS: gated-alive(agent dead): archive sha256 66fd4b8c70d3aef0e4265c21f2397307128d7bb9e53a929e89a53b124491a57e == journal-before sha256
-- instructions-restored-agent-state-unknown with an ambiguous foreground (sleep) (lab-gstate)
  agent_state=ambiguous
  PASS: gated-state(ambiguous): refused (exit 1)
  PASS: gated-state(ambiguous): reason contains 'agent is not proven stopped'
  PASS: gated-state(ambiguous): state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-gstate
  PASS: gated-state(ambiguous): tmux endpoints unchanged (fmlab:placeholder zsh;fmlab:fm-lab-gated zsh;fmlab:fm-lab-gstate sleep;)
  window removed; agent_state=missing
  PASS: gated-state(missing): exit 0
  PASS: gated-state(missing): worktree= now /Users/charlesabrooker/tmp/fm-lab-work.1Bf9yU/lab-gstate-new
  PASS: gated-state(missing): active journal path retired
  PASS: gated-state(missing): archive name lab-gstate.control-relaunch.archived-2026-11-17T123825Z.0 (UTC stamp + counter)
  PASS: gated-state(missing): archive sha256 e4ee039fc2fa070827cdf05569048b45328de5cece00a7bbb0ec320151a7493a == journal-before sha256
-- instructions-restored (not gated) with a REAL live claude in fmlab:fm-lab-ungated (lab-ungated)
  agent_state=alive
  PASS: ungated-live: exit 0
  PASS: ungated-live: worktree= now /Users/charlesabrooker/tmp/fm-lab-work.1Bf9yU/lab-ungated-new
  PASS: ungated-live: active journal path retired
  PASS: ungated-live: archive name lab-ungated.control-relaunch.archived-2026-11-17T123840Z.0 (UTC stamp + counter)
  PASS: ungated-live: archive sha256 9638884636af4bbc5999c6271cc3824f7f0385674655d6754f920926439e991c == journal-before sha256
  PASS: ungated-live: live worker untouched (still alive)
-- staging failure after the archive copy: data/lab-fail made read-only (lab-fail)
  PASS: failure: refused (exit 1)
  PASS: failure: active journal still in place, byte-exact
  PASS: failure: task record and brief unchanged
  archives after failed attempt: lab-fail.control-relaunch.archived-2026-11-17T123853Z.0 
-- re-run after fixing the cause
  PASS: failure-rerun: exit 0
  PASS: failure-rerun: worktree= now /Users/charlesabrooker/tmp/fm-lab-work.1Bf9yU/lab-fail-new
  PASS: failure-rerun: active journal path retired
  PASS: failure-rerun: archive name lab-fail.control-relaunch.archived-2026-11-17T123904Z.0 (UTC stamp + counter)
  PASS: failure-rerun: archive sha256 8de74b10f2a8b438150daf50eb33c68931b664253fbff6493a9f1db8fe8748ca == journal-before sha256
  archives now: lab-fail.control-relaunch.archived-2026-11-17T123853Z.0 lab-fail.control-relaunch.archived-2026-11-17T123904Z.0 
RESULT tag=head-live pass=95 fail=0

## base df896569 (same fixtures)
-- vernant shape on BASE (lab-vernant)
    | error: task lab-vernant has an unfinished relaunch transaction at /Users/charlesabrooker/tmp/fm-lab.l6QlNY/state/lab-vernant.control-relaunch; reconcile it before reassociating
  PASS: vernant-on-base: refused (exit 1)
  PASS: vernant-on-base: reason contains 'unfinished relaunch transaction'
  PASS: vernant-on-base: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-vernant
  PASS: vernant-on-base: tmux endpoints unchanged (fmlab:placeholder zsh;)
-- instructions-restored with live claude on BASE (lab-ungated)
  agent_state=alive
    | error: task lab-ungated has an unfinished relaunch transaction at /Users/charlesabrooker/tmp/fm-lab.l6QlNY/state/lab-ungated.control-relaunch; reconcile it before reassociating
  PASS: ungated-on-base: refused (exit 1)
  PASS: ungated-on-base: reason contains 'unfinished relaunch transaction'
  PASS: ungated-on-base: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive
  only telemetry appended: guard-event: gate-agent-containment allow gate-context lab-ungated
  PASS: ungated-on-base: tmux endpoints unchanged (fmlab:placeholder zsh;fmlab:fm-lab-ungated 2.1.326;)
RESULT tag=base-live pass=8 fail=0
