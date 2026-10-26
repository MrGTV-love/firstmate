# T5 test round 5 (HEAD 8190de2b4), macOS Mac-Studio.local, 2026-10-26

Disposable lab: FM_HOME from bin/fm-lab-home.sh create under ~/tmp/fm-lab.XSuKB2/home,
HOME=<lab>/user-home, private tmux socket from fm-lab-home.sh tmux-dir (-L fm-lab), real treehouse,
lab-local bare origin. Real bin/fm-spawn.sh from the gate worktree, real sandbox-exec.
The claude CLI was a model-free stand-in (r5-lab-standin-claude.sh) that records argv and confinement
and attacks the real other task t5o. Driver: r5-lab-drive.sh. No provider call. Lab removed after the run.

| Task | Raw launch | Result |
|---|---|---|
| t5o | named `claude` | seatbelt-v1, session id recorded (the "other" task) |
| t5c1 | `[ -d src ] && cd src; claude --print hi` | PASS: harness=claude, seatbelt-v1, argv `--session-id <recorded> --print hi`; (a)(c) other-task deletes refused, (e) own append ok, other status rewrite refused |
| t5c2 | `true && claude --print hi` | PASS: same as t5c1 |
| t5c3 | `[[ -f x ]] && claude --print hi` | FAIL: recorded confined, but delivered `env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI [[ -f x ]] && claude ...`; pane shows `env: [[: No such file or directory`; Claude never runs |
| t5c4 | `true; FOO=1 claude --print hi` | PASS: confined under recorded session id |
| t5p | `claude --print hi` | PASS: unchanged, confined |
| t5x1 | `true && claude --print "$(date)"` | FAIL: harness=true, unconfined-macos-true; stand-in Claude ran and deleted t5o's B3 fixture and data file, rewrote t5o.status, appended to the primary checkout |
| t5x2 | ``true && claude --print `date` `` | FAIL: same, unconfined |
| t5x3 | `true && (claude --print hi)` | FAIL: same, unconfined |
| t5x4 | `claude --print "$(date)"` | PASS: spawn exit 1 with construct-specific refusal, no launch |
| t5n | `true && echo no-claude-here` | PASS: stays unconfined-macos-true (unmeasured path unchanged) |

Cause of t5x1-3: `fm-raw-launch.py runs-claude` exits 2 when its scanner refuses the text, and
bin/fm-spawn.sh:3164-3166 treats every non-zero exit as "no claude", so the launch falls back to
the unmeasured, unconfined path instead of refusing.
Cause of t5c3: bin/fm-spawn.sh:7261 prepends `env -u ...` to the whole raw launch; `env` cannot
exec a shell keyword or builtin (`[[`, `export`) as the first word.

Files: r5-live-lab-raw-spawns.txt (driver transcript), r5-live-lab-delivered-launches.txt
(delivered launch lines and pane tails), r5-fm-spawn-worktree-settle.test.log and
r5-fm-write-confinement.test.log (both passed).
