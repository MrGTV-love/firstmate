Live validation of the brief-named deletion allowance in jev-guard (target c7babd560).
Lab: disposable marked FM_HOME (bin/fm-lab-home.sh create), a clone of this repo at the target commit as the task worktree,
and a local stand-in judge that answers every rm as the real Jev did in the incident (irreversible, destructive 0.99).
Hosts driven: real Claude Code 2.1.310 (`claude -p`, guard registered as a PreToolUse command hook in .claude/settings.local.json,
exactly as fm-spawn writes it) and real omp v18.12.4 (`omp -p` and an interactive omp TUI in a private tmux server,
guard loaded through an extension that calls installJevGuard with the spawn-shaped context).
Files:
 01-publish-cli.txt                     bin/fm-jev-deletions.sh --help and publish; meta digest equals sha256 of the list
 02-live-host-runs.txt                  per-phase host transcripts, judge request counts, allowance audit rows, guard terminal rows, git status
                                        (two runs are marked INVALID / setup fault: the stand-in judge was reaped; each was re-run)
 03-omp-live-session-update-revoke.txt  one running omp session: allow, live narrowing republish, explicit-cwd skip, revoke-all republish
 04-spawn-snapshot-and-id-reuse.test.log  real fm-spawn.sh (fake omp binary): initial snapshot consumed; reused task id loses stale list
 05-teardown-retires-list.test.log      real fm-teardown.sh: list removed, .jsonl audit kept, other task untouched
 fm-jev-guard.test.log                  tests/fm-jev-guard.test.sh (includes test_authorized_deletions, both hosts)
 lab-*.txt / lab-*.json                 lab wiring used (paths redacted to $LAB)
