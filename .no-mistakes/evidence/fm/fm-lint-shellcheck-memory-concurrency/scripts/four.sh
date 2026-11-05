#!/usr/bin/env bash
# four.sh <lint> <label> <pool> [ENV=VAL...]: 4 concurrent lint runs, each with its own HOME, XDG_CACHE_HOME, FM_HOME,
# 3 stand-in roots each, 2 workers; samples aggregate stand-in RSS every 0.2 s.
set -u
lint=$1 label=$2 pool=$3; shift 3
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6N1HVAKM46GY6DT148EV8A5/s1
T=/tmp/fmlt/$label; rm -rf "$T"; mkdir -p "$T" "$E"
for r in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "/tmp/fmlt/$r.sh"; done
: > "$T/spans"; rm -f "$T/stop"
perl /tmp/fmlt-scripts/sampler.pl "$E/$label.samples" "$T/stop" /tmp/fmlt/bin/shellcheck &
sp=$!
start=$(date +%s)
pids=()
for h in 1 2 3 4; do
  mkdir -p "$T/home$h/.cache" "$T/fm$h"
  env HOME="$T/home$h" XDG_CACHE_HOME="$T/home$h/.cache" FM_HOME="$T/fm$h" FM_LINT_CACHE_DIR=off \
    FM_LINT_SLOT_DIR="$pool" PATH="/tmp/fmlt/bin:$PATH" SIM_LOG="$T/spans" "$@" \
    "$lint" --jobs 2 --telemetry "$T/tel.$h.tsv" /tmp/fmlt/a.sh /tmp/fmlt/b.sh /tmp/fmlt/c.sh > "$T/out.$h" 2>&1 &
  pids+=($!)
done
rc_all=
for p in "${pids[@]}"; do wait "$p"; rc_all+="$? "; done
touch "$T/stop"; wait "$sp"
end=$(date +%s)
peak=$(awk '!/^#/ && $3>m {m=$3; n=$2} END {print m+0, n+0}' "$E/$label.samples")
maxn=$(awk '!/^#/ && $2>m {m=$2} END {print m+0}' "$E/$label.samples")
other=$(awk '!/^#/ && $5>m {m=$5} END {print m+0}' "$E/$label.samples")
nsamp=$(grep -vc '^#' "$E/$label.samples")
{
echo "label=$label lint=$lint pool=$pool env=$*"
echo "exit statuses: $rc_all"
echo "wall seconds: $((end-start))"
echo "roots completed (stand-in end records): $(wc -l < "$T/spans" | tr -d ' ') of 12"
echo "samples: $nsamp at 0.2 s"
echo "peak aggregate stand-in RSS KiB, count at that sample: $peak"
echo "max concurrent stand-ins in any sample: $maxn"
echo "max RSS KiB of other (real) shellcheck processes on host during window: $other"
} | tee "$E/$label.summary"
