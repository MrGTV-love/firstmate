#!/usr/bin/env bash
# Live check, real forge read-only: a throwaway replica of the d1 B5 r4 copy.
# The copy is a fresh worktree of a temp blobless Vernant clone at the real copy's
# HEAD 5714eb0f (read from the forge; the real copy is never touched). The task
# records the real member PR 3528. gh is the real gh behind a read-only filter.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6G0SSW287C5ENA2421F4C38
LAB=$(cat /tmp/fm-train-lab.path)
COPY_HEAD=5714eb0f19016970a2750666f28619d6d71ab5a4
MEMBER_URL=https://github.com/MrGTV-love/vernant/pull/3528
MEMBER_HEAD=0b2e8a9f116efe9b9bbfc22b4df108e5a7be88e3
. "$WT/tests/fm-teardown-helpers.sh"
c=$(make_case real-d1b5-replica)
git -C "$c/project" worktree remove --force "$c/wt" 2>/dev/null || true
rm -rf "$c/project" "$c/wt"
cp -R "$LAB/vernant" "$c/project"
git -C "$c/project" config credential.helper '!/opt/homebrew/bin/gh auth git-credential'
git -C "$c/project" worktree add -q -b fm/vernant-d1-b5-replica "$c/wt" "$COPY_HEAD"
write_meta "$c" no-mistakes ship
printf '%s\n' "pr=$MEMBER_URL" >> "$c/state/task-x1.meta"
seed_backlog_in_flight "$c"
add_logging_treehouse "$c"
cat > "$c/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "gh \$*" >> "$c/gh.log"
case "\${1:-} \${2:-}" in
  "pr view"|"pr list") exec /opt/homebrew/bin/gh "\$@" ;;
esac
echo "read-only filter: blocked gh \$*" >&2
exit 97
SH
chmod +x "$c/fakebin/gh"
show() {
  local rc=0
  : > "$c/gh.log"
  run_teardown "$c" > "$c/stdout" 2> "$c/stderr" || rc=$?
  echo "=== $1"
  echo "exit: $rc"
  echo "--- stderr (watcher banner removed):"; grep -v '^●' "$c/stderr"
  echo "--- real gh calls (read-only filter):"; sed 's/^/  /' "$c/gh.log"
  echo "--- treehouse calls: $(tr '\n' ';' < "$c/treehouse.log" 2>/dev/null)"
  echo "--- task record present after: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"
  echo "--- copy present after: $([ -d "$c/wt" ] && echo yes || echo no)"
  echo "--- backlog state: $(backlog_row_state "$c")"
  echo
}
echo "# real forge, d1 B5 r4 replica, at $(git -C "$WT" rev-parse HEAD), $(date -u +%FT%TZ)"
echo "copy HEAD $(git -C "$c/wt" rev-parse HEAD), clean: $([ -z "$(git -C "$c/wt" status --porcelain)" ] && echo yes || echo no)"
echo "member PR 3528 head is ancestor of copy: $(git -C "$c/wt" merge-base --is-ancestor $MEMBER_HEAD $COPY_HEAD && echo yes || echo no); copy is ancestor of member head: $(git -C "$c/wt" merge-base --is-ancestor $COPY_HEAD $MEMBER_HEAD && echo yes || echo no)"
echo
show "W1. replica of the d1 B5 r4 copy, member 3528 CLOSED, train 3599 verified, NO run record: expect refused (feature commit 0bb1ac955 has no equal patch in the train)"
write_nm_run_record "$c" 01LABRUND1B5 "$MEMBER_URL" "$COPY_HEAD" "$MEMBER_HEAD"
echo "(lab run record written: pr_url=$MEMBER_URL submitted_head_sha=$COPY_HEAD last_pushed_sha=$MEMBER_HEAD)"
show "W2. same replica, with a run record that says this copy was the input of the run that pushed 3528's head: expect accepted, naming 3599"
