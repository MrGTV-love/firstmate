#!/usr/bin/env bash
# realmem.sh <mode>: calibrate | head2 | base2 — real ShellCheck on 4 repo roots.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6N1HVAKM46GY6DT148EV8A5
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6N1HVAKM46GY6DT148EV8A5/s6; mkdir -p $E
R=/tmp/fmlt/realmem; mkdir -p $R
mode=$1; shift
roots=(bin/fm-test-run.sh bin/fm-doc-audience-check.sh bin/fm-guard-lint.sh bin/fm-lint-workflows.sh)
"$W/bin/fm-mem-guard.sh" admit >/dev/null || { echo "mem guard refused; not starting"; exit 3; }
echo "pressure level before: $(sysctl -n kern.memorystatus_vm_pressure_level)"
echo "real shellcheck processes on host before: $(ps -axo comm= | awk '{sub(/.*\//,"")} $0=="shellcheck"' | wc -l | tr -d ' ')"
rm -f $R/stop.$mode
case $mode in calibrate) L=$W/bin/fm-lint.sh; cwd=$W; n=1; jobs=1;; head2) L=$W/bin/fm-lint.sh; cwd=$W; n=2; jobs=2;; base2) L=/tmp/fmlt/base/bin/fm-lint.sh; cwd=/tmp/fmlt/base; n=2; jobs=2;; esac
cp /dev/null $R/$mode.pressure
perl /tmp/fmlt-scripts/sampler2.pl $E/$mode.samples $R/stop.$mode "$cwd/bin/" & sp=$!
( while [ ! -e $R/stop.$mode ]; do echo "$(date +%s) $(sysctl -n kern.memorystatus_vm_pressure_level)" >> $R/$mode.pressure; sleep 1; done ) & pw=$!
s=$(date +%s)
pids=()
for h in $(seq $n); do
  ( cd $cwd && env HOME=$R/$mode.h$h XDG_CACHE_HOME=$R/$mode.h$h/.cache FM_HOME=$R/$mode.fm$h FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR=$R/pool-$mode-shared "$@" \
      $L --jobs $jobs --telemetry $R/$mode.$h.tsv "${roots[@]/#/$cwd/}" > $R/$mode.$h.out 2>&1 ) &
  pids+=($!)
done
rcs=; for p in "${pids[@]}"; do wait $p; rcs+="$? "; done
e=$(date +%s); touch $R/stop.$mode; wait $sp $pw
echo "mode=$mode env=$* runs=$n jobs=$jobs exit statuses: $rcs wall s: $((e-s))"
for h in $(seq $n); do awk -F'\t' '$1=="end"{r=$3; sub(/.*\//,"",r); print "  run '$h'", r, "rc="$9, "rss_kib="$10}' $R/$mode.$h.roots.tsv; done
awk '!/^#/ {if($3>m){m=$3;mc=$2} if($2>c)c=$2; if($5>o)o=$5} END {print "  peak aggregate RSS KiB of this test'"'"'s shellcheck:", m, "(count", mc, ") max concurrent:", c, "max other host shellcheck RSS KiB:", o}' $E/$mode.samples
echo "  samples: $(grep -vc '^#' $E/$mode.samples) at 0.2 s; max pressure level seen: $(awk '$2>m{m=$2} END{print m+0}' $R/$mode.pressure)"
[ -d $R/pool-$mode-shared/history ] && echo "  history records KiB: $(cat $R/pool-$mode-shared/history/* 2>/dev/null | tr '\n' ' ')"
