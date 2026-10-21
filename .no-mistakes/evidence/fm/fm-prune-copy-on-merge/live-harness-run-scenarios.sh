#!/usr/bin/env bash
# Drives each live scenario against a fresh disposable world and prints a
# transcript. Usage: run-scenarios.sh [scenario...]
set -u
HARNESS=/Users/charlesabrooker/tmp/fm-mp-harness.lWvmi7
# shellcheck source=/dev/null
. "$HARNESS/world.sh"

RESULTS=()
CHECK_FAIL=0
check() {  # <label> <command...>
  local label=$1; shift
  if "$@"; then printf '  PASS  %s\n' "$label"; else printf '  FAIL  %s\n' "$label"; CHECK_FAIL=1; fi
}
not() { ! "$@"; }
exists() { [ -e "$1" ]; }
th_destroy_calls() { grep -c '^destroy ' "$W/th.log" 2>/dev/null || true; }
no_forced_th() { ! grep -Eq -- '--include-unlanded|--include-in-use|^destroy .*--force' "$W/th.log"; }  # teardown's own guarded 'return --force' predates this change
wake_is() { [ "$(wakes)" = "$1" ]; }
log_has() { grep -q -- "$1" "$DATA/t1/merge-prune.log" 2>/dev/null; }
pid_alive() { kill -0 "$1" 2>/dev/null; }
on_branch() { [ "$(git -C "$COPY" symbolic-ref -q --short HEAD 2>/dev/null)" = "$1" ]; }

show() {
  echo "  --- data/t1/merge-prune.log"; sed 's/^/    /' "$DATA/t1/merge-prune.log" 2>/dev/null
  echo "  --- state/t1.merge-prune"; sed 's/^/    /' "$STATE/t1.merge-prune" 2>/dev/null || echo "    (gone)"
  echo "  --- state/.wake-queue"; sed 's/^/    /' "$STATE/.wake-queue" 2>/dev/null || echo "    (empty)"
  echo "  --- treehouse calls (real binary, args recorded)"; sed 's/^/    /' "$W/th.log"
  echo "  --- teardown REFUSED lines (real bin/fm-teardown.sh)"; grep -E '^(===|REFUSED)' "$W/teardown.out" | sed 's/^/    /' || true
  echo "  --- treehouse status"; th_status | grep -v 'new version\|treehouse update\|^$' | sed 's/^/    /'
}

begin() {
  CHECK_FAIL=0
  echo
  echo "################ $1"
  make_world || { echo "world setup failed"; return 1; }
  STATE=$LABH/state DATA=$LABH/data
}

finish() {  # <name>
  show
  if [ "$CHECK_FAIL" = 0 ]; then RESULTS+=("PASS $1"); else RESULTS+=("FAIL $1"); fi
  teardown_world
}

pane_shell_pid() {  # the treehouse-get subshell inside the copy
  local pid
  for pid in $(pgrep -x bash); do
    [ "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$COPY" ] && { echo "$pid"; return 0; }
  done
  return 1
}

# 1. A merged task's copy is pruned through the real teardown, right after the merge.
s1_merged_copy_returned_by_teardown() {
  begin "S1 merged task: arm --run (as fm-pr-merge.sh does) prunes the copy via real teardown + real treehouse" || return
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && write_task_record
  echo "  before: $(th_status | grep -E '^1 ')"
  prune arm t1 --run
  fm_wait() { local i; for i in $(seq 1 120); do log_has 'reaped\|kept' && return 0; sleep 1; done; return 1; }
  check "the detached attempt finished within 120s" fm_wait
  check "log says reaped: teardown completed" log_has 'reaped: teardown completed'
  check "task record closed (state/t1.meta gone)" not exists "$STATE/t1.meta"
  check "prune record removed" not exists "$STATE/t1.merge-prune"
  check "real treehouse shows the slot returned (available)" sh -c "cd '$W/project' && TREEHOUSE_ROOT='$W/th' HOME='$W/fakehome' '$HOME/.local/bin/treehouse' status 2>/dev/null | grep -E '^1 +available'"
  check "no wake raised" wake_is 0
  check "treehouse never forced" no_forced_th
  finish S1
}

# 2. The 2026-10-18 shape: teardown refuses (closeout driver: exact tree not
# covered) for a nested copy; the fallback proves and destroys the slot.
s2_closeout_false_positive_fallback() {
  begin "S2 2026-10-18 shape: closeout driver refuses a nested copy; fallback proves and real treehouse destroy removes the slot" || return
  add_closeout_driver_to_project
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && add_locked_nested_copy && write_task_record
  echo "  before: $(th_status | grep -E '^1 ')"
  prune arm t1
  prune run t1 --now
  check "teardown refused with the closeout 'exact tree not covered' line" grep -q "closeout driver did not release foreign copy .*exact tree not covered" "$W/teardown.out"
  check "log says fallback destroyed" log_has 'fallback destroyed'
  check "log says reaped: removed by fallback, teardown completed" log_has 'reaped: removed by fallback, teardown completed'
  check "the slot directory is gone" not exists "$COPY"
  check "real treehouse destroy was called exactly as the reaper does" grep -qx "destroy $COPY --include-leased --yes" "$W/th.log"
  check "treehouse never forced" no_forced_th
  check "task record closed by the second teardown" not exists "$STATE/t1.meta"
  check "no wake raised" wake_is 0
  check "the finished worker was stopped via the control exit verb" grep -qx 't1 exit' "$W/control.log"
  finish S2
}

# 3. Adversarial: a commit that was never pushed.
s3_unpushed_commit_kept() {
  local head
  begin "S3 adversarial: merged task whose copy holds an UNPUSHED commit is kept, one wake, nothing stopped" || return
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && write_task_record
  printf 'more\n' > "$COPY/more.txt"; gx -C "$COPY" add more.txt; gx -C "$COPY" commit -q -m "unpushed after merge"
  head=$(git -C "$COPY" rev-parse HEAD)
  local shell; shell=$(pane_shell_pid)
  prune arm t1; prune run t1 --now
  check "copy still exists" exists "$COPY"
  check "copy still on fm/t1 at the unpushed commit" sh -c "[ \"\$(git -C '$COPY' rev-parse HEAD)\" = '$head' ]"
  check "no treehouse destroy" wake_is_and_nodestroy
  check "task record kept" exists "$STATE/t1.meta"
  check "exactly one wake naming the copy" sh -c "[ \"\$(grep -c 'merge-prune:t1' '$STATE/.wake-queue')\" = 1 ] && grep -F '$COPY' '$STATE/.wake-queue' | grep -q 'merge-prune kept'"
  check "the treehouse-get pane shell was not ended" pid_alive "$shell"
  check "the agent stand-in was not stopped" pid_alive "$(cat "$W/agent.pid")"
  prune run t1 --now; prune run t1 --now
  check "two more attempts raise no second wake" wake_is 1
  finish S3
}
wake_is_and_nodestroy() { [ "$(th_destroy_calls)" = 0 ]; }

# 4. Adversarial: an untracked unique file inside the nested copy that git config
# hides from a plain `git status`, under the closeout refusal that reaches the fallback.
s4_hidden_untracked_file_kept() {
  begin "S4 adversarial: closeout-refused slot whose nested copy holds an untracked file hidden by status.showUntrackedFiles=no is kept" || return
  add_closeout_driver_to_project
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && add_locked_nested_copy && write_task_record
  git -C "$W/project" config status.showUntrackedFiles no
  printf 'unique notes\n' > "$COPY/.claude/worktrees/n1/unique-notes.txt"
  echo "  plain git status in nested copy prints: [$(git -C "$COPY/.claude/worktrees/n1" status --porcelain)]"
  prune arm t1; prune run t1 --now
  check "copy still exists" exists "$COPY"
  check "the unique file still exists" exists "$COPY/.claude/worktrees/n1/unique-notes.txt"
  check "no treehouse destroy" wake_is_and_nodestroy
  check "task record kept" exists "$STATE/t1.meta"
  check "exactly one wake" wake_is 1
  finish S4
}

# 5. Adversarial: a follow-up commit pushed after the merge, not in the merged PR.
s5_pushed_follow_up_kept() {
  begin "S5 adversarial: copy with a PUSHED follow-up commit not in the merged PR is kept before anything is stopped" || return
  add_closeout_driver_to_project
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && add_locked_nested_copy && write_task_record
  printf 'follow\n' > "$COPY/follow.txt"; gx -C "$COPY" add follow.txt; gx -C "$COPY" commit -q -m "follow-up after merge"
  gx -C "$COPY" push -q origin fm/t1 2>/dev/null
  local shell; shell=$(pane_shell_pid)
  prune arm t1; prune run t1 --now
  check "copy still exists" exists "$COPY"
  check "copy still on fm/t1 (not returned to the pool under its unmerged commit)" on_branch fm/t1
  check "no treehouse destroy" wake_is_and_nodestroy
  check "the treehouse-get pane shell was not ended" pid_alive "$shell"
  check "the control exit verb was never called" sh -c "[ ! -s '$W/control.log' ]"
  check "exactly one wake, saying it is not in the merged pull request" sh -c "[ \"\$(grep -c 'merge-prune:t1' '$STATE/.wake-queue')\" = 1 ] && grep -q 'not in the merged pull request' '$STATE/.wake-queue'"
  finish S5
}

# 6. Transient: a co-tenant holds the task's lifecycle lock; the prune backs off
# silently and reaps once it clears.
s6_contention_retries_then_reaps() {
  local holder
  begin "S6 transient: task lifecycle lock held by another actor -> silent backoff, then reaped on retry" || return
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && write_task_record
  prune arm t1
  sleep 300 & holder=$!
  mkdir "$STATE/.control-t1.lock"; printf '%s\n' "$holder" > "$STATE/.control-t1.lock/pid"
  prune run t1 --now
  check "copy and record untouched while the lock is held" sh -c "[ -e '$COPY' ] && [ -e '$STATE/t1.meta' ]"
  check "record is pending with 1 attempt" sh -c "grep -qx 'state=pending' '$STATE/t1.merge-prune' && grep -qx 'attempts=1' '$STATE/t1.merge-prune'"
  check "no wake for contention" wake_is 0
  kill "$holder"; rm -rf "$STATE/.control-t1.lock"
  prune run t1 --now
  check "retry after the lock cleared reaped the copy" log_has 'reaped: teardown completed'
  check "log shows the retry" log_has 'retry in'
  check "task record closed" not exists "$STATE/t1.meta"
  check "still no wake" wake_is 0
  finish S6
}

# 7. The watcher path: a merge armed with no attempt (as the merge poll does for a
# merge made elsewhere) is pruned by the REAL watcher's tick starting the REAL sweep.
s7_watcher_tick_prunes_armed_record() {
  local wpid i
  begin "S7 watcher: real bin/fm-watch.sh in the lab home starts the real sweep for an armed record and the copy is pruned" || return
  spawn_task && do_work_and_push && squash_merge && delete_remote_branch && write_task_record
  prune arm t1
  # Firstmate already handled the task's done status (it is what made it merge
  # the PR), so mark it seen the way firstmate does before the watcher starts.
  lab_env bash -c '. "$1/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3"' _ "$BIN" "$STATE" "$STATE/t1.status"
  echo "  armed record: $(tr '\n' ' ' < "$STATE/t1.merge-prune")"
  lab_env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_MERGE_PRUNE_INTERVAL=2 FM_WATCH_HANDLING_SUCCESSOR=1 \
    "$BIN/fm-watch.sh" > "$W/watch.out" 2> "$W/watch.err" &
  wpid=$!
  for i in $(seq 1 150); do log_has 'reaped\|kept' && break; sleep 1; done
  check "watcher still running after the sweep (or exited only on its own wake)" sh -c "kill -0 $wpid 2>/dev/null || [ -s '$W/watch.out' ]"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  echo "  --- watcher stdout"; sed 's/^/    /' "$W/watch.out" | head -10
  echo "  --- watcher stderr (tail)"; tail -5 "$W/watch.err" | sed 's/^/    /'
  check "log says reaped: teardown completed" log_has 'reaped: teardown completed'
  check "prune record removed" not exists "$STATE/t1.merge-prune"
  check "task record closed" not exists "$STATE/t1.meta"
  check "real treehouse shows the slot returned (available)" sh -c "cd '$W/project' && TREEHOUSE_ROOT='$W/th' HOME='$W/fakehome' '$HOME/.local/bin/treehouse' status 2>/dev/null | grep -E '^1 +available'"
  check "no merge-prune wake" wake_is 0
  finish S7
}

ALL=(s1_merged_copy_returned_by_teardown s2_closeout_false_positive_fallback s3_unpushed_commit_kept
  s4_hidden_untracked_file_kept s5_pushed_follow_up_kept s6_contention_retries_then_reaps s7_watcher_tick_prunes_armed_record)
[ "$#" -eq 0 ] || ALL=("$@")
for s in "${ALL[@]}"; do "$s"; done
echo
echo "################ SUMMARY"
printf '%s\n' "${RESULTS[@]}"
