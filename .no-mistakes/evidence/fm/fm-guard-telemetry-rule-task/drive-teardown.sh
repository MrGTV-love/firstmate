#!/usr/bin/env bash
# Live driver: real fm-teardown.sh in a marked lab home on a ship task with
# uncommitted work. (1) no --force: refused, attributed landed-work deny, and a
# manual backlog backend records one backlog-transition bypass. Remote-service
# CLIs (gh, gh-axi, no-mistakes, treehouse) are stubbed so nothing outside the
# lab is read or changed.
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
STUB=$(mktemp -d "${TMPDIR:-/tmp}/fm-td-stub.XXXXXX")
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1; rm -rf "$STUB"' EXIT
for c in gh gh-axi no-mistakes treehouse; do
  printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "count: 0 (showing first 0)\\npull_requests[]: []\\n";; "pr view") exit 1;; esac\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
P=$FM_HOME/projects/demo
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
git init -q -b main "$P"; echo x > "$P/x"; git -C "$P" add x; git -C "$P" commit -qm init
git -C "$P" worktree add -q -b fm/probe-td "$FM_HOME/projects/wt-probe-td"
echo dirty > "$FM_HOME/projects/wt-probe-td/dirty.txt"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '%s\n' "window=firstmate:fm-probe-td" "endpoint_task_id=probe-td" "worktree=$FM_HOME/projects/wt-probe-td" \
  "project=$P" "kind=ship" "mode=local-only" "spawn_gen=lab-probe-td" > "$FM_HOME/state/probe-td.meta"
LOG=$FM_HOME/state/guard-events.jsonl
rc=0
env -u FM_TASK_ID PATH="$STUB:$PATH" bin/fm-teardown.sh probe-td >"$FM_HOME/td.out" 2>&1 </dev/null || rc=$?
echo "teardown (no --force) exit=$rc"; grep -m2 -E 'REFUSED|error' "$FM_HOME/td.out" | cut -c1-200
echo "worktree still present: $([ -d "$FM_HOME/projects/wt-probe-td" ] && echo yes || echo no)"
jq -c 'select(.guard=="teardown-unlanded" or .guard=="backlog-transition") | {guard,decision,rule,task,override,cleared_by}' "$LOG" 2>/dev/null
# (2) --force with the captain's words file: the forced discard proceeds and
# records one landed-work bypass with override=true and cleared_by=force.
printf 'Lab fixture: the captain approved discarding this disposable lab work.\n' > "$STUB/words.txt"
: > "$LOG"
rc=0
env -u FM_TASK_ID PATH="$STUB:$PATH" bin/fm-teardown.sh probe-td --force --drop-file "$STUB/words.txt" >"$FM_HOME/td2.out" 2>&1 </dev/null || rc=$?
echo "teardown --force exit=$rc"; grep -m2 -E 'REFUSED|error' "$FM_HOME/td2.out" | cut -c1-200
echo "worktree still present: $([ -d "$FM_HOME/projects/wt-probe-td" ] && echo yes || echo no)"
jq -c 'select(.guard=="teardown-unlanded") | {guard,decision,rule,task,override,cleared_by}' "$LOG" 2>/dev/null
