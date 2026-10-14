#!/usr/bin/env bash
# run-case.sh <case-name> <pr-url> <fault> [extra fm-pr-merge args...]
LAB=$1; W=$2; name=$3; url=$4; fault=$5; shift 5
id="lab$(printf '%s' "$name" | tr -cd 'a-z0-9' | cut -c1-20)"
printf '%s\n' "window=fm-$id" "worktree=$LAB/wt" "project=$LAB/wt" "kind=ship" "mode=no-mistakes" > "$LAB/state/$id.meta"
sd="$LAB/shim-$name"; rm -rf "$sd"; mkdir -p "$sd"; : > "$sd/calls.log"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" SHIM_DIR="$sd" SHIM_FAULT="$fault" SHIM_DROP="${SHIM_DROP:-}" PATH="$LAB/shimbin:$PATH" \
  "$W/bin/fm-pr-merge.sh" "$id" "$url" "$@" >"$sd/stdout" 2>"$sd/stderr"
rc=$?
end=$(date +%s)
echo "=== case: $name"
echo "url: $url  fault: $fault  extra: $*"
echo "exit code: $rc   elapsed: $((end-start))s"
echo "--- rollup GraphQL reads: $(grep -c "contexts(first:" "$sd/calls.log")   pr view reads: $(grep -c '^pr view .*mergeStateStatus' "$sd/calls.log")   branch reads: $(grep -c 'branches/' "$sd/calls.log")"
echo "--- stdout:"; cat "$sd/stdout"
echo "--- stderr:"; cat "$sd/stderr"
echo "--- blocked by shim:"; cat "$sd/blocked.log" 2>/dev/null || echo "(none)"
for f in "$sd"/rollup-real-*.json; do [ -f "$f" ] || continue
  echo "--- real rollup read $(basename "$f"): $(jq -s -c '[.[].data.repository.object.statusCheckRollup.contexts] | {pages:length, totalCount:.[0].totalCount, nodes:([.[].nodes[]]|length), lastHasNextPage:.[-1].pageInfo.hasNextPage}' "$f")"
done
