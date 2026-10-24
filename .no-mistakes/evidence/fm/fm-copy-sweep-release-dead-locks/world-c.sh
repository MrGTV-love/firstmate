#!/usr/bin/env bash
# World C: a preservable ignored hook dir holding a log, a FIFO and a stale Unix socket, real driver.
# The sweep must compare them as cp -RPp copies them: no "could not be compared" loop, no preserve growth.
set -u
WT=$1 LAB=$2; . "$(dirname "$0")/lab-lib.sh"
new_world c
DEAD=$(dead_pid)
add_copy s merged "$DEAD"
git -C "$SLOT" fetch -q origin
H=$(cp_of s)/scripts/hooks; mkdir -p "$H"
printf 'log line\n' > "$H/run.log"; mkfifo "$H/pipe.log"
(cd "$H" && python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("stale.log")')
ls -l "$H" | sed "s|$LAB|\$LAB|g"
pres() { find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name run.log -type f 2>/dev/null | wc -l | tr -d ' '; }
for r in 1 2 3; do echo; echo "===== RUN $r: --apply"; sweep --apply; echo "exit=$?"
  echo "preserves holding run.log: $(pres)   copy s registered: $(git -C "$SLOT" worktree list | grep -c '/s ')   waiting: $(ls "$HOMED/data/copy-sweep/waiting" 2>/dev/null | wc -l | tr -d ' ')   receipts: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"
  [ -d "$(cp_of s)" ] || break
done
echo; echo "===== preserve contents:"; find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -exec ls -ld {} + 2>/dev/null | sed "s|$LAB|\$LAB|g"
echo; echo "===== copy-sweep.log:"; sed "s|$LAB|\$LAB|g" "$HOMED/data/copy-sweep.log" 2>/dev/null
