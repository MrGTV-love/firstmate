#!/usr/bin/env bash
# Round 2 (head 8af931ab): loop the real bin/fm-bootstrap.sh in fresh test homes
# and count any "pile-up detector" line. Arming now runs in the background beside
# the diagnostics, so each home also has a data/ dir: bootstrap then also runs
# `fm-contributions.sh arm --if-owned` while the detector arm is in flight
# (concurrent process-event registration). Half the iterations use the
# tests/lib.sh held claim (live owner, as in a suite), half use a cold private
# claim root (a real runner is started, then swept). Optional CPU burners.
# Usage: round2-bootstrap-arm-flake-loop.sh <worktree> <iterations> <burners>
set -u
WT=$1; N=$2; B=$3
# shellcheck disable=SC1091
. "$WT/tests/lib.sh"
T=$(fm_test_tmproot boot-arm-flake2)
fakebin="$T/fakebin"; mkdir -p "$fakebin"
for t in tmux node chrome-devtools-axi; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
pids=()
for _ in $(seq 1 "$B"); do ( while :; do :; done ) & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; fm_test_cleanup' EXIT
held_fail=0; cold_fail=0; noreg=0; badexit=0; contrib=0
for i in $(seq 1 "$N"); do
  home="$T/h$i"; mkdir -p "$home/data" "$home/config"
  if [ $((i % 2)) = 0 ]; then claims="$T/claims$i"; mkdir -p "$claims"; kind=cold; else claims=$FM_PROCEVENT_CLAIM_ROOT; kind=held; fi
  out=$(PATH="$fakebin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_PROCEVENT_CLAIM_ROOT="$claims" "$WT/bin/fm-bootstrap.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { badexit=$((badexit + 1)); echo "iteration $i ($kind): bootstrap exit $rc"; }
  if printf '%s\n' "$out" | grep -q 'pile-up detector'; then
    [ "$kind" = held ] && held_fail=$((held_fail + 1)) || cold_fail=$((cold_fail + 1))
    echo "iteration $i ($kind): $(printf '%s\n' "$out" | grep 'pile-up detector')"
  fi
  printf '%s\n' "$out" | grep -q 'contribution observation' && { contrib=$((contrib + 1)); echo "iteration $i ($kind): $(printf '%s\n' "$out" | grep 'contribution observation')"; }
  [ -s "$home/state/procevent/proc-guard.source" ] || { noreg=$((noreg + 1)); echo "iteration $i ($kind): no registration"; }
  fm_test_track_procevent_home "$home" "$claims"
  if [ "$kind" = cold ]; then
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$claims" "$WT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  fi
done
echo "iterations=$N burners=$B held_missing=$held_fail cold_missing=$cold_fail contribution_missing=$contrib no_registration=$noreg nonzero_exit=$badexit"
