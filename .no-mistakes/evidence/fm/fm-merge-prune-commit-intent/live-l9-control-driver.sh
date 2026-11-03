#!/usr/bin/env bash
# L9 control: the same teardown-refusal-then-fallback flow, with only plain
# scratch (node_modules/x) in the copy, run against a given source tree. Shows
# whether the "retry ... teardown could not finish its records yet" tail after a
# fallback removal is old fallback behaviour or new to the intent path.
set -u
SUITE_TREE=$1 SRC=$2 LABEL=$3
SUITE="$SUITE_TREE/tests/fm-merge-prune.test.sh"
HELP=$(mktemp -t fm-live-helpers.XXXXXX)
end=$(( $(grep -n '^ALL_TESTS=(' "$SUITE" | cut -d: -f1) - 1 ))
sed -n "1,${end}p" "$SUITE" | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$SUITE_TREE/tests/lib.sh\"#" > "$HELP"
. "$HELP"; rm -f "$HELP"
ROOT=$SRC; BIN_DIR=$SRC/bin
make_e2e_world
printf 'branch=fm/t1\n' >> "$STATE/t1.meta"
mkdir -p "$COPY/node_modules"; printf x > "$COPY/node_modules/x"
touch "$W/refuse"
prune_real arm t1 >/dev/null 2>&1
prune_real run t1 --now >/dev/null 2>&1
echo "== $LABEL L9 control (only node_modules/x, teardown refuses, fallback decides)"
if [ -e "$COPY" ]; then echo "   copy: STILL ON DISK"; else echo "   copy: GONE"; fi
echo "   destroy calls: $(destroy_calls)   wakes: $(wake_count)   record state: $(rec_field t1 state)"
sed 's/^/   log: /' "$DATA/t1/merge-prune.log"
echo "   tmp root: $TMP_ROOT"
