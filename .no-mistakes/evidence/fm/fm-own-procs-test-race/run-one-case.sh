#!/usr/bin/env bash
# run-one-case.sh <repo-root> <runs> - run test_own_procs_stops_a_runaway_tree <runs> times
# from <repo-root>/tests/fm-proc-budget.test.sh, without the other cases.
root=$1 runs=$2
drv=$(mktemp -d)/drv.test.sh
mkdir -p "$(dirname "$drv")"
# everything above the case list, with lib.sh sourced from the given root
awk '/^test_own_procs_invalid_calls$/ {exit} /^test_memory_invalid_limits$/ {skip=1} /^# --- --own-procs/ {skip=0} !skip {print}' "$root/tests/fm-proc-budget.test.sh" \
  | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$root/tests/lib.sh#" >"$drv"
cat >>"$drv" <<EOF
for i in \$(seq 1 $runs); do
  ( test_own_procs_stops_a_runaway_tree ) && ok=\$((\${ok:-0}+1)) || bad=\$((\${bad:-0}+1))
done
echo "SUMMARY pass=\${ok:-0} fail=\${bad:-0} of $runs"
EOF
bash "$drv"; rc=$?; rm -rf "$(dirname "$drv")"; exit $rc
