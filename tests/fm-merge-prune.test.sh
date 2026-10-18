#!/usr/bin/env bash
# tests/fm-merge-prune.test.sh - bin/fm-merge-prune.sh and bin/fm-merge-prune-lib.sh.
#
# A merged task's pool copy must be pruned right after its PR merges, with no
# human step, and an unsafe copy must never be removed. This suite drives the
# real scripts against a fake pool in a temp directory: a throwaway
# TREEHOUSE_ROOT, bare origins, real git clones as pool copies, and a stub
# `treehouse` first on PATH that records its arguments and removes the fake
# directory. The real treehouse binary and the real ~/.treehouse are never
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
# ORIGIN and COPY (the task's pool copy: <pool root>/pool1/1/repo). The task's
# project is the clone $W/project.
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
  printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.claude/' '.tac/' '.mypy_cache/' '*.local' > "$seed/.gitignore"
  printf 'readme\n' > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m base
  git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$ORIGIN" "$COPY" 2>/dev/null
  git -C "$COPY" checkout -q -b fm/t1
  printf 'work\n' > "$COPY/work.txt"
  git -C "$COPY" add work.txt
  git -C "$COPY" commit -q -m "task work"
  git -C "$COPY" push -q origin fm/t1
  git clone -q "$ORIGIN" "$W/project" 2>/dev/null
  install_stubs
  mk_task t1 "$COPY"
}

install_stubs() {
  cat > "$W/bin/treehouse" <<'SH'
#!/usr/bin/env bash
# Stand-in for treehouse. It accepts exactly the call the reaper makes and
# removes the fake directory; every other call is logged and refused. Like the
# real tool it refuses a copy that has a process with its working directory
# inside it (the system lsof, not a fixture's); a process that only has a file
# open there does not block it.
printf '%s\n' "$*" >> "$TH_LOG"
if [ "${1:-}" = destroy ] && [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ]; then
  case "$2" in
    "$TREEHOUSE_ROOT"/*/*/*) ;;
    *) echo "stub treehouse: $2 is outside the fake pool" >&2; exit 3 ;;
  esac
  [ ! -s "$TH_FAIL" ] || { echo "stub treehouse: destroy refused" >&2; exit 4; }
  inuse=$(command -p lsof -a -d cwd +D "$2" -t 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -n "${inuse// /}" ]; then
    echo "Skipped 1 worktree: [in-use:${inuse%% *}] $2" >&2
    echo "did not destroy 1 (in-use); re-run with --include-in-use" >&2
    exit 1
  fi
  rm -rf "$2"
  exit 0
fi
echo "stub treehouse: unexpected arguments: $*" >&2
exit 9
SH
  cat > "$W/bin/teardown-stub" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-teardown.sh. Records how it was called, then behaves as
# the mode file says.
printf 'args=%s|admission=%s|prune=%s\n' "$*" "${FM_IDLE_REAP_ADMISSION:-}" "${FM_IDLE_REAP_MERGE_PRUNE:-}" >> "$STUB_LOG"
mode=$(cat "$STUB_MODE" 2>/dev/null || echo ok)
copy=$(sed -n 's/^worktree=//p' "$FM_STATE_OVERRIDE/$1.meta" 2>/dev/null)
done_ok() { rm -f "$FM_STATE_OVERRIDE/$1.meta"; exit 0; }
case "$mode" in
  ok) rm -f "$FM_STATE_OVERRIDE/$1.status"; done_ok "$1" ;;
  flaky)
    n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
    printf '%s\n' $((n + 1)) > "$STUB_COUNT"
    [ "$n" -ge 1 ] || exit 75
    done_ok "$1"
    ;;
  lock) exit 75 ;;
  lease) exit 6 ;;
  timeout) exit 124 ;;
  ineligible) echo "REFUSED: automatic reap ineligible: active: busy state busy" >&2; exit 1 ;;
  lifecycle) echo "error: another lifecycle action is already running for task $1; nothing was changed" >&2; exit 1 ;;
  pipeline) echo "REFUSED: no-mistakes run for $1 is still parked after axi abort" >&2; exit 1 ;;
  false-positive|ship-not-landed|foreign-head|foreign-ignored|own-ignored|closeout-own)
    # The known landing refusals, in the words of bin/fm-teardown.sh and
    # bin/fm-teardown-nested-lib.sh; they stop once the copy is gone.
    if [ -e "$copy" ]; then
      case "$mode" in
        false-positive) echo "REFUSED: Vernant's closeout driver did not release foreign copy $copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2 ;;
        closeout-own) echo "REFUSED: Vernant's closeout driver did not release own nested copy $copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2 ;;
        ship-not-landed)
          echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." >&2
          echo "Land its PR, or get the captain's own words to drop it and pass --force --drop-file." >&2
          ;;
        foreign-head) echo "REFUSED: foreign copy $copy/.claude/worktrees/n1 stays in pool slot $copy: its HEAD 0123456789ab is not proved landed." >&2 ;;
        foreign-ignored) echo "REFUSED: foreign copy $copy/.claude/worktrees/n1 stays in pool slot $copy: it holds ignored files that exist nowhere else: a.local b.local." >&2 ;;
        own-ignored) echo "REFUSED: own nested copy $copy/.claude/worktrees/n1 stays in pool slot $copy: it holds ignored files that exist nowhere else: a.local." >&2 ;;
      esac
      exit 1
    fi
    done_ok "$1"
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
# Stand-in for tmux: answers only the question for the pane's shell pid.
case "$*" in
  *'#{pane_pid}'*) [ -s "$PANE_PID_FILE" ] && cat "$PANE_PID_FILE" ;;
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
  chmod +x "$W/bin/treehouse" "$W/bin/teardown-stub" "$W/bin/control-stub" "$W/bin/tmux" "$W/bin/herdr" \
    "$W/bin/pane-idle" "$W/bin/pane-busy" "$W/bin/pane-stubborn" "$W/bin/pane-holder"
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

wake_count() {
  local n
  n=$(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null) || n=0
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

# A stand-in terminal pane whose agent has exited: the pane process starts
# <command...> with <dir> as its working directory, as the pane started the
# `treehouse get` subshell, and the command is its child (PANE_CHILD). The pane
# process id is what tmux and herdr report as the pane's shell, and the pane
# stays open when its child ends.
PANE_CHILD=
start_pane() {  # <dir> <command...>
  local dir=$1 pid
  shift
  bash -c '(cd "$1" && shift && exec "$@") & wait; exec sleep 300' _ "$dir" "$@" 2>/dev/null &
  pid=$!
  WORKER_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$W/pane.pid"
  fm_test_wait_until 10 sh -c '[ -n "$(pgrep -P "$1")" ]' _ "$pid" || true
  PANE_CHILD=$(pgrep -P "$pid" | sed -n 1p)
  wait_inside "$dir"
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
  fm_test_wait_until 10 sh -c '[ -n "$(lsof -t +D "$1" 2>/dev/null)" ]' _ "$1" || true
}

# The task's terminal pane lives on <tmux|herdr>; the world starts on herdr.
use_pane_backend() {  # <tmux|herdr>
  [ "$1" != tmux ] || sed -i.bak -e 's/^backend=.*/backend=tmux/' -e 's#^window=.*#window=firstmate:fm-t1#' "$STATE/t1.meta"
}

project_lock_path() {
  FM_HOME="$HOME_DIR" bash -c '. "$1/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$BIN_DIR" "$W/project"
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
  [ -s "$W/control.log" ] && [ -z "$(grep -vx 't1 exit' "$W/control.log")" ] || why "the finished worker was not stopped by 't1 exit': $(cat "$W/control.log")" || return 1
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
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a commit proved landed by the PR head kept the copy: $(rec_field t1 reason)" || return 1
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
scn_foreign_head_is_settled() { scn_landing_refusal_is_settled foreign-head; }
scn_foreign_ignored_is_settled() { scn_landing_refusal_is_settled foreign-ignored; }
scn_own_ignored_is_settled() { scn_landing_refusal_is_settled own-ignored; }
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
    PATH="$W/bin:$PATH" "$@" "$BIN_DIR/fm-idle-session-reap.sh" scan 2>/dev/null | grep -q "^reap	t1	"
}

scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune() {
  make_world
  scan_reap || why "the world's finished idle worker is not reapable at all" || return 1
  FM_STATE_OVERRIDE="$STATE" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" STEAL_FILE="$W/steal" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" SLOT_MARKER=/dev/null \
    "$W/bin/control-stub" t1 exit || why "the stand-in exit verb failed" || return 1
  [ ! -e "$STATE/t1.busy-state" ] && [ -f "$STATE/t1.control-exit" ] || why "the exit verb did not retire the busy record and mark the exit" || return 1
  ! scan_reap || why "the ordinary sweep accepted a worker with no busy record" || return 1
  scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune did not accept the worker that its exit verb stopped" || return 1
  mv "$STATE/t1.control-exit" "$W/control-exit.kept"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker with no record of a deliberate exit" || return 1
  mv "$W/control-exit.kept" "$STATE/t1.control-exit"
  printf 'working [at=%s]: more to do\n' "$NOW" >> "$STATE/t1.status"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker whose last event is not done" || return 1
  printf 'done [at=%s]: PR %s checks green\n' "$NOW" "$PR" >> "$STATE/t1.status"
  printf 'g2.1.1\n' > "$STATE/t1.busy-gen"
  printf 'v1 gen=g2.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$NOW" > "$STATE/t1.busy-state"
  ! scan_reap FM_IDLE_REAP_MERGE_PRUNE=1 || why "the prune accepted a worker that reads busy again" || return 1
  return 0
}

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
  [ "$(destroy_calls)" = 0 ] || fail "a completed teardown needed no fallback"
  pass "a verified merge asks teardown once, never forced, and logs reaped"
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
test_fallback_keeps_a_stash() { assert_scenario scn_stash_is_kept "a stash entry keeps the copy"; }
test_fallback_keeps_a_live_process() { assert_scenario scn_live_process_is_kept "a live process inside keeps the copy with exactly one wake"; }
test_fallback_nested_unpushed_commit_keeps_the_slot() { assert_scenario scn_nested_unpushed_commit_keeps_the_slot "an unpushed commit in a NESTED copy keeps the whole slot"; }
test_fallback_removes_a_clean_nested_copy_with_the_slot() { assert_scenario scn_clean_nested_copy_goes_with_the_slot "a clean pushed orphan nested copy goes with its slot, its preserve-list records preserved"; }
test_fallback_keeps_unique_ignored_files() { assert_scenario scn_unique_ignored_file_is_kept "a unique ignored file outside the preserve list and the scratch patterns keeps the copy"; }
test_fallback_keeps_a_non_pool_copy() { assert_scenario scn_non_pool_copy_is_kept "a copy outside the pool is never destroyed"; }
test_fallback_accepts_the_merged_pr_head() { assert_scenario scn_pr_head_proves_a_squash_merged_commit "a commit proved landed by the merged PR head does not keep the copy"; }
test_fallback_ignores_a_search_indexer() { assert_scenario scn_search_indexer_does_not_keep_the_copy "a system search indexer (Spotlight) reading the copy does not keep it; any other process does"; }
test_fallback_never_overrides_a_live_pipeline_refusal() { assert_scenario scn_pipeline_refusal_never_falls_back "a refusal about a live pipeline is retained, never overridden"; }
test_fallback_settles_a_ship_deliverable_not_landed_refusal() { assert_scenario scn_ship_not_landed_is_settled "the ship-deliverable-not-landed refusal is settled by the fallback"; }
test_fallback_settles_a_foreign_copy_head_not_landed_refusal() { assert_scenario scn_foreign_head_is_settled "a foreign nested copy whose HEAD is not proved landed is settled by the fallback"; }
test_fallback_settles_a_foreign_copy_ignored_files_refusal() { assert_scenario scn_foreign_ignored_is_settled "a foreign nested copy holding ignored files is settled by the fallback"; }
test_fallback_settles_an_own_nested_copy_ignored_files_refusal() { assert_scenario scn_own_ignored_is_settled "an own nested copy holding ignored files is settled by the fallback"; }
test_fallback_settles_an_own_nested_copy_closeout_refusal() { assert_scenario scn_closeout_own_is_settled "a closeout driver's exact-tree refusal for an own nested copy is settled by the fallback"; }
test_fallback_keeps_the_copy_on_leaked_worktree_processes() { assert_scenario scn_leaked_worktree_keeps_the_copy "a leaked worktree process refusal keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_on_leaked_tasktmp_processes() { assert_scenario scn_leaked_tasktmp_keeps_the_copy "a leaked task tmp process refusal keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_while_a_launch_agent_is_loaded() { assert_scenario scn_launchd_loaded_keeps_the_copy "a launch agent that is still loaded after launchctl bootout keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_when_process_ownership_is_not_proven() { assert_scenario scn_ownership_unproven_keeps_the_copy "a process whose ownership is not proven keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_on_an_unknown_refusal() { assert_scenario scn_unknown_refusal_keeps_the_copy "an unknown new refusal text keeps the copy with one wake and no fallback"; }
test_fallback_keeps_the_copy_when_any_refusal_line_is_not_a_landing_refusal() { assert_scenario scn_mixed_refusals_keep_the_copy "a landing refusal printed together with a non-landing refusal keeps the copy"; }
test_fallback_destroy_failure_keeps_the_copy() { assert_scenario scn_destroy_failure_keeps_the_copy_with_one_wake "a destroy the tool refuses keeps the copy with one wake"; }
test_retained_copy_is_reaped_quietly_when_the_cause_clears() { assert_scenario scn_retained_copy_is_reaped_when_the_cause_clears "a retained copy is reaped on the quiet retry once its cause clears"; }
test_long_retained_reason_is_logged_once() { assert_scenario scn_long_reason_is_logged_once "a retained reason longer than the saved 300 characters is logged and woken once, not at every retry"; }
test_fallback_ends_the_tasks_idle_pane_shell_on_tmux() { assert_scenario scn_lingering_pane_shell_on_tmux "the idle shell the task's tmux pane keeps in the copy is ended with SIGHUP and the copy then goes, with the pane left open"; }
test_fallback_ends_the_tasks_idle_pane_shell_on_herdr() { assert_scenario scn_lingering_pane_shell_on_herdr "the idle shell the task's herdr pane keeps in the copy is ended with SIGHUP and the copy then goes, with the pane left open"; }
test_fallback_keeps_a_non_shell_process_in_the_pane() { assert_scenario scn_pane_build_keeps_the_copy "a build, editor or test started in the pane keeps the copy with exactly one wake"; }
test_fallback_keeps_a_pane_shell_that_runs_something() { assert_scenario scn_pane_busy_shell_keeps_the_copy "a pane shell with a child process keeps the copy with exactly one wake"; }
test_fallback_keeps_a_pane_shell_that_works_elsewhere() { assert_scenario scn_pane_shell_working_elsewhere_keeps_the_copy "a pane shell with a file of the copy open but its working directory elsewhere keeps the copy and is left alone"; }
test_fallback_keeps_the_copy_when_the_pane_shell_ignores_sighup() { assert_scenario scn_stubborn_pane_shell_keeps_the_copy "a pane shell that ignores SIGHUP keeps the copy with one wake and is never forced"; }
test_fallback_leaves_the_pane_shell_until_the_agent_is_confirmed_stopped() { assert_scenario scn_unconfirmed_stop_leaves_the_pane_shell "an exit verb that does not confirm the agent stopped leaves the pane shell alone and keeps the copy"; }
test_deliberately_exited_worker_reads_as_stopped_only_for_the_prune() { assert_scenario scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "a worker stopped by fm-control.sh exit reads as reapable for the prune only when the busy record is gone, the exit marker is present and its last event is done"; }
test_fallback_keeps_a_shell_no_pane_started() { assert_scenario scn_stray_shell_keeps_the_copy "an idle shell that is not the task's pane shell keeps the copy with exactly one wake"; }
test_fallback_exempts_nothing_when_the_pane_is_unreadable() { assert_scenario scn_unreadable_pane_exempts_nothing "a pane that cannot be read exempts no shell"; }
test_fallback_never_destroys_a_reassigned_slot() { assert_scenario scn_reassigned_slot_is_never_destroyed "a slot another task claimed after the worker stopped, or whose claim cannot be read, is never destroyed"; }
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

test_unsafe_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh orch=fm-merge-prune.sh reap=fm-idle-reap-lib.sh
  expect_caught no-dirty-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_changed_file_is_kept "changed-file proof"
  expect_caught no-untracked-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_untracked_file_is_kept "untracked-file proof"
  expect_caught no-unpushed-check $lib '  if [ "$unpushed" != 0 ]; then' '  if false; then' scn_unpushed_commit_is_kept "unpushed-commit proof"
  expect_caught no-stash-check $lib '  if [ "$stashes" != 0 ]; then' '  if false; then' scn_stash_is_kept "stash proof"
  expect_caught no-process-check $lib "  out=\$(printf '%s\\n' \"\$out\" | sort -u | tr '\\n' ' ')" '  out=' scn_live_process_is_kept "live-process proof"

  expect_caught no-nested-check $lib '    FM_MP_NESTED+=("$dir")' '    :' scn_nested_unpushed_commit_keeps_the_slot "nested-copy proof"
  expect_caught unique-is-scratch $lib '  if fm_mp_scratch_name "$name"; then' '  if true; then' scn_unique_ignored_file_is_kept "unique-ignored-file proof"
  expect_caught no-pool-check $lib '    "$root"/*/*/*) return 0 ;;' '    *) return 0 ;;' scn_non_pool_copy_is_kept "pool-copy proof"
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
  expect_caught allow-unknown-text $orch '      *) return 1 ;;' '      *) seen=1 ;;' scn_unknown_refusal_keeps_the_copy "unknown refusal text"
  expect_caught allow-when-any-line-is-landing $orch '      *) return 1 ;;' '      *) ;;' scn_mixed_refusals_keep_the_copy "every-line rule"
  expect_caught pane-exempts-any-process $lib '  [ "$(fm_agent_process_classify_name "$comm")" = shell ] || return 1' '  :' scn_pane_build_keeps_the_copy "shell-only pane exemption"
  expect_caught pane-exempts-busy-shell $lib '      if (child) exit 1' '      if (0) exit 1' scn_pane_busy_shell_keeps_the_copy "idle-shell-only pane exemption"
  expect_caught pane-exempts-any-shell $lib '        if (p == pane) exit 0' '        if (1) exit 0' scn_stray_shell_keeps_the_copy "pane-ancestry pane exemption"
  expect_caught pane-shell-cwd-not-required $lib '  case "$cwd" in "$copy"|"$copy"/*) ;; *) return 1 ;; esac' '  :' scn_pane_shell_working_elsewhere_keeps_the_copy "pane-shell working-directory proof"
  expect_caught sigkill-instead-of-sighup $lib '  kill -HUP "$pid" 2>/dev/null || return 1' '  kill -KILL "$pid" 2>/dev/null || return 1' scn_stubborn_pane_shell_keeps_the_copy "SIGHUP-only rule"
  expect_caught no-stop-confirmation $orch '    if [ "$WORKER_STOPPED" != 1 ]; then' '    if false; then' scn_unconfirmed_stop_leaves_the_pane_shell "agent-stopped proof"
  expect_caught exit-accepted-outside-the-prune $reap '  [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ] || return 1' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "merge-prune-only rule"
  expect_caught exit-accepted-without-marker $reap '  [ -f "$1/$2.control-exit" ] && [ ! -L "$1/$2.control-exit" ]' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "deliberate-exit marker rule"
  expect_caught exit-accepted-with-a-busy-record $reap '  [ "$(fm_busy_record_read "$1" "$2")" = missing ] || return 1' '  :' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "retired-busy-record rule"
  expect_caught no-slot-owner-check $orch '    mine|absent) ;;' '    mine|absent|other) ;;' scn_reassigned_slot_is_never_destroyed "slot-owner re-read"
  expect_caught no-project-lock $orch '  fm_project_lock_try "$plock" "merge-prune $ID" >/dev/null 2>&1 || rc=$?' '  :' scn_project_lock_busy_backs_off "project lock"
  expect_caught wake-every-time $orch '  if [ "$R_WAKE" = 0 ]; then' '  if true; then' scn_changed_file_is_kept "one-wake rule"
  pass "mutation proof (unsafe direction): breaking any safety proof makes its keep case fail"
}

test_over_strict_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh orch=fm-merge-prune.sh reap=fm-idle-reap-lib.sh
  expect_caught no-scratch-names $lib '  if fm_mp_scratch_name "$name"; then' '  if false; then' scn_scratch_copy_is_removed "scratch patterns"
  expect_caught no-claude-scratch $lib '    .claude/*|.opencode|.opencode/*) return 0 ;;' '    .opencode|.opencode/*) return 0 ;;' scn_scratch_copy_is_removed ".claude scratch rule"
  expect_caught no-tac-scratch $lib '    .tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) return 0 ;;' '    .tac/NEVER) return 0 ;;' scn_scratch_copy_is_removed ".tac scratch rule"
  expect_caught no-preserve-list $lib '    .claude/bug-evidence|.claude/bug-evidence/*|.claude/channel-outbox|.claude/channel-outbox/*)' '    .claude/NEVER-MATCHES)' scn_scratch_copy_is_removed "preserve list"
  expect_caught pane-shell-not-exempt $lib '    elif [ -z "$FM_MP_PANE_SHELL" ] && fm_mp_pane_shell "$pid" "$pane" "$copy"; then' '    elif false; then' scn_lingering_pane_shell_on_tmux "pane-shell exemption"
  expect_caught pane-shell-never-signaled $lib '  kill -HUP "$pid" 2>/dev/null || return 1' '  :' scn_lingering_pane_shell_on_herdr "SIGHUP step"
  expect_caught exit-never-accepted $reap '  [ "${FM_IDLE_REAP_MERGE_PRUNE:-0}" = 1 ] || return 1' '  return 1' scn_deliberately_exited_worker_reads_as_stopped_only_for_the_prune "stopped-worker acceptance"
  expect_caught empty-checksums-fail $lib '  [ ! -s "$dest/SHA256SUMS" ] || (cd "$dest"' '  (cd "$dest"' scn_empty_preserve_paths_do_not_keep_the_copy "empty-manifest rule"
  expect_caught long-reason-relogs fm-merge-prune.sh '  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$(clean_detail "$reason")" ] && changed=0' '  [ "$R_STATE" = retained ] && [ "$R_REASON" = "$reason" ] && changed=0' scn_long_reason_is_logged_once "saved-reason comparison"
  expect_caught ship-not-landed-not-allowed $orch '      "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion.") seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_ship_not_landed_is_settled "ship-deliverable landing refusal"
  expect_caught foreign-head-not-allowed $orch '      "REFUSED: foreign copy "*" stays in pool slot "*": its HEAD "*" is not proved landed.") seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_foreign_head_is_settled "foreign-copy HEAD refusal"
  expect_caught foreign-ignored-not-allowed $orch '      "REFUSED: foreign copy "*" stays in pool slot "*": it holds ignored files that exist nowhere else: "*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_foreign_ignored_is_settled "foreign-copy ignored-files refusal"
  expect_caught own-ignored-not-allowed $orch '      "REFUSED: own nested copy "*" stays in pool slot "*": it holds ignored files that exist nowhere else: "*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_own_ignored_is_settled "own-nested-copy ignored-files refusal"
  expect_caught closeout-foreign-not-allowed $orch '      "REFUSED: Vernant'"'"'s closeout driver did not release foreign copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_landing_refusal_via_closeout_foreign "foreign-copy closeout refusal"
  expect_caught closeout-own-not-allowed $orch '      "REFUSED: Vernant'"'"'s closeout driver did not release own nested copy "*" (exit "*"): "*"exact tree not covered"*) seen=1 ;;' '      "REFUSED: never") seen=1 ;;' scn_closeout_own_is_settled "own-nested-copy closeout refusal"
  expect_caught no-checksums $lib '      shasum -a 256 -- "$file" || exit 1' '      :' scn_scratch_copy_is_removed "checksum manifest"
  expect_caught indexer-counts-as-use $lib '    if fm_mp_indexer_pid "$pid"; then' '    if false; then' scn_search_indexer_does_not_keep_the_copy "search-indexer exemption"
  expect_caught pr-head-ignored $lib '  [ -z "$prsha" ] || extra=("$prsha")' '  extra=()' scn_pr_head_proves_a_squash_merged_commit "merged-PR-head proof"
  expect_caught nested-never-passes fm-merge-prune.sh '    fm_mp_prove_git "$n" "" || { record_verdict "$real"; return 1; }' '    false || { record_verdict "$real"; return 1; }' scn_clean_nested_copy_goes_with_the_slot "nested-copy removal"
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
# Fake pool: `return` and the reaper's `destroy` both remove the fake copy.
printf '%s\n' "$*" >> "$TH_LOG"
case "${1:-}" in
  return) for a in "$@"; do wt=$a; done; rm -rf "$wt"; exit 0 ;;
  destroy)
    [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ] || { echo "stub treehouse: unexpected arguments: $*" >&2; exit 9; }
    case "$2" in "$TREEHOUSE_ROOT"/*/*/*) ;; *) echo "stub treehouse: outside the fake pool" >&2; exit 3 ;; esac
    inuse=$(command -p lsof -a -d cwd +D "$2" -t 2>/dev/null | sort -u | tr '\n' ' ')
    if [ -n "${inuse// /}" ]; then
      echo "Skipped 1 worktree: [in-use:${inuse%% *}] $2" >&2
      echo "did not destroy 1 (in-use); re-run with --include-in-use" >&2
      exit 1
    fi
    rm -rf "$2"; exit 0 ;;
esac
exit 0
SH
  # The real teardown, with every call it is given recorded.
  cat > "$W/bin/teardown-real" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
# A case may make teardown refuse the way the 2026-10-18 closeout driver did, so
# the fallback alone decides.
if [ -e "$REFUSE_FLAG" ]; then
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
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t1"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
  fm_write_meta "$STATE/t1.meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" "worktree=$COPY" \
    "project=$W/project" "kind=ship" "mode=no-mistakes" "spawn_gen=e2e-t1" "harness=claude" "backend=tmux" \
    "pr=$PR" "pr_head=$head"
  touch "$STATE/.last-watcher-beat"
}

# prune_real <args...>: the prune scripts with the REAL teardown and control.
prune_real() {
  HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_ROOT_OVERRIDE="$W/code-root" NM_HOME="$W/nm" \
    TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" TH_LOG="$W/th.log" FM_MERGE_PRUNE_EXIT_WAIT="${FM_MERGE_PRUNE_EXIT_WAIT:-0}" \
    FM_TEARDOWN_GUARD_DONE=1 ROOT="$ROOT" STUB_LOG="$W/stub.log" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-real" REFUSE_FLAG="$W/refuse" \
    FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" \
    PANE_PID_FILE="$W/pane.pid" STEAL_FILE="$W/steal" SLOT_MARKER="$POOL/pool1/1/.fm-slot-owner" \
    STOP_FAIL_FILE="$W/stop-fail" BUSY_EVENT_BIN="$BIN_DIR/fm-busy-event.sh" \
    "$BIN_DIR/fm-merge-prune.sh" "$@"
}

wake_count_real() {
  local n
  n=$(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# Nothing is forced: teardown is only ever asked for the task by name, and the
# fallback's treehouse calls never carry a force or an include-unlanded flag.
# (Teardown's own `treehouse return --force` is the landed-work-guarded return
# of the slot it has just proved safe; it is not a forced teardown.)
assert_nothing_forced() {  # <label>
  if [ -s "$W/stub.log" ] && [ -n "$(grep -vx 't1' "$W/stub.log")" ]; then
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

test_e2e_merge_prunes_the_copy_with_the_real_teardown() {
  make_e2e_world
  prune_real arm t1 --run || fail "arm --run failed"
  fm_test_wait_until 60 test ! -e "$STATE/t1.merge-prune" || fail "the detached attempt did not finish: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null)"
  [ ! -e "$COPY" ] || fail "the pool copy is still there after the merge"
  [ ! -e "$STATE/t1.meta" ] || fail "the task record is still there: real teardown did not complete"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped: $(cat "$DATA/t1/merge-prune.log")"
  [ "$(wake_count_real)" = 0 ] || fail "a clean prune raised a wake"
  grep -q '^return ' "$W/th.log" || fail "teardown did not return the slot through treehouse"
  assert_nothing_forced "e2e merge"
  pass "end to end: a verified merge arms the prune, the detached run reaps the copy through the real teardown, and the log says reaped"
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
  [ ! -e "$COPY" ] && [ ! -e "$STATE/t1.meta" ] && [ ! -e "$STATE/t1.merge-prune" ] || fail "the retry after the contention cleared did not reap: $(cat "$DATA/t1/merge-prune.log")"
  grep -q 'retry in' "$DATA/t1/merge-prune.log" && grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not show the retry and then reaped"
  pass "end to end: a co-tenant's lifecycle lock makes the real teardown refuse, the prune retries later without a wake, and then reaps"
}

# Real teardown refuses a copy that went on after its PR merged (a stale PR
# head), though that follow-up commit is pushed and nothing is lost. The
# fallback proves the copy clean, pushed and unused, removes it, and teardown
# then finishes the records.
test_e2e_false_positive_refusal_is_reaped_by_the_fallback() {
  make_e2e_world
  printf 'follow-up\n' > "$COPY/followup.txt"
  git -C "$COPY" add followup.txt
  git -C "$COPY" commit -q -m "follow-up after the merge"
  git -C "$COPY" push -q origin fm/t1
  mkdir -p "$COPY/.claude/bug-evidence" "$COPY/node_modules/x"
  printf 'closeout\n' > "$COPY/.claude/bug-evidence/slot.json"
  printf x > "$COPY/node_modules/x/i.js"
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
  pass "end to end: a copy real teardown refuses for a pushed follow-up is removed by the fallback, preserved records first, and teardown then closes the task"
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
  test_fallback_keeps_an_unpushed_commit
  test_fallback_keeps_a_stash
  test_fallback_keeps_a_live_process
  test_fallback_nested_unpushed_commit_keeps_the_slot
  test_fallback_removes_a_clean_nested_copy_with_the_slot
  test_fallback_keeps_unique_ignored_files
  test_fallback_keeps_a_non_pool_copy
  test_fallback_accepts_the_merged_pr_head
  test_fallback_ignores_a_search_indexer
  test_fallback_never_overrides_a_live_pipeline_refusal
  test_fallback_settles_a_ship_deliverable_not_landed_refusal
  test_fallback_settles_a_foreign_copy_head_not_landed_refusal
  test_fallback_settles_a_foreign_copy_ignored_files_refusal
  test_fallback_settles_an_own_nested_copy_ignored_files_refusal
  test_fallback_settles_an_own_nested_copy_closeout_refusal
  test_fallback_keeps_the_copy_on_leaked_worktree_processes
  test_fallback_keeps_the_copy_on_leaked_tasktmp_processes
  test_fallback_keeps_the_copy_while_a_launch_agent_is_loaded
  test_fallback_keeps_the_copy_when_process_ownership_is_not_proven
  test_fallback_keeps_the_copy_on_an_unknown_refusal
  test_fallback_keeps_the_copy_when_any_refusal_line_is_not_a_landing_refusal
  test_fallback_destroy_failure_keeps_the_copy
  test_retained_copy_is_reaped_quietly_when_the_cause_clears
  test_long_retained_reason_is_logged_once
  test_fallback_ends_the_tasks_idle_pane_shell_on_tmux
  test_fallback_ends_the_tasks_idle_pane_shell_on_herdr
  test_fallback_keeps_a_non_shell_process_in_the_pane
  test_fallback_keeps_a_pane_shell_that_runs_something
  test_fallback_keeps_a_shell_no_pane_started
  test_fallback_keeps_a_pane_shell_that_works_elsewhere
  test_fallback_keeps_the_copy_when_the_pane_shell_ignores_sighup
  test_fallback_leaves_the_pane_shell_until_the_agent_is_confirmed_stopped
  test_deliberately_exited_worker_reads_as_stopped_only_for_the_prune
  test_fallback_exempts_nothing_when_the_pane_is_unreadable
  test_fallback_never_destroys_a_reassigned_slot
  test_fallback_backs_off_while_the_project_lock_is_held
  test_fallback_removes_a_copy_whose_preserve_paths_are_empty
  test_e2e_merge_prunes_the_copy_with_the_real_teardown
  test_e2e_transient_contention_retries_then_succeeds
  test_e2e_false_positive_refusal_is_reaped_by_the_fallback
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
