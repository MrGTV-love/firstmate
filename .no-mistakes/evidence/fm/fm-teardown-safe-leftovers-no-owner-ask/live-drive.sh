#!/usr/bin/env bash
# usage: live-drive.sh <worktree> <evidence-dir>
# Hand-driven runs of the real bin/fm-teardown.sh (attended, no --force) on
# throwaway fixtures the repository's own builders make under a scratch
# TMP_ROOT: a scratch FM_HOME, state, data, config, a scratch Treehouse pool
# (pool/1 slot), a throwaway project repository, a Vernant-locked nested copy
# and a stand-in closeout driver. No real pool slot, home or lock is touched.
# Each run keeps stdout, stderr, the git worktree argv log, and listings of the
# copy and of data/task-x1/nested-copy-preserved in <evidence-dir>/live/<run>/.
set -u
WT=$1 EV=$2
cd "$WT" || exit 2
# shellcheck source=/dev/null
. tests/fm-teardown-helpers.sh
OUT=$EV/live
mkdir -p "$OUT"

seed_ignored() {  # <copy>: ignored files of every class the R6-1/R8-1 rule names
  local exclude
  exclude=$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' '.claude/channel-outbox/' '.opencode/' '.cache/' 'notes/' >> "$exclude"
  mkdir -p "$1/.claude/channel-outbox" "$1/.opencode/state" "$1/.cache" "$1/notes"
  printf 'one\n' > "$1/.claude/channel-outbox/a.jsonl"
  printf 'evidence\n' > "$1/.opencode/state/log.json"
  printf 'run\n' > "$1/.cache/run.bin"
  printf 'only here\n' > "$1/notes/unique.dat"
}

collect() {  # <run> <rc>
  local d=$OUT/$1 f p
  mkdir -p "$d"
  cp "$FOREIGN_CASE/stdout" "$d/stdout.txt" 2>/dev/null
  cp "$FOREIGN_CASE/stderr" "$d/stderr.txt" 2>/dev/null
  cp "$FOREIGN_CASE/git-worktree.log" "$d/git-worktree-argv.log" 2>/dev/null
  cp "$FOREIGN_CASE/closeout.log" "$d/closeout-driver-calls.log" 2>/dev/null
  {
    echo "exit=$2"
    if [ -e "$FOREIGN_COPY" ]; then echo "copy=present"; else echo "copy=gone"; fi
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A3 -F "worktree $FOREIGN_COPY" | sed 's/^/worktree-list: /'
    if [ -e "$FOREIGN_CASE/state/task-x1.meta" ]; then echo "task-meta=present"; else echo "task-meta=gone"; fi
    for f in .claude/channel-outbox/a.jsonl .opencode/state/log.json .cache/run.bin notes/unique.dat; do
      p=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -path "*/files/$f" -type f 2>/dev/null | head -n 1)
      if [ -n "$p" ]; then
        printf 'preserved %s bytes=%q sha256-line=%s\n' "$f" "$(cat "$p")" \
          "$(grep -cF "  $f" "${p%/files/*}/meta/SHA256SUMS" 2>/dev/null)"
      else
        printf 'NOT-preserved %s\n' "$f"
      fi
    done
    find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" 2>/dev/null | sed "s|$FOREIGN_CASE|<case>|" | sed 's/^/preserve-tree: /'
  } > "$d/observed.txt"
  echo "== $1"; cat "$d/observed.txt"; grep -E 'released creation lock|REFUSED|closeout credit|launcher' "$d/stderr.txt" | head -8
}

# Run 1 (R6-1/R8-1, S1): foreign copy, dead launcher, closeout interpreter
# missing (exit 127) -> teardown's own direct release.
dead_launcher_pid
make_foreign_copy_case live-foreign "$FOREIGN_DEAD_PID"
add_git_worktree_log "$FOREIGN_CASE"
seed_ignored "$FOREIGN_COPY"
rm -f "$FOREIGN_CASE/vernant-python"
rc=0; run_foreign_teardown rc
collect 1-foreign-dead-launcher-driver-missing "$rc"

# Run 2 (R6-1, S1): own nested copy (task worktree is the copy, slot is
# prior), same dead launcher, interpreter missing.
dead_launcher_pid
make_own_locked_copy_case live-own enclosing "$FOREIGN_DEAD_PID"
add_git_worktree_log "$FOREIGN_CASE"
seed_ignored "$FOREIGN_COPY"
rm -f "$FOREIGN_CASE/vernant-python"
rc=0; run_foreign_teardown rc
collect 2-own-dead-launcher-driver-missing "$rc"

# Run 3 (S1, S5): own nested copy, dead launcher, driver present but it refuses
# an uncredited copy (verification_stale_or_uncovered_paths).
dead_launcher_pid
make_own_locked_copy_case live-own-uncovered enclosing "$FOREIGN_DEAD_PID"
add_git_worktree_log "$FOREIGN_CASE"
seed_ignored "$FOREIGN_COPY"
rc=0; run_foreign_teardown rc FM_STUB_REQUIRE_CREDIT=1
collect 3-own-dead-launcher-driver-uncovered "$rc"

# Run 4 (adversarial, S2): a LIVE launcher (a real sleep started before the
# lock was written), driver missing. Must refuse, keep the lock, not signal it.
sleep 900 &
LIVE=$!
make_own_locked_copy_case live-launcher enclosing "$LIVE"
add_git_worktree_log "$FOREIGN_CASE"
seed_ignored "$FOREIGN_COPY"
rm -f "$FOREIGN_CASE/vernant-python"
rc=0; run_foreign_teardown rc
collect 4-own-live-launcher-driver-missing "$rc"
if kill -0 "$LIVE" 2>/dev/null; then echo "live launcher $LIVE still running (not signalled)" | tee -a "$OUT/4-own-live-launcher-driver-missing/observed.txt"; else echo "live launcher $LIVE is GONE" | tee -a "$OUT/4-own-live-launcher-driver-missing/observed.txt"; fi
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
echo "drive done"
