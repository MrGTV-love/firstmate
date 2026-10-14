#!/usr/bin/env bash
# concurrent.sh <impl-root> <scen-dir> <nruns> <jobs> <roots-file> [extra env...]
set -u
impl=$1 scen=$2 nruns=$3 jobs=$4 rootsfile=$5; shift 5
mkdir -p "$scen"
roots=()
if [ "$rootsfile" != full ]; then while IFS= read -r line; do roots+=("$line"); done < "$rootsfile"; fi
per=$(( ${#roots[@]} / nruns ))
perl "$(dirname "$0")/psampler.pl" "$scen/slots" "$scen/ps.tsv" "$scen/stop" &
sp=$!
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf 'start\t%s\tload\t%s\n' "$start" "$(sysctl -n vm.loadavg)" > "$scen/summary.txt"
pids=()
for ((i=0;i<nruns;i++)); do
  (
    s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    env XDG_CACHE_HOME="$scen/xdg" FM_DURATION_FILE=off FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$scen/slots" "$@" \
      "$impl/bin/fm-lint.sh" --jobs "$jobs" --telemetry "$scen/run$i.tsv" ${roots[@]+"${roots[@]:i*per:per}"} > "$scen/run$i.out" 2>&1
    rc=$?
    e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    printf 'run%d\trc=%d\twall=%.3f\n' "$i" "$rc" "$(perl -e "print $e-$s")" >> "$scen/summary.txt"
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
touch "$scen/stop"; wait "$sp"
printf "total_wall\t%.3f\tload_end\t%s\t%s\n" "$(perl -e "print $end-$start")" "$(sysctl -n vm.loadavg)" "$(grep "^#peak" "$scen/ps.tsv")" >> "$scen/summary.txt"
cat "$scen/summary.txt"
