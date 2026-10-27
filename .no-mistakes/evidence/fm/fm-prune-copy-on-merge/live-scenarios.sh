# Scenarios for live-harness.sh. Each sets RESULT=PASS only when every
# observable check holds; the transcript records why.

# 1. A verified merge arms the prune (the exact call bin/fm-pr-merge.sh makes)
#    and the detached attempt removes the copy with no human step.
scn_merge_prunes_copy() {
  pane_tree
  run_prune arm t1 --run
  wait_log 'reaped' 120 || say "no reaped line within 120s"
  copy_gone_for 30 || true
  evidence
  if [ ! -e "$SLOT" ] && grep -q 'reaped' "$DATA/t1/merge-prune.log" 2>/dev/null \
    && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null && [ ! -e "$STATE/t1.merge-prune" ]; then
    RESULT=PASS
  fi
}

one_wake_naming_copy() {  # <reason text>
  [ "$(grep -c 'merge-prune' "$STATE/.wake-queue" 2>/dev/null || echo 0)" = 1 ] \
    && grep 'merge-prune' "$STATE/.wake-queue" | grep -F "$SLOT" | grep -q -- "$1"
}
kept_checks() {  # <reason text>: copy kept, task kept, one wake naming copy+reason
  [ -e "$SLOT" ] && [ -e "$STATE/t1.meta" ] && one_wake_naming_copy "$1"
}
retry_twice() {
  say "--- two more attempts (must raise no second wake):"
  run_prune run t1 --now
  run_prune run t1 --now
}

# 2. A worker stopped with the exit verb BEFORE the merge: busy record retired,
#    control-exit marker present, the pane holds only its shell, the real
#    `treehouse get` and the slot's subshell. The copy must be pruned.
scn_exited_before_merge() {
  fmenv "$REPO/bin/fm-busy-event.sh" retire "$STATE" t1 --gen "$GEN" >&3 2>&1
  printf 'gen=%s\n' "$GEN" > "$STATE/t1.control-exit"
  say "busy record: $([ -e "$STATE/t1.busy-state" ] && echo present || echo retired); control-exit marker: $(cat "$STATE/t1.control-exit")"
  pane_tree
  run_prune arm t1
  run_prune run t1 --now
  copy_gone_for 20 || true
  evidence
  if [ ! -e "$SLOT" ] && grep -q 'reaped' "$DATA/t1/merge-prune.log" && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null; then
    RESULT=PASS
  fi
}

# 3. A changed tracked file: kept, one wake naming the copy, nothing forced.
scn_dirty_copy_kept() {
  printf 'edit\n' >> "$SLOT/README.md"
  run_prune arm t1
  run_prune run t1 --now
  retry_twice
  evidence
  say "--- git status in the kept copy:"; git -C "$SLOT" status --short >&3 2>&1
  pane_tree
  if kept_checks 'merge-prune kept' && grep -q 'edit' "$SLOT/README.md"; then RESULT=PASS; fi
}

# 4. An unpushed commit: kept, one wake.
scn_unpushed_commit_kept() {
  printf 'new\n' > "$SLOT/new.txt"
  git -C "$SLOT" add new.txt && git -C "$SLOT" commit -q -m "unpushed work"
  run_prune arm t1
  run_prune run t1 --now
  retry_twice
  evidence
  say "--- commits on fm/t1 missing from origin:"; git -C "$SLOT" log --oneline origin/fm/t1..HEAD >&3 2>&1
  if kept_checks 'merge-prune kept' && [ -n "$(git -C "$SLOT" log --oneline origin/fm/t1..HEAD)" ]; then RESULT=PASS; fi
}

# 5. An unpushed commit in a NESTED copy keeps the whole slot.
scn_nested_unpushed_commit_kept() {
  git clone -q "$X/origin.git" "$SLOT/.claude/worktrees/n1" 2>/dev/null
  printf 'o\n' > "$SLOT/.claude/worktrees/n1/o.txt"
  git -C "$SLOT/.claude/worktrees/n1" add o.txt && git -C "$SLOT/.claude/worktrees/n1" commit -q -m "unpushed in nested"
  run_prune arm t1
  run_prune run t1 --now
  retry_twice
  evidence
  say "--- nested copy unpushed commit:"; git -C "$SLOT/.claude/worktrees/n1" log --oneline origin/main..HEAD >&3 2>&1
  if kept_checks 'merge-prune kept' && [ -e "$SLOT/.claude/worktrees/n1/o.txt" ]; then RESULT=PASS; fi
}

# 6. A live job in the task pane (a build started there): kept, job not killed.
scn_live_job_in_pane_kept() {
  tmux -L fm-lab send-keys -t firstmate:fm-t1 'sleep 900' Enter
  sleep 2
  pane_tree
  job=$(pgrep -f '^sleep 900$' | head -1)
  say "job pid: ${job:-none}"
  run_prune arm t1
  run_prune run t1 --now
  retry_twice
  evidence
  pane_tree
  if [ -n "$job" ] && kill -0 "$job" 2>/dev/null && kept_checks 'merge-prune kept'; then RESULT=PASS; fi
  [ -z "$job" ] || kill "$job" 2>/dev/null
}

# 7. A busy worker (its busy record says busy: a steered follow-up turn) is
#    never closed: the attempt backs off quietly, the pane stays.
scn_busy_worker_not_closed() {
  fmenv "$REPO/bin/fm-busy-event.sh" apply "$STATE" t1 busy --gen "$GEN" --source claude-hook --event UserPromptSubmit >&3 2>&1
  pane_tree
  run_prune arm t1
  run_prune run t1 --now
  evidence
  pane_tree
  if [ -e "$SLOT" ] && [ -e "$STATE/t1.meta" ] && grep -q '^state=pending' "$STATE/t1.merge-prune" \
    && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null && tmux -L fm-lab list-windows -t firstmate | grep -q fm-t1; then
    RESULT=PASS
  fi
}

# 8. Transient contention (a co-tenant lifecycle action holds the task lock):
#    a quiet retry, then the watcher's sweep reaps once it clears.
scn_contention_retries_then_reaps() {
  sleep 600 & holder=$!
  mkdir "$STATE/.control-t1.lock"; printf '%s\n' "$holder" > "$STATE/.control-t1.lock/pid"
  run_prune arm t1
  run_prune run t1 --now
  say "--- record while the lock is held:"; cat "$STATE/t1.merge-prune" >&3
  ok1=0
  [ -e "$SLOT" ] && grep -q '^state=pending' "$STATE/t1.merge-prune" && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null && ok1=1
  say "--- a sweep before the backoff elapsed (must do nothing):"
  run_prune sweep
  ok2=0; [ -e "$SLOT" ] && ok2=1
  kill "$holder"; rm -rf "$STATE/.control-t1.lock"
  sed -i '' 's/^next_at=.*/next_at=0/' "$STATE/t1.merge-prune"
  say "--- lock released, backoff made due; the watcher's sweep:"
  run_prune sweep
  copy_gone_for 20 || true
  evidence
  if [ "$ok1" = 1 ] && [ "$ok2" = 1 ] && [ ! -e "$SLOT" ] && grep -q 'retry in' "$DATA/t1/merge-prune.log" \
    && grep -q reaped "$DATA/t1/merge-prune.log" && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null; then
    RESULT=PASS
  fi
}

# 9. No verified merge (no merge marker): arming records nothing.
scn_unverified_merge_not_armed() {
  rm -f "$STATE/t1.pr-poll-merge-notified"
  run_prune arm t1 --run
  sleep 5
  evidence
  if [ ! -e "$STATE/t1.merge-prune" ] && [ -e "$SLOT" ] && [ -e "$STATE/t1.meta" ]; then RESULT=PASS; fi
}

# Teardown wrapper for the fallback cases: while the copy exists it refuses with
# the 2026-10-18 Vernant closeout driver's text (Vernant's driver is an outside
# project hook, not present here); otherwise it is the real bin/fm-teardown.sh.
closeout_wrapper() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'copy=$(sed -n "s/^worktree=//p" "%s/$1.meta" 2>/dev/null)\n' "$STATE"
    printf '%s\n' 'if [ -n "$copy" ] && [ -e "$copy" ]; then'
    printf '%s\n' "  echo \"REFUSED: Vernant's closeout driver did not release foreign copy \$copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR\" >&2"
    printf '%s\n' '  exit 1' 'fi'
    printf 'exec "%s/bin/fm-teardown.sh" "$@"\n' "$REPO"
  } > "$X/bin/teardown-closeout"
  chmod +x "$X/bin/teardown-closeout"
}
run_fallback() {
  say "\$ FM_MERGE_PRUNE_TEARDOWN_BIN=teardown-closeout FM_MERGE_PRUNE_EXIT_WAIT=5 bin/fm-merge-prune.sh run t1 --now"
  fmenv FM_MERGE_PRUNE_TEARDOWN_BIN="$X/bin/teardown-closeout" FM_MERGE_PRUNE_EXIT_WAIT=5 "$REPO/bin/fm-merge-prune.sh" run t1 --now >&3 2>&1
  say "[exit $?]"
}

# 10. Provable-scratch fallback: teardown refuses only for the false-positive
#     closeout reason; the copy is clean, pushed, merged and unused, holding
#     ignored scratch and a preserve-list record. The fallback preserves the
#     record with a checksum, ends only the pane's idle subshell, and the REAL
#     `treehouse destroy --include-leased --yes` removes it.
scn_fallback_removes_scratch_copy() {
  closeout_wrapper
  mkdir -p "$SLOT/.claude/bug-evidence" "$SLOT/node_modules/x"
  printf 'closeout\n' > "$SLOT/.claude/bug-evidence/slot.json"
  printf 'x\n' > "$SLOT/node_modules/x/i.js"
  pane_tree
  run_prune arm t1
  run_fallback
  copy_gone_for 20 || true
  evidence
  pane_tree
  say "--- preserved records:"; find "$DATA/t1/merge-prune-preserved" -type f -exec sh -c 'echo "$1"; cat "$1"' _ {} \; >&3 2>&1
  if [ ! -e "$SLOT" ] && grep -q 'fallback destroyed' "$DATA/t1/merge-prune.log" \
    && find "$DATA/t1/merge-prune-preserved" -name slot.json | grep -q . \
    && [ -n "$(find "$DATA/t1/merge-prune-preserved" -name SHA256SUMS -exec grep -l slot.json {} \;)" ] \
    && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null; then
    RESULT=PASS
  fi
}

# 11. Fallback edge: a unique file outside the preserve list and the scratch
#     patterns (an ignored *.local secret) keeps the copy with one wake.
scn_fallback_keeps_unique_ignored_file() {
  closeout_wrapper
  printf 'SECRET=1\n' > "$SLOT/.env.local"
  run_prune arm t1
  run_fallback
  say "--- two more attempts:"
  run_fallback
  run_fallback
  evidence
  pane_tree
  if kept_checks 'merge-prune kept' && [ -e "$SLOT/.env.local" ]; then RESULT=PASS; fi
}

# 12. Fallback edge: a follow-up commit pushed after the merge (not in the
#     merged PR) keeps the copy before anything is stopped.
scn_fallback_keeps_unmerged_followup() {
  closeout_wrapper
  printf 'follow-up\n' > "$SLOT/followup.txt"
  git -C "$SLOT" add followup.txt && git -C "$SLOT" commit -q -m "follow-up after the merge"
  git -C "$SLOT" push -q origin fm/t1 2>/dev/null
  run_prune arm t1
  run_fallback
  evidence
  pane_tree
  say "--- copy branch: $(git -C "$SLOT" symbolic-ref -q --short HEAD 2>&1)"
  if kept_checks 'not in the merged pull request' && [ "$(git -C "$SLOT" symbolic-ref -q --short HEAD)" = fm/t1 ]; then RESULT=PASS; fi
}

# 13. Adversarial (owner ruling case B): an old control-exit marker is still on
#     disk, the busy record is gone, but an agent was relaunched and is live in
#     the pane (a process named claude in the slot's subshell). The prune must
#     not close it: a quiet back-off, the agent and pane alive, the copy kept.
scn_relaunched_agent_with_old_marker_not_closed() {
  mkdir -p "$X/agent"
  printf '%s\n' '#include <unistd.h>' 'int main(void){int i;for(i=0;i<900;i++)sleep(1);return 0;}' > "$X/agent/a.c"
  cc -o "$X/agent/claude" "$X/agent/a.c" 2>&3 || { say "no C compiler"; return; }
  fmenv "$REPO/bin/fm-busy-event.sh" retire "$STATE" t1 --gen "$GEN" >&3 2>&1
  printf 'gen=%s\n' "$GEN" > "$STATE/t1.control-exit"
  tmux -L fm-lab send-keys -t firstmate:fm-t1 "$X/agent/claude" Enter
  sleep 2
  agent=$(pgrep -f "^$X/agent/claude\$" | head -1)
  say "busy record: $([ -e "$STATE/t1.busy-state" ] && echo present || echo retired); old control-exit marker: $(cat "$STATE/t1.control-exit"); live agent pid: ${agent:-none}"
  pane_tree
  run_prune arm t1
  run_prune run t1 --now
  evidence
  pane_tree
  if [ -n "$agent" ] && kill -0 "$agent" 2>/dev/null && [ -e "$SLOT" ] && [ -e "$STATE/t1.meta" ] \
    && grep -q '^state=pending' "$STATE/t1.merge-prune" && ! grep -q merge-prune "$STATE/.wake-queue" 2>/dev/null \
    && tmux -L fm-lab list-windows -t firstmate | grep -q fm-t1; then
    RESULT=PASS
  fi
  [ -z "$agent" ] || kill "$agent" 2>/dev/null
}
