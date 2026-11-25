#!/usr/bin/env bash
# run-lane.sh <suite> <case>...: run each named case of <suite> alone, under a process budget,
# with the gate and fleet overrides removed, one log per case in the evidence dir.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M89SHBX5SR6TE8YAYXSMV1RN
E=/Users/charlesabrooker/.no-mistakes/evidence/01M89SHBX5SR6TE8YAYXSMV1RN
suite=$1; shift
cd "$W" || exit 2
for c in "$@"; do
  start=$(date +%s)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_HOME FM_TEST_SIGNALS=1 \
      FM_RETAINED_EVIDENCE="$E/cases/retained-observations.txt" \
    bin/fm-proc-budget.sh --own-procs 200 -- bash "$suite" "$c" > "$E/cases/$c.log" 2>&1
  rc=$?
  printf '%s\t%s\trc=%s\tsecs=%s\n' "$suite" "$c" "$rc" "$(( $(date +%s) - start ))" >> "$E/cases/index.tsv"
done
