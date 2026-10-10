#!/usr/bin/env bash
# Loop the real bootstrap in fresh test homes (tests/lib.sh env: held claim,
# restricted PATH like tests/fm-bootstrap.test.sh) and catch the intermittent
# "MISSING: process pile-up detector could not be armed" line. BASH_ENV traces
# only the detector scripts, into a per-iteration log, without product changes.
# Usage: bootstrap-arm-flake-repro.sh <worktree> <iterations> <burners>
set -u
ROOT_ARG=$1; N=$2; B=$3
# shellcheck disable=SC1091
. "$ROOT_ARG/tests/lib.sh"
T=$(fm_test_tmproot boot-arm-flake)
fakebin="$T/fakebin"; mkdir -p "$fakebin"
for t in tmux node chrome-devtools-axi; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
cat > "$T/trace.env" <<'ENV'
case "$0" in
  */fm-procevent-proc.sh|*/fm-procevent.sh)
    exec 2>>"$FM_REPRO_TRACE"; printf '=== %s %s pid=%s\n' "$0" "$*" "$$" >&2; set -x ;;
esac
ENV
pids=()
for _ in $(seq 1 "$B"); do ( while :; do :; done ) & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; fm_test_cleanup' EXIT
fails=0
for i in $(seq 1 "$N"); do
  home="$T/h$i"; mkdir -p "$home"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" BASH_ENV="$T/trace.env" FM_REPRO_TRACE="$T/trace.$i" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  if printf '%s\n' "$out" | grep -q 'pile-up detector'; then
    fails=$((fails + 1)); echo "iteration $i: $(printf '%s\n' "$out" | grep 'pile-up detector')"
    cp "$T/trace.$i" "$(dirname "$0")/arm-flake-trace.$i.log"
    grep -n 'die\|error\|cannot\|exit 1\|return 1' "$T/trace.$i" | tail -15
  fi
  fm_test_track_procevent_home "$home" "$FM_PROCEVENT_CLAIM_ROOT"
  [ -s "$home/state/procevent/proc-guard.source" ] || echo "iteration $i: no registration"
done
echo "iterations=$N failures=$fails"
