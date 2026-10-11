#!/usr/bin/env bash
# Real bin/fm-bootstrap.sh in fresh homes of each kind, each with its own EMPTY
# private claim root, to show which homes arm the standing detector:
#   primary     plain home            -> registers proc-guard; a runner comes up after return
#   lab         .fm-lab-home marker   -> registers nothing, takes no claim
#   secondmate  .fm-secondmate-home   -> registers nothing, takes no claim
#   detect-only FM_BOOTSTRAP_DETECT_ONLY=1 -> registers nothing, takes no claim
#   suite       tests/lib.sh held default claim root -> registers, starts no runner
# Usage: round4-bootstrap-home-kinds.sh <worktree>
set -u
WT=$1
# shellcheck disable=SC1091
. "$WT/tests/lib.sh"
T=$(fm_test_tmproot boot-kinds4)
fakebin="$T/fakebin"; mkdir -p "$fakebin"
for t in tmux node chrome-devtools-axi; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
run() {  # <kind> <home> <claims> [env...]
  local kind=$1 home=$2 claims=$3 rc s e
  shift 3
  s=$(python3 -I -c 'import time; print(time.time())')
  env "$@" PATH="$fakebin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_PROCEVENT_CLAIM_ROOT="$claims" "$WT/bin/fm-bootstrap.sh" > "$home.out" 2>&1; rc=$?
  e=$(python3 -I -c 'import time; print(time.time())')
  at_return=$([ -s "$claims/proc-guard.claim" ] && sed -n 3p "$claims/proc-guard.claim" || echo none)
  up=no
  for _ in $(seq 1 100); do
    r=$(cat "$home/state/procevent/proc-guard.runner" 2>/dev/null)
    if [ -n "$r" ] && kill -0 "$r" 2>/dev/null; then up=yes; break; fi
    sleep 0.1
  done
  printf '%-11s exit=%s seconds=%.2f registration=%s claim_at_return=%s runner_up_within_10s=%s missing_line=%s\n' \
    "$kind" "$rc" "$(python3 -I -c "print($e-$s)")" \
    "$([ -s "$home/state/procevent/proc-guard.source" ] && echo yes || echo no)" "$at_return" "$up" \
    "$(grep -c 'pile-up detector' "$home.out")"
  fm_test_track_procevent_home "$home" "$claims"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$claims" "$WT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
}
for kind in primary lab secondmate detect-only; do
  home="$T/$kind"; mkdir -p "$home" "$T/claims-$kind"
  extra=()
  case $kind in
    lab) "$WT/bin/fm-lab-home.sh" create "$home" >/dev/null ;;
    secondmate) : > "$home/.fm-secondmate-home" ;;
    detect-only) extra=(FM_BOOTSTRAP_DETECT_ONLY=1) ;;
  esac
  run "$kind" "$home" "$T/claims-$kind" ${extra[@]+"${extra[@]}"}
done
home="$T/suite"; mkdir -p "$home"
before=$(pgrep -f 'fm-proc-guard.py watch' | sort)
run suite "$home" "$FM_PROCEVENT_CLAIM_ROOT"
after=$(pgrep -f 'fm-proc-guard.py watch' | sort)
echo "suite: new fm-proc-guard samplers started by the held-claim bootstrap=$(comm -13 <(echo "$before") <(echo "$after") | grep -c .)"
