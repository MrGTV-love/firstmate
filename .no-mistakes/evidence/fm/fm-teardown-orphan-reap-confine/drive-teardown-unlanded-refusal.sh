#!/usr/bin/env bash
# Unlanded-work variant of drive-teardown-orphan-confine.sh (no push). Live driver: run the real bin/fm-teardown.sh against a disposable marked lab
# home (bin/fm-lab-home.sh) for one landed task, while an unrelated "abandoned
# remote job worker" (code root pruned) is alive elsewhere on the account.
#
# Usage: drive-teardown-orphan-confine.sh <firstmate-root> <label>
#   <firstmate-root>  checkout whose bin/fm-teardown.sh is exercised
#   <label>           transcript label (e.g. base / target)
#
# Prints a transcript. Records: teardown exit code, stderr/stdout, whether the
# task-scoped leaked process was reaped, whether the unrelated orphan worker
# survived, backlog row state, and whether the task meta was retired.
set -u
FMROOT=$1
LABEL=$2
GATE_ROOT=$(cd "$(dirname "$0")" && pwd)
WT_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M3V0RXGZR39620ZPQ5GHY45E

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
ORPHAN_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/fm-orphan-root.XXXXXX")
ORPHAN_PARENT=$(cd "$ORPHAN_PARENT" && pwd -P)
"$WT_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
FAKEBIN="$LAB/fakebin"; mkdir -p "$FAKEBIN"

ORPHAN_PID=""; LEAK_PID=""
cleanup() {
  [ -n "$ORPHAN_PID" ] && { kill -KILL -- "-$ORPHAN_PID" 2>/dev/null; kill -KILL "$ORPHAN_PID" 2>/dev/null; }
  [ -n "$LEAK_PID" ] && kill -KILL "$LEAK_PID" 2>/dev/null
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
  rm -rf "$LAB" "$ORPHAN_PARENT"
}
trap cleanup EXIT

echo "=== [$LABEL] teardown under test: $FMROOT/bin/fm-teardown.sh"
echo "=== [$LABEL] lab home: $LAB (marker: $(ls "$LAB/.fm-lab-home" 2>/dev/null))"

# Hermetic external stubs only (treehouse pool, forge, no-mistakes): the
# worktree here is a plain git worktree, not a real treehouse pool slot.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/treehouse"
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr view") exit 1;; esac\nexit 0\n' > "$FAKEBIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"
chmod +x "$FAKEBIN"/*

# Real git: origin, project clone under the lab's projects/, task worktree with
# a landed (pushed) commit.
P="$LAB/projects"
git init -q --bare "$P/origin.git"
git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P/origin.git" "$P/_seed" 2>/dev/null
git -C "$P/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
git -C "$P/_seed" push -q origin main; rm -rf "$P/_seed"
git clone -q "$P/origin.git" "$P/demo"
git -C "$P/demo" remote set-head origin main 2>/dev/null
git -C "$P/demo" worktree add -q -b fm/task-x1 "$LAB/wt" main
printf hello > "$LAB/wt/feature.txt"; git -C "$LAB/wt" add feature.txt; git -C "$LAB/wt" -c user.email=t@t -c user.name=t commit -q -m "unlanded work"
git -C "$P/demo" fetch -q origin

cat > "$LAB/state/task-x1.meta" <<EOF
window=firstmate:fm-task-x1
endpoint_task_id=task-x1
worktree=$LAB/wt
project=$P/demo
kind=ship
mode=no-mistakes
spawn_gen=lab-task-x1
EOF
touch "$LAB/state/.last-watcher-beat"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-x1 "lab teardown task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null

# Unrelated account-level process: a remote job worker whose code root is then
# pruned - exactly the candidate class bin/fm-remote-job-reap-orphans.sh owns.
OROOT="$ORPHAN_PARENT/pruned-root"
mkdir -p "$OROOT/bin"; : > "$OROOT/AGENTS.md"
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$OROOT/bin/fm-remote-job-worker.sh"
# Double-fork so the worker is reparented to init, like a real abandoned one.
( perl -e 'setpgrp(0,0); exec "/bin/bash", shift, "--serve" or die' "$OROOT/bin/fm-remote-job-worker.sh" </dev/null >/dev/null 2>&1 &
  echo $! > "$ORPHAN_PARENT/pid" )
sleep 0.5
ORPHAN_PID=$(cat "$ORPHAN_PARENT/pid")
rm -rf "$OROOT"
echo "=== [$LABEL] unrelated orphan worker pid=$ORPHAN_PID ppid=$(ps -p "$ORPHAN_PID" -o ppid= | tr -d ' '): $(ps -p "$ORPHAN_PID" -o command= 2>/dev/null)"
echo "=== [$LABEL] standalone reaper --dry-run sees:"
"$WT_ROOT/bin/fm-remote-job-reap-orphans.sh" --dry-run | sed 's/^/    /'

# Task-scoped leaked process (cwd under the task worktree): must still be reaped.
( cd "$LAB/wt" && exec sleep 300 ) &
LEAK_PID=$!; disown
sleep 0.3

# Real tmux on the lab's private socket holds the task window; teardown runs
# inside that server so its tmux calls hit the lab socket only.
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n fm-task-x1 'sleep 600'
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t firstmate -n driver 'sleep 600'
echo "=== [$LABEL] lab tmux windows before: $(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t firstmate -F '#W' | tr '\n' ' ')"

RUNNER="$LAB/run.sh"
cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
cd "$P/demo"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$FAKEBIN:\$PATH" \
  "$FMROOT/bin/fm-teardown.sh" task-x1 > "$LAB/out" 2> "$LAB/err"
echo \$? > "$LAB/rc"
EOF
chmod +x "$RUNNER"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t firstmate -n runner "$RUNNER"
for _ in $(seq 1 600); do [ -f "$LAB/rc" ] && break; sleep 0.1; done

echo "=== [$LABEL] teardown exit code: $(cat "$LAB/rc" 2>/dev/null || echo TIMEOUT)"
echo "=== [$LABEL] teardown stderr:"; sed 's/^/    /' "$LAB/err"
echo "=== [$LABEL] teardown stdout:"; sed 's/^/    /' "$LAB/out"
echo "=== [$LABEL] lab tmux windows after: $(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')"
if kill -0 "$LEAK_PID" 2>/dev/null; then echo "RESULT [$LABEL] task-scoped leaked process: SURVIVED"; else echo "RESULT [$LABEL] task-scoped leaked process: REAPED"; LEAK_PID=""; fi
if kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "RESULT [$LABEL] unrelated account orphan worker: UNTOUCHED (alive)"; else echo "RESULT [$LABEL] unrelated account orphan worker: KILLED by task teardown"; ORPHAN_PID=""; fi
echo "RESULT [$LABEL] backlog row state: $(tasks-axi show task-x1 --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)"
if [ -e "$LAB/state/task-x1.meta" ]; then echo "RESULT [$LABEL] task meta: retained"; else echo "RESULT [$LABEL] task meta: retired"; fi

if [ -n "$ORPHAN_PID" ] && [ "${DRIVE_STANDALONE:-0}" = 1 ]; then
  echo "=== [$LABEL] explicit admin command: bin/fm-remote-job-reap-orphans.sh"
  t0=$(date +%s)
  "$WT_ROOT/bin/fm-remote-job-reap-orphans.sh" 2>&1 | sed 's/^/    /'
  echo "    exit=${PIPESTATUS[0]} elapsed=$(( $(date +%s) - t0 ))s"
  sleep 0.5
  if kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "RESULT [$LABEL] standalone reaper: orphan SURVIVED"; else echo "RESULT [$LABEL] standalone reaper: orphan REAPED"; ORPHAN_PID=""; fi
fi
