#!/bin/bash
# Run one real lint of the given paths, sampled every second.
# Args: <evidence-dir> <path>...
E=$1; shift
mkdir -p "$E"
start=$(date +%s)
FM_LINT_CACHE_DIR=off bin/fm-lint.sh --telemetry "$E/pass.tsv" "$@" > "$E/output.txt" 2>&1 &
lp=$!
/tmp/fmlint-sampler.sh "$lp" "$E/samples.tsv" &
sp=$!
wait "$lp"; rc=$?
end=$(date +%s)
wait "$sp"
echo "rc=$rc wall_s=$((end - start)) paths=$*" > "$E/result.txt"
cat "$E/result.txt"
