#!/usr/bin/env bash
# Live driver: the real bin/fm-teardown.sh (no --force) on a task whose nested copy
# sits in slot A of a REAL pool built by the REAL installed treehouse (unproven
# provider: it has no `capabilities` command). Sibling slot B is a recovered
# quarantine holding an unlanded nested copy. The installed binary sweeps
# recovered entries under its state lock, so any status/get/lease/return the
# teardown ran would put B at risk. Reuses the pool suite's own fixture builder.
set -u
WT=$1
cd "$WT/tests"
eval "$(sed -e '$d' -e 's|\$(dirname "\${BASH_SOURCE\[0\]}")|'"$WT"'/tests|g' fm-teardown-pool.test.sh)"
export FM_TEST_TREEHOUSE_PROVIDER
FM_TEST_TREEHOUSE_PROVIDER=$(command -v treehouse)
echo "provider: $FM_TEST_TREEHOUSE_PROVIDER $(TREEHOUSE_NO_UPDATE_CHECK=1 "$FM_TEST_TREEHOUSE_PROVIDER" --version)"
for kind in ordinary-old recovered-old; do
  echo "=================== slot A lease kind: $kind"
  unc_pool_case "live-inert-$kind" "$kind" real || { echo "BUILD FAILED"; continue; }
  c=$UNC_CASE
  echo "slot A: $UNC_A"; echo "slot B: $UNC_B (recovered, unlanded nested copy $UNC_B_COPY)"
  echo "--- pool state before:"; jq -c '.worktrees[] | {name,path,leased,lease_holder,lease_id}' "$UNC_STATE"
  before=$(cat "$UNC_STATE")
  unc_copy_snapshot "$UNC_B_COPY" "$c/b.before"; unc_copy_snapshot "$UNC_NESTED" "$c/n.before"
  : > "$c/treehouse.argv"
  rc=0; out=$(unc_run_teardown "$c") || rc=$?
  echo "--- teardown task-x1 (no --force) exit=$rc; output tail:"; printf '%s\n' "$out" | tail -6
  echo "--- treehouse argv during teardown:"; cat "$c/treehouse.argv"
  [ -e "$c/state/task-x1.meta" ] && echo "task record KEPT" || echo "task record retired"
  [ -e "$c/state/task-x1.teardown-return-pending" ] && echo "return-pending marker WRITTEN" || echo "no return-pending marker"
  [ "$(cat "$UNC_STATE")" = "$before" ] && echo "pool state byte-identical" || { echo "POOL STATE CHANGED:"; jq -c '.worktrees[]' "$UNC_STATE"; }
  unc_copy_snapshot "$UNC_B_COPY" "$c/b.after"; cmp -s "$c/b.before" "$c/b.after" && echo "sibling B unlanded copy unchanged (HEAD $(git -C "$UNC_B_COPY" rev-parse --short HEAD))" || echo "SIBLING B CHANGED"
  [ -d "$UNC_NESTED" ] && { unc_copy_snapshot "$UNC_NESTED" "$c/n.after"; cmp -s "$c/n.before" "$c/n.after" && echo "task's reassociated copy left in place unchanged" || echo "task copy changed"; } || echo "task copy removed"
  grep -E -- '(^| )(--force|-f|--yes)( |$)' "$c/git.argv" >/dev/null && echo "FORCED GIT RAN" || echo "no forced git command"
done
rm -rf "$TMP_ROOT"
echo "fixture root removed: $( [ -e "$TMP_ROOT" ] && echo no || echo yes )"
