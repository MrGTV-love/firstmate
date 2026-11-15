#!/usr/bin/env bash
# live driver: real bin/fm-teardown.sh, real git, real treehouse (disposable TREEHOUSE_ROOT),
# real tmux on the lab's private socket, real tasks-axi; stubs only for gh, gh-axi, no-mistakes (external services).
set -u
REPO=$1; W=$2; label=$3; variant=$4; claim=$5; shape=${6:-plain}
C=$W/$label; mkdir -p $C/stubs
export TREEHOUSE_ROOT=$C/pool
for s in gh gh-axi; do printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "count: 0 (showing first 0)\\npull_requests[]: []\\n";; "pr view") echo "not found" >&2; exit 1;; esac\nexit 0\n' > $C/stubs/$s; done
printf '#!/usr/bin/env bash\nexit 0\n' > $C/stubs/no-mistakes; chmod +x $C/stubs/*
git init -q --bare -b main $C/origin.git
git clone -q $C/origin.git $C/project 2>/dev/null
git -C $C/project -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '.claude/\n' > $C/project/.gitignore; git -C $C/project add .gitignore
git -C $C/project -c user.email=t@t -c user.name=t commit -q -m ignore; git -C $C/project push -q origin main
SLOT=$(cd $C/project && treehouse get --lease 2>$C/get.err) || { cat $C/get.err; exit 9; }
SLOT=$(cd "$SLOT" && pwd -P)
COPY=$SLOT/.claude/worktrees/task-x1-v2; mkdir -p ${COPY%/*}
git -C $C/project worktree add -q -b fm/task-x1-v2 $COPY origin/main
case $claim in mine) printf 'task=task-x1\nhome=%s\n' "$FM_HOME" > $(dirname $SLOT)/.fm-slot-owner;;
  other) printf 'task=other-task\nhome=%s\n' "$FM_HOME" > $(dirname $SLOT)/.fm-slot-owner;; esac
case $variant in
  slot-unlanded) echo w > $SLOT/slot.txt; git -C $SLOT add slot.txt; git -C $SLOT -c user.email=t@t -c user.name=t commit -qm "slot work";;
  copy-dirty) echo d > $COPY/dirty.txt; git -C $COPY add dirty.txt;;
esac
S=$FM_HOME/state; mkdir -p $S/task-x1.inbox $C/tasktmp $FM_HOME/data
printf 'steer\n' > $S/task-x1.inbox/001.msg; printf 'working\n' > $S/task-x1.status; echo s > $C/tasktmp/scratch.txt
{ echo "window=firstmate:fm-task-x1"; echo "endpoint_task_id=task-x1"; echo "worktree=$COPY"; echo "branch=fm/task-x1-v2"
  echo "project=$C/project"; echo "kind=ship"; echo "mode=no-mistakes"; echo "spawn_gen=live-gen-1"; echo "tasktmp=$C/tasktmp"
  [ $shape = prior ] && echo "prior_worktree=$SLOT"; } > $S/task-x1.meta
printf 'id=task-x1\ndata=%s\nspawn_gen=live-gen-1\ncleanup_incomplete=0\narg=--note\narg=dropped\n' "$FM_HOME/data" > $S/task-x1.backlog-close
printf 'spawn_gen=live-gen-1\nslot=\n' > $S/task-x1.teardown-return-pending
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > $FM_HOME/data/backlog.md
tasks-axi add task-x1 "live fixture" --kind ship --file $FM_HOME/data/backlog.md >/dev/null; tasks-axi start task-x1 --file $FM_HOME/data/backlog.md >/dev/null
tmux kill-server 2>/dev/null; tmux new-session -d -s firstmate -n fm-task-x1 "sleep 3600"
printf 'The captain said this copy may be dropped.\n' > $C/drop.txt
echo "SLOT=$SLOT" > $C/vars; echo "COPY=$COPY" >> $C/vars
