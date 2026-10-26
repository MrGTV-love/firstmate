# T5 test round 6 (HEAD 23e44803f), macOS Mac-Studio.local, 2026-10-26

Disposable lab: FM_HOME from bin/fm-lab-home.sh create under ~/tmp/fm-lab.9qE1tc/home,
HOME=<lab>/user-home, private tmux socket from fm-lab-home.sh tmux-dir (-L fm-lab), real treehouse,
lab-local bare origin. Real bin/fm-spawn.sh from the gate worktree, real sandbox-exec.
tmux server env carried CURSOR_AGENT=1 GEMINI_CLI=1 LAB_MARK=1 to test the env unset.
Claude was a model-free stand-in (r6-lab-standin-claude.sh) except r6v, which ran the real
Claude CLI 2.1.310 with --version only. No provider call. Lab removed after the run.

| Task | Raw launch | Result |
|---|---|---|
| r6o | named `claude` | seatbelt-v1 (the "other" task with fixtures) |
| r6c3 | `[[ -f README.md ]] && claude --print hi` | PASS (was FAIL in r5): seatbelt-v1, argv `--session-id <recorded> --print hi`, CURSOR_AGENT/GEMINI_CLI unset; (a)(c) refused, (d) ok, (e) own append ok, other rewrite refused, primary refused |
| r6c1 | `[ -d src ] && cd src; claude --print hi` | PASS: same |
| r6c2 | `true && claude --print hi` | PASS: same |
| r6c5 | `export X=1 && claude --print hi` | PASS: same (builtin first word) |
| r6p | `claude --print hi` | PASS: same, unchanged |
| r6v | `[[ -f README.md ]] && claude --version` (real CLI) | PASS: seatbelt-v1; pane prints `2.1.310 (Claude Code)` |
| r6x1 | `true && claude --print "$(date)"` | PASS (was FAIL): spawn rc=1, construct-specific refusal, no meta, no launch |
| r6x2 | ``true && claude --print `date` `` | PASS (was FAIL): rc=1, backtick refusal |
| r6x3 | `true && (claude --print hi)` | PASS (was FAIL): rc=1, grouping refusal |
| r6x4 | `claude --print "$(date)"` | PASS: rc=1 refusal (unchanged) |
| r6x5 | `[[ -f README.md ]] && claude --print hi $X` | PASS: rc=1, shell-expansion refusal |
| r6n | `true && echo no-claude-here` | PASS: unconfined-macos-true, runs (unmeasured path unchanged) |
| r6n2 | `true && echo "$(date)"` | rc=1 refusal, as documented ("whatever its first program is") |

Other task r6o fixtures (base.r6o, ~/tmp/fixture-r6o, data/r6o/eval-target, state/r6o.status,
primary README) were intact after every spawn group. (b) B15 aged sweep run under r6c3's real
generated profile: other task's ~/tmp fixture refused (Operation not permitted), own entry deleted.
