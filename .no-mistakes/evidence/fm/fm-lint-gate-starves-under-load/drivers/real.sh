#!/usr/bin/env bash
# real.sh <label> <lint-bin> <runs>: <runs> concurrent real lints (--jobs 2,
# cache off, private pool, default cap) over the same 13 canonical roots.
set -u
LAB=/Users/charlesabrooker/tmp/fm-lint-lab.xiz6Z3; W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4XFRRHNM6DGKRMTRZQB0YPJ
label=$1 bin=$2 runs=$3
out="$LAB/out/$label"; rm -rf "$out"; mkdir -p "$out"
roots=(); while read -r r; do roots+=("$W/$r"); done < "$LAB/real-roots.txt"
l0=$(sysctl -n vm.loadavg)
perl "$LAB/sample.pl" "$W/" "$out/samples.tsv" "$out/stop" &
sp=$!
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
pids=()
for r in $(seq 1 "$runs"); do
  ( a=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    LINT_BIN="$bin" LAB_SLOTS="$LAB/pool-real-$label" "$LAB/lint.sh" --jobs 2 --telemetry "$out/run$r.tsv" "${roots[@]}" > "$out/run$r.log" 2>&1; rc=$?
    b=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    printf 'run%s rc=%s wall=%.1fs\n' "$r" "$rc" "$(echo "$b - $a" | bc)" > "$out/run$r.result" ) &
  pids+=($!)
done
wait "${pids[@]}"
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
touch "$out/stop"; wait "$sp"
echo "== $label: $runs concurrent real lint(s), 13 canonical roots each, --jobs 2, cache off, cap 9"
cat "$out"/run*.result
printf 'total_wall=%.1fs  load(1/5/15) start=%s end=%s\n' "$(echo "$e - $s" | bc)" "$l0" "$(sysctl -n vm.loadavg)"
grep MAX "$out/samples.tsv" | sed 's/MAX\t/peak_concurrent_shellcheck=/'
for r in $(seq 1 "$runs"); do awk -F '\t' -v r=$r '$1=="end"{q+=($7-$6)-$8; a+=$8} END{printf "  run%s summed_queue=%.1fs summed_analysis=%.1fs\n", r, q/1000, a/1000}' "$out/run$r.roots.tsv"; done
