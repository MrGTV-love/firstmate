#!/usr/bin/env bash
# usage: live-drive-r7.sh <worktree> <evidence-dir>
# R7-1 on the real CLI path: an own nested copy under a dead launcher's lock,
# closeout interpreter missing (direct release), with a .claude file written by
# a one-shot fixture hook at the launcher read or inside the real
# `git worktree unlock` (the repository's own add_late_mutation_hooks). Real
# git does the unlock, the relock and the worktree list. Expect: the late file
# is never lost - either preserved, or the copy stays, still locked, with it.
set -u
WT=$1 EV=$2
cd "$WT" || exit 2
# shellcheck source=/dev/null
. tests/fm-teardown-helpers.sh
eval "$(awk '/^add_late_mutation_hooks\(\) \{/{on=1} on{print} on && /^}/{exit}' tests/fm-teardown-cleanup.test.sh)"
OUT=$EV/live

# Run 1b (R6-1, foreign, S1): a foreign copy whose only ignored files are under
# .claude and .opencode (a foreign copy that also holds unique ignored files
# such as .cache or notes is held whole, see run 1), dead launcher,
# interpreter missing -> direct release.
dead_launcher_pid
make_foreign_copy_case live-foreign-claude "$FOREIGN_DEAD_PID"
add_git_worktree_log "$FOREIGN_CASE"
exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
printf '%s\n' '.claude/channel-outbox/' '.opencode/' >> "$exclude"
mkdir -p "$FOREIGN_COPY/.claude/channel-outbox" "$FOREIGN_COPY/.opencode/state"
printf 'one\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"
printf 'evidence\n' > "$FOREIGN_COPY/.opencode/state/log.json"
rm -f "$FOREIGN_CASE/vernant-python"
rc=0; run_foreign_teardown rc
d=$OUT/1b-foreign-claude-only-dead-launcher-driver-missing
mkdir -p "$d"
cp "$FOREIGN_CASE/stdout" "$d/stdout.txt"; cp "$FOREIGN_CASE/stderr" "$d/stderr.txt"; cp "$FOREIGN_CASE/git-worktree.log" "$d/git-worktree-argv.log" 2>/dev/null
{
  echo "exit=$rc"
  if [ -e "$FOREIGN_COPY" ]; then echo "copy=present"; else echo "copy=gone"; fi
  git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | sed 's/^/worktree-list: /'
  for f in .claude/channel-outbox/a.jsonl .opencode/state/log.json; do
    p=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -path "*/files/$f" -type f 2>/dev/null | head -n 1)
    if [ -n "$p" ]; then printf 'preserved %s bytes=%q sha256-lines=%s\n' "$f" "$(cat "$p")" "$(grep -cF "  $f" "${p%/files/*}/meta/SHA256SUMS")"; else echo "NOT-preserved $f"; fi
  done
  grep -E 'worktree (unlock|remove)' "$d/git-worktree-argv.log" | sed "s|$FOREIGN_CASE|<case>|g; s/^/argv: /"
} > "$d/observed.txt"
echo "== 1b"; cat "$d/observed.txt"; grep -E 'released creation lock|REFUSED' "$d/stderr.txt" | head -3
for point in launcher unlock; do
  dead_launcher_pid
  make_own_locked_copy_case "live-r7-$point" enclosing "$FOREIGN_DEAD_PID"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' '.claude/channel-outbox/' 'notes/' >> "$exclude"
  mkdir -p "$FOREIGN_COPY/.claude/channel-outbox" "$FOREIGN_COPY/notes"
  printf 'one\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"
  printf 'only here\n' > "$FOREIGN_COPY/notes/unique.dat"
  add_late_mutation_hooks "$point"
  printf 'printf late > %q\n' "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl" > "$FOREIGN_CASE/mutate.sh"
  rc=0; run_foreign_teardown rc
  d=$OUT/5-own-late-claude-file-at-$point
  mkdir -p "$d"
  cp "$FOREIGN_CASE/stderr" "$d/stderr.txt"; cp "$FOREIGN_CASE/git-worktree.log" "$d/git-worktree-argv.log" 2>/dev/null
  {
    echo "exit=$rc"
    if [ -e "$FOREIGN_CASE/git-protects-ran.done" ]; then echo "mutation=ran"; else echo "mutation=did-not-run"; fi
    if [ -e "$FOREIGN_COPY" ]; then echo "copy=present"; else echo "copy=gone"; fi
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | sed 's/^/worktree-list: /'
    if [ -f "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl" ]; then echo "late-file=in-copy"; fi
    p=$(grep -rlF late "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" 2>/dev/null | grep 'c.jsonl' | head -1)
    [ -z "$p" ] || echo "late-file=preserved at ${p#"$FOREIGN_CASE/"}"
    if [ -e "$FOREIGN_CASE/state/task-x1.meta" ]; then echo "task-meta=present"; else echo "task-meta=gone"; fi
  } > "$d/observed.txt"
  echo "== point=$point"; cat "$d/observed.txt"; grep -E 'released creation lock|REFUSED|restored|unlocked' "$d/stderr.txt" | head -5
done
echo "drive done"
