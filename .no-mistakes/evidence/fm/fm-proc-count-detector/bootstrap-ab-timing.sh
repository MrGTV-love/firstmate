#!/usr/bin/env bash
# Interleaved A/B wall time of one real bin/fm-bootstrap.sh in a fresh test home:
# main copy vs this head, same environment (tests/lib.sh of the head: held claim,
# so the head's arm sees a live owner and starts no runner, as in a test suite),
# plus a cold-claim head variant (empty claim root, the real first-session path).
# Usage: bootstrap-ab-timing.sh <head-worktree> <main-copy> <pairs>
set -u
HEAD_ROOT=$1; MAIN_ROOT=$2; N=$3
# shellcheck disable=SC1091
. "$HEAD_ROOT/tests/lib.sh"
T=$(fm_test_tmproot boot-ab)
fakebin="$T/fakebin"; mkdir -p "$fakebin"
for t in tmux node chrome-devtools-axi; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done
one() {  # <root> <home> [claim-root]
  local s e
  s=$(python3 -I -c 'import time; print(time.time())')
  PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$2" FM_ROOT_OVERRIDE="$2" \
    FM_PROCEVENT_CLAIM_ROOT="${3:-$FM_PROCEVENT_CLAIM_ROOT}" "$1/bin/fm-bootstrap.sh" >/dev/null 2>&1
  e=$(python3 -I -c 'import time; print(time.time())')
  python3 -I -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 3))' "$s" "$e"
}
for i in $(seq 1 "$N"); do
  mkdir -p "$T/m$i" "$T/h$i" "$T/c$i" "$T/claims$i"
  m=$(one "$MAIN_ROOT" "$T/m$i")
  h=$(one "$HEAD_ROOT" "$T/h$i")
  c=$(one "$HEAD_ROOT" "$T/c$i" "$T/claims$i")
  fm_test_track_procevent_home "$T/h$i" "$FM_PROCEVENT_CLAIM_ROOT"
  fm_test_track_procevent_home "$T/c$i" "$T/claims$i"
  FM_HOME="$T/c$i" FM_STATE_OVERRIDE="$T/c$i/state" FM_PROCEVENT_CLAIM_ROOT="$T/claims$i" "$HEAD_ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  printf 'pair %s main=%s head_held_claim=%s head_cold_claim=%s\n' "$i" "$m" "$h" "$c"
done
