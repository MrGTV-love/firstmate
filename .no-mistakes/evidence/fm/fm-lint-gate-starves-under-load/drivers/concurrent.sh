#!/usr/bin/env bash
# concurrent.sh <label> <lint-bin> <slot-dir> <runs> <roots-per-run>
# Starts <runs> concurrent real lints (--jobs 2) on disjoint fixture roots and
# reports per-run wall time, exit status, peak concurrent ShellChecks, and load.
set -u
LAB=$(cat /tmp/fm-lint-lab-path.txt)
label=$1 bin=$2 slots=$3 runs=$4 per=$5
out="$LAB/out/$label"; rm -rf "$out"; mkdir -p "$out"
rm -f "$out/stop"
perl "$LAB/sample.pl" "$LAB/fx/" "$out/samples.tsv" "$out/stop" &
sampler=$!
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
pids=()
for r in $(seq 1 "$runs"); do
  files=()
  for i in $(seq $(( (r-1)*per + 1 )) $(( r*per ))); do files+=("$LAB/fx/c$i.sh"); done
  ( s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    LINT_BIN="$bin" LAB_SLOTS="$slots" "$LAB/lint.sh" --jobs 2 "${files[@]}" > "$out/run$r.log" 2>&1
    rc=$?
    e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    printf 'run%s\trc=%s\twall=%.1fs\n' "$r" "$rc" "$(echo "$e - $s" | bc)" > "$out/run$r.result" ) &
  pids+=($!)
done
wait "${pids[@]}"
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
touch "$out/stop"; wait "$sampler"
{
  echo "== $label: $runs concurrent lints x --jobs 2 x $per roots, cap=${FM_LINT_HOST_SLOTS:-default(ncpu/2=9)}, ncpu=$(sysctl -n hw.ncpu)"
  cat "$out"/run*.result
  printf 'total_wall=%.1fs\n' "$(echo "$end - $start" | bc)"
  awk -F '\t' '$1!="MAX"{n++; s+=$3; if(min==""||$3<min)min=$3; if($3>max)max=$3; c[$2]++} $1=="MAX"{print "peak_concurrent_shellcheck=" $2} END{printf "load_1min min=%.1f mean=%.1f max=%.1f (2*ncpu=36)\n", min, s/n, max; for(k in c) printf "  samples_with_%s_running=%d\n", k, c[k]}' "$out/samples.tsv" | sort
}
