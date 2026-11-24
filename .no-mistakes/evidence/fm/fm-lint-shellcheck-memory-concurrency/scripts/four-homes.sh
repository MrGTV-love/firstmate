#!/usr/bin/env bash
# four-homes.sh <repo> <label> <mib> <hold_s>: start 4 concurrent bin/fm-lint.sh runs,
# each with its own HOME, XDG_CACHE_HOME and FM_HOME, each linting 3 roots with --jobs 2,
# against a stand-in shellcheck that allocates <mib> MiB of resident memory and holds it.
# A sampler reads every stand-in's RSS with ps every 0.25 s.
set -u
repo=$1 label=$2 mib=$3 hold=$4
W=$(mktemp -d "${TMPDIR:-/tmp}/fourhomes.XXXXXX")
mkdir -p "$W/bin"
cat > "$W/bin/shellcheck" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then printf 'ShellCheck\nversion: 0.11.0\n'; exit 0; fi
exec perl -e '\$0="fmstandin-$label"; my \$s = "x" x ($mib*1024*1024); select(undef,undef,undef,$hold); exit 0'
SH
chmod +x "$W/bin/shellcheck"
for r in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$W/$r.sh"; done
samples="$W/samples.tsv"
( while :; do
    t=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    ps -axo rss=,command= | awk -v t="$t" -v tag="fmstandin-$label" '$2==tag {n++; s+=$1} END {printf "%s\t%d\t%d\n", t, n+0, s+0}'
    sleep 0.25
  done ) > "$samples" &
sp=$!
start=$(date +%s)
pids=()
for i in 1 2 3 4; do
  mkdir -p "$W/home.$i/.cache" "$W/fm.$i"
  ( cd "$repo" && env -u FM_LINT_SLOT_DIR -u FM_LINT_HOST_SLOTS -u FM_LINT_ROOT_RSS_KIB GITHUB_ACTIONS= CI= \
      HOME="$W/home.$i" XDG_CACHE_HOME="$W/home.$i/.cache" FM_HOME="$W/fm.$i" PATH="$W/bin:$PATH" \
      bin/fm-lint.sh --jobs 2 "$W/a.sh" "$W/b.sh" "$W/c.sh" > "$W/run.$i.out" 2>&1; echo "run $i exit=$?" >> "$W/exits" ) &
  pids+=($!)
done
wait "${pids[@]}"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
end=$(date +%s)
echo "== $label: 4 runs x 3 roots, stand-in ${mib} MiB each, hold ${hold}s"
sort "$W/exits"
echo "wall_s=$((end-start))"
awk -F'\t' 'BEGIN{mx=0;mn=0} {if($3>mx)mx=$3; if($2>mn)mn=$2} END{printf "samples=%d peak_concurrent_standins=%d peak_aggregate_rss_kib=%d (%.0f MiB)\n", NR, mn, mx, mx/1024}' "$samples"
echo "budget stated by head: 3670016 KiB (3584 MiB)"
echo "-- concurrency over time (sampled count -> number of samples)"
awk -F'\t' '{c[$2]++} END{for(k in c) printf "  %d at once: %d samples\n", k, c[k]}' "$samples" | sort -n
echo "-- run 1 stderr"
cat "$W/run.1.out"
cp "$samples" "${OUT_SAMPLES:-/dev/null}" 2>/dev/null
rm -rf "$W"
