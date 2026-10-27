#!/usr/bin/env bash
# tests/fm-merge-prune.test.sh - bin/fm-merge-prune.sh and bin/fm-merge-prune-lib.sh.
#
# A merged task's pool copy must be pruned right after its PR merges, with no
# human step, and an unsafe copy must never be removed. This suite drives the
# real scripts against a fake pool in a temp directory: a throwaway
# TREEHOUSE_ROOT, bare origins, pool copies that are linked git worktrees of a
# project clone with the pool's treehouse-state.json beside them (the way
# treehouse lays them out), and a stub `treehouse` first on PATH that records its
# arguments and removes the fake directory. The real treehouse binary and the real ~/.treehouse are never
# touched; the stub proves only the CALL SHAPE the fallback makes
# (`treehouse destroy <copy> --include-leased --yes`), not how the real tool
# behaves.
#
# Sections:
#   1. arming and the due-time rules
#   2. orchestration against a stub teardown: transient refusals back off and then
#      succeed, one wake for a retained copy, nothing forced
#   3. the provable-scratch fallback against the fake pool: what is removed and
#      what is kept
#   4. mutation proof both ways: each safety proof, broken, makes a keep case
#      fail; each permission, broken, makes a removal case fail
#   5. the merge path end to end through bin/fm-pr-merge.sh and the real teardown
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_HOME
fm_git_identity fmtest fmtest@example.invalid
# tests/lib.sh turns arming off for every other suite; this one tests it.
export FM_MERGE_PRUNE=1

TMP_ROOT=$(fm_test_tmproot fm-merge-prune)
NOW=$(date +%s)
OLD=$((NOW - 7200))
PR=https://github.com/acme/widget/pull/7
BIN_DIR="$ROOT/bin"
WN=0
SCN_WHY=
WORKER_PIDS=()

cleanup_workers() {
  local pid kids
  for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
    kids=$(pgrep -P "$pid" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
    # shellcheck disable=SC2086 # Word splitting is the point: one pid per word.
    [ -z "$kids" ] || kill $kids 2>/dev/null || true
  done
  WORKER_PIDS=()
}
trap cleanup_workers EXIT

# --- the fake pool ------------------------------------------------------------

# make_world builds one isolated world and sets W, HOME_DIR, STATE, DATA, POOL,
# ORIGIN and COPY (the task's pool copy: <pool root>/pool1/1/repo, a linked
# worktree of the task's project, the clone $W/project, with the pool's
# treehouse-state.json at <pool root>/pool1). The project ignores .claude/
# unless IGNORE_CLAUDE=0 is set, which leaves a clone under .claude/worktrees
# visible to `git status` as an untracked directory.
make_world() {
  local seed
  WN=$((WN + 1))
  W="$TMP_ROOT/w$WN"
  HOME_DIR="$W/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  POOL="$W/th"
  ORIGIN="$W/origin.git"
  COPY="$POOL/pool1/1/repo"
  mkdir -p "$STATE" "$DATA" "$HOME_DIR/config" "$POOL/pool1/1" "$W/bin" "$W/fakehome"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  seed="$W/seed"
  git clone -q "$ORIGIN" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main
  printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.tac/' '.mypy_cache/' '*.local' > "$seed/.gitignore"
  [ "${IGNORE_CLAUDE:-1}" = 0 ] || printf '%s\n' '.claude/' >> "$seed/.gitignore"
  printf 'readme\n' > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m base
  git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$ORIGIN" "$W/project" 2>/dev/null
  git -C "$W/project" worktree add -q -b fm/t1 "$COPY" origin/main
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t1"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
  printf 'work\n' > "$COPY/work.txt"
  git -C "$COPY" add work.txt
  git -C "$COPY" commit -q -m "task work"
  git -C "$COPY" push -q origin fm/t1
  squash_merge_into_main "$COPY"
  install_stubs
  mk_task t1 "$COPY"
}

# The task's PR is squash-merged: origin/main gets one new commit with exactly
# the tree of <copy>'s HEAD, which is not a commit of the task's branch.
squash_merge_into_main() {  # <copy>
  local squash
  squash=$(git -C "$1" commit-tree 'HEAD^{tree}' -p "$(git -C "$1" rev-parse origin/main)" -m "task work (#7)")
  git -C "$1" push -q origin "$squash:refs/heads/main"
  git -C "$1" fetch -q origin
}

install_stubs() {
  cat > "$W/bin/treehouse" <<'SH'
#!/usr/bin/env bash
# Stand-in for treehouse. It accepts exactly the call the reaper makes and
# removes the fake directory; every other call is logged and refused. Like the
# real tool it refuses a copy that has a process working inside it and a leased
# slot that is not merged (th-gate).
printf '%s\n' "$*" >> "$TH_LOG"
if [ "${1:-}" = destroy ] && [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ]; then
  case "$2" in
    "$TREEHOUSE_ROOT"/*/*/*) ;;
    *) echo "stub treehouse: $2 is outside the fake pool" >&2; exit 3 ;;
  esac
  [ ! -s "$TH_FAIL" ] || { echo "stub treehouse: destroy refused" >&2; exit 4; }
  "$(dirname "$0")/th-gate" "$2" || exit 1
  "$(dirname "$0")/th-remove" "$2"
  exit 0
fi
echo "stub treehouse: unexpected arguments: $*" >&2
exit 9
SH
  cat > "$W/bin/th-remove" <<'SH'
#!/usr/bin/env bash
# Removes a destroyed slot the way `treehouse destroy` does: the directory and
# the project's registration of that linked worktree.
common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
rm -rf "$1"
[ -z "$common" ] || git --git-dir="$common" worktree prune 2>/dev/null || true
exit 0
SH
  cat > "$W/bin/th-gate" <<'SH'
#!/usr/bin/env bash
# What the real `treehouse destroy <slot> --include-leased --yes` checks before
# it removes a leased slot, in the real tool's words: a process with its working
# directory inside the slot (the system lsof, not a fixture's; a process that
# only has a file open there does not block it), a dirty slot (any line of
# `git status --porcelain`, a nested clone's untracked directory included), and
# work that is not merged. A slot counts as merged when its HEAD is on
# origin/main or its tree is exactly origin/main's tree (a squash merge).
copy=$1
inuse=$(command -p lsof -a -d cwd +D "$copy" -t 2>/dev/null | sort -u | tr '\n' ' ')
if [ -n "${inuse// /}" ]; then
  echo "Skipped 1 worktree: [in-use:${inuse%% *}] $copy" >&2
  echo "did not destroy 1 (in-use); re-run with --include-in-use" >&2
  exit 1
fi
if [ -n "$(git -C "$copy" status --porcelain 2>/dev/null)" ]; then
  echo "Skipped 1 worktree: [leased,dirty] $copy re-run with --include-unlanded to include" >&2
  exit 1
fi
merged=0
if git -C "$copy" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  merged=1
else
  head_tree=$(git -C "$copy" rev-parse 'HEAD^{tree}' 2>/dev/null) \
    && main_tree=$(git -C "$copy" rev-parse 'origin/main^{tree}' 2>/dev/null) \
    && [ "$head_tree" = "$main_tree" ] && merged=1
fi
if [ "$merged" != 1 ]; then
  echo "Skipped 1 worktree: [leased,unmerged] $copy" >&2
  echo "did not destroy 1 (leased); re-run with --include-unlanded" >&2
  exit 1
fi
exit 0
SH
  cat > "$W/bin/teardown-stub" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-teardown.sh. Records how it was called, then behaves as
# the mode file says.
printf 'args=%s|admission=%s|prune=%s\n' "$*" "${FM_IDLE_REAP_ADMISSION:-}" "${FM_IDLE_REAP_MERGE_PRUNE:-}" >> "$STUB_LOG"
mode=$(cat "$STUB_MODE" 2>/dev/null || echo ok)
copy=$(sed -n 's/^worktree=//p' "$FM_STATE_OVERRIDE/$1.meta" 2>/dev/null)
# A completed teardown returns the slot the way `treehouse return` does: it
# releases the slot's lease in the pool's treehouse-state.json. A teardown that
# keeps the slot (shared with another task, or held for foreign copies) leaves
# the lease as it is (ok-keeps-lease).
release_lease() {
  local st="${copy%/*/*}/treehouse-state.json" tmp
  [ -n "$copy" ] && [ -f "$st" ] || return 0
  tmp=$(mktemp "$st.XXXXXX") && jq --arg p "$copy" '.worktrees |= map(if .path == $p then (.leased = false | del(.lease_holder)) else . end)' "$st" > "$tmp" && mv -f "$tmp" "$st"
}
done_ok() { [ "$mode" = ok-keeps-lease ] || release_lease; rm -f "$FM_STATE_OVERRIDE/$1.meta"; exit 0; }
case "$mode" in
  ok|ok-keeps-lease) rm -f "$FM_STATE_OVERRIDE/$1.status"; done_ok "$1" ;;
  flaky)
    n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
    printf '%s\n' $((n + 1)) > "$STUB_COUNT"
    [ "$n" -ge 1 ] || exit 75
    done_ok "$1"
    ;;
  # Real teardown ends the agent working in the copy before it returns the slot.
  ok-ends-agents)
    for pid in $(command -p lsof -a -d cwd +D "$copy" -t 2>/dev/null | sort -u); do kill "$pid" 2>/dev/null; done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -z "$(command -p lsof -a -d cwd +D "$copy" -t 2>/dev/null)" ] && break
      sleep 1
    done
    rm -f "$FM_STATE_OVERRIDE/$1.status"; done_ok "$1" ;;
  lock) exit 75 ;;
  lease) exit 6 ;;
  timeout) exit 124 ;;
  ineligible) echo "REFUSED: automatic reap ineligible: active: busy state busy" >&2; exit 1 ;;
  lifecycle) echo "error: another lifecycle action is already running for task $1; nothing was changed" >&2; exit 1 ;;
  pipeline) echo "REFUSED: no-mistakes run for $1 is still parked after axi abort" >&2; exit 1 ;;
  false-positive|ship-not-landed|closeout-own)
    # The two refusal classes that reach the fallback, in the words of
    # bin/fm-teardown.sh and bin/fm-teardown-nested-lib.sh; they stop once the
    # copy is gone.
    if [ -e "$copy" ]; then
      case "$mode" in
        false-positive) echo "REFUSED: Vernant's closeout driver did not release foreign copy $copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2 ;;
        closeout-own) echo "REFUSED: Vernant's closeout driver did not release own nested copy $copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2 ;;
        ship-not-landed)
          echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." >&2
          echo "Land its PR, or get the captain's own words to drop it and pass --force --drop-file." >&2
          ;;
      esac
      exit 1
    fi
    done_ok "$1"
    ;;
  # An orphan nested copy refused for a HEAD that is not proved landed: teardown
  # (bin/fm-teardown-nested-lib.sh teardown_foreign_copies_prove, then bin/
  # fm-teardown.sh require_registered_slot_copies) always prints both lines.
  foreign-head)
    echo "REFUSED: foreign copy $copy/.claude/worktrees/n1 stays in pool slot $copy: its HEAD 0123456789ab is not proved landed." >&2
    echo "REFUSED: pool slot $copy contains registered copy $copy/.claude/worktrees/n1 that is not one of task $1's proven copies; its record and lease must stay in place, even with --force." >&2
    exit 1
    ;;
  # Refusals that are not landing refusals, in the words of bin/fm-teardown.sh.
  leaked-worktree) echo "REFUSED: leaked worktree processes for $1 remain after 3 reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2; exit 1 ;;
  leaked-tasktmp) echo "REFUSED: leaked tasktmp processes for $1 remain after 3 reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2; exit 1 ;;
  launchd-loaded) echo "REFUSED: no-mistakes launch agent com.example.nm.$1 (rooted in $1's copy) is still loaded after launchctl bootout; preserving the worktree and /tmp/agent.plist." >&2; exit 1 ;;
  ownership-unproven) echo "REFUSED: process 4242 (identity unavailable) matched path $copy/.claude/worktrees/n1 beneath scan root $copy, whose ownership by $1 is not proven; preserving it and task $1 without signalling." >&2; exit 1 ;;
  unknown-new) echo "REFUSED: a refusal text that teardown did not have when this list was written" >&2; exit 1 ;;
  mixed)
    echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." >&2
    echo "REFUSED: leaked worktree processes for $1 remain after 3 reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
    exit 1
    ;;
esac
SH
  cat > "$W/bin/control-stub" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-control.sh exit: stops the finished worker's session. Like
# the real verb it leaves the terminal pane open, records the deliberate exit in
# state/<id>.control-exit and retires the busy record (the real retire). When
# STOP_FAIL_FILE has content the agent is reported as not stopped and nothing
# changes. When STEAL_FILE names a task, a launch for that task takes the slot
# the stopped worker freed.
printf '%s\n' "$*" >> "$CONTROL_LOG"
[ ! -s "$STOP_FAIL_FILE" ] || exit 1
if [ -s "$WORKER_PID_FILE" ]; then
  kill "$(cat "$WORKER_PID_FILE")" 2>/dev/null || true
fi
gen=$(cat "$FM_STATE_OVERRIDE/$1.busy-gen" 2>/dev/null || true)
printf 'gen=%s\n' "${gen:--}" > "$FM_STATE_OVERRIDE/$1.control-exit"
[ -z "$gen" ] || "$BUSY_EVENT_BIN" retire "$FM_STATE_OVERRIDE" "$1" --gen "$gen" >/dev/null 2>&1
if [ -s "$STEAL_FILE" ]; then
  printf 'task=%s\nhome=/elsewhere\n' "$(cat "$STEAL_FILE")" > "$SLOT_MARKER"
fi
exit 0
SH
  cat > "$W/bin/tmux" <<'SH'
#!/usr/bin/env bash
# Stand-in for tmux: answers the question for the pane's shell pid, and a
# capture with the content of PANE_TAIL_FILE.
case "$*" in
  *'#{pane_pid}'*) [ -s "$PANE_PID_FILE" ] && cat "$PANE_PID_FILE" ;;
  capture-pane*) [ -s "${PANE_TAIL_FILE:-}" ] && cat "$PANE_TAIL_FILE" ;;
esac
exit 0
SH
  cat > "$W/bin/herdr" <<'SH'
#!/usr/bin/env bash
# Stand-in for herdr: answers only `pane process-info` for pane t1.
case "$*" in
  "pane process-info --pane t1 "*)
    [ -s "$PANE_PID_FILE" ] || exit 1
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"t1","shell_pid":%s}}}\n' "$(cat "$PANE_PID_FILE")"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$W/bin/pane-idle" <<'SH'
#!/usr/bin/env bash
# An idle shell: blocked opening a FIFO nobody writes, so it has no child process.
read -r _ < "$1"
SH
  cat > "$W/bin/pane-returns-slot" <<'SH'
#!/usr/bin/env bash
# The idle `treehouse get` subshell of a pane. Like the real one it returns the
# slot to the pool when it ends: the slot is reset to a detached origin/main, so
# nothing is unmerged in it any more (th-gate counts it merged).
trap 'git -C "$2" checkout -q --detach origin/main; exit 0' HUP
read -r _ < "$1"
SH
  cat > "$W/bin/pane-stubborn" <<'SH'
#!/usr/bin/env bash
# An idle shell that ignores SIGHUP.
trap '' HUP
read -r _ < "$1"
SH
  cat > "$W/bin/pane-holder" <<'SH'
#!/usr/bin/env bash
# An idle shell that works elsewhere but holds a file of the copy open.
cd "$2" || exit 1
exec 3< "$1"
read -r _ < "$3"
SH
  cat > "$W/bin/pane-busy" <<'SH'
#!/usr/bin/env bash
# A shell running a job that works elsewhere: the job is its child process.
(cd / && exec sleep 300) &
wait
SH
  chmod +x "$W/bin/treehouse" "$W/bin/th-gate" "$W/bin/th-remove" "$W/bin/teardown-stub" "$W/bin/control-stub" "$W/bin/tmux" "$W/bin/herdr" \
    "$W/bin/pane-idle" "$W/bin/pane-returns-slot" "$W/bin/pane-busy" "$W/bin/pane-stubborn" "$W/bin/pane-holder"
  mkfifo "$W/hold"
  : > "$W/th.log"; : > "$W/stub.log"; : > "$W/control.log"; : > "$W/th.fail"
  printf 'false-positive\n' > "$W/stub.mode"
}

# mk_task <id> <copy>: a finished ship whose merge was verified, a day old.
mk_task() {
  local id=$1 copy=$2
  fm_write_meta "$STATE/$id.meta" "window=w:$id" "kind=ship" "harness=claude" "backend=herdr" \
    "worktree=$copy" "project=$W/project" "pr=$PR"
  printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$STATE/$id.status"
  printf 'g1.1.1\n' > "$STATE/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/$id.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$STATE/$id.pr-poll-merge-notified"
  chmod 0600 "$STATE/$id.pr-poll-merge-notified"
  fm_touch_epoch "$OLD" "$STATE/$id.pr-poll-merge-notified"
}

# prune <args...>: run the script under test (BIN_DIR) inside the current world.
prune() {
  HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" \
    TH_LOG="$W/th.log" TH_FAIL="$W/th.fail" STUB_LOG="$W/stub.log" STUB_MODE="$W/stub.mode" \
    STUB_COUNT="$W/stub.count" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" \
    PANE_PID_FILE="$W/pane.pid" STEAL_FILE="$W/steal" SLOT_MARKER="$POOL/pool1/1/.fm-slot-owner" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" \
    FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-stub" FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" \
    FM_MERGE_PRUNE_EXIT_WAIT="${EXIT_WAIT:-0}" \
    "$BIN_DIR/fm-merge-prune.sh" "$@"
}

rec_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$STATE/$1.merge-prune" 2>/dev/null | sed -n 1p
}

set_rec() {  # <id> <key> <value>
  local tmp="$STATE/.rec.tmp"
  sed "s/^$2=.*/$2=$3/" "$STATE/$1.merge-prune" > "$tmp" && mv -f "$tmp" "$STATE/$1.merge-prune"
}

# Wakes that say a copy stays; a reaped outcome is a wake of its own (reaped_wake_count).
wake_count() {
  local n
  n=$(grep 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null | grep -vc ' reaped ') || n=0
  printf '%s' "$n"
}

reaped_wake_count() {
  local n
  n=$(grep 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null | grep -c ' reaped ') || n=0
  printf '%s' "$n"
}

stub_calls() { wc -l < "$W/stub.log" | tr -d ' '; }
destroy_calls() { grep -c '^destroy ' "$W/th.log" 2>/dev/null || true; }

# A process that works inside a directory, like a finished worker's session or a
# stray editor. The pid is recorded so the stub control can stop the worker.
start_inside() {  # <dir> <pidfile-or-empty>
  local pid
  (cd "$1" && exec sleep 300) &
  pid=$!
  WORKER_PIDS+=("$pid")
  [ -z "$2" ] || printf '%s\n' "$pid" > "$2"
}

# A stand-in terminal pane whose agent has exited, shaped like a real one: the
# pane's shell runs `treehouse get` (a stand-in named treehouse, working outside
# the copy), which starts <command...> with <dir> as its working directory, as
# the real one opens the slot's subshell, and stays its parent (PANE_CHILD). The
# pane process id is what tmux and herdr report as the pane's shell; the
# launcher ends when its child ends, and the pane stays open, an idle shell.
PANE_CHILD=
start_pane() {  # <dir> <command...>
  local dir=$1 pid launcher
  shift
  if [ ! -e "$W/th/get" ]; then
    mkdir -p "$W/th"
    ln -s "$(command -v bash)" "$W/th/treehouse"
    # shellcheck disable=SC2016 # The single-quoted lines are the stand-in's own source.
    printf '%s\n' '# Stand-in for `treehouse get`: opens <command...> in <dir> and stays its parent.' \
      'dir=$1; shift' '(cd "$dir" && exec "$@") &' 'wait' > "$W/th/get"
  fi
  PATH="$W/th:$PATH" bash -c 'cd "$1" || exit 1; shift; treehouse get "$@"; read -r _ < "$0"' "$W/hold" "$W/th" "$dir" "$@" 2>/dev/null &
  pid=$!
  WORKER_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$W/pane.pid"
  # shellcheck disable=SC2016 # The single-quoted sh -c body expands in the child shell.
  fm_test_wait_until 10 sh -c 'l=$(pgrep -P "$1" | sed -n 1p); [ -n "$l" ] && [ -n "$(pgrep -P "$l")" ]' _ "$pid" || true
  launcher=$(pgrep -P "$pid" | sed -n 1p)
  PANE_CHILD=$(pgrep -P "$launcher" | sed -n 1p)
  WORKER_PIDS+=("$launcher" "$PANE_CHILD")
  wait_inside "$dir"
}

# The worker's agent still running in the pane: a process named claude inside
# the copy. It runs tests/lib.sh fm_agent_standin, not the host sleep, which a
# multicall coreutils (Ubuntu 26.04) refuses to run under a foreign name.
start_pane_agent() {
  local standin
  standin=$(fm_agent_standin "$W/standin") || return 1
  mkdir -p "$W/agent"
  ln -s "$standin" "$W/agent/claude"
  start_pane "$COPY" "$W/agent/claude"
}

# An idle shell inside <dir> that no pane started (STRAY_SHELL).
STRAY_SHELL=
start_stray_shell() {  # <dir>
  (cd "$1" && exec bash "$W/bin/pane-idle" "$W/hold") &
  STRAY_SHELL=$!
  WORKER_PIDS+=("$STRAY_SHELL")
  wait_inside "$1"
}

wait_inside() {  # <dir>: until some process works inside it
  # shellcheck disable=SC2016 # The single-quoted sh -c body expands in the child shell.
  fm_test_wait_until 10 sh -c '[ -n "$(lsof -t +D "$1" 2>/dev/null)" ]' _ "$1" || true
}

# The task's terminal pane lives on <tmux|herdr>; the world starts on herdr.
use_pane_backend() {  # <tmux|herdr>
  [ "$1" != tmux ] || sed -i.bak -e 's/^backend=.*/backend=tmux/' -e 's#^window=.*#window=firstmate:fm-t1#' "$STATE/t1.meta"
}

project_lock_path() {
  FM_HOME="$HOME_DIR" bash -c '. "$1/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$BIN_DIR" "$W/project"
}

kill_tree() {  # <pid>: the process and everything below it
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$1" 2>/dev/null || true
}

why() { SCN_WHY=$1; return 1; }

# go: arm the task (once) and make one forced attempt, as the merge path does.
# go: arm the task (once) and make one forced attempt, as the merge path does.
go() {
  [ -e "$STATE/t1.merge-prune" ] || prune arm t1 >/dev/null 2>&1
  prune run t1 --now >/dev/null 2>&1
}

# --- scenarios: each returns 0 when the contract holds, else sets SCN_WHY --------
# A scenario builds its own world and runs against BIN_DIR, so the mutation
# section can run the very same scenario against a deliberately broken copy.

scn_scratch_copy_is_removed() {
  local sums f
  make_world
  mkdir -p "$COPY/.venv/lib" "$COPY/node_modules/p" "$COPY/__pycache__" "$COPY/.mypy_cache" \
    "$COPY/.claude/bug-evidence" "$COPY/.claude/channel-outbox" "$COPY/.tac/tmp" "$COPY/.tac/uv-cache"
  printf x > "$COPY/.venv/lib/x.py"; printf x > "$COPY/node_modules/p/i.js"; printf x > "$COPY/__pycache__/a.pyc"
  printf x > "$COPY/.mypy_cache/m"; printf x > "$COPY/.DS_Store"; printf x > "$COPY/.tac/tmp/t"; printf x > "$COPY/.tac/uv-cache/c"
  printf '{}' > "$COPY/.claude/settings.local.json"
  printf 'evidence-one\n' > "$COPY/.claude/bug-evidence/ev1.json"
  printf 'rate-one\n' > "$COPY/.claude/channel-outbox/rate.json"
  ln -s /nonexistent "$COPY/.venv/link"
  printf 'task=t1\nhome=%s\n' "$HOME_DIR" > "$POOL/pool1/1/.fm-slot-owner"
  cp "$STATE/t1.status" "$W/status.before"
  start_inside "$COPY" "$W/worker.pid"
  EXIT_WAIT=3 go || why "run exited nonzero" || return 1
  [ ! -e "$COPY" ] || why "the clean scratch copy was not removed" || return 1
  [ "$(destroy_calls)" = 1 ] || why "treehouse destroy was called $(destroy_calls) times" || return 1
  [ "$(sed -n 1p "$W/th.log")" = "destroy $COPY --include-leased --yes" ] \
    || why "treehouse was called as: $(cat "$W/th.log")" || return 1
  if grep -Eq -- '--force|--include-unlanded|--include-in-use' "$W/th.log" "$W/stub.log"; then
    why "something was forced" || return 1
  fi
  [ ! -e "$STATE/t1.merge-prune" ] || why "the prune record outlived the reap" || return 1
  grep -q 'reaped' "$DATA/t1/merge-prune.log" || why "the log does not say reaped" || return 1
  grep -q 'fallback destroyed' "$DATA/t1/merge-prune.log" || why "the log does not say the fallback destroyed the copy" || return 1
  cmp -s "$W/status.before" "$STATE/t1.status" || why "the prune wrote to the task's status file: $(cat "$STATE/t1.status")" || return 1
  [ ! -e "$(project_lock_path)" ] || why "the project lock outlived the attempt" || return 1
  [ "$(wake_count)" = 0 ] || why "a reaped copy raised a wake" || return 1
  [ -s "$W/control.log" ] || why "the finished worker was not stopped by 't1 exit': $(cat "$W/control.log")" || return 1
  ! grep -qvx 't1 exit' "$W/control.log" || why "the finished worker was not stopped by 't1 exit': $(cat "$W/control.log")" || return 1
  f=$(find "$DATA/t1/merge-prune-preserved" -path '*/root/.claude/bug-evidence/ev1.json' 2>/dev/null | sed -n 1p)
  [ -n "$f" ] && [ "$(cat "$f")" = evidence-one ] || why "the bug-evidence record was not preserved" || return 1
  f=$(find "$DATA/t1/merge-prune-preserved" -path '*/root/.claude/channel-outbox/rate.json' 2>/dev/null | sed -n 1p)
  [ -n "$f" ] && [ "$(cat "$f")" = rate-one ] || why "the channel-outbox rate file was not preserved" || return 1
  sums=$(find "$DATA/t1/merge-prune-preserved" -name SHA256SUMS | sed -n 1p)
  [ -n "$sums" ] && [ "$(wc -l < "$sums" | tr -d ' ')" = 2 ] || why "the checksum manifest does not list both records" || return 1
  (cd "$(dirname "$sums")" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || why "the checksums do not verify" || return 1
  [ "$(stub_calls)" = 2 ] || why "teardown ran $(stub_calls) times, want refusal then completion" || return 1
  grep -q '^args=t1|admission=1|prune=1$' "$W/stub.log" || why "teardown was not called as 't1' with the admission markers: $(cat "$W/stub.log")" || return 1
  return 0
}

scn_changed_file_is_kept() {
  make_world
  printf 'edited\n' >> "$COPY/README.md"
  cp "$STATE/t1.status" "$W/status.before"
  go
  [ -e "$COPY/README.md" ] || why "the copy with a changed file was removed" || return 1
  [ "$(destroy_calls)" = 0 ] || why "destroy was called on a copy with a changed file" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'changed or untracked' || why "the wake does not name the copy and the reason" || return 1
  go; go
  [ "$(wake_count)" = 1 ] || why "repeat attempts raised more wakes: $(wake_count)" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the record is not retained" || return 1
  grep -q 'retained' "$DATA/t1/merge-prune.log" || why "the log does not say retained" || return 1
  cmp -s "$W/status.before" "$STATE/t1.status" || why "the prune wrote to the task's status file: $(cat "$STATE/t1.status")" || return 1
  return 0
}

scn_untracked_file_is_kept() {
  make_world
  printf 'mine\n' > "$COPY/new-file.txt"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with an untracked file was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# Git config can hide what a plain `git status` prints: with
# status.showUntrackedFiles=no an untracked file prints nothing, and with
# diff.ignoreSubmodules=all a changed submodule prints nothing. The dirty-file
# proof must see both whatever the config says, in the task's own copy and in a
# nested copy. The fixture checks that the config really hides the work, so a
# passing result is not a fixture that never held any.
scn_hidden_untracked_file_is_kept() {  # <root|nested>
  local where
  make_world
  where=$COPY
  if [ "$1" = nested ]; then
    make_nested .claude/worktrees/n1
    where="$COPY/.claude/worktrees/n1"
  fi
  git -C "$where" config status.showUntrackedFiles no
  printf 'mine\n' > "$where/new-file.txt"
  [ -z "$(git -C "$where" status --porcelain)" ] || why "the fixture's git config does not hide the untracked file" || return 1
  [ -n "$(git -C "$where" status --porcelain --untracked-files=all)" ] || why "the fixture has no untracked file" || return 1
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy ($1) holding an untracked file that git config hides was removed" || return 1
  [ -e "$where/new-file.txt" ] || why "the untracked file ($1) was lost" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although an untracked file ($1) was left" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$where" "$STATE/.wake-queue" | grep -q 'changed or untracked' || why "the wake does not name the copy and the untracked file" || return 1
  return 0
}
scn_hidden_untracked_file_is_kept_in_the_copy() { scn_hidden_untracked_file_is_kept root; }
scn_hidden_untracked_file_is_kept_in_a_nested_copy() { scn_hidden_untracked_file_is_kept nested; }

scn_hidden_submodule_change_is_kept() {
  make_world
  git init -q "$W/sub-origin"
  git -C "$W/sub-origin" commit -q --allow-empty -m "sub base"
  git -C "$COPY" -c protocol.file.allow=always submodule add -q "$W/sub-origin" sub >/dev/null 2>&1 || why "the fixture's submodule could not be added" || return 1
  git -C "$COPY" commit -q -m "add the submodule"
  git -C "$COPY" push -q origin fm/t1
  squash_merge_into_main "$COPY" >/dev/null 2>&1
  git -C "$COPY/sub" commit -q --allow-empty -m "work inside the submodule"
  git -C "$COPY" config diff.ignoreSubmodules all
  [ -z "$(git -C "$COPY" status --porcelain)" ] || why "the fixture's git config does not hide the changed submodule" || return 1
  [ -n "$(git -C "$COPY" status --porcelain --ignore-submodules=none)" ] || why "the fixture has no changed submodule" || return 1
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy holding a changed submodule that git config hides was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although a submodule was changed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'changed or untracked' || why "the wake does not name the copy and the changed submodule" || return 1
  return 0
}

scn_unpushed_commit_is_kept() {
  make_world
  printf 'later\n' > "$COPY/later.txt"
  git -C "$COPY" add later.txt
  git -C "$COPY" commit -q -m "unpushed"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with an unpushed commit was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the copy and the unpushed commit" || return 1
  return 0
}

scn_stash_is_kept() {
  make_world
  printf 'wip\n' >> "$COPY/README.md"
  git -C "$COPY" stash -q
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy holding a stash entry was removed" || return 1
  return 0
}

scn_live_process_is_kept() {
  make_world
  start_inside "$COPY" ""
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with a live process inside was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process" || return 1
  return 0
}

# A nested copy: a second clone inside the task's copy, under an ignored tree.
make_nested() {  # <rel>
  git clone -q "$ORIGIN" "$COPY/$1" 2>/dev/null
}

scn_nested_unpushed_commit_keeps_the_slot() {
  make_world
  make_nested .claude/worktrees/n1
  printf 'orphan\n' > "$COPY/.claude/worktrees/n1/orphan.txt"
  git -C "$COPY/.claude/worktrees/n1" add orphan.txt
  git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed in nested"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "an unpushed nested commit did not keep the slot" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY/.claude/worktrees/n1" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the nested copy" || return 1
  return 0
}

# Teardown would succeed here and return the slot, nested copy and all, to the
# pool, so the nested proof runs before teardown: an independent clone or a
# linked worktree of the project with an unpushed commit keeps the whole slot
# with one wake, and teardown never runs.
scn_nested_unpushed_commit_keeps_the_slot_before_teardown() {  # <clone|worktree>
  local n
  make_world
  printf 'ok\n' > "$W/stub.mode"
  n="$COPY/.claude/worktrees/n1"
  case "$1" in
    clone) make_nested .claude/worktrees/n1 ;;
    worktree) git -C "$W/project" worktree add -q -b fm/n1 "$n" origin/main ;;
  esac
  printf 'orphan\n' > "$n/orphan.txt"
  git -C "$n" add orphan.txt
  git -C "$n" commit -q -m "unpushed in nested"
  go
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" = 0 ] || why "teardown ran although a nested copy holds an unpushed commit" || return 1
  [ -e "$n/orphan.txt" ] && [ -f "$STATE/t1.meta" ] && [ "$(destroy_calls)" = 0 ] || why "the slot or the task record did not stay" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although the nested copy holds unpushed work" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the record is not retained: $(rec_field t1 state)" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake over two attempts, got $(wake_count)" || return 1
  grep -F "$n" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the nested copy: $(cat "$STATE/.wake-queue")" || return 1
  return 0
}
scn_nested_clone_unpushed_commit_keeps_the_slot_before_teardown() { scn_nested_unpushed_commit_keeps_the_slot_before_teardown clone; }
scn_nested_worktree_unpushed_commit_keeps_the_slot_before_teardown() { scn_nested_unpushed_commit_keeps_the_slot_before_teardown worktree; }

# Teardown would succeed here and end a job working at the copy root, so a job
# in the task's terminal pane keeps the copy with one wake before teardown runs,
# and the job is left alone.
scn_pane_job_keeps_the_copy_before_teardown() {
  make_world
  printf 'ok\n' > "$W/stub.mode"
  use_pane_backend tmux
  start_pane "$COPY" sleep 300
  go
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" = 0 ] || why "teardown ran although a job runs in the task's pane" || return 1
  [ -e "$COPY" ] && [ -f "$STATE/t1.meta" ] && [ "$(destroy_calls)" = 0 ] || why "the copy or the task record did not stay" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although a job runs in its pane" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the record is not retained: $(rec_field t1 state)" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake over two attempts, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process: $(cat "$STATE/.wake-queue")" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "the pane's job was ended" || return 1
  return 0
}

# The finished worker's agent in its pane is teardown's to stop: it does not keep
# the copy, and teardown runs.
scn_pane_agent_does_not_block_teardown() {
  make_world
  printf 'ok-ends-agents\n' > "$W/stub.mode"
  use_pane_backend tmux
  start_pane_agent || why "no agent stand-in survives a foreign name on this host" || return 1
  go
  [ "$(stub_calls)" = 1 ] || why "teardown did not run with only the worker's agent in the pane: $(rec_field t1 reason)" || return 1
  [ ! -e "$STATE/t1.merge-prune" ] || why "the record stayed: $(rec_field t1 reason)" || return 1
  [ ! -e "$COPY" ] || why "the copy teardown returned was not removed" || return 1
  [ "$(wake_count)" = 0 ] || why "the worker's agent raised a wake" || return 1
  return 0
}

scn_clean_nested_copy_goes_with_the_slot() {
  make_world
  make_nested .claude/worktrees/n1
  mkdir -p "$COPY/.claude/worktrees/n1/node_modules" "$COPY/.claude/worktrees/n1/.claude/bug-evidence"
  printf x > "$COPY/.claude/worktrees/n1/node_modules/x"
  printf 'nested-evidence\n' > "$COPY/.claude/worktrees/n1/.claude/bug-evidence/e.json"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a clean pushed nested copy kept the slot: $(rec_field t1 reason)" || return 1
  find "$DATA/t1/merge-prune-preserved" -path '*/nested-.claude__worktrees__n1/.claude/bug-evidence/e.json' | grep -q . \
    || why "the nested copy's preserve-list record was not preserved" || return 1
  return 0
}

# A project that does not ignore .claude/ shows a nested clone to `git status`
# as one untracked directory of the outer copy. That line is not the outer
# copy's own work: the clone is proved on its own. Any other untracked file is.
scn_unignored_nested_clone_goes_with_the_slot() {
  local n
  IGNORE_CLAUDE=0 make_world
  make_nested .claude/worktrees/n1
  make_nested .claude/worktrees/n1/sub/n2
  n="$COPY/.claude/worktrees/n1"
  printf '.claude/\n' >> "$(git -C "$n" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$n/.claude/bug-evidence"
  printf 'nested-evidence\n' > "$n/.claude/bug-evidence/e.json"
  [ "$(git -C "$COPY" status --porcelain --untracked-files=all)" = '?? .claude/worktrees/n1/' ] || why "the fixture's outer copy does not show the clone as one untracked directory: $(git -C "$COPY" status --porcelain --untracked-files=all)" || return 1
  [ "$(git -C "$n" status --porcelain --untracked-files=all)" = '?? sub/n2/' ] || why "the fixture's nested copy does not show its own clone as one untracked directory: $(git -C "$n" status --porcelain --untracked-files=all)" || return 1
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a clean pushed nested clone that .gitignore does not cover kept the slot: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "a clean nested clone raised a wake" || return 1
  find "$DATA/t1/merge-prune-preserved" -path '*/nested-.claude__worktrees__n1/.claude/bug-evidence/e.json' | grep -q . \
    || why "the nested clone's own proofs did not run: its preserve-list record was not preserved" || return 1
  return 0
}

# The same for a clean linked worktree of the project nested in the copy: the
# real `treehouse destroy` counts its untracked directory as dirt, so it is
# removed (and its registration with it) before the destroy.
scn_unignored_nested_worktree_goes_with_the_slot() {
  local n
  IGNORE_CLAUDE=0 make_world
  n="$COPY/.claude/worktrees/w1"
  git -C "$W/project" worktree add -q --detach "$n" origin/main
  [ "$(git -C "$COPY" status --porcelain --untracked-files=all)" = '?? .claude/worktrees/w1/' ] || why "the fixture's outer copy does not show the nested worktree as one untracked directory: $(git -C "$COPY" status --porcelain --untracked-files=all)" || return 1
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a clean nested linked worktree that .gitignore does not cover kept the slot: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "a clean nested linked worktree raised a wake" || return 1
  ! git -C "$W/project" worktree list --porcelain | grep -Fq "worktrees/w1" || why "the nested linked worktree is still registered with the project" || return 1
  return 0
}

# The nested clone's line is skipped and nothing else: an untracked file beside
# it keeps the copy, and the wake names that file, not the clone.
scn_unignored_nested_clone_does_not_hide_an_untracked_file() {
  local first
  IGNORE_CLAUDE=0 make_world
  make_nested .claude/worktrees/n1
  printf 'only here\n' > "$COPY/.claude/worktrees/notes.txt"
  first=$(git -C "$COPY" status --porcelain --untracked-files=all | sed -n 1p)
  [ "$first" = '?? .claude/worktrees/n1/' ] || why "the fixture does not list the clone first: $first" || return 1
  go
  [ -e "$COPY/.claude/worktrees/notes.txt" ] && [ "$(destroy_calls)" = 0 ] || why "an untracked file beside a nested clone was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although an untracked file was left" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'worktrees/notes.txt' || why "the wake does not name the untracked file: $(cat "$STATE/.wake-queue")" || return 1
  return 0
}

scn_unignored_nested_clone_with_unpushed_work_is_kept() {
  IGNORE_CLAUDE=0 make_world
  make_nested .claude/worktrees/n1
  printf 'orphan\n' > "$COPY/.claude/worktrees/n1/orphan.txt"
  git -C "$COPY/.claude/worktrees/n1" add orphan.txt
  git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed in nested"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "an unpushed commit in a nested clone that .gitignore does not cover did not keep the slot" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although the nested clone holds unpushed work" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY/.claude/worktrees/n1" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the nested clone and its unpushed commit: $(cat "$STATE/.wake-queue")" || return 1
  return 0
}

# The prune must judge an ignored entry the way bin/fm-teardown-nested-lib.sh
# does: for each entry below, the prune's classifier (fm_mp_prove_ignored) and
# teardown's own (teardown_preservable_ignored) must agree on whether it blocks
# removal, so a name that one list learns and the other lacks fails here. Each
# entry is the only ignored thing of its own throwaway repo; a trailing slash is
# a directory holding one file. Other entries under .claude and .opencode are
# left out on purpose: the prune is stricter there
# (scn_unique_data_under_claude_or_opencode_is_kept). A wholly ignored .tac/ is
# the one shape where the prune is looser
# (scn_wholly_ignored_tac_caches_are_the_named_exception).
IGNORED_ENTRIES_BOTH_PASS=(
  .venv/ venv/ node_modules/ __pycache__/ .pytest_cache/ .ruff_cache/ .mypy_cache/
  .next/ graphify-out/ .import_linter_cache/ pkg/__pycache__/ a/b/node_modules/
  .DS_Store .fm-grok-turnend .fm-kimi-turnend tsconfig.tsbuildinfo sub/.DS_Store
  .tac/tmp/ .tac/uv-cache/
  .claude/settings.local.json .opencode/plugins/fm-busy-state.js
  scripts/hooks/_conformance_manifest.json
)
IGNORED_ENTRIES_BOTH_BLOCK=(
  build/ data/unique.bin precious.local .tac/state.json
  scripts/hooks/other.json scripts/hooks/_conformance_manifest.json.bak
  scripts/_conformance_manifest.json sub/scripts/hooks/_conformance_manifest.json
)

make_ignored_entry_repo() {  # <dir> <entry>
  local d=$1 entry=$2 file dir
  file=${entry%/}
  git init -q "$d"
  : > "$d/top.keep"
  dir=$file
  while dir=$(dirname "$dir"); [ "$dir" != . ]; do
    mkdir -p "$d/$dir"
    : > "$d/$dir/tracked.keep"
  done
  git -C "$d" add -f -A
  git -C "$d" commit -q -m seed
  printf '/%s\n' "$entry" > "$d/.git/info/exclude"
  if [ "$file" != "$entry" ]; then
    mkdir -p "$d/$file"
    : > "$d/$file/x"
  else
    mkdir -p "$d/$(dirname "$file")"
    : > "$d/$file"
  fi
}

teardown_ignored_verdict() {  # <real-copy>: passes | blocks
  local out
  out=$(bash -c 'set -u; . "$1/fm-teardown-nested-lib.sh" && teardown_preservable_ignored "$2"' _ "$ROOT/bin" "$1" 2>/dev/null) || { printf 'error'; return 0; }
  if [ -z "$out" ]; then printf 'passes'; else printf 'blocks'; fi
}

prune_ignored_verdict() {  # <real-copy>: passes | blocks
  bash -c 'set -u; . "$1/fm-merge-prune-lib.sh"; if fm_mp_prove_ignored "$2" >/dev/null 2>&1; then printf passes; else printf blocks; fi' _ "$BIN_DIR" "$1" 2>/dev/null
}

scn_ignored_entries_get_teardowns_verdict() {
  local entry d real want got n=0 passes=0 blocks=0
  make_world
  for entry in "${IGNORED_ENTRIES_BOTH_PASS[@]}" "${IGNORED_ENTRIES_BOTH_BLOCK[@]}"; do
    n=$((n + 1))
    d="$W/parity/r$n"
    mkdir -p "$d"
    make_ignored_entry_repo "$d" "$entry"
    real=$(cd "$d" && pwd -P)
    [ -n "$(git -C "$real" ls-files -o -i --exclude-standard --directory)" ] || why "the fixture holds no ignored entry for $entry" || return 1
    want=$(teardown_ignored_verdict "$real")
    got=$(prune_ignored_verdict "$real")
    case "$want" in passes) passes=$((passes + 1)) ;; blocks) blocks=$((blocks + 1)) ;; *) why "teardown's classifier could not be run for $entry" || return 1 ;; esac
    [ "$got" = "$want" ] || why "for the ignored entry $entry teardown says $want and the prune says ${got:-nothing}" || return 1
  done
  [ "$passes" -gt 0 ] && [ "$blocks" -gt 0 ] || why "the entries do not cover both verdicts ($passes pass, $blocks block)" || return 1
  return 0
}

# The one named shape where the prune and teardown differ on purpose. A project
# that ignores the whole .tac/ directory lists it as one entry. Teardown
# preserves every child except tmp and uv-cache; the prune opens .tac and counts
# a rebuildable cache child (.venv, node_modules) as scratch. Any other child
# of that .tac/ still blocks both.
scn_wholly_ignored_tac_caches_are_the_named_exception() {
  local d real
  make_world
  d="$W/parity/tac-caches"
  mkdir -p "$d"
  make_ignored_entry_repo "$d" ".tac/"
  rm -f "$d/.tac/x"
  mkdir -p "$d/.tac/.venv" "$d/.tac/node_modules"
  : > "$d/.tac/.venv/x"
  : > "$d/.tac/node_modules/x"
  real=$(cd "$d" && pwd -P)
  [ "$(git -C "$real" ls-files -o -i --exclude-standard --directory)" = ".tac/" ] || why "the fixture does not list the whole .tac/ directory as one ignored entry" || return 1
  [ "$(teardown_ignored_verdict "$real")" = blocks ] || why "teardown no longer preserves the caches of a wholly ignored .tac/; retire this named exception" || return 1
  [ "$(prune_ignored_verdict "$real")" = passes ] || why "the prune does not count .venv and node_modules under a wholly ignored .tac/ as scratch" || return 1
  : > "$d/.tac/state.json"
  [ "$(teardown_ignored_verdict "$real")" = blocks ] || why "teardown passes a wholly ignored .tac/ that holds state.json" || return 1
  [ "$(prune_ignored_verdict "$real")" = blocks ] || why "the exception hides .tac/state.json beside the caches" || return 1
  return 0
}

scn_unique_ignored_file_is_kept() {
  make_world
  printf 'only here\n' > "$COPY/precious.local"
  go
  [ -e "$COPY/precious.local" ] && [ "$(destroy_calls)" = 0 ] || why "a unique ignored file was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'precious.local' || why "the wake does not name the unique file" || return 1
  return 0
}

scn_non_pool_copy_is_kept() {
  make_world
  git clone -q "$ORIGIN" "$W/outside" 2>/dev/null
  git -C "$W/outside" checkout -q -b fm/t1 origin/fm/t1
  mk_task t1 "$W/outside"
  go
  [ -e "$W/outside" ] && [ "$(destroy_calls)" = 0 ] || why "a copy outside the pool was destroyed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# A squash merge leaves the task's commits on no remote branch; the merged
# PR's head is the proof they landed.
scn_pr_head_proves_a_squash_merged_commit() {
  make_world
  printf 'last\n' > "$COPY/last.txt"
  git -C "$COPY" add last.txt
  git -C "$COPY" commit -q -m "landed through the PR head only"
  git -C "$COPY" push -q origin HEAD:refs/pull/7/head
  squash_merge_into_main "$COPY"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a commit proved landed by the PR head kept the copy: $(rec_field t1 reason)" || return 1
  return 0
}

# The merged PR's head can carry a commit that the default branch does not (a
# squash merge whose message or content was edited, or one that main later
# changed): the head alone proves it landed. The pane's `treehouse get` subshell
# returns the slot to the pool when it ends, as the real one does, which is what
# lets `treehouse destroy` take a slot whose branch is not on the default branch.
scn_pr_head_alone_proves_a_commit_the_default_branch_lacks() {
  make_world
  use_pane_backend tmux
  printf 'edited at merge\n' > "$COPY/edited.txt"
  git -C "$COPY" add edited.txt
  git -C "$COPY" commit -q -m "carried by the PR head only"
  git -C "$COPY" push -q origin HEAD:refs/pull/7/head
  start_pane "$COPY" bash "$W/bin/pane-returns-slot" "$W/hold" "$COPY"
  EXIT_WAIT=3 go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a commit proved landed by the PR head alone kept the copy: $(rec_field t1 reason)" || return 1
  return 0
}

# The default branch moves on after a squash merge, so the copy's HEAD is
# neither an ancestor of it nor has its tree; its content is still in it. The
# pane's subshell returns the slot to the pool when it ends, as the real one does.
scn_squash_merged_copy_after_the_default_branch_moved_on() {
  make_world
  use_pane_backend tmux
  start_pane "$COPY" bash "$W/bin/pane-returns-slot" "$W/hold" "$COPY"
  git clone -q "$ORIGIN" "$W/later" 2>/dev/null
  printf 'later\n' > "$W/later/later.txt"
  git -C "$W/later" add later.txt
  git -C "$W/later" commit -q -m "a later change on main"
  git -C "$W/later" push -q origin main
  EXIT_WAIT=3 go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a squash-merged copy was kept after main moved on: $(rec_field t1 reason)" || return 1
  return 0
}

scn_pipeline_refusal_never_falls_back() {
  make_world
  printf 'pipeline\n' > "$W/stub.mode"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a live-pipeline refusal was overridden by the fallback" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# Only teardown's known landing refusals let the fallback prove the copy and
# remove it; the copy here is clean, pushed and unused, so it goes.
scn_landing_refusal_is_settled() {  # <stub mode>
  make_world
  printf '%s\n' "$1" > "$W/stub.mode"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the landing refusal '$1' was not settled by the fallback: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "a settled landing refusal raised a wake" || return 1
  return 0
}

# Every other refusal keeps the copy at once, though the copy would pass every
# proof: the worker is not even stopped, nothing is destroyed, one wake names
# the refusal, and later attempts stay silent.
scn_other_refusal_keeps_the_copy() {  # <stub mode> <text the wake must name>
  make_world
  printf '%s\n' "$1" > "$W/stub.mode"
  go; go; go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the refusal '$1' was overridden by the fallback" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although the refusal '$1' bars the fallback" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q -- "$2" || why "the wake does not name the copy and '$2'" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the record is not retained" || return 1
  return 0
}

scn_ship_not_landed_is_settled() { scn_landing_refusal_is_settled ship-not-landed; }
scn_orphan_nested_copy_refusal_keeps_the_copy() { scn_other_refusal_keeps_the_copy foreign-head 'stays in pool slot'; }
scn_landing_refusal_via_closeout_foreign() { scn_landing_refusal_is_settled false-positive; }
scn_closeout_own_is_settled() { scn_landing_refusal_is_settled closeout-own; }
scn_leaked_worktree_keeps_the_copy() { scn_other_refusal_keeps_the_copy leaked-worktree 'leaked worktree processes'; }
scn_leaked_tasktmp_keeps_the_copy() { scn_other_refusal_keeps_the_copy leaked-tasktmp 'leaked tasktmp processes'; }
scn_launchd_loaded_keeps_the_copy() { scn_other_refusal_keeps_the_copy launchd-loaded 'still loaded after launchctl bootout'; }
scn_ownership_unproven_keeps_the_copy() { scn_other_refusal_keeps_the_copy ownership-unproven 'ownership by t1 is not proven'; }
scn_unknown_refusal_keeps_the_copy() { scn_other_refusal_keeps_the_copy unknown-new 'did not have when this list was written'; }
scn_mixed_refusals_keep_the_copy() { scn_other_refusal_keeps_the_copy mixed 'ship deliverable is not landed'; }

scn_destroy_failure_keeps_the_copy_with_one_wake() {
  make_world
  printf 'locked\n' > "$W/th.fail"
  go
  [ -e "$COPY" ] || why "the stub refused destroy but the copy is gone" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# The 2026-10-18 case where an old retained copy is cleaned later: the retry is
# silent and succeeds.
scn_retained_copy_is_reaped_when_the_cause_clears() {
  make_world
  printf 'edited\n' >> "$COPY/README.md"
  go
  [ "$(wake_count)" = 1 ] || why "want one wake while retained" || return 1
  git -C "$COPY" checkout -q -- README.md
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] && [ ! -e "$STATE/t1.merge-prune" ] || why "the cleared copy was not reaped on the quiet retry" || return 1
  [ "$(wake_count)" = 1 ] || why "the quiet retry raised another wake" || return 1
  return 0
}

# A long reason is cut to 300 characters when the record is saved; the same
# reason on the next attempt is the same reason and is not logged again.
scn_long_reason_is_logged_once() {
  local name
  make_world
  name=$(printf 'a%.0s' $(seq 1 200))
  printf 'mine\n' > "$COPY/$name"
  go; go; go
  [ -e "$COPY/$name" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with a long-named untracked file was removed" || return 1
  [ "$(grep -c 'retained' "$DATA/t1/merge-prune.log")" = 1 ] || why "a repeated long reason was logged $(grep -c 'retained' "$DATA/t1/merge-prune.log") times" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# The finished worker's session ends but its terminal pane stays open with the
# idle shell it entered the copy with. The fake treehouse refuses a copy that has
# a process working inside it, as the real one does, so the copy goes only
# because that one shell is ended with SIGHUP first, on either backend that
# reports a pane pid; the pane itself stays open.
scn_lingering_pane_shell_is_ended() {  # <tmux|herdr>
  make_world
  use_pane_backend "$1"
  start_inside "$COPY" "$W/worker.pid"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  [ -n "$(lsof -t +D "$COPY" 2>/dev/null)" ] || why "the pane shell is not inside the copy" || return 1
  EXIT_WAIT=3 go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the task's own idle pane shell kept the copy: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "an idle pane shell raised a wake" || return 1
  ! kill -0 "$PANE_CHILD" 2>/dev/null || why "the idle pane shell was not ended" || return 1
  kill -0 "$(cat "$W/pane.pid")" 2>/dev/null || why "the pane process was closed" || return 1
  return 0
}

# Only that one process is ended: a build, an editor or a test in the pane, a
# shell that is running something, an idle shell no pane started, or a pane
# shell that works elsewhere keeps the copy and is left alone.
scn_other_process_in_the_pane_keeps_the_copy() {  # <build|busy-shell|stray-shell|holder>
  local alive
  make_world
  use_pane_backend tmux
  alive=
  case "$1" in
    build) start_pane "$COPY" sleep 300 ;;
    busy-shell) start_pane "$COPY" bash "$W/bin/pane-busy" ;;
    stray-shell)
      start_pane "$W" sleep 300
      start_stray_shell "$COPY"
      alive=$STRAY_SHELL
      ;;
    holder)
      start_pane "$W" bash "$W/bin/pane-holder" "$COPY/README.md" "$W" "$W/hold"
      # shellcheck disable=SC2016 # The single-quoted sh -c body expands in the child shell.
      fm_test_wait_until 10 sh -c '[ -n "$(lsof -t "$1" 2>/dev/null)" ]' _ "$COPY/README.md" || true
      ;;
  esac
  [ -n "$alive" ] || alive=$PANE_CHILD
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "$1 inside the copy did not keep it" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process" || return 1
  kill -0 "$alive" 2>/dev/null || why "$1 was ended although it is not the pane's idle shell" || return 1
  return 0
}

# A shell that ignores SIGHUP is not forced: the copy and the shell stay, with
# one wake.
scn_stubborn_pane_shell_keeps_the_copy() {
  make_world
  use_pane_backend tmux
  start_pane "$COPY" bash "$W/bin/pane-stubborn" "$W/hold"
  EXIT_WAIT=1 go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy went although its pane shell did not exit" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'did not exit on SIGHUP' || why "the wake does not say the shell stayed" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "the shell that ignored SIGHUP was ended by something stronger" || return 1
  return 0
}

# The pane's shell is ended only after the exit verb has stopped the agent.
scn_unconfirmed_stop_leaves_the_pane_shell() {
  make_world
  use_pane_backend tmux
  printf 'fail\n' > "$W/stop-fail"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  EXIT_WAIT=1 go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy went although the agent was not confirmed stopped" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "the pane shell was ended before the agent was confirmed stopped" || return 1
  return 0
}

scn_lingering_pane_shell_on_tmux() { scn_lingering_pane_shell_is_ended tmux; }
scn_lingering_pane_shell_on_herdr() { scn_lingering_pane_shell_is_ended herdr; }
scn_pane_build_keeps_the_copy() { scn_other_process_in_the_pane_keeps_the_copy build; }
scn_pane_busy_shell_keeps_the_copy() { scn_other_process_in_the_pane_keeps_the_copy busy-shell; }
scn_stray_shell_keeps_the_copy() { scn_other_process_in_the_pane_keeps_the_copy stray-shell; }
scn_pane_shell_working_elsewhere_keeps_the_copy() { scn_other_process_in_the_pane_keeps_the_copy holder; }

# An agent still running in the pane after the exit verb passes the check before
# teardown (it is teardown's to stop), but in the fallback it is not the pane's
# idle shell: it keeps the copy with one wake and is never signalled.
scn_pane_agent_left_running_keeps_the_copy() {
  make_world
  use_pane_backend tmux
  start_pane_agent || why "no agent stand-in survives a foreign name on this host" || return 1
  EXIT_WAIT=1 go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy went although the agent is still running in it: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "the agent was signalled as if it were the pane's idle shell" || return 1
  return 0
}

# The pane's own shell is not a strict descendant of the pane: ending it would
# close the pane, so a bare pane shell inside the copy keeps the copy, with one
# wake, and is left alone.
scn_bare_pane_shell_keeps_the_copy() {
  make_world
  use_pane_backend tmux
  start_stray_shell "$COPY"
  printf '%s\n' "$STRAY_SHELL" > "$W/pane.pid"
  EXIT_WAIT=1 go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a bare pane shell did not keep the copy: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process" || return 1
  kill -0 "$STRAY_SHELL" 2>/dev/null || why "the bare pane shell, which is the pane itself, was ended" || return 1
  return 0
}

# A stand-in git first on PATH. It runs everything as the real git does, except:
#   fetch     with the project lock held, it logs the call and hangs (a remote
#             that never answers); once, after the first fetch, it steers or
#             busies the worker when after-first-fetch says steer or busy (the
#             worker changes between the first verdict and the lock);
#   ls-files  -o -i (the ignored listing), ls-files -s (the tracked listing) and
#   stash list   fail with a git error when fail-ls-files, fail-ls-files-s or
#             fail-stash-list exists in the world.
install_git_standin() {
  {
    printf '#!/usr/bin/env bash\nREAL_GIT=%q\nSTANDIN_DIR=%q\nLOCK=%q\n' "$(command -v git)" "$W" "$(project_lock_path)"
    cat <<'SH'
case " $* " in
  *" fetch "*)
    if [ -s "$STANDIN_DIR/after-first-fetch" ]; then
      case "$(cat "$STANDIN_DIR/after-first-fetch")" in
        steer)
          mkdir -p "$FM_STATE_OVERRIDE/t1.inbox"
          printf 'one more thing\n' > "$FM_STATE_OVERRIDE/t1.inbox/1.msg"
          ;;
        busy)
          printf 'v1 gen=g1.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$(date +%s)" > "$FM_STATE_OVERRIDE/t1.busy-state"
          ;;
      esac
      : > "$STANDIN_DIR/after-first-fetch"
    fi
    if [ -e "$LOCK" ]; then
      printf '%s\n' "$*" >> "$STANDIN_DIR/fetch-under-lock.log"
      exec sleep 300
    fi
    ;;
  *" ls-files -o -i "*)
    [ ! -e "$STANDIN_DIR/fail-ls-files" ] || { echo "fatal: simulated ls-files failure" >&2; exit 128; }
    ;;
  *" ls-files -s "*)
    [ ! -e "$STANDIN_DIR/fail-ls-files-s" ] || { echo "fatal: simulated ls-files failure" >&2; exit 128; }
    ;;
  *" stash list "*)
    [ ! -e "$STANDIN_DIR/fail-stash-list" ] || { echo "fatal: simulated stash failure" >&2; exit 128; }
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  } > "$W/bin/git"
  chmod +x "$W/bin/git"
  : > "$W/fetch-under-lock.log"
}

# A remote that never answers must not hold the project lock or the control
# lock: the proof repeated under them reuses the refs fetched before them. The
# stand-in git logs and hangs on any fetch made while the project lock exists;
# the attempt, with a nested copy, must finish within its bound with no fetch
# logged.
scn_hung_remote_never_holds_the_project_lock() {
  local pid waited=0
  make_world
  make_nested .claude/worktrees/n1
  install_git_standin
  prune arm t1 >/dev/null 2>&1
  prune run t1 --now >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ ! -s "$W/fetch-under-lock.log" ] && [ "$waited" -lt 900 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill_tree "$pid"
    why "the attempt was still running (fetch made under the project lock: $(cat "$W/fetch-under-lock.log"))" || return 1
  fi
  wait "$pid" 2>/dev/null || true
  [ ! -s "$W/fetch-under-lock.log" ] || why "a fetch ran while the project lock was held: $(cat "$W/fetch-under-lock.log")" || return 1
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the copy was not removed: $(rec_field t1 reason)" || return 1
  [ ! -e "$(project_lock_path)" ] || why "the project lock outlived the attempt" || return 1
  return 0
}

# A pane that cannot be read exempts nothing.
scn_unreadable_pane_exempts_nothing() {
  make_world
  use_pane_backend tmux
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  : > "$W/pane.pid"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a shell was ignored although the pane could not be read" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "a shell was ended although the pane could not be read" || return 1
  return 0
}

# A launch for another task takes the slot the stopped worker freed. The slot is
# not this task's any more, whatever was proved earlier.
scn_reassigned_slot_is_never_destroyed() {
  make_world
  printf 't9\n' > "$W/steal"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a slot claimed by another task was destroyed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 't9' || why "the wake does not name the other task" || return 1
  [ ! -e "$(project_lock_path)" ] || why "the project lock outlived the attempt" || return 1
  rm -f "$W/steal"
  : > "$POOL/pool1/1/.fm-slot-owner"
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a slot with an unreadable claim was destroyed" || return 1
  [ "$(wake_count)" = 1 ] || why "the unreadable claim raised another wake" || return 1
  return 0
}

# Another actor holds the project lock: nothing is stopped or touched, the
# attempt backs off silently, and a later attempt finishes.
# The returned copy is removed under the same project lock as the fallback's
# destroy, because every slot allocation takes it: a busy lock is a silent
# retry that needs only the prune record, since teardown has already removed the
# task's record.
scn_project_lock_busy_backs_off_for_the_returned_copy() {
  local lock holder
  make_world
  printf 'ok\n' > "$W/stub.mode"
  lock=$(project_lock_path)
  sleep 120 &
  holder=$!
  WORKER_PIDS+=("$holder")
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the returned copy was touched while another actor held the project lock" || return 1
  [ ! -e "$STATE/t1.meta" ] || why "the stand-in teardown did not finish the task record" || return 1
  [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 returned)" = 1 ] && [ "$(wake_count)" = 0 ] || why "a busy project lock was not a silent retry: $(cat "$STATE/t1.merge-prune")" || return 1
  kill "$holder" 2>/dev/null || true
  rm -rf "$lock"
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the retry after the lock cleared did not remove the returned copy: $(rec_field t1 reason)" || return 1
  [ ! -e "$STATE/t1.merge-prune" ] || why "the record outlived the removal: $(cat "$STATE/t1.merge-prune")" || return 1
  [ "$(reaped_wake_count)" = 1 ] || why "want one reaped outcome, got $(reaped_wake_count)" || return 1
  [ "$(stub_calls)" = 1 ] || why "the retry asked teardown again" || return 1
  return 0
}

# A teardown that completes but keeps the slot leased has not returned it: a
# slot another task's record still names stays durably leased for that task
# (the shared-slot route), and a slot holding foreign copies stays leased for
# this task (the held-close route). Neither copy is the prune's to remove: the
# record goes with "teardown kept the copy", and nothing is destroyed or woken.
scn_slot_teardown_keeps_leased_is_left_alone() {
  local holder
  for holder in t2 t1; do
    make_world
    printf 'ok-keeps-lease\n' > "$W/stub.mode"
    if [ "$holder" = t2 ]; then
      printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t2"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
      mk_task t2 "$COPY"
    fi
    go
    [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a slot teardown kept leased for $holder was destroyed" || return 1
    [ ! -e "$STATE/t1.merge-prune" ] || why "the record stayed for a copy teardown kept: $(cat "$STATE/t1.merge-prune")" || return 1
    [ "$(wake_count)" = 0 ] && [ "$(reaped_wake_count)" = 0 ] || why "a copy teardown kept raised a wake: $(cat "$STATE/.wake-queue" 2>/dev/null)" || return 1
    grep -q 'reaped: teardown completed; teardown kept the copy' "$DATA/t1/merge-prune.log" || why "the log does not say teardown kept the copy" || return 1
  done
  return 0
}

# A copy that is not a Treehouse pool slot was never returned to a pool: teardown
# leaves it as it is, and so does the prune, with no wake and no record.
scn_copy_that_is_not_a_pool_slot_is_left_after_teardown() {
  make_world
  printf 'ok\n' > "$W/stub.mode"
  rm -f "$POOL/pool1/treehouse-state.json"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a copy that is not a pool slot was destroyed" || return 1
  [ ! -e "$STATE/t1.merge-prune" ] || why "the record stayed for a copy that can never be returned: $(cat "$STATE/t1.merge-prune")" || return 1
  [ "$(wake_count)" = 0 ] && [ "$(reaped_wake_count)" = 0 ] || why "a copy that is not a pool slot raised a wake" || return 1
  grep -q 'reaped: teardown completed; teardown kept the copy' "$DATA/t1/merge-prune.log" || why "the log does not say teardown kept the copy" || return 1
  return 0
}

# The retry from the prune record reads the lease again under the project lock: a
# returned slot that a new launch leased meanwhile is that launch's, and stays.
scn_returned_copy_leased_again_before_the_retry_is_left() {
  local lock holder
  make_world
  printf 'ok\n' > "$W/stub.mode"
  lock=$(project_lock_path)
  sleep 120 &
  holder=$!
  WORKER_PIDS+=("$holder")
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  go
  [ "$(rec_field t1 returned)" = 1 ] || why "the returned copy was not recorded for the retry: $(cat "$STATE/t1.merge-prune" 2>/dev/null)" || return 1
  kill "$holder" 2>/dev/null || true
  rm -rf "$lock"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t9"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the retry destroyed a slot a new launch had leased" || return 1
  [ ! -e "$STATE/t1.merge-prune" ] || why "the record stayed: $(cat "$STATE/t1.merge-prune")" || return 1
  [ "$(wake_count)" = 0 ] && [ "$(reaped_wake_count)" = 0 ] || why "a slot leased again raised a wake" || return 1
  return 0
}

# Teardown's reset of a returned slot keeps its ignored files. A unique ignored
# file keeps the returned copy with one wake, as it keeps a copy the fallback
# would destroy.
scn_returned_copy_with_unique_ignored_file_is_kept() {
  make_world
  printf 'ok\n' > "$W/stub.mode"
  printf 'secret\n' > "$COPY/.env.local"
  go
  [ -e "$COPY/.env.local" ] && [ "$(destroy_calls)" = 0 ] || why "a returned copy with a unique ignored file was destroyed" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the returned copy with unique data is not retained: $(cat "$STATE/t1.merge-prune" 2>/dev/null)" || return 1
  [ "$(wake_count)" = 1 ] || why "want one wake for the unique ignored file, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q '.env.local' || why "the wake does not name the copy and the file: $(cat "$STATE/.wake-queue")" || return 1
  return 0
}

# The preserve-list records of a returned copy are copied with checksums before
# the copy is removed.
scn_returned_copy_preserves_bug_evidence_first() {
  local sums
  make_world
  printf 'ok\n' > "$W/stub.mode"
  mkdir -p "$COPY/.claude/bug-evidence"
  printf 'closeout record\n' > "$COPY/.claude/bug-evidence/r1.md"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the returned copy was not removed: $(rec_field t1 reason)" || return 1
  sums=$(find "$DATA/t1/merge-prune-preserved" -path '*/root/SHA256SUMS' 2>/dev/null | sed -n 1p)
  [ -n "$sums" ] || why "no checksummed copy of the preserve list was made" || return 1
  [ "$(cat "${sums%/SHA256SUMS}/.claude/bug-evidence/r1.md")" = "closeout record" ] || why "the preserved record differs" || return 1
  grep -q 'bug-evidence/r1.md' "$sums" || why "the record has no checksum: $(cat "$sums")" || return 1
  return 0
}

scn_project_lock_busy_backs_off() {
  local lock holder
  make_world
  lock=$(project_lock_path)
  sleep 120 &
  holder=$!
  WORKER_PIDS+=("$holder")
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy was touched while another actor held the project lock" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped without the project lock" || return 1
  [ "$(rec_field t1 state)" = pending ] && [ "$(wake_count)" = 0 ] || why "a busy project lock was not a silent retry: $(cat "$STATE/t1.merge-prune")" || return 1
  kill "$holder" 2>/dev/null || true
  rm -rf "$lock"
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the retry after the lock cleared did not remove the copy: $(rec_field t1 reason)" || return 1
  return 0
}

# A preserve-list path with no regular file has nothing to checksum.
scn_empty_preserve_paths_do_not_keep_the_copy() {
  make_world
  make_nested .claude/worktrees/n1
  mkdir -p "$COPY/.claude/channel-outbox" "$COPY/.claude/worktrees/n1/.claude/bug-evidence/sub"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "an empty preserve-list path kept the copy: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "an empty preserve-list path raised a wake" || return 1
  return 0
}

# `fm-control.sh exit` retires the busy record and leaves state/<id>.control-exit.
# Only the merge prune reads such a worker, whose last event is still `done`, as
# stopped; the ordinary finished-session sweep classifies it as before.
scan_reap() {  # [VAR=value ...]: 0 when the scan lists t1 as reapable
  env HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    PATH="$W/bin:$PATH" PANE_PID_FILE="$W/pane.pid" "$@" "$BIN_DIR/fm-idle-session-reap.sh" scan 2>/dev/null | grep -q "^reap	t1	"
}

scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune() {
  local pane
  make_world
  scan_reap || why "the world's finished idle worker is not reapable at all" || return 1
  FM_STATE_OVERRIDE="$STATE" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" STEAL_FILE="$W/steal" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" SLOT_MARKER=/dev/null \
    "$W/bin/control-stub" t1 exit || why "the stand-in exit verb failed" || return 1
  [ ! -e "$STATE/t1.busy-state" ] && [ -f "$STATE/t1.control-exit" ] || why "the exit verb did not retire the busy record and mark the exit" || return 1
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a stopped worker whose terminal pane it cannot read" || return 1
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  ! scan_reap || why "the ordinary sweep accepted a worker with no busy record" || return 1
  scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune did not accept the worker that its exit verb stopped, with only the pane's treehouse get and its idle shell left" || return 1
  pane=$(cat "$W/pane.pid")
  start_pane "$COPY" "$W/th/treehouse" get "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a pane holding a second treehouse get" || return 1
  printf '%s\n' "$pane" > "$W/pane.pid"
  mv "$STATE/t1.control-exit" "$W/control-exit.kept"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker with no record of a deliberate exit" || return 1
  ln -s "$W/control-exit.kept" "$STATE/t1.control-exit"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a symlink as the record of a deliberate exit" || return 1
  rm -f "$STATE/t1.control-exit"
  mv "$W/control-exit.kept" "$STATE/t1.control-exit"
  printf 'working [at=%s]: more to do\n' "$NOW" >> "$STATE/t1.status"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker whose last event is not done" || return 1
  printf 'done [at=%s]: PR %s checks green\n' "$NOW" "$PR" >> "$STATE/t1.status"
  printf 'g2.1.1\n' > "$STATE/t1.busy-gen"
  printf 'v1 gen=g2.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$NOW" > "$STATE/t1.busy-state"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker that reads busy again" || return 1
  printf 'v1 gen=g9.9.9 seq=3 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/t1.busy-state"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker whose busy record is present but unreadable" || return 1
  return 0
}

# A harness with no busy record (grok here) reads busy from its pane. An exit
# marker left from an earlier stop never lifts that busy verdict.
scn_busy_worker_with_an_old_exit_marker_is_not_reapable() {
  make_world
  use_pane_backend tmux
  sed -i.bak 's/^harness=.*/harness=grok/' "$STATE/t1.meta"
  rm -f "$STATE/t1.busy-state" "$STATE/t1.busy-gen"
  printf 'gen=-\n' > "$STATE/t1.control-exit"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  : > "$W/pane-tail"
  scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 PANE_TAIL_FILE="$W/pane-tail" || why "the prune did not accept the idle grok worker of the fixture" || return 1
  printf 'Working... Ctrl+c:cancel\n' > "$W/pane-tail"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 PANE_TAIL_FILE="$W/pane-tail" || why "the prune accepted a worker that reads busy because an old exit marker is present" || return 1
  return 0
}

# A worker relaunched after an earlier `fm-control.sh exit` still has that
# marker. Its busy record is gone and it reads unknown, but its agent is alive in
# the terminal pane, so the prune backs off: nothing is stopped or destroyed and
# the copy stays, with no wake.
scn_relaunched_agent_with_an_old_exit_marker_is_kept() {
  make_world
  rm -f "$STATE/t1.busy-state" "$STATE/t1.busy-gen"
  printf 'gen=-\n' > "$STATE/t1.control-exit"
  start_pane_agent || why "the fixture could not start the agent in the pane" || return 1
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a copy whose relaunched agent is alive in the pane was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the live agent was stopped: $(cat "$W/control.log")" || return 1
  [ "$(wake_count)" = 0 ] || why "the back-off raised a wake" || return 1
  rec_field t1 reason | grep -q 'automatic reap ineligible' || why "the prune did not back off as ineligible: $(rec_field t1 reason)" || return 1
  return 0
}

# A process table that is only partly read proves nothing. `ps` prints the pane's
# own row and then fails: the live agent's row may be the one that is missing,
# so the pane does not show "no agent", whether the exit marker is old (the
# reap admission) or a job runs in the pane (the check before teardown).
partial_ps_stub() {  # <pane-pid>: the process table, cut to the pane's own row, then an error
  local real_ps
  real_ps=$(command -v ps)
  cat > "$W/bin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-axo pid=,ppid="*) $real_ps -axo pid=,ppid= | awk -v p=$1 '\$1 == p'; exit 1 ;;
  *) exec $real_ps "\$@" ;;
esac
SH
  chmod +x "$W/bin/ps"
}

scn_partial_process_table_proves_no_agent_gone() {
  make_world
  rm -f "$STATE/t1.busy-state" "$STATE/t1.busy-gen"
  printf 'gen=-\n' > "$STATE/t1.control-exit"
  start_pane_agent || why "the fixture could not start the agent in the pane" || return 1
  partial_ps_stub "$(cat "$W/pane.pid")"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a partly read process table admitted the removal of a copy with a live agent" || return 1
  [ ! -s "$W/control.log" ] || why "the live agent was stopped on a partial process table: $(cat "$W/control.log")" || return 1
  rec_field t1 reason | grep -Eq 'automatic reap ineligible|terminal pane failed' || why "the prune did not back off on the failed read: $(rec_field t1 reason)" || return 1
  # The reap admission's own proof, asked directly: the pane's shell row alone is not "no agent".
  if PATH="$W/bin:$PATH" bash -c '. "$1/fm-merge-prune-lib.sh"; fm_mp_pane_pid() { printf %s "$2"; }; fm_mp_pane_agent_gone "$3"' _ "$BIN_DIR" "$(cat "$W/pane.pid")" "$STATE/t1.meta" 2>/dev/null; then
    why "the reap admission took a partly read process table for an agent that is gone" || return 1
  fi
  make_world
  printf 'ok\n' > "$W/stub.mode"
  use_pane_backend tmux
  start_pane "$COPY" sleep 300
  partial_ps_stub "$(cat "$W/pane.pid")"
  go
  [ "$(stub_calls)" = 0 ] || why "teardown ran on a partly read process table of the task's pane" || return 1
  [ -e "$COPY" ] && [ -f "$STATE/t1.meta" ] || why "the copy or the task record did not stay" || return 1
  [ "$(rec_field t1 state)" = pending ] && grep -q 'terminal pane failed' "$STATE/t1.merge-prune" || why "the failed pane read was not a retry: $(cat "$STATE/t1.merge-prune")" || return 1
  return 0
}

# A commit pushed after the merge but never merged is work the merged PR does not
# carry. The fallback proves that itself, before it stops anything: the real
# `treehouse get` subshell of the pane returns the slot to the pool, reset to
# origin/main, when it ends, and after that `treehouse destroy` sees nothing
# unmerged and would remove the copy. So the copy stays with one wake, the pane
# shell is not ended and treehouse is not called.
scn_pushed_but_unmerged_copy_is_kept() {
  make_world
  use_pane_backend tmux
  printf 'follow-up\n' > "$COPY/followup.txt"
  git -C "$COPY" add followup.txt
  git -C "$COPY" commit -q -m "follow-up after the merge"
  git -C "$COPY" push -q origin fm/t1
  start_pane "$COPY" bash "$W/bin/pane-returns-slot" "$W/hold" "$COPY"
  EXIT_WAIT=3 go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a copy with a pushed, unmerged follow-up commit was destroyed" || return 1
  [ "$(git -C "$COPY" symbolic-ref -q --short HEAD)" = fm/t1 ] || why "the slot was returned to the pool under its unmerged commit" || return 1
  kill -0 "$PANE_CHILD" 2>/dev/null || why "the pane shell was ended over a copy that stays" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although the copy stays" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'not in the merged pull request' || why "the wake does not name that the commit is not in the merged pull request" || return 1
  return 0
}

# A pool slot is a linked worktree of the project: it shares the project's
# branches and stash list. The git proofs read only this copy's work.

# Another task's work in the project: its own branch with a local-only commit,
# and a stash made on that branch.
add_other_task_work() {
  git -C "$W/project" checkout -q -b fm/other
  printf 'other\n' > "$W/project/other.txt"
  git -C "$W/project" add other.txt
  git -C "$W/project" commit -q -m "other task work, local only"
  printf 'wip\n' >> "$W/project/README.md"
  git -C "$W/project" stash -q
}

scn_linked_slot_ignores_other_tasks_work() {
  make_world
  add_other_task_work
  [ "$(git -C "$COPY" stash list | wc -l | tr -d ' ')" = 1 ] || why "the fixture's stash is not shared with the slot" || return 1
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "another task's local commit or stash kept the slot: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "another task's work raised a wake" || return 1
  return 0
}

scn_linked_slot_own_unpushed_commit_is_kept() {
  make_world
  add_other_task_work
  printf 'later\n' > "$COPY/later.txt"
  git -C "$COPY" add later.txt
  git -C "$COPY" commit -q -m "unpushed"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the slot with its own unpushed commit was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the unpushed commit" || return 1
  return 0
}

scn_linked_slot_own_branch_stash_is_kept() {
  make_world
  add_other_task_work
  printf 'wip\n' >> "$COPY/README.md"
  git -C "$COPY" stash -q
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the slot with a stash of its own branch was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'stash' || why "the wake does not name the stash" || return 1
  return 0
}

scn_linked_detached_slot_keeps_every_stash() {
  make_world
  add_other_task_work
  git -C "$COPY" checkout -q --detach
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a detached slot was removed although a stash exists that cannot be told from its own" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# Teardown can finish the records of a removed copy only for a PR URL of the
# exact form https://github.com/<owner>/<repo>/pull/<n>. For any other provider
# the fallback does not run: the worker is not stopped, nothing is destroyed,
# and one wake names the PR.
scn_non_github_pr_keeps_the_copy() {  # <pr url>
  make_world
  prune arm t1 >/dev/null 2>&1
  sed -i.bak "s#^pr=.*#pr=$1#" "$STATE/t1.meta" "$STATE/t1.merge-prune"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy of a task with the PR $1 was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped for the PR $1" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q -- "$1" || why "the wake does not name the copy and the PR" || return 1
  return 0
}
scn_enterprise_pr_keeps_the_copy() { scn_non_github_pr_keeps_the_copy https://github.example.com/acme/widget/pull/7; }
scn_forgejo_pr_keeps_the_copy() { scn_non_github_pr_keeps_the_copy https://codeberg.org/acme/widget/pulls/7; }

# A git tree that merely sits at <root>/a/b/c is not a pool copy: Treehouse owns
# a slot only when the pool's treehouse-state.json is beside it and it shares the
# project's git directory. Every other proof passes for this clean, pushed,
# merged tree, so only the pool test keeps it.
scn_plain_git_tree_is_not_a_pool_copy() {
  make_world
  git clone -q "$ORIGIN" "$POOL/a/b/c" 2>/dev/null
  git -C "$POOL/a/b/c" checkout -q -b fm/t1 origin/fm/t1
  mk_task t1 "$POOL/a/b/c"
  go
  [ -e "$POOL/a/b/c" ] && [ "$(destroy_calls)" = 0 ] || why "a plain git tree at <root>/a/b/c was destroyed as a pool copy" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped for a copy that is not a pool slot" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$POOL/a/b/c" "$STATE/.wake-queue" | grep -q 'not a Treehouse pool slot' || why "the wake does not name the copy and that it is not a pool slot" || return 1
  return 0
}

# The worker is judged reapable first. Fetches and the lock wait follow, then
# the worker is stopped. A worker that is steered, or turns busy, in between
# stops nothing: no stop, no signal, no destroy, no wake, a backed-off record.
scn_worker_changed_after_the_first_verdict_is_not_stopped() {  # <steer|busy>
  make_world
  install_git_standin
  start_inside "$COPY" "$W/worker.pid"
  printf '%s\n' "$1" > "$W/after-first-fetch"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy of a worker that went '$1' after the first verdict was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although it went '$1' after the first verdict: $(cat "$W/control.log")" || return 1
  kill -0 "$(cat "$W/worker.pid")" 2>/dev/null || why "the worker session was ended" || return 1
  [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 attempts)" = 1 ] || why "not a backed-off first attempt: $(cat "$STATE/t1.merge-prune")" || return 1
  [ "$(wake_count)" = 0 ] || why "a worker that changed raised a wake" || return 1
  [ ! -e "$(project_lock_path)" ] || why "the project lock outlived the attempt" || return 1
  return 0
}
scn_worker_steered_after_the_first_verdict() { scn_worker_changed_after_the_first_verdict_is_not_stopped steer; }
scn_worker_busy_after_the_first_verdict() { scn_worker_changed_after_the_first_verdict_is_not_stopped busy; }

# A proof read that fails must never count as finding nothing. Each stand-in
# failure happens in the first proof pass, before anything is stopped.
scn_failed_read_keeps_the_copy() {  # <fail flag> <state> <text the record must name>
  make_world
  install_git_standin
  : > "$W/$1"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy was removed although the read '$1' failed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although the read '$1' failed" || return 1
  [ "$(rec_field t1 state)" = "$2" ] || why "the record is '$(rec_field t1 state)', want '$2': $(cat "$STATE/t1.merge-prune")" || return 1
  rec_field t1 reason | grep -q -- "$3" || why "the record does not name '$3': $(rec_field t1 reason)" || return 1
  if [ "$2" = retained ]; then
    [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  else
    [ "$(wake_count)" = 0 ] || why "a retried read raised a wake" || return 1
  fi
  return 0
}
scn_failing_ignored_listing_keeps_the_copy() { scn_failed_read_keeps_the_copy fail-ls-files retained 'cannot list ignored files'; }
scn_failing_tracked_listing_keeps_the_copy() { scn_failed_read_keeps_the_copy fail-ls-files-s retained 'cannot list the tracked files'; }
scn_failing_stash_listing_is_retried() { scn_failed_read_keeps_the_copy fail-stash-list pending 'git stash list failed'; }

# A subtree that cannot be read cannot be searched for nested copies (find fails
# in a scratch directory the search enters), and a .claude directory that cannot
# be listed cannot be classified. Neither counts as finding nothing. The search
# for nested copies runs first and reads every directory, so an unreadable
# .claude fails there; the listing failure is made by a stand-in `ls` instead.
scn_unreadable_subtree_keeps_the_copy() {  # <relative directory> <text the record must name>
  make_world
  mkdir -p "$COPY/$1"
  chmod 000 "$COPY/$1"
  go
  chmod 755 "$COPY/$1" 2>/dev/null || true
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy was removed although $1 cannot be read" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although $1 cannot be read" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  rec_field t1 reason | grep -q -- "$2" || why "the record does not name '$2': $(rec_field t1 reason)" || return 1
  return 0
}
scn_unreadable_scratch_subtree_keeps_the_copy() { scn_unreadable_subtree_keeps_the_copy .mypy_cache/sub 'cannot search'; }
scn_unreadable_claude_directory_keeps_the_copy() {
  make_world
  mkdir -p "$COPY/.claude/sub"
  printf '#!/usr/bin/env bash\nREAL_LS=%q\nSTANDIN_DIR=%q\n' "$(command -v ls)" "$W" > "$W/bin/ls"
  cat >> "$W/bin/ls" <<'SH'
case " $* " in
  *" -A "*/.claude" "*) [ ! -e "$STANDIN_DIR/fail-claude-ls" ] || { echo "ls: simulated listing failure" >&2; exit 1; } ;;
esac
exec "$REAL_LS" "$@"
SH
  chmod +x "$W/bin/ls"
  : > "$W/fail-claude-ls"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy was removed although .claude cannot be listed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped although .claude cannot be listed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  rec_field t1 reason | grep -q 'cannot list .claude' || why "the record does not name 'cannot list .claude': $(rec_field t1 reason)" || return 1
  return 0
}

# A nested copy that is an independent clone has its own branches and stashes,
# which removing it destroys. It is clean, on main and pushed, so a HEAD-only
# proof passes it; the full proof sees the side branch's unpushed commit and the
# stash made on that branch.
scn_independent_clone_side_work_is_kept() {  # <branch|stash|both> <text the wake must name>
  local n
  make_world
  make_nested .claude/worktrees/n1
  n="$COPY/.claude/worktrees/n1"
  git -C "$n" checkout -q -b wip
  case "$1" in
    branch|both)
      printf 'side\n' > "$n/side.txt"
      git -C "$n" add side.txt
      git -C "$n" commit -q -m "unpushed on wip"
      ;;
  esac
  case "$1" in
    stash|both)
      printf 'wip\n' >> "$n/README.md"
      git -C "$n" stash -q
      ;;
  esac
  git -C "$n" checkout -q main
  [ -z "$(git -C "$n" status --porcelain)" ] || why "the fixture's clone is not clean" || return 1
  [ "$(git -C "$n" rev-list --count HEAD --not --remotes)" = 0 ] || why "the fixture's clone HEAD is not pushed" || return 1
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy holding an independent clone with side work '$1' was removed" || return 1
  [ ! -s "$W/control.log" ] || why "the worker was stopped for a clone with side work '$1'" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$n" "$STATE/.wake-queue" | grep -q -- "$2" || why "the wake does not name the clone and '$2'" || return 1
  return 0
}
scn_independent_clone_side_branch_is_kept() { scn_independent_clone_side_work_is_kept branch 'commit(s) on no remote'; }
scn_independent_clone_side_stash_is_kept() { scn_independent_clone_side_work_is_kept stash 'stash entries'; }
scn_independent_clone_side_branch_and_stash_is_kept() { scn_independent_clone_side_work_is_kept both 'stash entries'; }

run_scenario() {  # <name>
  SCN_WHY=
  cleanup_workers
  if "$1"; then cleanup_workers; return 0; fi
  cleanup_workers
  return 1
}

assert_scenario() {  # <name> <label>
  run_scenario "$1" || fail "$2: $SCN_WHY"$'\n'"prune log: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null)"$'\n'"record: $(cat "$STATE/t1.merge-prune" 2>/dev/null)"$'\n'"treehouse: $(cat "$W/th.log" 2>/dev/null)"
  pass "$2"
}

scn_search_indexer_does_not_keep_the_copy() {
  local real_ps pid
  make_world
  real_ps=$(command -v ps)
  start_inside "$W" ""
  pid=${WORKER_PIDS[$((${#WORKER_PIDS[@]} - 1))]}
  # The copy reports a Spotlight worker, named as macOS names it, as its only
  # process; ps answers for that pid the way macOS does.
  cat > "$W/bin/lsof" <<SH
#!/usr/bin/env bash
printf '%s\n' $pid
SH
  cat > "$W/bin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-o comm= -p $pid") echo /System/Library/Frameworks/CoreServices.framework/Support/mdworker_shared ;;
  *) exec $real_ps "\$@" ;;
esac
SH
  chmod +x "$W/bin/lsof" "$W/bin/ps"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a search indexer's read kept the copy: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "an indexer-only read raised a wake" || return 1
  return 0
}

# An independent clone with a commit on no remote, inside a directory that
# holds dependencies or an environment: the search for nested copies enters it,
# and the commit keeps the whole slot with one wake.
scn_clone_inside_a_scratch_directory_keeps_the_slot() {
  local dir
  for dir in .venv node_modules; do
    make_world
    make_nested "$dir/src/pkg"
    printf 'local only\n' > "$COPY/$dir/src/pkg/local.txt"
    git -C "$COPY/$dir/src/pkg" add local.txt
    git -C "$COPY/$dir/src/pkg" commit -q -m "unpushed under $dir"
    go
    [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "an unpushed commit in a clone under $dir did not keep the slot" || return 1
    [ "$(wake_count)" = 1 ] || why "under $dir: want exactly one wake, got $(wake_count)" || return 1
    grep -F "$COPY/$dir/src/pkg" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "under $dir: the wake does not name the nested copy" || return 1
  done
  return 0
}

# Ignored data under .claude or .opencode that is neither Firstmate's own hook
# file, a nested clone, nor on the preserve list is unique: the copy stays with
# one wake. The hook files and a nested clone do not keep it.
scn_unique_data_under_claude_or_opencode_is_kept() {
  local dir
  for dir in .claude .opencode; do
    make_world
    printf '%s/\n' "$dir" >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$COPY/$dir/private"
    printf 'only here\n' > "$COPY/$dir/private/unique.bin"
    go
    [ -e "$COPY/$dir/private/unique.bin" ] && [ "$(destroy_calls)" = 0 ] || why "unique data under $dir/private was removed" || return 1
    [ "$(wake_count)" = 1 ] || why "under $dir: want exactly one wake, got $(wake_count)" || return 1
    grep -F "$COPY" "$STATE/.wake-queue" | grep -q "$dir/private" || why "under $dir: the wake does not name the data" || return 1
  done
  make_world
  printf '.opencode/\n' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$COPY/.opencode/plugins" "$COPY/.claude/worktrees"
  printf 'x\n' > "$COPY/.opencode/plugins/fm-busy-state.js"
  make_nested .claude/worktrees/n1
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "the hook files and a clean nested clone kept the copy: $(rec_field t1 reason)" || return 1
  return 0
}

# A process probe that fails proves nothing about who holds the copy open. Real
# lsof exits 1 with no output and no message when nothing is open (measured on
# this Mac, also when something is), so that answer still passes.
scn_failed_process_probe_keeps_the_copy() {
  local variant
  for variant in exit2 message; do
    make_world
    start_inside "$COPY" ""
    case "$variant" in
      exit2) printf '#!/usr/bin/env bash\nexit 2\n' > "$W/bin/lsof" ;;
      message) printf '#!/usr/bin/env bash\necho "lsof: WARNING: could not read the copy" >&2\nexit 1\n' > "$W/bin/lsof" ;;
    esac
    chmod +x "$W/bin/lsof"
    go
    [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a failed process probe ($variant) did not keep the copy" || return 1
    [ "$(rec_field t1 state)" = pending ] || why "a failed process probe ($variant) was not a retry: $(cat "$STATE/t1.merge-prune")" || return 1
    [ "$(rec_field t1 reason)" != "" ] && grep -q 'process check' "$STATE/t1.merge-prune" || why "the record does not say the process check failed" || return 1
  done
  make_world
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/lsof"
  chmod +x "$W/bin/lsof"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a silent exit 1 with nothing open kept the copy: $(rec_field t1 reason)" || return 1
  return 0
}

# A probe that lists some processes and then fails has not read the whole copy: a
# live process in the part it could not read is not excluded.
scn_partial_process_probe_keeps_the_copy() {
  local real_ps pid
  make_world
  real_ps=$(command -v ps)
  start_inside "$W" ""
  pid=${WORKER_PIDS[$((${#WORKER_PIDS[@]} - 1))]}
  cat > "$W/bin/lsof" <<SH
#!/usr/bin/env bash
printf '%s\n' $pid
echo "lsof: can't stat protected subtree: Permission denied" >&2
exit 2
SH
  cat > "$W/bin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-o comm= -p $pid") echo /System/Library/Frameworks/CoreServices.framework/Support/mdworker_shared ;;
  *) exec $real_ps "\$@" ;;
esac
SH
  chmod +x "$W/bin/lsof" "$W/bin/ps"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a probe that failed after listing a safe process proved the copy unused" || return 1
  [ "$(rec_field t1 state)" = pending ] || why "the partial probe was not a retry: $(cat "$STATE/t1.merge-prune")" || return 1
  grep -q 'process check' "$STATE/t1.merge-prune" || why "the record does not say the process check failed" || return 1
  return 0
}

# A slot claim that names this task id under another Firstmate home belongs to
# that home's task, not this one.
scn_slot_claimed_by_the_same_task_id_of_another_home_is_kept() {
  make_world
  printf 'task=t1\nhome=%s/other-home\n' "$W" > "$POOL/pool1/1/.fm-slot-owner"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a slot claimed by the same task id of another home was destroyed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'other-home' || why "the wake does not name the other home" || return 1
  make_world
  printf 'task=t1\n' > "$POOL/pool1/1/.fm-slot-owner"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a slot claim that names no home was destroyed" || return 1
  return 0
}

# The wake is what tells a person a copy stays. It is recorded as sent only
# when it was appended: a failed append leaves the record unsent, so the next
# attempt raises it, and a repaired queue then gets exactly one.
scn_failed_wake_append_is_not_recorded_as_sent() {
  make_world
  printf 'only here\n' > "$COPY/precious.local"
  mkdir "$STATE/.wake-queue"
  go
  [ -e "$COPY/precious.local" ] && [ "$(destroy_calls)" = 0 ] || why "the unique file was removed" || return 1
  [ "$(rec_field t1 wake_sent)" = 0 ] || why "a failed wake append was recorded as sent: $(cat "$STATE/t1.merge-prune")" || return 1
  rmdir "$STATE/.wake-queue"
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || why "after the queue was repaired want exactly one wake, got $(wake_count)" || return 1
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || why "a later attempt raised another wake: $(wake_count)" || return 1
  make_world
  printf 'lock\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  set_rec t1 attempts 23
  mkdir "$STATE/.wake-queue"
  prune run t1 --now >/dev/null 2>&1
  [ "$(rec_field t1 wake_sent)" = 0 ] || why "a failed attempt-limit wake append was recorded as sent: $(cat "$STATE/t1.merge-prune")" || return 1
  rmdir "$STATE/.wake-queue"
  set_rec t1 next_at 0
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || why "after the queue was repaired the attempt-limit wake count is $(wake_count)" || return 1
  return 0
}

# --- 1. arming ----------------------------------------------------------------

test_arm_needs_a_verified_merge() {
  local out
  make_world
  out=$(prune arm t1 2>&1) || fail "arm failed: $out"
  [ -f "$STATE/t1.merge-prune" ] || fail "a verified merge did not arm the prune"
  [ "$(rec_field t1 pr)" = "$PR" ] && [ "$(rec_field t1 state)" = pending ] || fail "armed record is wrong: $(cat "$STATE/t1.merge-prune")"
  set_rec t1 attempts 5
  prune arm t1 >/dev/null 2>&1
  [ "$(rec_field t1 attempts)" = 5 ] || fail "arming twice reset the record"
  rm -f "$STATE/t1.merge-prune" "$STATE/t1.pr-poll-merge-notified"
  prune arm t1 >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] || fail "a PR with no merge marker armed the prune"
  mk_task t1 "$COPY"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n99\n' > "$STATE/t1.pr-poll-merge-notified"
  prune arm t1 >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] || fail "a marker for a different PR armed the prune"
  pass "only a verified merge of the recorded PR arms the prune, and arming is idempotent"
}

test_arm_skips_tasks_it_does_not_own() {
  make_world
  printf 'kind=scout\n' >> "$STATE/t1.meta"
  mk_task t2 "$COPY"; printf 'remote_host=far\n' >> "$STATE/t2.meta"
  mk_task t3 "$COPY"; sed -i.bak 's/^kind=ship/kind=secondmate/' "$STATE/t3.meta"
  prune arm t2 >/dev/null 2>&1; prune arm t3 >/dev/null 2>&1
  [ ! -e "$STATE/t2.merge-prune" ] || fail "a remote task was armed"
  [ ! -e "$STATE/t3.merge-prune" ] || fail "a secondmate was armed"
  mk_task t4 "$COPY"
  FM_MERGE_PRUNE=0 prune arm t4 >/dev/null 2>&1
  [ ! -e "$STATE/t4.merge-prune" ] || fail "FM_MERGE_PRUNE=0 still armed"
  prune arm 'bad id' >/dev/null 2>&1 && fail "an invalid id was accepted"
  pass "remote tasks, secondmates and a disabled setting are never armed"
}

test_run_not_due_does_nothing() {
  make_world
  prune arm t1 >/dev/null 2>&1
  set_rec t1 next_at $((NOW + 600))
  prune run t1 >/dev/null 2>&1
  [ "$(stub_calls)" = 0 ] || fail "a record that is not due was attempted"
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" -ge 1 ] || fail "--now did not attempt"
  pass "a record that is not due waits, and --now overrides"
}

test_missing_task_or_changed_pr_drops_the_record() {
  make_world
  prune arm t1 >/dev/null 2>&1
  rm -f "$STATE/t1.meta"
  prune run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 0 ] || fail "a record for a vanished task was kept or attempted"
  mk_task t1 "$COPY"
  prune arm t1 >/dev/null 2>&1
  sed -i.bak 's#^pr=.*#pr=https://github.com/acme/widget/pull/8#' "$STATE/t1.meta"
  prune run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 0 ] || fail "a record for a different PR was kept or attempted"
  pass "a vanished task or a different PR drops the record without calling teardown"
}

# --- 2. orchestration against a stub teardown -----------------------------------

test_merge_cleanup_runs_teardown_unforced() {
  make_world
  printf 'ok\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] || fail "teardown ran $(stub_calls) times"
  [ "$(cat "$W/stub.log")" = "args=t1|admission=1|prune=1" ] || fail "teardown was not asked plainly: $(cat "$W/stub.log")"
  [ ! -e "$STATE/t1.merge-prune" ] || fail "the record outlived a completed teardown"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped"
  [ "$(stub_calls)" = 1 ] || fail "the removal of the returned copy ran teardown again"
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || fail "the copy the completed teardown left was not removed with one destroy"
  pass "a verified merge asks teardown once, never forced, removes the copy teardown left, and logs reaped"
}

test_transient_refusals_back_off_silently_then_succeed() {
  local mode delay
  for mode in lock lease timeout ineligible lifecycle; do
    make_world
    printf '%s\n' "$mode" > "$W/stub.mode"
    prune arm t1 >/dev/null 2>&1
    prune run t1 --now >/dev/null 2>&1
    [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || fail "$mode: a transient refusal touched the copy"
    [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 attempts)" = 1 ] || fail "$mode: not a pending first attempt: $(cat "$STATE/t1.merge-prune")"
    delay=$(( $(rec_field t1 next_at) - $(date +%s) ))
    [ "$delay" -ge 50 ] && [ "$delay" -le 70 ] || fail "$mode: first backoff is ${delay}s, want about 60s"
    [ "$(wake_count)" = 0 ] || fail "$mode: a transient refusal raised a wake"
    prune run t1 >/dev/null 2>&1
    [ "$(stub_calls)" = 1 ] || fail "$mode: retried before the backoff elapsed"
    printf 'ok\n' > "$W/stub.mode"
    set_rec t1 next_at 0
    prune run t1 >/dev/null 2>&1
    [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 2 ] || fail "$mode: the retry did not succeed"
    grep -q 'reaped' "$DATA/t1/merge-prune.log" || fail "$mode: the retry did not log reaped"
  done
  pass "co-tenant, lease, timeout, not-ready and lifecycle refusals retry on later ticks and then succeed, silently"
}

test_flaky_contention_retries_through_the_sweep() {
  make_world
  printf 'flaky\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] && [ -e "$STATE/t1.merge-prune" ] || fail "the first sweep did not meet the contention"
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] || fail "a sweep ran a record that was not due"
  set_rec t1 next_at 0
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 2 ] && [ ! -e "$STATE/t1.merge-prune" ] || fail "the second due sweep did not finish the prune"
  pass "the sweep retries a contended task on a later tick and finishes it"
}

test_backoff_doubles_to_a_cap_and_wakes_once() {
  local want got
  make_world
  printf 'lock\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  for want in 60 120 240 480; do
    prune run t1 --now >/dev/null 2>&1
    got=$(( $(rec_field t1 next_at) - $(date +%s) ))
    [ "$got" -ge $((want - 10)) ] && [ "$got" -le $((want + 10)) ] || fail "backoff is ${got}s, want about ${want}s"
  done
  set_rec t1 attempts 10
  prune run t1 --now >/dev/null 2>&1
  got=$(( $(rec_field t1 next_at) - $(date +%s) ))
  [ "$got" -ge 3590 ] && [ "$got" -le 3610 ] || fail "backoff is ${got}s, want the 3600s cap"
  set_rec t1 attempts 22
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 0 ] || fail "a wake before the attempt limit"
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || fail "no wake at the attempt limit"
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || fail "more than one wake after the limit"
  pass "backoff doubles from 60s to a 3600s cap and one wake follows the 24th attempt"
}

test_sweep_runs_only_due_records_and_at_most_three() {
  local id
  make_world
  printf 'ok\n' > "$W/stub.mode"
  for id in a1 a2 a3 a4 a5; do
    mk_task "$id" "$W/none-$id"
    prune arm "$id" >/dev/null 2>&1
  done
  set_rec a5 next_at $((NOW + 9999))
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 3 ] || fail "a sweep ran $(stub_calls) teardowns, want 3"
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 4 ] || fail "the next sweep ran $(( $(stub_calls) - 3 )) teardowns, want the 1 due record left"
  [ -e "$STATE/a5.merge-prune" ] || fail "a record that is not due was run"
  pass "a sweep runs only due records, at most 3 per pass"
}

# --- 3. the fallback against the fake pool ---------------------------------------

test_fallback_removes_a_clean_pushed_unused_scratch_copy() { assert_scenario scn_scratch_copy_is_removed "a copy refused by a false positive but clean, pushed and unused is removed, preserve-list files copied with checksums first"; }
test_fallback_keeps_a_changed_file() { assert_scenario scn_changed_file_is_kept "a changed tracked file keeps the copy with exactly one wake naming it"; }
test_fallback_keeps_an_untracked_file() { assert_scenario scn_untracked_file_is_kept "an untracked file keeps the copy with exactly one wake"; }
test_fallback_keeps_an_unpushed_commit() { assert_scenario scn_unpushed_commit_is_kept "an unpushed commit keeps the copy with exactly one wake naming it"; }
test_fallback_keeps_an_untracked_file_that_git_config_hides() { assert_scenario scn_hidden_untracked_file_is_kept_in_the_copy "an untracked file that status.showUntrackedFiles=no hides from a plain git status still keeps the copy with exactly one wake"; }
test_fallback_keeps_a_nested_copy_with_an_untracked_file_that_git_config_hides() { assert_scenario scn_hidden_untracked_file_is_kept_in_a_nested_copy "an untracked file in a nested copy that status.showUntrackedFiles=no hides still keeps the copy with exactly one wake"; }
test_fallback_keeps_a_changed_submodule_that_git_config_hides() { assert_scenario scn_hidden_submodule_change_is_kept "a changed submodule that diff.ignoreSubmodules=all hides from a plain git status still keeps the copy with exactly one wake"; }
test_fallback_keeps_a_stash() { assert_scenario scn_stash_is_kept "a stash entry keeps the copy"; }
test_fallback_keeps_a_live_process() { assert_scenario scn_live_process_is_kept "a live process inside keeps the copy with exactly one wake"; }
test_fallback_nested_unpushed_commit_keeps_the_slot() { assert_scenario scn_nested_unpushed_commit_keeps_the_slot "an unpushed commit in a NESTED copy keeps the whole slot"; }
test_nested_clone_unpushed_commit_keeps_the_slot_before_teardown() { assert_scenario scn_nested_clone_unpushed_commit_keeps_the_slot_before_teardown "an unpushed commit in a nested clone keeps the whole slot with one wake before a teardown that would return it"; }
test_pane_job_keeps_the_copy_before_teardown() { assert_scenario scn_pane_job_keeps_the_copy_before_teardown "a job in the task's terminal pane keeps the copy with one wake before a teardown that would end it"; }
test_pane_agent_does_not_block_teardown() { assert_scenario scn_pane_agent_does_not_block_teardown "the finished worker's agent in its pane does not keep the copy: teardown runs"; }
test_nested_worktree_unpushed_commit_keeps_the_slot_before_teardown() { assert_scenario scn_nested_worktree_unpushed_commit_keeps_the_slot_before_teardown "an unpushed commit in a nested linked worktree keeps the whole slot with one wake before a teardown that would close the task"; }
test_fallback_removes_a_clean_nested_copy_with_the_slot() { assert_scenario scn_clean_nested_copy_goes_with_the_slot "a clean pushed orphan nested copy goes with its slot, its preserve-list records preserved"; }
test_fallback_removes_an_unignored_clean_nested_clone_with_the_slot() { assert_scenario scn_unignored_nested_clone_goes_with_the_slot "a clean pushed nested clone that the project's .gitignore does not cover, and a clone inside it, go with the slot: the clones are not untracked files of the copy that holds them, and their own proofs ran"; }
test_fallback_removes_an_unignored_clean_nested_worktree_with_the_slot() { assert_scenario scn_unignored_nested_worktree_goes_with_the_slot "a clean linked worktree of the project nested in the copy, which the project's .gitignore does not cover, is removed before the destroy so treehouse does not refuse the slot as dirty"; }
test_fallback_keeps_an_untracked_file_beside_an_unignored_nested_clone() { assert_scenario scn_unignored_nested_clone_does_not_hide_an_untracked_file "an untracked file beside a nested clone still keeps the copy with one wake naming that file"; }
test_fallback_keeps_an_unignored_nested_clone_with_unpushed_work() { assert_scenario scn_unignored_nested_clone_with_unpushed_work_is_kept "a nested clone that the project's .gitignore does not cover, with an unpushed commit, keeps the slot with one wake naming the clone"; }
test_fallback_judges_ignored_entries_like_teardown() { assert_scenario scn_ignored_entries_get_teardowns_verdict "the prune and bin/fm-teardown-nested-lib.sh agree on whether each ignored entry blocks removal"; }
test_fallback_counts_the_caches_of_a_wholly_ignored_tac_as_scratch() { assert_scenario scn_wholly_ignored_tac_caches_are_the_named_exception "the one named difference from teardown: a wholly ignored .tac/ holding .venv and node_modules passes the prune and blocks teardown, and state.json beside them still blocks both"; }
test_fallback_keeps_unique_ignored_files() { assert_scenario scn_unique_ignored_file_is_kept "a unique ignored file outside the preserve list and the scratch patterns keeps the copy"; }
test_fallback_keeps_a_non_pool_copy() { assert_scenario scn_non_pool_copy_is_kept "a copy outside the pool is never destroyed"; }
test_fallback_keeps_a_plain_git_tree_shaped_like_a_slot() { assert_scenario scn_plain_git_tree_is_not_a_pool_copy "a plain git tree at <root>/a/b/c is not a pool copy: it is kept with one wake and nothing is stopped or destroyed"; }
test_fallback_does_not_stop_a_worker_steered_after_the_first_verdict() { assert_scenario scn_worker_steered_after_the_first_verdict "a worker steered between the first verdict and the project lock is not stopped, signalled or destroyed, and the attempt backs off"; }
test_fallback_does_not_stop_a_worker_busy_after_the_first_verdict() { assert_scenario scn_worker_busy_after_the_first_verdict "a worker that turns busy between the first verdict and the project lock is not stopped, signalled or destroyed, and the attempt backs off"; }
test_fallback_keeps_the_copy_when_the_ignored_listing_fails() { assert_scenario scn_failing_ignored_listing_keeps_the_copy "a failing git ls-files for ignored files keeps the copy and is never read as no ignored files"; }
test_fallback_keeps_the_copy_when_the_tracked_listing_fails() { assert_scenario scn_failing_tracked_listing_keeps_the_copy "a failing git ls-files for tracked files keeps the copy and is never read as no submodules"; }
test_fallback_retries_when_the_stash_listing_fails() { assert_scenario scn_failing_stash_listing_is_retried "a failing git stash list keeps the copy and retries later and is never read as no stash"; }
test_fallback_keeps_the_copy_when_a_subtree_cannot_be_searched() { assert_scenario scn_unreadable_scratch_subtree_keeps_the_copy "a subtree the nested-copy search cannot read keeps the copy and is never read as no nested copy"; }
test_fallback_keeps_the_copy_when_the_claude_directory_cannot_be_listed() { assert_scenario scn_unreadable_claude_directory_keeps_the_copy "a .claude directory that cannot be listed keeps the copy and is never read as empty"; }
test_fallback_accepts_the_merged_pr_head() { assert_scenario scn_pr_head_proves_a_squash_merged_commit "a commit proved landed by the merged PR head does not keep the copy"; }
test_fallback_accepts_a_commit_only_the_merged_pr_head_carries() { assert_scenario scn_pr_head_alone_proves_a_commit_the_default_branch_lacks "a commit that only the merged PR head carries does not keep the copy"; }
test_fallback_removes_a_squash_merged_copy_after_main_moved_on() { assert_scenario scn_squash_merged_copy_after_the_default_branch_moved_on "a squash-merged copy is removed although the default branch moved on after the merge"; }
test_fallback_ignores_a_search_indexer() { assert_scenario scn_search_indexer_does_not_keep_the_copy "a system search indexer (Spotlight) reading the copy does not keep it; any other process does"; }
test_fallback_never_overrides_a_live_pipeline_refusal() { assert_scenario scn_pipeline_refusal_never_falls_back "a refusal about a live pipeline is retained, never overridden"; }
test_fallback_settles_a_ship_deliverable_not_landed_refusal() { assert_scenario scn_ship_not_landed_is_settled "the ship-deliverable-not-landed refusal is settled by the fallback"; }
test_fallback_keeps_the_copy_on_an_orphan_nested_copy_refusal() { assert_scenario scn_orphan_nested_copy_refusal_keeps_the_copy "an orphan nested copy refused for a HEAD that is not proved landed, with the registered-copy refusal teardown always prints with it, is not settled: the copy stays with one wake"; }
test_fallback_keeps_an_independent_clone_with_an_unpushed_side_branch() { assert_scenario scn_independent_clone_side_branch_is_kept "a nested independent clone that is clean and pushed on main but has an unpushed commit on a side branch keeps the copy with one wake"; }
test_fallback_keeps_an_independent_clone_with_a_stash_of_a_side_branch() { assert_scenario scn_independent_clone_side_stash_is_kept "a nested independent clone with a stash made on a side branch keeps the copy with one wake"; }
test_fallback_keeps_an_independent_clone_with_side_work_of_both_kinds() { assert_scenario scn_independent_clone_side_branch_and_stash_is_kept "a nested independent clone with an unpushed side branch and a stash made on it keeps the copy with one wake"; }
test_fallback_settles_an_own_nested_copy_closeout_refusal() { assert_scenario scn_closeout_own_is_settled "a closeout driver's exact-tree refusal for an own nested copy is settled by the fallback"; }
test_fallback_keeps_the_copy_on_leaked_worktree_processes() { assert_scenario scn_leaked_worktree_keeps_the_copy "a leaked worktree process refusal keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_on_leaked_tasktmp_processes() { assert_scenario scn_leaked_tasktmp_keeps_the_copy "a leaked task tmp process refusal keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_while_a_launch_agent_is_loaded() { assert_scenario scn_launchd_loaded_keeps_the_copy "a launch agent that is still loaded after launchctl bootout keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_when_process_ownership_is_not_proven() { assert_scenario scn_ownership_unproven_keeps_the_copy "a process whose ownership is not proven keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_on_an_unknown_refusal() { assert_scenario scn_unknown_refusal_keeps_the_copy "an unknown new refusal text keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_when_any_refusal_line_is_not_a_landing_refusal() { assert_scenario scn_mixed_refusals_keep_the_copy "a landing refusal printed together with a non-landing refusal keeps the copy"; }
test_fallback_keeps_a_pushed_but_unmerged_copy() { assert_scenario scn_pushed_but_unmerged_copy_is_kept "a copy with a pushed follow-up commit that the merged PR does not carry stays with one wake before the pane shell is ended, nothing stopped and nothing destroyed"; }
test_fallback_ignores_other_tasks_work_in_a_linked_slot() { assert_scenario scn_linked_slot_ignores_other_tasks_work "in a linked worktree slot, another task's local-only commit and stash do not keep the copy"; }
test_fallback_keeps_a_linked_slot_with_its_own_unpushed_commit() { assert_scenario scn_linked_slot_own_unpushed_commit_is_kept "in a linked worktree slot, the copy's own unpushed commit keeps it"; }
test_fallback_keeps_a_linked_slot_with_a_stash_of_its_own_branch() { assert_scenario scn_linked_slot_own_branch_stash_is_kept "in a linked worktree slot, a stash made on the copy's branch keeps it"; }
test_fallback_keeps_a_clone_inside_a_scratch_directory_with_an_unpushed_commit() { assert_scenario scn_clone_inside_a_scratch_directory_keeps_the_slot "an independent clone under .venv or node_modules with a commit on no remote keeps the whole slot with one wake"; }
test_fallback_keeps_unique_data_under_claude_and_opencode() { assert_scenario scn_unique_data_under_claude_or_opencode_is_kept "ignored data under .claude or .opencode that is not a hook file, a nested clone or on the preserve list keeps the copy with one wake"; }
test_fallback_keeps_the_copy_when_the_process_probe_fails_after_listing() { assert_scenario scn_partial_process_probe_keeps_the_copy "a process probe that lists a process and then fails keeps the copy and retries"; }
test_partial_process_table_proves_no_agent_gone() { assert_scenario scn_partial_process_table_proves_no_agent_gone "a process table that is only partly read (ps fails after printing rows) never shows the agent gone, in the reap admission and in the check before teardown"; }
test_fallback_keeps_the_copy_when_the_process_probe_fails() { assert_scenario scn_failed_process_probe_keeps_the_copy "a process probe that exits with an error, or prints a message, keeps the copy and retries; a silent exit 1 with nothing open does not"; }
test_fallback_keeps_a_slot_claimed_by_the_same_task_id_of_another_home() { assert_scenario scn_slot_claimed_by_the_same_task_id_of_another_home_is_kept "a slot claim that names this task id under another home, or no home, is never destroyed"; }
test_failed_wake_append_is_not_recorded_as_sent() { assert_scenario scn_failed_wake_append_is_not_recorded_as_sent "a wake that could not be appended is not recorded as sent, and the repaired queue gets exactly one"; }
test_fallback_keeps_a_detached_linked_slot_with_a_stash() { assert_scenario scn_linked_detached_slot_keeps_every_stash "a detached linked worktree slot keeps the copy while any stash exists"; }
test_fallback_keeps_the_copy_of_a_github_enterprise_pr() { assert_scenario scn_enterprise_pr_keeps_the_copy "a GitHub Enterprise PR keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_of_a_forgejo_pr() { assert_scenario scn_forgejo_pr_keeps_the_copy "a Forgejo PR keeps the copy with one wake and no fallback"; }
test_fallback_destroy_failure_keeps_the_copy() { assert_scenario scn_destroy_failure_keeps_the_copy_with_one_wake "a destroy the tool refuses keeps the copy with one wake"; }
test_retained_copy_is_reaped_quietly_when_the_cause_clears() { assert_scenario scn_retained_copy_is_reaped_when_the_cause_clears "a retained copy is reaped on the quiet retry once its cause clears"; }
test_long_retained_reason_is_logged_once() { assert_scenario scn_long_reason_is_logged_once "a retained reason longer than the saved 300 characters is logged and woken once, not at every retry"; }
test_fallback_ends_the_tasks_idle_pane_shell_on_tmux() { assert_scenario scn_lingering_pane_shell_on_tmux "the idle shell the task's tmux pane keeps in the copy is ended with SIGHUP and the copy then goes, with the pane left open"; }
test_fallback_ends_the_tasks_idle_pane_shell_on_herdr() { assert_scenario scn_lingering_pane_shell_on_herdr "the idle shell the task's herdr pane keeps in the copy is ended with SIGHUP and the copy then goes, with the pane left open"; }
test_fallback_keeps_a_non_shell_process_in_the_pane() { assert_scenario scn_pane_build_keeps_the_copy "a build, editor or test started in the pane keeps the copy with exactly one wake"; }
test_fallback_keeps_an_agent_left_running_in_the_pane() { assert_scenario scn_pane_agent_left_running_keeps_the_copy "an agent still running in the pane after the exit verb keeps the copy with one wake and is never signalled"; }
test_fallback_keeps_a_pane_shell_that_runs_something() { assert_scenario scn_pane_busy_shell_keeps_the_copy "a pane shell with a child process keeps the copy with exactly one wake"; }
test_fallback_keeps_a_pane_shell_that_works_elsewhere() { assert_scenario scn_pane_shell_working_elsewhere_keeps_the_copy "a pane shell with a file of the copy open but its working directory elsewhere keeps the copy and is left alone"; }
test_fallback_keeps_the_copy_when_the_pane_shell_ignores_sighup() { assert_scenario scn_stubborn_pane_shell_keeps_the_copy "a pane shell that ignores SIGHUP keeps the copy with one wake and is never forced"; }
test_fallback_leaves_the_pane_shell_until_the_agent_is_confirmed_stopped() { assert_scenario scn_unconfirmed_stop_leaves_the_pane_shell "an exit verb that does not confirm the agent stopped leaves the pane shell alone and keeps the copy"; }
test_deliberately_exited_worker_reads_as_stopped_only_for_the_prune() { assert_scenario scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "a worker stopped by fm-control.sh exit reads as reapable for the prune only when the busy record is gone, the exit marker is present and its last event is done"; }
test_busy_worker_with_an_old_exit_marker_is_not_reapable() { assert_scenario scn_busy_worker_with_an_old_exit_marker_is_not_reapable "a worker with no busy record whose pane reads busy is not reapable by the prune, even with state/<id>.control-exit left from an earlier stop"; }
test_relaunched_agent_with_an_old_exit_marker_is_kept() { assert_scenario scn_relaunched_agent_with_an_old_exit_marker_is_kept "a worker whose busy record is gone and whose old state/<id>.control-exit is still present is not closed while its agent is alive in the pane: the prune backs off and the copy stays"; }
test_fallback_keeps_a_bare_pane_shell() { assert_scenario scn_bare_pane_shell_keeps_the_copy "a shell that is the pane's own shell keeps the copy with one wake and is left alone, so the pane stays open"; }
test_fallback_never_holds_the_project_lock_on_a_hung_remote() { assert_scenario scn_hung_remote_never_holds_the_project_lock "a remote that never answers is never waited on while the project lock is held, and the attempt still finishes"; }
test_fallback_keeps_a_shell_no_pane_started() { assert_scenario scn_stray_shell_keeps_the_copy "an idle shell that is not the task's pane shell keeps the copy with exactly one wake"; }
test_fallback_exempts_nothing_when_the_pane_is_unreadable() { assert_scenario scn_unreadable_pane_exempts_nothing "a pane that cannot be read exempts no shell"; }
test_fallback_never_destroys_a_reassigned_slot() { assert_scenario scn_reassigned_slot_is_never_destroyed "a slot another task claimed after the worker stopped, or whose claim cannot be read, is never destroyed"; }
test_returned_copy_removal_backs_off_while_the_project_lock_is_held() { assert_scenario scn_project_lock_busy_backs_off_for_the_returned_copy "removing the copy teardown returned takes the project lock; a busy lock is a silent retry from the prune record alone, then the copy is removed and reported"; }
test_teardown_kept_leased_slot_is_left_alone() { assert_scenario scn_slot_teardown_keeps_leased_is_left_alone "a slot teardown kept leased, for another task's record or held for foreign copies, is never removed and raises no wake"; }
test_copy_that_is_not_a_pool_slot_is_left_after_teardown() { assert_scenario scn_copy_that_is_not_a_pool_slot_is_left_after_teardown "a copy that is not a pool slot is left after teardown, with no wake and no record"; }
test_returned_copy_leased_again_before_the_retry_is_left() { assert_scenario scn_returned_copy_leased_again_before_the_retry_is_left "the retry reads the lease again and leaves a returned slot that a new launch leased"; }
test_returned_copy_with_unique_ignored_file_is_kept() { assert_scenario scn_returned_copy_with_unique_ignored_file_is_kept "a returned copy with a unique ignored file is kept with one wake"; }
test_returned_copy_preserves_bug_evidence_first() { assert_scenario scn_returned_copy_preserves_bug_evidence_first "a returned copy's preserve-list records are copied with checksums before it is removed"; }
test_fallback_backs_off_while_the_project_lock_is_held() { assert_scenario scn_project_lock_busy_backs_off "a project lock held by another actor stops nothing, backs off silently, and the retry finishes"; }
test_fallback_removes_a_copy_whose_preserve_paths_are_empty() { assert_scenario scn_empty_preserve_paths_do_not_keep_the_copy "an empty preserve-list path, in the copy or a nested copy, has nothing to checksum and does not keep the copy"; }

# --- 4. mutation proof, both ways ------------------------------------------------
#
# Each mutation edits a COPY of bin/ so that exactly one criterion is broken.
# Weakening a safety proof must make the matching keep scenario fail (the copy
# would be destroyed). Tightening a permission must make the matching removal
# scenario fail (a provably clean copy would be kept). A mutation whose target
# text is not found exactly once is itself a failure, so a mutation can never
# silently do nothing.

mutate() {  # <name> <file-in-bin> <old> <new> -> echoes the mutated bin dir
  local dir="$TMP_ROOT/mut-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$ROOT/bin" "$dir/bin"
  python3 - "$dir/bin/$2" "$3" "$4" <<'PY' || return 1
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit('mutation target found %d times: %s' % (text.count(old), old))
open(path, 'w').write(text.replace(old, new))
PY
  printf '%s\n' "$dir/bin"
}

expect_caught() {  # <name> <file> <old> <new> <scenario> <what the mutation breaks>
  local dir
  dir=$(mutate "$1" "$2" "$3" "$4") || fail "mutation $1 could not be applied"
  BIN_DIR=$dir
  if run_scenario "$5"; then
    BIN_DIR="$ROOT/bin"
    fail "mutation $1 ($6) was NOT caught by $5"
  fi
  BIN_DIR="$ROOT/bin"
}

# shellcheck disable=SC2016 # Every mutation old/new text is literal shell source, never expanded here.
test_unsafe_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh orch=fm-merge-prune.sh reap=fm-idle-reap-lib.sh
  expect_caught no-dirty-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_changed_file_is_kept "changed-file proof"
  expect_caught no-untracked-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_untracked_file_is_kept "untracked-file proof"
  expect_caught status-flags-removed $lib 'status --porcelain --untracked-files=all --ignore-submodules=none' 'status --porcelain' scn_hidden_untracked_file_is_kept_in_the_copy "dirty-file status flags"
  expect_caught status-untracked-all-removed $lib 'status --porcelain --untracked-files=all --ignore-submodules=none' 'status --porcelain --ignore-submodules=none' scn_hidden_untracked_file_is_kept_in_a_nested_copy "dirty-file status flag --untracked-files=all"
  expect_caught status-ignore-submodules-removed $lib 'status --porcelain --untracked-files=all --ignore-submodules=none' 'status --porcelain --untracked-files=all' scn_hidden_submodule_change_is_kept "dirty-file status flag --ignore-submodules=none"
  expect_caught no-unpushed-check $lib '  if [ "$unpushed" != 0 ]; then' '  if false; then' scn_unpushed_commit_is_kept "unpushed-commit proof"
  expect_caught no-stash-check $lib '  if [ "$stashes" != 0 ]; then' '  if false; then' scn_stash_is_kept "stash proof"
  expect_caught scratch-dirs-not-searched $lib '    -path "$copy/.git" -prune -o' '    \( -path "$copy/.git" -o -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o' scn_clone_inside_a_scratch_directory_keeps_the_slot "search of dependency and environment trees"
  expect_caught claude-wildcard-is-scratch $lib '    .claude/settings.local.json|.opencode/plugins/fm-busy-state.js) return 0 ;;' '    .claude/*|.opencode/*) return 0 ;;' scn_unique_data_under_claude_or_opencode_is_kept "unique data under .claude or .opencode"
  expect_caught failed-probe-is-all-clear $lib '  if [ "$rc" -gt 1 ] || [ -n "$err" ]; then' '  if false; then' scn_failed_process_probe_keeps_the_copy "failed process probe"
  expect_caught partial-probe-is-all-clear $lib '  if [ "$rc" -gt 1 ] || [ -n "$err" ]; then' '  if [ -z "$out" ] && { [ "$rc" -gt 1 ] || [ -n "$err" ]; }; then' scn_partial_process_probe_keeps_the_copy "a probe that failed after listing a process"
  expect_caught partial-process-table-is-accepted $lib '  table=$(ps -axo pid=,ppid= 2>/dev/null) || return 1
  [ -n "$table" ] || return 1
  tree=' '  table=$(ps -axo pid=,ppid= 2>/dev/null) || true
  tree=' scn_partial_process_table_proves_no_agent_gone "a partly read process table"
  expect_caught claim-of-another-home-passes fm-merge-prune.sh '  if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] && ! same_home "$FM_TREEHOUSE_SLOT_OWNER_HOME"; then' '  if false; then' scn_slot_claimed_by_the_same_task_id_of_another_home_is_kept "home check of the slot claim"
  expect_caught failed-wake-is-sent fm-merge-prune.sh '  if fm_wake_append check "merge-prune:$ID" "$1"; then' '  fm_wake_append check "merge-prune:$ID" "$1" || true
  if true; then' scn_failed_wake_append_is_not_recorded_as_sent "recording a wake as sent only when appended"
  expect_caught no-process-check $lib "  out=\$(printf '%s\\n' \"\$out\" | sort -u | tr '\\n' ' ')" '  out=' scn_live_process_is_kept "live-process proof"

  expect_caught no-nested-check $lib '    FM_MP_NESTED+=("$dir")' '    :' scn_nested_unpushed_commit_keeps_the_slot "nested-copy proof"
  expect_caught no-nested-proof-before-teardown $orch '  prove_nested_first || return 0' '  :' scn_nested_clone_unpushed_commit_keeps_the_slot_before_teardown "nested-copy proof before teardown"
  expect_caught no-pane-job-proof-before-teardown $orch '  fm_mp_prove_pane_idle "$real" "$(fm_mp_pane_pid "$META")" || { record_verdict "$real"; return 1; }' '  :' scn_pane_job_keeps_the_copy_before_teardown "pane-job proof before teardown"
  expect_caught unique-is-scratch $lib '  if fm_mp_scratch_name "$name"; then' '  if true; then' scn_unique_ignored_file_is_kept "unique-ignored-file proof"
  expect_caught opened-directory-children-unchecked $lib '          fm_mp_classify_entry "$copy" "$rel/$child" || return 1' '          fm_mp_classify_entry "$copy" "$rel/$child" || true' scn_wholly_ignored_tac_caches_are_the_named_exception "proof of each child of an opened ignored directory"
  expect_caught every-claude-untracked-line-skipped $lib 'grep -Fxv -- "?? ${nested#"$copy"/}/"' 'grep -v -- "^?? .claude/"' scn_unignored_nested_clone_does_not_hide_an_untracked_file "skipping only a nested copy's own untracked line"
  expect_caught nested-clone-not-proved-once-its-line-is-skipped $orch '    fm_mp_prove_git "$n" "" "$1" "$(proof_scope "$n" "$project")" || return 1' '    :' scn_unignored_nested_clone_with_unpushed_work_is_kept "own git proof of a nested clone whose untracked line is skipped"
  expect_caught conformance-manifest-by-path-suffix $lib '    scripts/hooks/_conformance_manifest.json) return 0 ;;' '    *scripts/hooks/_conformance_manifest.json) return 0 ;;' scn_ignored_entries_get_teardowns_verdict "exact path of the conformance manifest"
  expect_caught conformance-manifest-by-name-prefix $lib '    scripts/hooks/_conformance_manifest.json) return 0 ;;' '    scripts/hooks/_conformance_manifest.json*) return 0 ;;' scn_ignored_entries_get_teardowns_verdict "exact name of the conformance manifest"
  expect_caught scratch-list-adds-a-name-teardown-lacks $lib '    .next|graphify-out|.import_linter_cache|*.tsbuildinfo) return 0 ;;' '    .next|graphify-out|.import_linter_cache|*.tsbuildinfo|build) return 0 ;;' scn_ignored_entries_get_teardowns_verdict "scratch list kept equal to teardown's"
  expect_caught no-pool-slot-check $orch '  if ! real=$(fm_mp_real "$wt") || ! fm_treehouse_pool_slot "$project" "$real"; then' '  if ! real=$(fm_mp_real "$wt"); then' scn_plain_git_tree_is_not_a_pool_copy "pool-slot proof"
  expect_caught no-pool-slot-check-outside-the-pool $orch '  if ! real=$(fm_mp_real "$wt") || ! fm_treehouse_pool_slot "$project" "$real"; then' '  if ! real=$(fm_mp_real "$wt"); then' scn_non_pool_copy_is_kept "pool-slot proof (outside the pool)"
  expect_caught no-second-classification $orch '  if ! reapable; then
    fm_project_lock_release "$plock" || true' '  if false; then
    fm_project_lock_release "$plock" || true' scn_worker_steered_after_the_first_verdict "second idle classification under the project lock"
  expect_caught no-second-classification-busy $orch '  if ! reapable; then
    fm_project_lock_release "$plock" || true' '  if false; then
    fm_project_lock_release "$plock" || true' scn_worker_busy_after_the_first_verdict "second idle classification under the project lock (busy)"
  expect_caught ignored-listing-status-is-tr $lib 'listing=$(set -o pipefail; git -C "$copy" ls-files -o -i' 'listing=$(git -C "$copy" ls-files -o -i' scn_failing_ignored_listing_keeps_the_copy "checked ignored-file listing"
  expect_caught tracked-listing-status-is-sed $lib 'gitlinks=$(set -o pipefail; git -C' 'gitlinks=$(git -C' scn_failing_tracked_listing_keeps_the_copy "checked tracked-file listing"
  expect_caught stash-listing-failure-is-nothing $lib 'listing=$(git -C "$copy" stash list --format=%gs 2>/dev/null) || return 1' 'listing=$(git -C "$copy" stash list --format=%gs 2>/dev/null) || true' scn_failing_stash_listing_is_retried "checked stash listing"
  expect_caught find-status-is-tr $lib 'found=$(set -o pipefail; find "$copy"' 'found=$(find "$copy"' scn_unreadable_scratch_subtree_keeps_the_copy "checked nested-copy search"
  expect_caught claude-listing-failure-is-empty $lib 'if ! children=$(ls -A "$copy/$rel" 2>/dev/null); then' 'children=$(ls -A "$copy/$rel" 2>/dev/null); if false; then' scn_unreadable_claude_directory_keeps_the_copy "checked .claude listing"
  expect_caught allow-leaked-worktree $orch '      *) return 1 ;;' '      *"leaked worktree processes"*) seen=1 ;;
      *) return 1 ;;' scn_leaked_worktree_keeps_the_copy "leaked-worktree refusal"
  expect_caught allow-leaked-tasktmp $orch '      *) return 1 ;;' '      *"leaked tasktmp processes"*) seen=1 ;;
      *) return 1 ;;' scn_leaked_tasktmp_keeps_the_copy "leaked-tasktmp refusal"
  expect_caught allow-launchd-loaded $orch '      *) return 1 ;;' '      *"still loaded after launchctl bootout"*) seen=1 ;;
      *) return 1 ;;' scn_launchd_loaded_keeps_the_copy "launch-agent refusal"
  expect_caught allow-ownership-unproven $orch '      *) return 1 ;;' '      *"whose ownership by"*) seen=1 ;;
      *) return 1 ;;' scn_ownership_unproven_keeps_the_copy "process-ownership refusal"
  expect_caught allow-pipeline $orch '      *) return 1 ;;' '      *"no-mistakes run"*) seen=1 ;;
      *) return 1 ;;' scn_pipeline_refusal_never_falls_back "live-pipeline refusal"
  expect_caught allow-orphan-nested-copy-refusals $orch '      *) return 1 ;;' '      *"stays in pool slot"*|*"contains registered copy"*) seen=1 ;;
      *) return 1 ;;' scn_orphan_nested_copy_refusal_keeps_the_copy "orphan-nested-copy refusal"
  expect_caught allow-unknown-text $orch '      *) return 1 ;;' '      *) seen=1 ;;' scn_unknown_refusal_keeps_the_copy "unknown refusal text"
  expect_caught allow-when-any-line-is-landing $orch '      *) return 1 ;;' '      *) ;;' scn_mixed_refusals_keep_the_copy "every-line rule"
  expect_caught pane-exempts-any-process $lib '  [ "$(fm_agent_process_classify_name "$comm")" = shell ] || return 1' '  :' scn_pane_agent_left_running_keeps_the_copy "shell-only pane exemption"
  expect_caught pane-exempts-busy-shell $lib '      if (child) exit 1' '      if (0) exit 1' scn_pane_busy_shell_keeps_the_copy "idle-shell-only pane exemption"
  expect_caught pane-exempts-any-shell $lib '        if (p == pane) exit 0' '        if (1) exit 0' scn_stray_shell_keeps_the_copy "pane-ancestry pane exemption"
  expect_caught independent-clone-proved-as-linked $orch "    printf 'all'" "    printf 'own'" scn_independent_clone_side_branch_and_stash_is_kept "full proof of an independent clone"
  expect_caught independent-clone-branches-ignored $lib '  [ "$scope" != all ] || refs+=(--branches)' '  :' scn_independent_clone_side_branch_is_kept "every-local-branch proof of an independent clone"
  expect_caught independent-clone-stashes-filtered $lib '    if [ "$scope" = all ]; then n=$((n + 1)); continue; fi' '    :' scn_independent_clone_side_stash_is_kept "every-stash proof of an independent clone"
  expect_caught own-branch-stash-ignored $lib '    if [ -z "$branch" ] || [ -z "$name" ] || [ "$name" = "(no branch)" ] || [ "$name" = "$branch" ]; then' '    if false; then' scn_linked_slot_own_branch_stash_is_kept "own-branch stash proof"
  expect_caught detached-copy-ignores-stashes $lib '    if [ -z "$branch" ] || [ -z "$name" ]' '    if [ -z "$name" ]' scn_linked_detached_slot_keeps_every_stash "detached-copy stash proof"
  expect_caught linked-own-unpushed-ignored $lib '  if [ "$unpushed" != 0 ]; then' '  if false; then' scn_linked_slot_own_unpushed_commit_is_kept "own unpushed-commit proof in a linked slot"
  expect_caught pushed-follow-up-counts-as-landed $lib '  [ -z "$prn" ] || fm_mp_prove_landed "$copy" "$prsha" || return 1' '  :' scn_pushed_but_unmerged_copy_is_kept "landed-in-the-merged-PR proof"
  expect_caught non-github-guard-removed $orch '  if [[ ! "$R_PR" =~ ^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then' '  if false; then' scn_enterprise_pr_keeps_the_copy "github.com-only guard"
  expect_caught non-github-guard-removed-forgejo $orch '  if [[ ! "$R_PR" =~ ^https://github[.]com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then' '  if false; then' scn_forgejo_pr_keeps_the_copy "github.com-only guard (Forgejo)"
  expect_caught fetch-back-in-the-lock $orch '  if ! prove_all "$real" "$pr_number" nofetch; then' '  if ! prove_all "$real" "$pr_number"; then' scn_hung_remote_never_holds_the_project_lock "no-fetch re-proof under the locks"
  expect_caught nested-fetch-back-in-the-lock $orch '  prove_nested_git "$mode" || { record_verdict "$real"; return 1; }' '  prove_nested_git fetch || { record_verdict "$real"; return 1; }' scn_hung_remote_never_holds_the_project_lock "no-fetch nested re-proof under the locks"
  expect_caught bare-pane-shell-exempt $lib '      if (child) exit 1
      p = parent[p]
' '      if (child) exit 1
' scn_bare_pane_shell_keeps_the_copy "strict-descendant rule"
  expect_caught pane-shell-cwd-not-required $lib '  case "$cwd" in "$copy"|"$copy"/*) ;; *) return 1 ;; esac' '  :' scn_pane_shell_working_elsewhere_keeps_the_copy "pane-shell working-directory proof"
  expect_caught sigkill-instead-of-sighup $lib '  kill -HUP "$pid" 2>/dev/null || return 1' '  kill -KILL "$pid" 2>/dev/null || return 1' scn_stubborn_pane_shell_keeps_the_copy "SIGHUP-only rule"
  expect_caught no-stop-confirmation $orch '    if [ "$WORKER_STOPPED" != 1 ]; then' '    if false; then' scn_unconfirmed_stop_leaves_the_pane_shell "agent-stopped proof"
  expect_caught exit-accepted-outside-the-prune $reap '  [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ] || return 1' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "merge-prune-only rule"
  expect_caught exit-accepted-without-marker $reap '  [ -f "$1/$2.control-exit" ] && [ ! -L "$1/$2.control-exit" ]' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "deliberate-exit marker rule"
  expect_caught exit-accepted-with-a-busy-record $reap '  [ "$(fm_busy_record_read "$1" "$2")" = missing ] || return 1' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "retired-busy-record rule"
  expect_caught exit-marker-lifts-a-busy-verdict $reap '    && { [ "${busy%% *}" = busy ] || ! fm_idle_reap_exited_by_control "$state" "$id"; }; then' '    && ! fm_idle_reap_exited_by_control "$state" "$id"; then' scn_busy_worker_with_an_old_exit_marker_is_not_reapable "never lifting a positive busy verdict"
  expect_caught exit-accepted-with-a-live-pane-agent $reap '  fm_mp_pane_agent_gone "$1/$2.meta"' '  :' scn_relaunched_agent_with_an_old_exit_marker_is_kept "positive proof that no agent is left in the pane"
  expect_caught pane-accepts-any-process $lib '      launcher=1
      continue
    fi
    return 1' '      launcher=1
      continue
    fi
    continue' scn_relaunched_agent_with_an_old_exit_marker_is_kept "accepting only shells and one treehouse get in the pane"
  expect_caught pane-accepts-a-second-launcher $lib '    if [ "$launcher" = 0 ] && [ "${comm##*/}" = treehouse ]' '    if [ "${comm##*/}" = treehouse ]' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "accepting at most one treehouse get"
  expect_caught exit-accepted-with-an-unreadable-pane $lib '  pane=$(fm_mp_pane_pid "$1")
  [ -n "$pane" ] || return 1' '  pane=$(fm_mp_pane_pid "$1")
  [ -n "$pane" ] || return 0' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "failing closed on a pane that cannot be read"
  expect_caught no-slot-owner-check $orch '    mine|absent) ;;' '    mine|absent|other) ;;' scn_reassigned_slot_is_never_destroyed "slot-owner re-read"
  expect_caught no-project-lock $orch '  fm_project_lock_try "$plock" "merge-prune $ID" >/dev/null 2>&1 || rc=$?' '  :' scn_project_lock_busy_backs_off "project lock"
  expect_caught returned-lease-not-read $orch '  [ "$FM_TASK_COPY_SLOT_STATE" != unleased ] || return 0' '  return 0' scn_slot_teardown_keeps_leased_is_left_alone "lease proof of a returned slot"
  expect_caught returned-lease-not-reread $orch '  if returned_slot "$copy" "$project"; then' '  if RETURNED_REAL=$copy; then' scn_returned_copy_leased_again_before_the_retry_is_left "lease re-read under the project lock"
  expect_caught returned-ignored-not-proved $orch '  preserve_all "$real" "$dest" || return 1' '  :' scn_returned_copy_with_unique_ignored_file_is_kept "ignored-file proof of a returned copy"
  expect_caught returned-records-not-preserved $orch '  preserve_all "$real" "$dest" || return 1' '  :' scn_returned_copy_preserves_bug_evidence_first "preserve-list copy of a returned copy"
  expect_caught no-project-lock-for-the-returned-copy $orch '  if ! fm_project_lock_try "$plock" "merge-prune $ID" >/dev/null 2>&1; then' '  if false; then' scn_project_lock_busy_backs_off_for_the_returned_copy "project lock for the returned copy"
  expect_caught wake-every-time $orch '  [ "$R_WAKE" = 0 ] || return 0' '  :' scn_changed_file_is_kept "one-wake rule"
  pass "mutation proof (unsafe direction): breaking any safety proof makes its keep case fail"
}

# shellcheck disable=SC2016 # Every mutation old/new text is literal shell source, never expanded here.
test_over_strict_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh orch=fm-merge-prune.sh reap=fm-idle-reap-lib.sh
  expect_caught no-scratch-names $lib '  if fm_mp_scratch_name "$name"; then' '  if false; then' scn_scratch_copy_is_removed "scratch patterns"
  expect_caught pane-launcher-never-accepted $lib '    if [ "$launcher" = 0 ] && [ "${comm##*/}" = treehouse ]' '    if false && [ "${comm##*/}" = treehouse ]' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "accepting the pane's one treehouse get"
  expect_caught no-claude-scratch $lib '    .claude/settings.local.json|.opencode/plugins/fm-busy-state.js) return 0 ;;' '    .opencode/plugins/fm-busy-state.js) return 0 ;;' scn_scratch_copy_is_removed ".claude hook-file rule"
  expect_caught no-tac-scratch $lib '    .tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) return 0 ;;' '    .tac/NEVER) return 0 ;;' scn_scratch_copy_is_removed ".tac scratch rule"
  expect_caught nested-clone-line-counts $lib 'grep -Fxv -- "?? ${nested#"$copy"/}/"' 'cat' scn_unignored_nested_clone_goes_with_the_slot "skipping a nested copy's untracked directory"
  expect_caught unignored-nested-clone-left-for-the-destroy $orch '  if ! fm_mp_remove_unignored_nested "$real"; then' '  if false; then' scn_unignored_nested_clone_goes_with_the_slot "removing an unignored nested clone before the destroy"
  expect_caught unignored-nested-worktree-left-for-the-destroy $lib '      git --git-dir="$common" worktree remove "$n" >/dev/null 2>&1' '      :' scn_unignored_nested_worktree_goes_with_the_slot "removing an unignored nested linked worktree before the destroy"
  expect_caught no-conformance-manifest-scratch $lib '    scripts/hooks/_conformance_manifest.json) return 0 ;;' '    scripts/hooks/NEVER) return 0 ;;' scn_ignored_entries_get_teardowns_verdict "conformance manifest rule"
  expect_caught scratch-list-drops-a-name-teardown-has $lib '    .next|graphify-out|.import_linter_cache|*.tsbuildinfo) return 0 ;;' '    graphify-out|.import_linter_cache|*.tsbuildinfo) return 0 ;;' scn_ignored_entries_get_teardowns_verdict "scratch list kept equal to teardown's"
  expect_caught wholly-ignored-tac-not-opened $lib '    .claude|.opencode|.claude/worktrees|.opencode/plugins|.tac)' '    .claude|.opencode|.claude/worktrees|.opencode/plugins)' scn_wholly_ignored_tac_caches_are_the_named_exception "opening a wholly ignored .tac/ one level at a time"
  expect_caught no-preserve-list $lib '    .claude/bug-evidence|.claude/bug-evidence/*|.claude/channel-outbox|.claude/channel-outbox/*)' '    .claude/NEVER-MATCHES)' scn_scratch_copy_is_removed "preserve list"
  expect_caught pane-agent-not-exempt $lib '    [ "$(fm_agent_process_classify "$comm" "${args%% *}" "$args" "$p")" = agent ] || continue' '    continue' scn_pane_agent_does_not_block_teardown "worker-agent exemption before teardown"
  expect_caught pane-shell-not-exempt $lib '    elif [ -z "$FM_MP_PANE_SHELL" ] && fm_mp_pane_shell "$pid" "$pane" "$copy"; then' '    elif false; then' scn_lingering_pane_shell_on_tmux "pane-shell exemption"
  expect_caught nofetch-forgets-pr-head $lib '    [ -z "$prn" ] || prsha=$FM_MP_PR_HEAD' '    :' scn_pr_head_proves_a_squash_merged_commit "reuse of the merged PR head"
  expect_caught other-branches-count-again $lib '  [ "$scope" != all ] || refs+=(--branches)' '  refs+=(--branches)' scn_linked_slot_ignores_other_tasks_work "own-work-only branch proof"
  expect_caught linked-slot-stashes-all-count $lib '    if [ "$scope" = all ]; then n=$((n + 1)); continue; fi' '    n=$((n + 1)); continue' scn_linked_slot_ignores_other_tasks_work "own-work-only stash proof (every stash counts)"
  expect_caught other-branch-stash-counts $lib '    if [ -z "$branch" ] || [ -z "$name" ] || [ "$name" = "(no branch)" ] || [ "$name" = "$branch" ]; then' '    if true; then' scn_linked_slot_ignores_other_tasks_work "own-work-only stash proof"
  expect_caught pane-shell-never-signaled $lib '  kill -HUP "$pid" 2>/dev/null || return 1' '  :' scn_lingering_pane_shell_on_herdr "SIGHUP step"
  expect_caught exit-never-accepted $reap '  [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ] || return 1' '  return 1' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "stopped-worker acceptance"
  expect_caught empty-checksums-fail $lib '  [ ! -s "$dest/SHA256SUMS" ] || (cd "$dest"' '  (cd "$dest"' scn_empty_preserve_paths_do_not_keep_the_copy "empty-manifest rule"
  expect_caught long-reason-relogs fm-merge-prune.sh '  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$(clean_detail "$reason")" ] && changed=0' '  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$reason" ] && changed=0' scn_long_reason_is_logged_once "saved-reason comparison"
  expect_caught ship-not-landed-not-allowed $orch '      "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion.") seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_ship_not_landed_is_settled "ship-deliverable landing refusal"
  expect_caught closeout-foreign-not-allowed $orch '      "REFUSED: Vernant'"'"'s closeout driver did not release foreign copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_landing_refusal_via_closeout_foreign "foreign-copy closeout refusal"
  expect_caught closeout-own-not-allowed $orch '      "REFUSED: Vernant'"'"'s closeout driver did not release own nested copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_closeout_own_is_settled "own-nested-copy closeout refusal"
  expect_caught no-checksums $lib '      shasum -a 256 -- "$file" || exit 1' '      :' scn_scratch_copy_is_removed "checksum manifest"
  expect_caught indexer-counts-as-use $lib '    if fm_mp_indexer_pid "$pid"; then' '    if false; then' scn_search_indexer_does_not_keep_the_copy "search-indexer exemption"
  expect_caught pr-head-ignored $lib '  [ -z "$prsha" ] || extra=("$prsha")' '  extra=()' scn_pr_head_proves_a_squash_merged_commit "merged-PR-head proof"
  expect_caught landed-proof-needs-the-pr-head $lib '  if [ -n "$prsha" ] && git -C "$copy" merge-base --is-ancestor "$head" "$prsha" 2>/dev/null; then
    return 0
  fi
' '' scn_pr_head_alone_proves_a_commit_the_default_branch_lacks "merged-PR-head landing rule"
  expect_caught landed-proof-needs-the-default-branch $lib '    && [ "${merged%%$'"'"'\n'"'"'*}" = "$tree" ]; then' '    && false; then' scn_squash_merged_copy_after_the_default_branch_moved_on "default-branch content landing rule"
  expect_caught probe-error-on-silent-exit-1 $lib '  if [ "$rc" -gt 1 ] || [ -n "$err" ]; then' '  if [ "$rc" -gt 0 ] || [ -n "$err" ]; then' scn_failed_process_probe_keeps_the_copy "silent exit 1 means nothing is open"
  expect_caught every-claim-is-another-home fm-merge-prune.sh '  if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] && ! same_home "$FM_TREEHOUSE_SLOT_OWNER_HOME"; then' '  if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ]; then' scn_scratch_copy_is_removed "own-home slot claim"
  expect_caught clone-under-claude-worktrees-kept $lib '      if [ -e "$copy/$rel/.git" ]; then' '      if false; then' scn_unique_data_under_claude_or_opencode_is_kept "clone under .claude/worktrees"
  expect_caught nested-never-passes fm-merge-prune.sh '    fm_mp_prove_git "$n" "" "$1" "$(proof_scope "$n" "$project")" || return 1' '    false || return 1' scn_clean_nested_copy_goes_with_the_slot "nested-copy removal"
  pass "mutation proof (over-strict direction): tightening any permission makes its removal case fail"
}

# --- 5. end to end through the real teardown --------------------------------------
#
# The fake pool, the real bin/fm-teardown.sh, and the real prune scripts. Only
# the outside world is stubbed: tmux, gh-axi/gh (the merged PR), no-mistakes and
# treehouse (whose `return` and `destroy` both remove the fake copy).

# make_e2e_world: make_world plus a project clone, the stubs real teardown calls,
# and a pool lease record, so teardown can run against the pool copy.
make_e2e_world() {
  local head
  make_world
  git -C "$W/project" remote set-head origin main 2>/dev/null || true
  mkdir -p "$W/code-root" "$W/primary-home"
  ln -s "$ROOT/bin" "$W/code-root/bin"
  cat > "$W/bin/treehouse" <<'SH'
#!/usr/bin/env bash
# Fake pool: `return` resets the slot in place, as the real tool does (detached
# at origin/main, clean, still in the pool, its lease released in the pool's
# treehouse-state.json), and the reaper's `destroy` removes the slot.
printf '%s\n' "$*" >> "$TH_LOG"
case "${1:-}" in
  return)
    for a in "$@"; do wt=$a; done
    git -C "$wt" checkout -q --detach origin/main && git -C "$wt" reset -q --hard && git -C "$wt" clean -ffdxq || exit $?
    real=$(cd "$wt" && pwd -P) || exit 1
    st="${real%/*/*}/treehouse-state.json"
    tmp=$(mktemp "$st.XXXXXX") || exit 1
    jq --arg a "$wt" --arg b "$real" '.worktrees |= map(if (.path == $a or .path == $b) then (.leased = false | del(.lease_holder)) else . end)' "$st" > "$tmp" && mv -f "$tmp" "$st"
    exit $? ;;
  destroy)
    [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ] || { echo "stub treehouse: unexpected arguments: $*" >&2; exit 9; }
    case "$2" in "$TREEHOUSE_ROOT"/*/*/*) ;; *) echo "stub treehouse: outside the fake pool" >&2; exit 3 ;; esac
    [ ! -s "${TH_FAIL:-/dev/null}" ] || { echo "stub treehouse: destroy refused" >&2; exit 4; }
    "$(dirname "$0")/th-gate" "$2" || exit 1
    "$(dirname "$0")/th-remove" "$2"; exit 0 ;;
esac
exit 0
SH
  # The real teardown, with every call it is given recorded.
  cat > "$W/bin/teardown-real" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
# A case may make teardown refuse the way the 2026-10-18 closeout driver did, so
# the fallback alone decides; it refuses only while the copy is there.
copy=$(sed -n 's/^worktree=//p' "$FM_STATE_OVERRIDE/$1.meta" 2>/dev/null)
if [ -e "$REFUSE_FLAG" ] && [ -e "$copy" ]; then
  echo "REFUSED: Vernant's closeout driver did not release foreign copy /pool/1/repo/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2
  exit 1
fi
exec "$ROOT/bin/fm-teardown.sh" "$@"
SH
  chmod +x "$W/bin/teardown-real"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/no-mistakes"
  head=$(git -C "$COPY" rev-parse HEAD)
  cat > "$W/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
  cat > "$W/bin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED '$head' ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$head' 'https://github.com/acme/widget/pull/7'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head'; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$W/bin/treehouse" "$W/bin/no-mistakes" "$W/bin/gh-axi" "$W/bin/gh"
  fm_fake_docker "$W/bin"
  fm_write_meta "$STATE/t1.meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" "worktree=$COPY" \
    "project=$W/project" "kind=ship" "mode=no-mistakes" "spawn_gen=e2e-t1" "harness=claude" "backend=tmux" \
    "pr=$PR" "pr_head=$head"
  touch "$STATE/.last-watcher-beat"
}

# prune_real <args...>: the prune scripts with the REAL teardown and control.
prune_real() {
  HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_ROOT_OVERRIDE="$W/code-root" NM_HOME="$W/nm" \
    TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" TH_LOG="$W/th.log" TH_FAIL="$W/th.fail" FM_MERGE_PRUNE_EXIT_WAIT="${FM_MERGE_PRUNE_EXIT_WAIT:-0}" \
    FM_TEARDOWN_GUARD_DONE=1 ROOT="$ROOT" STUB_LOG="$W/stub.log" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-real" REFUSE_FLAG="$W/refuse" \
    FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" \
    PANE_PID_FILE="$W/pane.pid" STEAL_FILE="$W/steal" SLOT_MARKER="$POOL/pool1/1/.fm-slot-owner" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" \
    "$BIN_DIR/fm-merge-prune.sh" "$@"
}

wake_count_real() { wake_count; }

# Nothing is forced: teardown is only ever asked for the task by name, and the
# fallback's treehouse calls never carry a force or an include-unlanded flag.
# (Teardown's own `treehouse return --force` is the landed-work-guarded return
# of the slot it has just proved safe; it is not a forced teardown.)
assert_nothing_forced() {  # <label>
  if [ -s "$W/stub.log" ] && grep -qvx 't1' "$W/stub.log"; then
    fail "$1: teardown was asked with extra arguments: $(cat "$W/stub.log")"
  fi
  if grep -Eq -- '--include-unlanded|--include-in-use|^destroy .*--force' "$W/th.log"; then
    fail "$1: treehouse was forced: $(cat "$W/th.log")"
  fi
}

assert_not_destroyed() {  # <label>
  if grep -q '^destroy ' "$W/th.log"; then
    fail "$1: a copy was destroyed: $(cat "$W/th.log")"
  fi
}

# Real teardown returns the slot to the pool, reset in place, and the copy is
# still on disk; the prune then removes it with the reaper's call. The copy is
# gone, teardown returned the slot first, and the removal was never forced.
assert_copy_removed() {
  [ ! -e "$COPY" ] || fail "the returned copy is still on disk: $COPY"
  grep -q '^return ' "$W/th.log" || fail "teardown did not return the slot through treehouse"
  grep -q "^destroy .* --include-leased --yes\$" "$W/th.log" || fail "the returned copy was not removed with the reaper's call: $(cat "$W/th.log")"
  [ "$(destroy_calls)" = 1 ] || fail "want exactly one removal, got $(destroy_calls)"
}

test_e2e_merge_prunes_the_copy_with_the_real_teardown() {
  make_e2e_world
  prune_real arm t1 --run || fail "arm --run failed"
  fm_test_wait_until 60 grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the detached attempt did not finish: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null)"
  [ ! -e "$COPY" ] || fail "the copy is still on disk after the prune reported it reaped"
  assert_copy_removed
  [ "$(reaped_wake_count)" = 1 ] || fail "want exactly one reaped outcome where Main sees it, got $(reaped_wake_count): $(cat "$STATE/.wake-queue" 2>/dev/null)"
  [ ! -e "$STATE/t1.meta" ] || fail "the task record is still there: real teardown did not complete"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped: $(cat "$DATA/t1/merge-prune.log")"
  [ "$(wake_count_real)" = 0 ] || fail "a clean prune raised a wake"
  grep -q '^return ' "$W/th.log" || fail "teardown did not return the slot through treehouse"
  assert_nothing_forced "e2e merge"
  pass "end to end: a verified merge arms the prune, the detached run reaps the copy through the real teardown, the copy is gone, and the log and one wake say reaped"
}

test_e2e_transient_contention_retries_then_succeeds() {
  local holder
  make_e2e_world
  prune_real arm t1
  # Another lifecycle action (a co-tenant's control action) holds the task's
  # lock, so real teardown refuses without changing anything.
  sleep 120 &
  holder=$!
  WORKER_PIDS+=("$holder")
  mkdir "$STATE/.control-t1.lock"
  printf '%s\n' "$holder" > "$STATE/.control-t1.lock/pid"
  prune_real run t1 --now >/dev/null 2>&1
  [ -e "$COPY" ] && [ -e "$STATE/t1.meta" ] || fail "contention closed something: the copy or record is gone"
  [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 attempts)" = 1 ] || fail "contention was not a pending retry: $(cat "$STATE/t1.merge-prune")"
  [ "$(wake_count_real)" = 0 ] || fail "contention raised a wake"
  assert_nothing_forced "e2e contention"
  assert_not_destroyed "e2e contention"
  prune_real run t1 >/dev/null 2>&1
  [ -e "$STATE/t1.meta" ] || fail "a retry ran before its backoff elapsed"
  kill "$holder" 2>/dev/null || true
  rm -rf "$STATE/.control-t1.lock"
  set_rec t1 next_at 0
  prune_real run t1 >/dev/null 2>&1
  [ ! -e "$STATE/t1.meta" ] && [ ! -e "$STATE/t1.merge-prune" ] || fail "the retry after the contention cleared did not reap: $(cat "$DATA/t1/merge-prune.log")"
  [ ! -e "$COPY" ] || fail "the copy is still on disk after the prune reported it reaped"
  assert_copy_removed
  [ "$(reaped_wake_count)" = 1 ] || fail "want exactly one reaped outcome where Main sees it, got $(reaped_wake_count): $(cat "$STATE/.wake-queue" 2>/dev/null)"
  grep -q 'retry in' "$DATA/t1/merge-prune.log" || fail "the log does not show the retry and then reaped"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not show the retry and then reaped"
  pass "end to end: a co-tenant's lifecycle lock makes the real teardown refuse, the prune retries later without a wake, and then reaps"
}

# The slot teardown returned cannot be removed (the pool refuses): the copy and
# the prune record stay, the one wake names the copy, and no force is tried. The
# task record is already gone, so the retry that follows the cleared refusal
# removes the copy from the prune record alone and reports the outcome.
test_e2e_removal_refused_after_teardown_keeps_the_record_and_wakes_once() {
  make_e2e_world
  printf 'refuse\n' > "$W/th.fail"
  prune_real arm t1
  prune_real run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.meta" ] || fail "real teardown did not complete"
  [ -e "$COPY" ] || fail "the copy vanished although the pool refused its removal"
  [ -e "$STATE/t1.merge-prune" ] || fail "the prune record was cleared while the copy is still on disk"
  [ "$(rec_field t1 state)" = retained ] || fail "the refused removal is not retained: $(cat "$STATE/t1.merge-prune")"
  [ "$(wake_count_real)" = 1 ] || fail "want exactly one wake for the refused removal, got $(wake_count_real)"
  [ "$(reaped_wake_count)" = 0 ] || fail "a copy that stays was reported reaped"
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'treehouse destroy refused' || fail "the wake does not name the copy and the refusal: $(cat "$STATE/.wake-queue")"
  assert_nothing_forced "e2e refused removal"
  : > "$W/th.fail"
  set_rec t1 next_at 0
  prune_real run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] || fail "the retry did not remove the returned copy"
  [ ! -e "$STATE/t1.merge-prune" ] || fail "the prune record outlived the removal"
  [ "$(wake_count_real)" = 1 ] && [ "$(reaped_wake_count)" = 1 ] || fail "want the one kept wake and one reaped outcome, got $(wake_count_real) and $(reaped_wake_count)"
  assert_nothing_forced "e2e refused removal, retried"
  pass "end to end: a refused removal of the returned copy keeps the copy and the prune record with one wake, and the retry removes it and reports reaped"
}

# A worker stopped with `fm-control.sh exit` before its PR merged: its busy
# record is gone and its exit marker is older than the arm. Its terminal pane
# holds only its `treehouse get` and the idle shell that opened in the copy, so
# the first, real teardown accepts it and the copy is pruned with no human step.
test_e2e_worker_exited_before_the_merge_is_pruned() {
  make_e2e_world
  FM_STATE_OVERRIDE="$STATE" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" STEAL_FILE="$W/steal" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" SLOT_MARKER=/dev/null \
    "$W/bin/control-stub" t1 exit || fail "the stand-in exit verb failed"
  [ ! -e "$STATE/t1.busy-state" ] && [ -f "$STATE/t1.control-exit" ] || fail "the exit verb did not retire the busy record and mark the exit"
  fm_touch_epoch "$OLD" "$STATE/t1.control-exit"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  prune_real arm t1
  prune_real run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.meta" ] || fail "a worker stopped before the merge kept its task: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null) $(cat "$STATE/t1.merge-prune" 2>/dev/null)"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped: $(cat "$DATA/t1/merge-prune.log")"
  [ ! -e "$COPY" ] || fail "the copy is still on disk after the prune reported it reaped"
  assert_copy_removed
  [ "$(reaped_wake_count)" = 1 ] || fail "want exactly one reaped outcome where Main sees it, got $(reaped_wake_count): $(cat "$STATE/.wake-queue" 2>/dev/null)"
  [ "$(wake_count_real)" = 0 ] || fail "a clean prune raised a wake"
  assert_nothing_forced "e2e exited before the merge"
  pass "end to end: a worker stopped with the exit verb before its PR merged, whose pane holds only its treehouse get and idle shell, is pruned through the real teardown with no human step"
}

# Real teardown refuses a squash-merged copy with ignored scratch files (the
# 2026-10-18 closeout driver's refusal). The fallback proves the copy clean,
# pushed and unused, ends the pane's idle shell, `treehouse destroy` removes the
# merged slot, and teardown then finishes the records.
test_e2e_squash_merged_copy_with_ignored_files_is_reaped_by_the_fallback() {
  make_e2e_world
  mkdir -p "$COPY/.claude/bug-evidence" "$COPY/node_modules/x"
  printf 'closeout\n' > "$COPY/.claude/bug-evidence/slot.json"
  printf x > "$COPY/node_modules/x/i.js"
  : > "$W/refuse"
  prune_real arm t1
  start_inside "$COPY" "$W/worker.pid"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  FM_MERGE_PRUNE_EXIT_WAIT=3 prune_real run t1 --now >/dev/null 2>&1
  if [ -e "$STATE/t1.merge-prune" ] && grep -q 'process(es) inside' "$STATE/t1.merge-prune"; then
    fail "the finished worker or the pane's idle shell kept the copy: $(cat "$STATE/t1.merge-prune")"
  fi
  kill -0 "$(cat "$W/pane.pid")" 2>/dev/null || fail "the pane was closed"
  [ ! -e "$COPY" ] || fail "the copy was not removed by the fallback: $(cat "$DATA/t1/merge-prune.log")"
  [ ! -e "$STATE/t1.meta" ] || fail "teardown did not finish the records after the fallback: $(cat "$DATA/t1/merge-prune.log")"
  grep -q 'fallback destroyed' "$DATA/t1/merge-prune.log" || fail "the log does not say the fallback destroyed it"
  grep -q 'reaped: removed by fallback' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped"
  grep -qx "destroy $COPY --include-leased --yes" "$W/th.log" || fail "the fallback did not call destroy as the reaper does: $(cat "$W/th.log")"
  find "$DATA/t1/merge-prune-preserved" -name slot.json | grep -q . || fail "the bug-evidence record was not preserved before removal"
  [ "$(wake_count_real)" = 0 ] || fail "a reaped copy raised a wake"
  assert_nothing_forced "e2e fallback"
  pass "end to end: a squash-merged copy with ignored files that teardown refuses is removed by the fallback, preserved records first, and teardown then closes the task"
}

# Real teardown refuses a copy that went on after its PR merged (a stale PR
# head). The follow-up commit is pushed but not merged. Ending the pane's
# `treehouse get` subshell would return the slot to the pool, reset to
# origin/main, and `treehouse destroy` would then see nothing unmerged. So the
# fallback proves the commit is not in the merged PR before it stops anything:
# the copy stays, the pane shell is not ended, treehouse is not called, and one
# wake names it.
test_e2e_pushed_follow_up_commit_after_the_merge_keeps_the_copy() {
  make_e2e_world
  printf 'follow-up\n' > "$COPY/followup.txt"
  git -C "$COPY" add followup.txt
  git -C "$COPY" commit -q -m "follow-up after the merge"
  git -C "$COPY" push -q origin fm/t1
  prune_real arm t1
  start_inside "$COPY" "$W/worker.pid"
  start_pane "$COPY" bash "$W/bin/pane-returns-slot" "$W/hold" "$COPY"
  FM_MERGE_PRUNE_EXIT_WAIT=3 prune_real run t1 --now >/dev/null 2>&1
  [ -e "$COPY" ] || fail "an unmerged copy was removed: $(cat "$DATA/t1/merge-prune.log")"
  [ -e "$STATE/t1.meta" ] || fail "the task record was closed over a kept copy"
  [ "$(git -C "$COPY" symbolic-ref -q --short HEAD)" = fm/t1 ] || fail "the slot was returned to the pool under its unmerged commit"
  kill -0 "$PANE_CHILD" 2>/dev/null || fail "the pane shell was ended over a copy that stays"
  assert_not_destroyed "e2e unmerged"
  [ "$(wake_count_real)" = 1 ] || fail "want exactly one wake, got $(wake_count_real): $(cat "$STATE/.wake-queue" 2>/dev/null)"
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'not in the merged pull request' || fail "the wake does not name the copy and that its commit is not in the merged pull request: $(cat "$STATE/.wake-queue")"
  assert_nothing_forced "e2e unmerged"
  prune_real run t1 --now >/dev/null 2>&1; prune_real run t1 --now >/dev/null 2>&1
  [ "$(wake_count_real)" = 1 ] || fail "repeat attempts raised more wakes"
  pass "end to end: a copy with a pushed follow-up commit that is not merged stays before anything is stopped, forces nothing and raises exactly one wake"
}

test_e2e_unsafe_copies_are_never_removed() {
  local what
  for what in dirty unpushed nested-unpushed; do
    make_e2e_world
    case "$what" in
      dirty) printf 'edit\n' >> "$COPY/README.md" ;;
      unpushed)
        printf 'new\n' > "$COPY/new.txt"; git -C "$COPY" add new.txt; git -C "$COPY" commit -q -m "unpushed work" ;;
      nested-unpushed)
        : > "$W/refuse"
        git clone -q "$ORIGIN" "$COPY/.claude/worktrees/n1" 2>/dev/null
        printf 'o\n' > "$COPY/.claude/worktrees/n1/o.txt"
        git -C "$COPY/.claude/worktrees/n1" add o.txt
        git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed in nested" ;;
    esac
    prune_real arm t1
    prune_real run t1 --now >/dev/null 2>&1
    [ -e "$COPY" ] || fail "$what: an unsafe copy was removed"
    [ -e "$STATE/t1.meta" ] || fail "$what: the task record was closed over an unsafe copy"
    assert_nothing_forced "e2e $what"
    assert_not_destroyed "e2e $what"
    [ "$(wake_count_real)" = 1 ] || fail "$what: want exactly one wake, got $(wake_count_real): $(cat "$STATE/.wake-queue" 2>/dev/null)"
    grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'merge-prune kept' || fail "$what: the wake does not name the copy"
    prune_real run t1 --now >/dev/null 2>&1; prune_real run t1 --now >/dev/null 2>&1
    [ "$(wake_count_real)" = 1 ] || fail "$what: repeat attempts raised more wakes"
    cleanup_workers
  done
  pass "end to end: a changed file, an unpushed commit and an unpushed NESTED commit each keep the copy, force nothing, and raise exactly one wake"
}

# --- run ----------------------------------------------------------------------
#
# Usage: bash tests/fm-merge-prune.test.sh [test_function_name ...]

ALL_TESTS=(
  test_arm_needs_a_verified_merge
  test_arm_skips_tasks_it_does_not_own
  test_run_not_due_does_nothing
  test_missing_task_or_changed_pr_drops_the_record
  test_merge_cleanup_runs_teardown_unforced
  test_transient_refusals_back_off_silently_then_succeed
  test_flaky_contention_retries_through_the_sweep
  test_backoff_doubles_to_a_cap_and_wakes_once
  test_sweep_runs_only_due_records_and_at_most_three
  test_fallback_removes_a_clean_pushed_unused_scratch_copy
  test_fallback_keeps_a_changed_file
  test_fallback_keeps_an_untracked_file
  test_fallback_keeps_an_untracked_file_that_git_config_hides
  test_fallback_keeps_a_nested_copy_with_an_untracked_file_that_git_config_hides
  test_fallback_keeps_a_changed_submodule_that_git_config_hides
  test_fallback_keeps_an_unpushed_commit
  test_fallback_keeps_a_stash
  test_fallback_keeps_a_live_process
  test_fallback_nested_unpushed_commit_keeps_the_slot
  test_nested_clone_unpushed_commit_keeps_the_slot_before_teardown
  test_nested_worktree_unpushed_commit_keeps_the_slot_before_teardown
  test_pane_job_keeps_the_copy_before_teardown
  test_pane_agent_does_not_block_teardown
  test_fallback_removes_a_clean_nested_copy_with_the_slot
  test_fallback_removes_an_unignored_clean_nested_clone_with_the_slot
  test_fallback_removes_an_unignored_clean_nested_worktree_with_the_slot
  test_fallback_keeps_an_untracked_file_beside_an_unignored_nested_clone
  test_fallback_keeps_an_unignored_nested_clone_with_unpushed_work
  test_fallback_judges_ignored_entries_like_teardown
  test_fallback_counts_the_caches_of_a_wholly_ignored_tac_as_scratch
  test_fallback_keeps_unique_ignored_files
  test_fallback_keeps_a_non_pool_copy
  test_fallback_keeps_a_plain_git_tree_shaped_like_a_slot
  test_fallback_does_not_stop_a_worker_steered_after_the_first_verdict
  test_fallback_does_not_stop_a_worker_busy_after_the_first_verdict
  test_fallback_keeps_the_copy_when_the_ignored_listing_fails
  test_fallback_keeps_the_copy_when_the_tracked_listing_fails
  test_fallback_retries_when_the_stash_listing_fails
  test_fallback_keeps_the_copy_when_a_subtree_cannot_be_searched
  test_fallback_keeps_the_copy_when_the_claude_directory_cannot_be_listed
  test_fallback_accepts_the_merged_pr_head
  test_fallback_accepts_a_commit_only_the_merged_pr_head_carries
  test_fallback_removes_a_squash_merged_copy_after_main_moved_on
  test_fallback_ignores_a_search_indexer
  test_fallback_never_overrides_a_live_pipeline_refusal
  test_fallback_settles_a_ship_deliverable_not_landed_refusal
  test_fallback_keeps_the_copy_on_an_orphan_nested_copy_refusal
  test_fallback_keeps_an_independent_clone_with_an_unpushed_side_branch
  test_fallback_keeps_an_independent_clone_with_a_stash_of_a_side_branch
  test_fallback_keeps_an_independent_clone_with_side_work_of_both_kinds
  test_fallback_settles_an_own_nested_copy_closeout_refusal
  test_fallback_keeps_the_copy_on_leaked_worktree_processes
  test_fallback_keeps_the_copy_on_leaked_tasktmp_processes
  test_fallback_keeps_the_copy_while_a_launch_agent_is_loaded
  test_fallback_keeps_the_copy_when_process_ownership_is_not_proven
  test_fallback_keeps_the_copy_on_an_unknown_refusal
  test_fallback_keeps_the_copy_when_any_refusal_line_is_not_a_landing_refusal
  test_fallback_keeps_a_pushed_but_unmerged_copy
  test_fallback_ignores_other_tasks_work_in_a_linked_slot
  test_fallback_keeps_a_linked_slot_with_its_own_unpushed_commit
  test_fallback_keeps_a_linked_slot_with_a_stash_of_its_own_branch
  test_fallback_keeps_a_detached_linked_slot_with_a_stash
  test_fallback_keeps_the_copy_of_a_github_enterprise_pr
  test_fallback_keeps_the_copy_of_a_forgejo_pr
  test_fallback_destroy_failure_keeps_the_copy
  test_retained_copy_is_reaped_quietly_when_the_cause_clears
  test_long_retained_reason_is_logged_once
  test_fallback_ends_the_tasks_idle_pane_shell_on_tmux
  test_fallback_ends_the_tasks_idle_pane_shell_on_herdr
  test_fallback_keeps_a_non_shell_process_in_the_pane
  test_fallback_keeps_an_agent_left_running_in_the_pane
  test_fallback_keeps_a_pane_shell_that_runs_something
  test_fallback_keeps_a_shell_no_pane_started
  test_fallback_keeps_a_pane_shell_that_works_elsewhere
  test_fallback_keeps_a_bare_pane_shell
  test_fallback_never_holds_the_project_lock_on_a_hung_remote
  test_fallback_keeps_the_copy_when_the_pane_shell_ignores_sighup
  test_fallback_leaves_the_pane_shell_until_the_agent_is_confirmed_stopped
  test_deliberately_exited_worker_reads_as_stopped_only_for_the_prune
  test_busy_worker_with_an_old_exit_marker_is_not_reapable
  test_relaunched_agent_with_an_old_exit_marker_is_kept
  test_fallback_exempts_nothing_when_the_pane_is_unreadable
  test_fallback_never_destroys_a_reassigned_slot
  test_fallback_keeps_a_clone_inside_a_scratch_directory_with_an_unpushed_commit
  test_fallback_keeps_unique_data_under_claude_and_opencode
  test_fallback_keeps_the_copy_when_the_process_probe_fails
  test_fallback_keeps_the_copy_when_the_process_probe_fails_after_listing
  test_partial_process_table_proves_no_agent_gone
  test_fallback_keeps_a_slot_claimed_by_the_same_task_id_of_another_home
  test_failed_wake_append_is_not_recorded_as_sent
  test_fallback_backs_off_while_the_project_lock_is_held
  test_returned_copy_removal_backs_off_while_the_project_lock_is_held
  test_teardown_kept_leased_slot_is_left_alone
  test_copy_that_is_not_a_pool_slot_is_left_after_teardown
  test_returned_copy_leased_again_before_the_retry_is_left
  test_returned_copy_with_unique_ignored_file_is_kept
  test_returned_copy_preserves_bug_evidence_first
  test_fallback_removes_a_copy_whose_preserve_paths_are_empty
  test_e2e_merge_prunes_the_copy_with_the_real_teardown
  test_e2e_transient_contention_retries_then_succeeds
  test_e2e_removal_refused_after_teardown_keeps_the_record_and_wakes_once
  test_e2e_worker_exited_before_the_merge_is_pruned
  test_e2e_squash_merged_copy_with_ignored_files_is_reaped_by_the_fallback
  test_e2e_pushed_follow_up_commit_after_the_merge_keeps_the_copy
  test_e2e_unsafe_copies_are_never_removed
  test_unsafe_mutations_are_caught
  test_over_strict_mutations_are_caught
)
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    declare -F "$name" >/dev/null || fail "unknown test case: $name"
  done
  ALL_TESTS=("$@")
fi
for name in "${ALL_TESTS[@]}"; do
  "$name"
done
