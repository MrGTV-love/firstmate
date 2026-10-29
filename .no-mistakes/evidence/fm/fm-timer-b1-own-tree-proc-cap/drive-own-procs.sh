#!/usr/bin/env bash
# Live driver for fm-proc-budget.sh --own-procs. Usage: drive-own-procs.sh <worktree>
set -u
W=$1; WRAP="$W/bin/fm-proc-budget.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-own-live.XXXXXX"); trap 'rm -rf "$T"' EXIT
TAG="fmownlive$$"
say() { printf '\n=== %s\n' "$*"; }
count_user() { ps -U "$(id -u)" -o pid= | wc -l | tr -d ' '; }

say "S1 normal command: status and args pass through"
"$WRAP" --own-procs 64 -- sh -c 'echo "args: $*"; exit 7' _ "a b" c; echo "rc=$?"

say "S2 invalid calls refuse (exit 2)"
for v in 0 -1 nope 1234567890; do "$WRAP" --own-procs "$v" -- echo RAN; echo "--own-procs $v rc=$?"; done
"$WRAP" --own-procs 50 --memory-kib 262144 -- echo RAN; echo "combined rc=$?"

say "S3 kernel safety net stays at count+1500 inside --own-procs"
before=$(count_user); inside=$("$WRAP" --own-procs 64 -- sh -c 'ulimit -u'); echo "user count before=$before kernel limit inside=$inside (expect about before+1500)"

say "S4 runaway tree is stopped at its own limit (exit 98), nothing left"
cat >"$T/bomb.sh" <<SH
#!/bin/sh
# $TAG: each level forks two more and waits
"\$0" & "\$0" & exec sleep 600
SH
chmod +x "$T/bomb.sh"
"$WRAP" --own-procs 40 -- "$T/bomb.sh"; echo "rc=$?"
sleep 1; echo "leftover members: $(pgrep -f "$T/bomb.sh" | wc -l | tr -d ' ')"

say "S5 neighbours spend the shared count while the tree works 5x slower"
mkdir -p "$T/shim"; printf '#!/bin/sh\nexec /bin/sleep "$(awk -v n="$1" '"'"'BEGIN{print n*5}'"'"')"\n' >"$T/shim/sleep"; chmod +x "$T/shim/sleep"
PY=$(python3 -c 'import sys;print(sys.executable)')
cat >"$T/work.py" <<'PY'
import os, subprocess, sys, time
go = sys.argv[1]
open(go + ".ready", "w").close()
while not os.path.exists(go): time.sleep(0.05)
for i in range(5):
    subprocess.run(["/usr/bin/true"], check=True)
    subprocess.run(["sleep", "0.1"], check=True)  # shim: 0.5 s
print("work done")
PY
run_case() {  # <label> <wrapper args...>
  local label=$1; shift; rm -f "$T/go" "$T/go.ready"
  local t0=$(date +%s)
  PATH="$T/shim:$PATH" "$WRAP" "$@" -- "$PY" "$T/work.py" "$T/go" >"$T/out" 2>"$T/err" & local w=$!
  while [ ! -e "$T/go.ready" ]; do kill -0 $w 2>/dev/null || break; sleep 0.05; done
  "$PY" -c '
import subprocess,sys,os
k=[subprocess.Popen(["/bin/sleep","86400"]) for _ in range(300)]
open(sys.argv[1],"w").close()
sys.stdin.read()
[p.kill() for p in k]; [p.wait() for p in k]' "$T/go" <"$T/hold" & local n=$!
  exec 9>"$T/hold"
  wait $w; local rc=$?
  exec 9>&-; wait $n
  echo "$label: rc=$rc secs=$(( $(date +%s)-t0 )) out=[$(cat "$T/out")] err_tail=[$(tail -1 "$T/err")]"
}
mkfifo "$T/hold"
run_case "old form, positional extra 64" 64
run_case "new form, --own-procs 128" --own-procs 128

say "S6 leftover background job is ended when the command exits"
"$WRAP" --own-procs 64 -- sh -c "sleep 600 & echo \$! >'$T/left.pid'; echo done"; echo "rc=$?"
lp=$(cat "$T/left.pid"); sleep 0.3; if kill -0 "$lp" 2>/dev/null; then echo "leftover $lp ALIVE"; else echo "leftover $lp ended"; fi

say "S7 SIGKILL of the supervisor: dead-man reader ends the tree"
"$WRAP" --own-procs 64 -- sh -c "echo \$\$ >'$T/dm.pid'; sleep 600 & echo \$! >>'$T/dm.pid'; wait" & w=$!
while [ "$(wc -l <"$T/dm.pid" 2>/dev/null || echo 0)" -lt 2 ]; do sleep 0.05; done
sup=$(pgrep -f "fm-proc-budget-tree.py 64" | head -1); echo "supervisor pid=$sup tree pids=$(tr '\n' ' ' <"$T/dm.pid")"
kill -KILL "$sup"; wait $w 2>/dev/null; sleep 2
for p in $(cat "$T/dm.pid"); do if kill -0 "$p" 2>/dev/null; then echo "$p ALIVE"; else echo "$p ended"; fi; done

say "S8 TERM to the wrapper ends the tree and returns 128+15"
"$WRAP" --own-procs 64 -- sh -c "sleep 600 & echo \$! >'$T/term.pid'; wait" & w=$!
while [ ! -s "$T/term.pid" ]; do sleep 0.05; done
kill -TERM $w; wait $w; echo "rc=$?"; sleep 0.3; tp=$(cat "$T/term.pid"); kill -0 "$tp" 2>/dev/null && echo "$tp ALIVE" || echo "$tp ended"
