verify-live-transcript.txt was produced by a throwaway driver script (since deleted with its /tmp fixtures) that:
- built one disposable git repo per scenario under mktemp -d /tmp/fm-live-carry.XXXXXX (main base, branch pr with app.txt, branch trunk with other.txt),
- wrote task-x1.meta (kind=ship, model=gpt-5.1, mode=direct-PR) into a disposable FM_HOME/state and an empty no-mistakes pipeline sqlite as NM_HOME,
- recorded PASS rows with: FM_HOME=<case>/home bin/fm-review-record.py review --pr https://github.com/example/repo/pull/9 --head <sha> --verdict PASS --reader-model <m> --author-groups '{"ship":["gpt-5.1"]}' --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report <file>
- ran: NM_HOME=<nm> FM_HOME=<case>/home <bin>/fm-review-record.py verify --pr <url> --head <live> --task task-x1 --base <trunk> --json
  once with the run worktree's bin/ (NEW, ca53e90f) and once with `git archive 535c9629 bin` (OLD, base commit).
- Scenario G puts a PATH git shim that logs the `git init` target and lists state/ during the proof, with TMPDIR pointed at a watched dir.
- Scenario H chmod 500s FM_HOME/state (uid 501, not root).
- Scenario I plants a keep-ours merge driver via a fake HOME ~/.gitconfig + core.attributesFile, then via $XDG_CONFIG_HOME/git/config + git/attributes, runs the fixture merge under it (conflict resolved by the driver), and runs verify with GIT_CONFIG_GLOBAL unset and HOME/XDG_CONFIG_HOME set to the fake home.
All runs used GIT_CONFIG_GLOBAL=/dev/null except scenario I.
