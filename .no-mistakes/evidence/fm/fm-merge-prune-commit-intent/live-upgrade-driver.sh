#!/usr/bin/env bash
# Upgrade check: a prune record armed by the BASE prune (no branch= line), then
# run by the HEAD prune, for a returned slot whose only ignored file is an
# UNEXPIRED intent naming the task's branch. Same disposable world as live-driver.sh.
set -u
SUITE_TREE=$1 BASE=$2
SUITE="$SUITE_TREE/tests/fm-merge-prune.test.sh"
HELP=$(mktemp -t fm-live-helpers.XXXXXX)
end=$(( $(grep -n '^ALL_TESTS=(' "$SUITE" | cut -d: -f1) - 1 ))
sed -n "1,${end}p" "$SUITE" | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$SUITE_TREE/tests/lib.sh\"#" > "$HELP"
. "$HELP"; rm -f "$HELP"
make_e2e_world
sed -i '' 's/git -C "\$wt" clean -ffdxq/git -C "$wt" clean -ffdq/' "$W/bin/treehouse"
printf 'branch=fm/t1\n' >> "$STATE/t1.meta"
put_intent "$COPY" 2999-01-01T00:00:00+00:00 fm/t1
BIN_DIR=$BASE/bin; ROOT=$BASE
prune_real arm t1 >/dev/null 2>&1
echo "== record armed by BASE prune:"; sed 's/^/   /' "$STATE/t1.merge-prune"
BIN_DIR=$SUITE_TREE/bin; ROOT=$SUITE_TREE
sed -i '' "s#$BASE/bin#$SUITE_TREE/bin#" "$W/bin/teardown-real" 2>/dev/null || true
rm -f "$W/code-root/bin"; ln -s "$SUITE_TREE/bin" "$W/code-root/bin"
prune_real run t1 --now >/dev/null 2>&1
echo "== after HEAD prune run:"
if [ -e "$COPY" ]; then echo "   copy: STILL ON DISK"; else echo "   copy: GONE"; fi
echo "   destroy calls: $(destroy_calls)   wakes: $(wake_count)"
echo "   task record: $([ -e "$STATE/t1.meta" ] && echo present || echo deleted by real teardown)"
echo "   prune record: $([ -e "$STATE/t1.merge-prune" ] && cat "$STATE/t1.merge-prune" | tr '\n' ' ' || echo cleared)"
sed 's/^/   log: /' "$DATA/t1/merge-prune.log"
[ ! -s "$STATE/.wake-queue" ] || sed 's/^/   wake: /' "$STATE/.wake-queue"
