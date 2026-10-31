#!/usr/bin/env bash
# Retirement test for spawn-brief-out-of-scope: a blank exclusion heading is
# equivalent to None, and must not prevent an otherwise complete dispatch.
# Exercise the real dispatcher for both ships and scouts, not just its parser.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-brief-scope)
trap fm_test_cleanup EXIT

for kind in ship scout; do
  home="$TMP_ROOT/$kind/home"
  project="$TMP_ROOT/$kind/project"
  wt="$TMP_ROOT/$kind/wt"
  id="blank-scope-$kind"
  fm_test_spawn_home "$home" claude
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/$kind/fake" claude)
  fm_git_worktree "$project" "$wt" "wt-$kind"
  fm_test_spawn_brief "$home" "$id" 'Fix the badge refresh without changing the renderer.'
  cat >> "$home/data/$id/brief.md" <<EOF

### Out of scope

## Definition Of Done (task)
### Mandatory items
$(fm_test_dod_item M1)
EOF
  args=()
  if [ "$kind" = ship ]; then
    args=(--mode no-mistakes --yolo off)
  else
    args=(--scout)
  fi
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$project" "${args[@]}") \
    || fail "a complete $kind brief with a blank exclusion heading did not spawn: $out"
  assert_present "$home/state/$id.meta" "$kind spawn did not record the task"
  assert_contains "$out" "spawned $id" "$kind dispatcher did not finish launch"
  pass "$kind dispatch accepts a blank out-of-scope heading"
done
