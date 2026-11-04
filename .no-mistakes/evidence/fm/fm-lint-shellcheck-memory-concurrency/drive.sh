#!/usr/bin/env bash
# Live driver: real bin/fm-lint.sh + real ShellCheck 0.11.0 on disposable
# fixtures, private slot pools, four HOME/XDG_CACHE_HOME/FM_HOME values.
# usage: drive.sh <lint> <phase-name> <runs> <slot-dir> [VAR=value...]
set -u
LINT=$1 PHASE=$2 RUNS=$3 POOL=$4
shift 4
W=/tmp/fmlint-live
FX=$W/fx
OUT=$W/out/$PHASE
rm -rf "$OUT"; mkdir -p "$OUT"
# Sampler: libproc every 0.1 s over the PIDs the shellcheck wrapper registers.
mkdir -p "$OUT/pids"
python3 -I "$W/tools/sampler.py" "$OUT/pids" "$OUT/samples.tsv" &
sampler=$!
start=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
if [ -d "$POOL/history" ]; then
  echo "history records before (KiB):" > "$OUT/history-before.txt"
  for f in "$POOL"/history/*; do [ -f "$f" ] && printf '  %s %s\n' "$(basename "$f" | cut -c1-12)" "$(cat "$f")"; done >> "$OUT/history-before.txt"
  cat "$OUT/history-before.txt"
fi
pids=()
for run in $(seq 1 "$RUNS"); do
  mkdir -p "$W/home.$run/.cache" "$W/fm.$run"
  if [ "$POOL" = default ]; then pool_env=(-u FM_LINT_SLOT_DIR PATH="$W/wrapbin:$W/idstub:$PATH"); else pool_env=(FM_LINT_SLOT_DIR="$POOL" PATH="$W/wrapbin:$PATH"); fi
  env "${pool_env[@]}" "$@" HOME="$W/home.$run" XDG_CACHE_HOME="$W/home.$run/.cache" FM_HOME="$W/fm.$run" \
    FM_LINT_CACHE_DIR=off FM_DURATION_HOME="$W/dur" FMLIVE_PID_DIR="$OUT/pids" \
    "$LINT" --jobs 2 "$FX/a.sh" "$FX/b.sh" "$FX/c.sh" > "$OUT/run.$run.out" 2>&1 &
  pids+=("$!")
done
i=0
for pid in "${pids[@]}"; do
  i=$((i + 1)); rc=0; wait "$pid" || rc=$?
  echo "run $i exit $rc" >> "$OUT/exits.txt"
done
end=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
sleep 0.5; kill "$sampler"; wait "$sampler" 2>/dev/null
awk -F'\t' 'NR>2{g=$1-prev; if (g>mg) mg=g} NR>1{prev=$1} END{printf "max sampler gap: %.2fs\n", mg}' "$OUT/samples.tsv" > "$OUT/gap.txt"
awk -F'\t' -v ph="$PHASE" -v s="$start" -v e="$end" 'NR>1{ if ($4>p) {p=$4; pl=$0}; if ($3>r) r=$3; if ($2>m) m=$2 } END {printf "%s: wall=%.1fs peak_sum_max_rss_footprint_kib=%d (%.0f MiB) peak_sum_rss_kib=%d peak_concurrent=%d samples=%d\n  peak sample: %s\n", ph, e-s, p, p/1024, r, m, NR-1, pl}' "$OUT/samples.tsv" | tee "$OUT/summary.txt"
cat "$OUT/gap.txt" "$OUT/exits.txt" | tee -a "$OUT/summary.txt"
if [ -d "$POOL/history" ]; then
  echo "history records (KiB):" | tee -a "$OUT/summary.txt"
  for f in "$POOL"/history/*; do [ -f "$f" ] && printf '  %s %s\n' "$(basename "$f" | cut -c1-12)" "$(cat "$f")"; done | tee -a "$OUT/summary.txt"
fi
