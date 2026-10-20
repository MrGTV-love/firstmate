#!/usr/bin/env bash
# brief-status-command-loop.sh <repo>
# The REAL fm-brief.sh writes a worker brief in a marked lab home; the status command a worker is told
# to run is taken from that brief and run exactly as a worker runs it, in a loop that never stops on its
# own, with cap 4096 and reserve 512 and a hard file-size limit as the safety net.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/projects/demo"
( cd "$R" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-brief.sh brieftask demo --mode no-mistakes ) > "$LAB/brief.out" 2> "$LAB/brief.err"; echo "fm-brief.sh rc=$? out: $(head -c 200 "$LAB/brief.out") err: $(head -c 300 "$LAB/brief.err")"
B="$LAB/data/brieftask/brief.md"; [ -f "$B" ] || { echo "no brief at $B"; ls -R "$LAB/data" | head; exit 1; }
# the worker's status command line
CMDLINE=$(grep -m1 'fm-status-append.sh' "$B" | sed 's/^[^`]*`//; s/`.*$//')
[ -n "$CMDLINE" ] || CMDLINE=$(grep -m1 'fm-status-append.sh' "$B")
echo "status-command line in the generated brief:"; echo "  $CMDLINE" | sed "s#$LAB#<lab>#g" | cut -c1-420
grep -n 'never hand-write\|bare `>>`\|printf. or a loop' "$B" | sed "s#$LAB#<lab>#g" | cut -c1-300 | head -3
S="$LAB/state/brieftask.status"; mkdir -p "$LAB/state"
run_cmd() { # <state-word> <text>
  local cmd=${CMDLINE//\{state\}/$1}; cmd=${cmd//\{one short line\}/$2}; cmd=${cmd//<epoch>/$(date +%s)}
  ( eval "$cmd" )
}
export FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512
(
  ulimit -f 64   # hard safety net: 64 KiB
  i=0; first_refusal=0
  while [ "$i" -lt 3000 ]; do
    i=$((i+1))
    run_cmd working "loop line $i padding padding padding" 2> "$LAB/e.err"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$first_refusal" -eq 0 ]; then first_refusal=$i; echo "first refusal at iteration $i: rc=$rc size=$(stat -f %z "$S")  stderr: $(sed "s#$LAB#<lab>#g" "$LAB/e.err" | cut -c1-230)"; fi
  done
  echo "3000 iterations done: size=$(stat -f %z "$S") (cap 4096, reserve 512)  refused=$((3000-first_refusal+1))"
)
run_cmd done "finished the work" 2> "$LAB/e.err"; echo "terminal done: line in the reserve: rc=$? size=$(stat -f %z "$S") last line: $(tail -1 "$S")"
run_cmd working "one more working line" 2> "$LAB/e.err"; echo "working: line after cap: rc=$? size=$(stat -f %z "$S")"
n=0; while [ $n -lt 200 ]; do n=$((n+1)); run_cmd blocked "flood $n" 2>/dev/null; done; echo "after 200 more blocked: lines: size=$(stat -f %z "$S") (limit 4608)"
run_cmd done "too late" 2> "$LAB/e.err"; echo "terminal line past cap+reserve: rc=$? size=$(stat -f %z "$S") stderr: $(sed "s#$LAB#<lab>#g" "$LAB/e.err" | cut -c1-200)"
echo "distinct first/last lines kept: first=$(head -1 "$S")  line_count=$(wc -l < "$S" | tr -d ' ')"
