#!/usr/bin/env bash
# Round-2c: does a bounded recover --one tick on a managed agent clear a stale notice? Base vs head.
set -u
L=$1; D=$(cd "$(dirname "$0")" && pwd)
. "$L/env.sh"; . "$D/lib.sh"
mkdir -p "$LAB/base"; git -C "$ROOT" archive d25e907c147d9e9460d1430d9632f682011eee2c | tar -x -C "$LAB/base"
echo "head=$(git -C "$ROOT" rev-parse HEAD) base=d25e907c1"
for side in BASE HEAD; do
  case $side in BASE) R="$LAB/base" ;; HEAD) R="$ROOT" ;; esac
  rm -f "$FM_HOME/state/.reboot-recovery-cursor" "$FM_HOME/state/$ID.reboot-notice"
  new_row "u-$side" unpinned; settle alive
  out=$("$R/bin/fm-reboot-recover.sh" recover --one 2>/dev/null)
  echo "$side unpinned --one: lines=$(printf '%s' "$out" | grep -c REBOOT_RECOVERY) notice=$([ -e "$FM_HOME/state/$ID.reboot-notice" ] && echo present || echo absent)"
  new_row "m-$side" pinned; settle alive; probe | grep verdict
  for t in 1 2; do
    out=$("$R/bin/fm-reboot-recover.sh" recover --one 2>/dev/null)
    echo "$side managed --one tick$t: lines=$(printf '%s' "$out" | grep -c REBOOT_RECOVERY) notice=$([ -e "$FM_HOME/state/$ID.reboot-notice" ] && echo present || echo absent) cursor=$(tr '\n' ' ' < "$FM_HOME/state/.reboot-recovery-cursor" 2>/dev/null)"
  done
  out=$("$R/bin/fm-reboot-recover.sh" recover 2>/dev/null)
  echo "$side managed full: lines=$(printf '%s' "$out" | grep -c REBOOT_RECOVERY) notice=$([ -e "$FM_HOME/state/$ID.reboot-notice" ] && echo present || echo absent)"
done
