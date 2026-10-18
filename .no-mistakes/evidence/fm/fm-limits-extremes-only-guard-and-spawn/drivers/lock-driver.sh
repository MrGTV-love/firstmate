#!/usr/bin/env bash
# usage: lock-driver.sh <label> <root> <holder-kind: busy|idle>
label=$1; root=$2; kind=$3; T=$(cat /tmp/fm-nm-live-dir.txt)
C=$T/lock-$label-$kind; rm -rf "$C"; mkdir -p "$C/home"
export FM_HOME="$C/home"
holder() { bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-project-lock-lib.sh"
  fm_project_lock_acquire "$2/p.lock" holder || exit 1
  : > "$2/holder.acquired"
  end=$((SECONDS + $4))
  if [ "$3" = busy ]; then
    # a real CPU-burning child of the holder: bash arithmetic loop
    ( while [ $SECONDS -lt $end ]; do i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done; done ) 
  else
    sleep "$4"
  fi
  fm_project_lock_release "$2/p.lock"
' _ "$root" "$C" "$kind" "$HOLD"; }
HOLD=14
holder & hp=$!
for _ in $(seq 1 200); do [ -e "$C/holder.acquired" ] && break; sleep 0.05; done
start=$(python3 -c 'import time;print(time.time())')
FM_PROJECT_LOCK_SERVICE_SECS=4 FM_PROJECT_LOCK_POLL_SECS=0.2 bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-project-lock-lib.sh"
  fm_project_lock_acquire "$2/p.lock" waiter && { echo "waiter ADMITTED"; fm_project_lock_release "$2/p.lock"; }' _ "$root" "$C" > "$C/waiter.out" 2>&1
rc=$?
end=$(python3 -c 'import time;print(time.time())')
wait $hp 2>/dev/null
printf '%s | holder=%s (holds %ss, allowance 4s) | waiter rc=%s after %.1fs | %s\n' "$label" "$kind" "$HOLD" "$rc" "$(python3 -c "print($end-$start)")" "$(grep -E 'ADMITTED|stall limit' "$C/waiter.out" | tail -1 | cut -c1-260)"
