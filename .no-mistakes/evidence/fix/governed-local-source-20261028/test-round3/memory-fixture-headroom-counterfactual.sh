#!/usr/bin/env bash
# Old vs corrected memory fixture under same-user process-headroom exhaustion.
# Both arms run the exact test payload through the real public nested wrapper
# (outer 2 GiB, inner 128 MiB), behind a fork-free FIFO gate. In "consume"
# trials, <extra> sleeping processes of this user start OUTSIDE the wrapped
# tree after the outer wrapper set its limit, before release.
#   old = test fixture before 957c2ade (real ps: cap = user count + 1500)
#   new = test fixture at 957c2ade (stub ps reports the inherited soft limit)
# Expected: old+consume fails closed (125/128, payload never starts: the
# production guard is unchanged); new+consume still returns 99 and the payload
# records RLIMIT_NPROC == "<soft> <soft>" (inherited soft kept, hard sealed).
# Usage: <worktree-root> <extra> <trials>
set -u
ROOT=$1 EXTRA=$2 N=$3
WRAP="$ROOT/bin/fm-proc-budget.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-fixture-cf.XXXXXX")
mkdir -p "$T/stub-ps"
printf '%s\n' '#!/bin/sh' 'i=0' 'while [ "$i" -lt "${FM_TEST_PS_COUNT:-0}" ]; do echo "$i"; i=$((i + 1)); done' 'exit "${FM_TEST_PS_STATUS:-0}"' >"$T/stub-ps/ps"
chmod +x "$T/stub-ps/ps"
cat >"$T/memory-tree.py" <<'PY'
import os
import resource
import subprocess
import sys
import time

if len(sys.argv) == 1:
    with open(os.environ["FM_MEMORY_NPROC"], "w") as handle:
        handle.write("%d %d\n" % resource.getrlimit(resource.RLIMIT_NPROC))
    subprocess.Popen([sys.executable, __file__, "child"])
    time.sleep(60)
else:
    if sys.argv[1] == "child":
        subprocess.Popen([sys.executable, __file__, "grandchild"])
    with open(os.environ["FM_MEMORY_PIDS"], "a") as handle:
        handle.write(str(os.getpid()) + "\n")
    allocation = bytearray(80 * 1024 * 1024)
    time.sleep(60)
PY
soft=$(ulimit -S -u) hard=$(ulimit -H -u)
count() { /bin/ps -U "$(id -u)" -o pid= | wc -l | tr -d ' '; }
echo "start=$(date -u +%FT%TZ) head=$(git -C "$ROOT" rev-parse HEAD) python3=$(python3 -c 'import sys;print(sys.version.split()[0], sys.executable)')"
echo "inherited_soft=$soft inherited_hard=$hard maxprocperuid=$(sysctl -n kern.maxprocperuid) user_procs=$(count) extra_sleepers=$EXTRA"
arm() { # <fixture:old|new> <consume:0|1> <i>
  local fx=$1 consume=$2 i=$3 pid rc sleepers=() go tag=$1.$2.$3 before during
  go="$T/go.$tag"; mkfifo "$go"; : >"$T/pids.$tag"; : >"$T/nproc.$tag"
  if [ "$fx" = new ]; then
    PATH="$T/stub-ps:$PATH" FM_TEST_PS_COUNT=$soft FM_MEMORY_PIDS="$T/pids.$tag" FM_MEMORY_NPROC="$T/nproc.$tag" \
      "$WRAP" --memory-kib 2097152 -- bash -c 'read -r _ <"$1"; exec "$2" --memory-kib 131072 -- python3 "$3"' \
      gate "$go" "$WRAP" "$T/memory-tree.py" 2>"$T/err.$tag" &
  else
    FM_MEMORY_PIDS="$T/pids.$tag" FM_MEMORY_NPROC="$T/nproc.$tag" \
      "$WRAP" --memory-kib 2097152 -- bash -c 'read -r _ <"$1"; exec "$2" --memory-kib 131072 -- python3 "$3"' \
      gate "$go" "$WRAP" "$T/memory-tree.py" 2>"$T/err.$tag" &
  fi
  pid=$!
  sleep 1
  before=$(count)
  if [ "$consume" = 1 ]; then
    for _ in $(seq 1 "$EXTRA"); do sleep 120 & sleepers+=($!); done
  fi
  during=$(count)
  echo go >"$go"
  wait "$pid"; rc=$?
  [ "${#sleepers[@]}" -eq 0 ] || { kill "${sleepers[@]}" 2>/dev/null; wait "${sleepers[@]}" 2>/dev/null; }
  printf 'fixture=%s consume=%s trial=%s exit=%s user_procs_before=%s at_release=%s payload_nproc=%s pids=%s stderr=%s\n' \
    "$fx" "$consume" "$i" "$rc" "$before" "$during" "'$(tr -d '\n' <"$T/nproc.$tag")'" \
    "$(tr '\n' ',' <"$T/pids.$tag")" "$(tr '\n' '|' <"$T/err.$tag")"
}
for i in $(seq 1 "$N"); do
  arm old 0 "$i"; arm old 1 "$i"
  arm new 0 "$i"; arm new 1 "$i"
done
echo "user_procs_end=$(count) end=$(date -u +%FT%TZ)"
rm -rf "$T"
