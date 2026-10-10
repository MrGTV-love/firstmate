#!/usr/bin/env bash
# Repro for the intermittent "MISSING: process pile-up detector could not be armed"
# line in a test bootstrap. Runs the adapter's arm the way bin/fm-bootstrap.sh
# does, in the tests/lib.sh environment (held claim), N times, under CPU load.
# Usage: arm-flake-repro.sh <worktree> <iterations> <burners>
set -u
ROOT_ARG=$1; N=$2; B=$3
# shellcheck disable=SC1091
. "$ROOT_ARG/tests/lib.sh"
T=$(fm_test_tmproot arm-flake)
pids=()
for _ in $(seq 1 "$B"); do ( while :; do :; done ) & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; fm_test_cleanup' EXIT
fails=0
for i in $(seq 1 "$N"); do
  home="$T/h$i"; mkdir -p "$home/state"
  err=$(PATH="${REPRO_PATH:-$PATH}" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-procevent-proc.sh" arm 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then fails=$((fails + 1)); printf 'iteration %s rc=%s stderr=%s\n' "$i" "$rc" "$err"; fi
done
echo "iterations=$N failures=$fails claim_still_held=$( [ -s "$FM_PROCEVENT_CLAIM_ROOT/proc-guard.claim" ] && sed -n 3p "$FM_PROCEVENT_CLAIM_ROOT/proc-guard.claim")"
