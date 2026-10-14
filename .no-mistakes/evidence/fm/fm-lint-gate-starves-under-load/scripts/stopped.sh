#!/usr/bin/env bash
# stopped.sh <impl> <scen> <mode stop|kill>
# Cap 1. H holds the slot with heavy roots. X queues as head, then its gate is
# stopped (SIGSTOP, ps state T) or killed. Y must still finish; a stopped X must
# finish after SIGCONT.
set -u
impl=$1 scen=$2 mode=$3
mkdir -p "$scen"
ts() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
log() { printf '%s\t%s\n' "$(ts)" "$*" | tee -a "$scen/events.log"; }
common=(env XDG_CACHE_HOME="$scen/xdg" FM_DURATION_FILE=off FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$scen/slots" FM_LINT_HOST_SLOTS=1)
"${common[@]}" "$impl/bin/fm-lint.sh" --jobs 1 bin/fm-config-push.sh bin/backends/herdr.sh bin/fm-procevent-lavish.sh > "$scen/H.out" 2>&1 &
ph=$!; log "H started pid=$ph"
until ls "$scen/slots"/slot.0 >/dev/null 2>&1 && ps -ww -A -o command= | grep -q "fm-lint-cache.pl gate $scen/slots 18 $ph .*shellcheck"; do sleep 0.1; done
sleep 1; log "H admitted"
perl -e 'setpgrp(0,0); exec @ARGV' "${common[@]}" "$impl/bin/fm-lint.sh" --jobs 1 tests/fm-watch-triage-waits.test.sh > "$scen/X.out" 2>&1 &
px=$!; log "X started pid=$px"
gx=
until [ -n "$gx" ]; do
  gx=$(ps -ww -A -o pid=,command= | awk -v d="$scen/slots" -v r="$px" '$2 ~ /perl$/ && $3 ~ /fm-lint-cache.pl$/ && $4=="gate" && $5==d && $7==r {print $1}')
  sleep 0.05
done
until ls "$scen/slots"/queue.*."$gx".* >/dev/null 2>&1; do sleep 0.05; done
log "X gate pid=$gx queued: $(cd "$scen/slots" && ls queue.*.$gx.*)"
if [ "$mode" = stop ]; then
  while :; do
    kill -STOP "$gx"
    perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX|LOCK_NB) ? 0 : 1)' "$scen/slots/admission.lock" && break
    kill -CONT "$gx"; sleep 0.03
  done
  log "X gate stopped: state=$(ps -o stat= -p "$gx")"
else
  kill -KILL "$gx"; log "X gate killed"
fi
"${common[@]}" "$impl/bin/fm-lint.sh" --jobs 1 tests/fm-backend-herdr-eventwait-smoke.test.sh > "$scen/Y.out" 2>&1 &
py=$!; log "Y started pid=$py"
wait "$py"; yrc=$?
log "Y finished rc=$yrc; X gate state now: $(ps -o stat= -p "$gx" 2>/dev/null || echo gone)"
if [ "$mode" = stop ]; then
  kill -CONT "$gx"; log "X gate continued"
fi
wait "$px"; xrc=$?; log "X finished rc=$xrc"
wait "$ph"; hrc=$?; log "H finished rc=$hrc"
log "summary mode=$mode Y_rc=$yrc X_rc=$xrc H_rc=$hrc"
