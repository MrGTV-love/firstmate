#!/usr/bin/env bash
# Round 2 (head 8af931ab): interleaved wall time of one real bin/fm-bootstrap.sh
# in a fresh test home, four variants per pair, same environment:
#   main            = git archive of base 924f479c (no detector)
#   head_noadapter  = git archive of head with bin/fm-procevent-proc.sh removed
#   head_held       = head, tests/lib.sh held claim (a live owner exists)
#   head_cold       = head, empty private claim root (first-session path; a real
#                     detached runner is started and then swept)
# After each head_cold run it also checks the runner came up after bootstrap
# returned (claim file + live runner pid), then sweeps it.
# Usage: round2-bootstrap-ab-timing.sh <head-worktree> <main-copy> <head-noadapter-copy> <pairs>
set -u
HEAD_ROOT=$1; MAIN_ROOT=$2; NOAD_ROOT=$3; N=$4
# shellcheck disable=SC1091
. "$HEAD_ROOT/tests/lib.sh"
T=$(fm_test_tmproot boot-ab2)
fakebin="$T/fakebin"; mkdir -p "$fakebin"
for t in tmux node chrome-devtools-axi; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
now() { python3 -I -c 'import time; print(f"{time.time():.3f}")'; }
one() {  # <root> <home> [claim-root]  -> prints seconds; stdout of bootstrap to $2.out
  local s e
  s=$(now)
  PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$2" FM_ROOT_OVERRIDE="$2" \
    FM_PROCEVENT_CLAIM_ROOT="${3:-$FM_PROCEVENT_CLAIM_ROOT}" "$1/bin/fm-bootstrap.sh" >"$2.out" 2>&1
  e=$(now)
  python3 -I -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")' "$s" "$e"
}
missing=0; nocold=0
for i in $(seq 1 "$N"); do
  mkdir -p "$T/m$i" "$T/n$i" "$T/h$i" "$T/c$i" "$T/claims$i"
  m=$(one "$MAIN_ROOT" "$T/m$i")
  n=$(one "$NOAD_ROOT" "$T/n$i")
  h=$(one "$HEAD_ROOT" "$T/h$i")
  c=$(one "$HEAD_ROOT" "$T/c$i" "$T/claims$i")
  # Was a runner already live the instant bootstrap returned, or does it come up after?
  at_return=$([ -s "$T/claims$i/proc-guard.claim" ] && echo claim || echo noclaim)
  up=no
  for _ in $(seq 1 100); do
    r=$(cat "$T/c$i/state/procevent/proc-guard.runner" 2>/dev/null)
    if [ -s "$T/claims$i/proc-guard.claim" ] && [ -n "$r" ] && kill -0 "$r" 2>/dev/null; then up=yes; break; fi
    sleep 0.1
  done
  [ "$up" = yes ] || nocold=$((nocold + 1))
  for f in "$T/m$i.out" "$T/n$i.out" "$T/h$i.out" "$T/c$i.out"; do
    if grep -q 'pile-up detector' "$f"; then missing=$((missing + 1)); echo "  MISSING line in $f: $(grep 'pile-up detector' "$f")"; fi
  done
  fm_test_track_procevent_home "$T/h$i" "$FM_PROCEVENT_CLAIM_ROOT"
  fm_test_track_procevent_home "$T/c$i" "$T/claims$i"
  FM_HOME="$T/c$i" FM_STATE_OVERRIDE="$T/c$i/state" FM_PROCEVENT_CLAIM_ROOT="$T/claims$i" "$HEAD_ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  printf 'pair %s main=%s head_noadapter=%s head_held=%s head_cold=%s cold_at_return=%s cold_runner_up=%s\n' "$i" "$m" "$n" "$h" "$c" "$at_return" "$up"
done
echo "missing_lines=$missing cold_runner_not_up=$nocold"
