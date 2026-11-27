# Live probe: shared Git program-file denies, base c89e6a597 vs head f7638b33c

Host: git version 2.54.0 (Apple Git-157); GIT_CONFIG_SYSTEM=/etc/gitconfig. Real head and base builders (bin/fm-write-confinement.py) and real /usr/bin/sandbox-exec, claude harness profile, disposable home under /private/tmp (removed). Script: probe/live_probe.py; raw: probe/live-probe.json.

Legend: sandbox_check columns are file-write-data/create/unlink; 1 = kernel says denied, 0 = not denied. For a path that does not exist yet (marked *), sandbox_check reads 1 even unconfined, so it is not judgeable; the write column is the evidence there.

| path | base data/create/unlink | base write | head data/create/unlink | head write |
|---|---|---|---|---|
| shared config | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared config.worktree | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared hooks/post-checkout (existing) | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared hooks/pre-push (new) * | 1/1/1 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared modules/sub/config | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared remotes/old | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| shared branches/old | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| own worktree config.worktree | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| file the shared config includes | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| absolute core.hooksPath folder file | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| user ~/.gitconfig | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| user ~/.config/git/config | 0/0/0 | succeeded | 1/1/1 | refused: Operation not permitted |
| control-protected packed-refs | 1/1/1 | refused: Operation not permitted | 1/1/1 | refused: Operation not permitted |
| control-protected HEAD | 1/1/1 | refused: Operation not permitted | 1/1/1 | refused: Operation not permitted |
| control-allowed worktree file | 0/0/0 | succeeded | 0/0/0 | succeeded |
| control-allowed own branch ref | 0/0/0 | succeeded | 0/0/0 | succeeded |
| control-allowed shared objects folder file * | 1/1/1 | succeeded | 1/1/1 | succeeded |

Unconfined control: every write succeeded (live-probe.json policy_unconfined).

## Harm: a confined worker sets core.fsmonitor in the shared config, then an unconfined supervisor runs `git -C <worktree> status`

| launch | plant exit | fsmonitor program ran |
|---|---|---|
| unconfined | 0  | True |
| base | 0  | True |
| head | 4 error: could not write config file /private/tmp/nmlive-058szza1/fmhome/projects/proj/.git/ | False |

The same harm() step also writes a new shared hook file. This shows the write is refused at head (exit 1) and allowed at base (exit 0). It is a refusal check only, not a hook-run demonstration.

## Ordinary builder Git work (launch env carries core.hooksPath via GIT_CONFIG_COUNT = legacy carrier only, fetch.prune=false, branch.autoSetupMerge=false)

| command | base exit | head exit | head result / note |
|---|---|---|---|
| status | 0 | 0 |   |
| add | 0 | 0 |   |
| commit (task hook via GIT_CONFIG_COUNT core.hooksPath) | 0 | 0 | {'task_hook_ran': True}  |
| checkout --detach | 0 | 0 |   |
| branch -D own branch | 0 | 0 |  error: could not write config file /private/tmp/nmlive-058szza1/fmhome/projects/proj/.git/config: Operation not permitte |
| checkout -b own branch | 0 | 0 |   |
| branch --list | 0 | 0 |   |
| fetch origin (remote has a new commit) | 0 | 0 | {'origin_main_is_new_tip': True}  |
| checkout -B own branch from remote-tracking ref (launch autoSetupMerge=false) | 0 | 0 | {'upstream_recorded': ''}  |
| checkout -B own branch from remote-tracking ref (Git default autoSetupMerge=true) | 0 | 0 | {'upstream_recorded': ''} error: could not write config file /private/tmp/nmlive-058szza1/fmhome/projects/proj/.git/config: Operation not permitte |
| checkout -B own branch back to tip | 0 | 0 |   |
| config --local read | 0 | 0 |   |
| config --worktree read (own config.worktree key, extensions.worktreeConfig=true) | 0 | 0 | {'value': 'own'}  |
| log | 0 | 0 |   |
| diff | 0 | 0 |   |
| stash list | 0 | 0 |   |
| config --local write (shared config write) | 0 | 4 |  error: could not write config file /private/tmp/nmlive-058szza1/fmhome/projects/proj/.git/config: Operation not permitte |
