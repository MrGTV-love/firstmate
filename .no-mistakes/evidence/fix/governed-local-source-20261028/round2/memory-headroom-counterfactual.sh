#!/usr/bin/env bash
# One-condition counterfactual for the historical macOS memory-case 125.
# The test runs the payload under the public wrapper's default own-process
# budget: the OUTER wrapper lowers RLIMIT_NPROC to (this user's process count
# at its start + 1500). That count is per user, so any other process of the
# same user (a concurrent test run, other agents) spends the wrapped tree's
# headroom after the outer wrapper starts.
# Both arms run the identical test payload behind the same fork-free gate (a
# bash builtin read on a FIFO, then exec of the inner 128 MiB wrapper). The only
# difference: in the "consume" arm, <extra> sleeping processes of this user
# start OUTSIDE the wrapped tree after the outer limit is set, before release.
# They are killed right after. Usage: <worktree-root> <extra> <trials>
set -u
ROOT=$1 EXTRA=$2 N=$3
WRAP="$ROOT/bin/fm-proc-budget.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-headroom.XXXXXX")
cat >"$T/memory-tree.py" <<'PY'
import os
import subprocess
import sys
import time

if len(sys.argv) == 1:
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
count() { ps -U "$(id -u)" -o pid= | wc -l | tr -d ' '; }
echo "start=$(date -u +%FT%TZ) python3=$(python3 -c 'import sys;print(sys.version.split()[0], sys.executable)') maxprocperuid=$(sysctl -n kern.maxprocperuid) user_procs=$(count)"
arm() { # <label> <consume:0|1> <i>
  local label=$1 consume=$2 i=$3 pid rc sleepers=() go
  go="$T/go.$label.$i"
  mkfifo "$go"
  : > "$T/pids.$label.$i"
  FM_MEMORY_PIDS="$T/pids.$label.$i" "$WRAP" --memory-kib 2097152 -- bash -c \
    'read -r _ <"$1"; exec "$2" --memory-kib 131072 -- python3 "$3"' \
    gate "$go" "$WRAP" "$T/memory-tree.py" 2>"$T/err.$label.$i" &
  pid=$!
  sleep 1
  local before; before=$(count)
  if [ "$consume" = 1 ]; then
    for _ in $(seq 1 "$EXTRA"); do sleep 120 & sleepers+=($!); done
  fi
  local during; during=$(count)
  echo go >"$go"
  wait "$pid"; rc=$?
  [ "${#sleepers[@]}" -eq 0 ] || { kill "${sleepers[@]}" 2>/dev/null; wait "${sleepers[@]}" 2>/dev/null; }
  printf 'arm=%s trial=%s exit=%s user_procs_at_outer_start~%s user_procs_at_release=%s pids=%s stderr=%s\n' \
    "$label" "$i" "$rc" "$before" "$during" "$(tr '\n' ',' <"$T/pids.$label.$i")" "$(tr '\n' '|' <"$T/err.$label.$i")"
}
for i in $(seq 1 "$N"); do
  arm control 0 "$i"
  arm consume 1 "$i"
done
echo "user_procs_end=$(count) end=$(date -u +%FT%TZ)"
rm -rf "$T"
