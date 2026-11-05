#!/usr/bin/env bash
# one.sh <lint> <label> <pool> [ENV=VAL...]: one lint run of 3 stand-in roots, 2 workers, sampled.
set -u
lint=$1 label=$2 pool=$3; shift 3
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6N1HVAKM46GY6DT148EV8A5/s1
T=/tmp/fmlt/$label; rm -rf "$T"; mkdir -p "$T/home/.cache" "$E"
: > "$T/spans"
perl /tmp/fmlt-scripts/sampler.pl "$E/$label.samples" "$T/stop" /tmp/fmlt/bin/shellcheck & sp=$!
s=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$pool" PATH="/tmp/fmlt/bin:$PATH" SIM_LOG="$T/spans" "$@" \
  "$lint" --jobs 2 /tmp/fmlt/a.sh /tmp/fmlt/b.sh /tmp/fmlt/c.sh > "$T/out" 2>&1; rc=$?
e=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
touch "$T/stop"; wait $sp
{ echo "label=$label lint=$lint env=$*"; echo "exit status: $rc"; echo "wall seconds: $(echo "$e - $s" | bc)"
  echo "roots completed: $(wc -l < "$T/spans" | tr -d ' ') of 3"
  echo "samples: $(grep -vc '^#' "$E/$label.samples") at 0.2 s"
  echo "peak aggregate stand-in RSS KiB: $(awk '!/^#/ && $3>m {m=$3} END {print m+0}' "$E/$label.samples")"
  echo "max concurrent stand-ins: $(awk '!/^#/ && $2>m {m=$2} END {print m+0}' "$E/$label.samples")"; } | tee "$E/$label.summary"
