#!/usr/bin/env bash
# End to end, sandbox: a captain-held train member. The real bin/fm-teardown.sh
# writes the pending close record itself (nothing hand-written). Then the real
# bin/fm-captain-hold.sh answer closes the row from that record.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6G0SSW287C5ENA2421F4C38
. "$WT/tests/fm-teardown-helpers.sh"
capt() {  # <case> <args...>
  local c=$1; shift
  FM_HOME="$c/primary-home" FM_ROOT_OVERRIDE="$c/code-root" FM_STATE_OVERRIDE="$c/state" \
    FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" PATH="$c/fakebin:$PATH" \
    "$WT/bin/fm-captain-hold.sh" "$@"
}
for variant in treehouse-fails treehouse-ok; do
  train_case "held-$variant" none head
  c=$TRAIN_CASE
  seed_backlog_in_flight "$c"
  echo "=============== variant: $variant  (head $(git -C "$WT" rev-parse HEAD))"
  echo "member $TRAIN_MEMBER_URL, train https://github.com/example/repo/pull/9"
  capt "$c" hold task-x1 --reason "captain must choose the follow-up" >/dev/null 2>"$c/hold.err" \
    && echo "captain hold set: yes" || { echo "captain hold set: FAILED"; cat "$c/hold.err"; }
  if [ "$variant" = treehouse-fails ]; then
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/treehouse.log"\nexit 1\n' "$c" > "$c/fakebin/treehouse"
    chmod +x "$c/fakebin/treehouse"
  fi
  rc=0; run_teardown "$c" > "$c/td.out" 2> "$c/td.err" || rc=$?
  echo "--- teardown exit: $rc"
  echo "--- teardown stderr (banner removed):"; grep -v '^●' "$c/td.err"
  echo "--- treehouse calls: $(tr '\n' ';' < "$c/treehouse.log" 2>/dev/null)"
  echo "--- pending close record written by teardown:"
  cat "$c/state/task-x1.backlog-close" 2>/dev/null || echo "(none present)"
  echo "--- row after teardown:"; tasks-axi show task-x1 --file "$c/data/backlog.md" --full 2>&1 | grep -E 'state:|held:|hold_kind:|links:|body:'
  printf 'Proceed with the landed train.\n' > "$c/answer.txt"
  rc=0; capt "$c" answer task-x1 --decision-file "$c/answer.txt" > "$c/ans.out" 2> "$c/ans.err" || rc=$?
  echo "--- captain answer exit: $rc"; cat "$c/ans.err"
  echo "--- row after the answer:"; tasks-axi show task-x1 --file "$c/data/backlog.md" --full 2>&1 | grep -E 'state:|held:|links:|body:'
  echo
done
