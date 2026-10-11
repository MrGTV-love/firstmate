#!/usr/bin/env bash
# Live drive of the process pile-up detector (head 0b8cb40d) against real
# self-recursive process trees, through the real adapter and the real
# process-event runner, in a disposable lab home with a private claim root.
# The threshold is moved with --limit so a pile of ~1200 real processes crosses
# 60% of the limit; production hold (5 s) and interval (1 s) are used.
# The pile depth stays far below the real kern.maxprocperuid so the host fleet
# never nears its cap.
# Usage: round4-live-drive.sh <firstmate-worktree> <evidence-dir>
set -u
ROOT=$1; EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
H="$LAB/home"
mkdir -p "$H"
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/claims" "$LAB/shim" "$LAB/cmp-head" "$LAB/cmp-prefix"
export FM_HOME="$H" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ADAPTER="$ROOT/bin/fm-procevent-proc.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
GUARD="$ROOT/bin/fm-proc-guard.sh"
S="$H/state"
# The engine as it was before the census bound (review fix F1), for comparison.
git -C "$ROOT" show 4902df58:bin/fm-proc-guard.py > "$LAB/prefix-proc-guard.py"

# Same-command pile, like the incident: a "basename" shim that runs itself.
cat > "$LAB/shim/basename" <<'SH'
#!/bin/bash
d=${PILE_DEPTH:-0}
if [ "$d" -gt 0 ]; then
  PILE_DEPTH=$((d - 1)) "$0" "$@" &
  wait
else
  exec "$PILE_SLEEP" 300
fi
SH
# Alternating pile (bash > zsh > bash > zsh ...), the census-growth case of F1.
cat > "$LAB/shim/alt-a" <<'SH'
#!/bin/bash
d=${PILE_DEPTH:-0}
if [ "$d" -gt 0 ]; then
  PILE_DEPTH=$((d - 1)) /bin/zsh "${0%/*}/alt-b" &
  wait
else
  exec "$PILE_SLEEP" 300
fi
SH
cat > "$LAB/shim/alt-b" <<'SH'
#!/bin/zsh
d=${PILE_DEPTH:-0}
if [ "$d" -gt 0 ]; then
  PILE_DEPTH=$((d - 1)) /bin/bash "${0%/*}/alt-a" &
  wait
else
  exec "$PILE_SLEEP" 300
fi
SH
chmod +x "$LAB/shim/basename" "$LAB/shim/alt-a" "$LAB/shim/alt-b"
ln -s /bin/sleep "$LAB/shim/pilesleep"
export PILE_SLEEP="$LAB/shim/pilesleep"
DEPTH=1200

t() { python3 -I -c 'import time; print(f"{time.time():.2f}")'; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pile_n() { pgrep -f "$LAB/shim/" | grep -c . ; }
status_at() { "$GUARD" check --json --limit "$LIMIT" | python3 -I -c 'import json,sys; j=json.load(sys.stdin); print(j["status"], j["count"], j["percent_of_limit"])'; }
kill_pile() { for _ in $(seq 1 200); do pkill -f "$LAB/shim/"; [ "$(pgrep -f "$LAB/shim/" | grep -c .)" = 0 ] && break; sleep 0.1; done; true; }
kill_until_below() { for _ in $(seq 1 200); do pkill -f "$LAB/shim/"; case "$(status_at)" in OK*) return 0 ;; esac; done; return 1; }
start_pile() { PILE_DEPTH=$DEPTH "$LAB/shim/basename" >/dev/null 2>&1 & }
start_alt_pile() { PILE_DEPTH=$DEPTH /bin/bash "$LAB/shim/alt-a" >/dev/null 2>&1 & }
wait_above() { for _ in $(seq 1 600); do case "$(status_at)" in WARNING*|CRITICAL*) return 0 ;; esac; sleep 0.1; done; return 1; }
wait_full() { for _ in $(seq 1 600); do [ "$(pile_n)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
census_n() { ls "$S"/proc-census.*.json 2>/dev/null | grep -c . ; }
wait_episode_closed() { for _ in $(seq 1 300); do [ -e "$LAB/claims/proc-guard.episode" ] || return 0; sleep 0.1; done; return 1; }
wait_result() {  # <seq>
  for _ in $(seq 1 600); do [ -e "$S/procevent-inbox/proc-guard.$1.result" ] && break; sleep 0.1; done
  for _ in $(seq 1 300); do awk -F '\t' -v k="procevent:proc-guard:$1" '$4==k{f=1} END{exit !f}' "$S/.wake-queue" 2>/dev/null && break; sleep 0.1; done
}
cleanup() {
  kill_pile
  "$ADAPTER" retire >/dev/null 2>&1
  "$PROCEVENT" sweep-home >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

BASE=$("$GUARD" check --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["count"])')
LIMIT=$(python3 -I -c 'import sys; print(int((int(sys.argv[1]) + int(sys.argv[2]) // 2) / 0.6) + 1)' "$BASE" "$DEPTH")
log "host kern.maxprocperuid=$(sysctl -n kern.maxprocperuid); base user process count=$BASE; drive limit=$LIMIT (60% threshold = base + $((DEPTH / 2))); hold=5s interval=1s (production defaults)"

log "== S1 arm the standing detector in the lab home (register --detach path)"
s=$(t); "$ADAPTER" arm --limit "$LIMIT"; rc=$?; e=$(t)
log "arm exit=$rc returned in $(python3 -I -c "print(round($e-$s,2))") s; runner file at return: $( [ -s "$S/procevent/proc-guard.runner" ] && echo present || echo 'not yet')"
for _ in $(seq 1 300); do [ -s "$S/procevent/proc-guard.runner" ] && break; sleep 0.1; done
RUNNER=$(cat "$S/procevent/proc-guard.runner")
log "runner pid=$RUNNER alive=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no); claim owner home=$(sed -n 1p "$LAB/claims/proc-guard.claim")"
log "registration:"; sed 's/^/  | /' "$S/procevent/proc-guard.source"

log "== S2 removed public path: fm-procevent.sh start --detach is refused and launches nothing"
"$PROCEVENT" start --detach proc-guard > "$LAB/sd.out" 2>&1; rc=$?
log "start --detach proc-guard exit=$rc; first output line: $(head -1 "$LAB/sd.out")"
"$PROCEVENT" start --detach > "$LAB/sd2.out" 2>&1; rc=$?
log "start --detach (no id) exit=$rc; output: $(head -1 "$LAB/sd2.out")"
log "runner after refused calls: pid=$(cat "$S/procevent/proc-guard.runner") (unchanged=$( [ "$(cat "$S/procevent/proc-guard.runner")" = "$RUNNER" ] && echo yes || echo no)) alive=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no) claim_pid=$(sed -n 2p "$LAB/claims/proc-guard.claim")"

log "== S3 adversarial: a pile that stays high for less than the 5 s hold"
start_pile
wait_above || log "pile never crossed threshold"
log "crossed: $(status_at) pile=$(pile_n)"
up=$(t); sleep 2
kill_until_below
log "count back below threshold $(python3 -I -c "import time; print(round(time.time()-$up,2))") s after it crossed; now $(status_at)"
kill_pile
sleep 8
log "after 8 s quiet: inbox result=$( [ -e "$S/procevent-inbox/proc-guard.1.result" ] && echo PRESENT || echo none ) census_files=$(census_n) episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo none )"

log "== S4 a real self-recursive pile held above 60% for more than 5 s"
start_pile
wait_above || log "pile never crossed threshold"
cross=$(t)
log "crossed: $(status_at) pile=$(pile_n)"
wait_result 1
got=$(t)
log "result captured $(python3 -I -c "print(round($got-$cross,2))") s after the threshold was crossed"
log "captured result document:"; sed 's/^/  | /' "$S/procevent-inbox/proc-guard.1.result"
CENSUS=$(sed -n 's/^census: //p' "$S/procevent-inbox/proc-guard.1.result")
log "census file: $CENSUS mode=$(stat -f %Lp "$CENSUS") bytes=$(stat -f %z "$CENSUS")"
cp "$CENSUS" "$EV/round4-live-census-same-command.json"
python3 -I - "$CENSUS" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("  census schema", c["schema"], "platform", c["platform"], "user_process_count", c["user_process_count"], "limit", c.get("limit"))
print("  trigger:", c["trigger"])
print("  census cost ms:", c["census_cost_ms"], "cpu ms:", c.get("census_cpu_ms"))
print("  summary:", c["summary"])
print("  by_command top 3:", [(e["command"], e["count"]) for e in c["by_command"][:3]])
print("  parent_chains:", c["parent_chains"], "by_parent_chain entries:", len(c["by_parent_chain"]))
print("  by_parent_chain top 2:", [(e["chain"][:120], e["count"]) for e in c["by_parent_chain"][:2]])
print("  deepest chains:", len(c["deepest_chains"]), "first depth", c["deepest_chains"][0]["depth"], "chain", c["deepest_chains"][0]["chain"][:160])
print("  oldest:", len(c["oldest"]), "newest:", len(c["newest"]))
PY
log "durable wake queue rows:"; sed 's/^/  | /' "$S/.wake-queue"
log "wake presentation through bin/fm-wake-drain.sh in the lab home:"
"$ROOT/bin/fm-wake-drain.sh" 2>&1 | sed 's/^/  | /' | head -30
log "pile still alive after census: pile=$(pile_n) (never kills)"

log "== S5 the pile stays high 12 s more: no second census or wake"
sleep 12
log "result.2=$( [ -e "$S/procevent-inbox/proc-guard.2.result" ] && echo PRESENT || echo none ) census_files=$(census_n) check_wakes=$(awk -F '\t' '$3=="check"' "$S/.wake-queue" | grep -c .) episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo none ) runner_alive=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no) pile=$(pile_n)"

log "== S6 the pile ends; the episode closes after >5 s quiet; a new pile is reported again"
kill_pile
log "pile killed; now $(status_at)"
wait_episode_closed
log "episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo closed )"
start_pile
wait_above
log "second pile crossed: $(status_at)"
wait_result 2
log "result.2=$( [ -e "$S/procevent-inbox/proc-guard.2.result" ] && echo PRESENT || echo none ) census_files=$(census_n) check_wakes=$(awk -F '\t' '$3=="check"' "$S/.wake-queue" | grep -c .)"
log "durable wake queue rows:"; sed 's/^/  | /' "$S/.wake-queue"
kill_pile
wait_episode_closed
log "episode after kill=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo closed )"

log "== S7 adversarial (F1): an ALTERNATING pile bash > zsh > bash > zsh held above 60%"
start_alt_pile
wait_above || log "alternating pile never crossed threshold"
log "crossed: $(status_at) pile=$(pile_n)"
wait_result 3
log "result.3=$( [ -e "$S/procevent-inbox/proc-guard.3.result" ] && echo PRESENT || echo none )"
sed 's/^/  | /' "$S/procevent-inbox/proc-guard.3.result"
CENSUS3=$(sed -n 's/^census: //p' "$S/procevent-inbox/proc-guard.3.result")
wait_full "$DEPTH"
log "runner census file bytes=$(stat -f %z "$CENSUS3") pile=$(pile_n)"
cp "$CENSUS3" "$EV/round4-live-census-alternating.json"
python3 -I - "$CENSUS3" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("  user_process_count", c["user_process_count"], "census cost ms:", c["census_cost_ms"], "cpu ms:", c.get("census_cpu_ms"))
print("  summary:", c["summary"])
print("  parent_chains (distinct):", c["parent_chains"], "by_parent_chain entries kept:", len(c["by_parent_chain"]))
print("  longest by_parent_chain string:", max(len(e["chain"]) for e in c["by_parent_chain"]))
print("  longest deepest_chains[].chain string:", max(len(e["chain"]) for e in c["deepest_chains"]))
print("  deepest chain[0]:", c["deepest_chains"][0]["chain"])
print("  deepest depth:", c["deepest_chains"][0]["depth"], "run_length:", c["deepest_chains"][0]["run_length"])
print("  top by_parent_chain:", [(e["chain"], e["count"]) for e in c["by_parent_chain"][:3]])
PY
log "same live alternating pile, one-shot census: head engine vs pre-fix engine (4902df58)"
/usr/bin/time -l python3 -I "$ROOT/bin/fm-proc-guard.py" census --limit "$LIMIT" --state-dir "$LAB/cmp-head" > "$LAB/cmp-head.out" 2> "$LAB/cmp-head.time"
/usr/bin/time -l python3 -I "$LAB/prefix-proc-guard.py" census --limit "$LIMIT" --state-dir "$LAB/cmp-prefix" > "$LAB/cmp-prefix.out" 2> "$LAB/cmp-prefix.time"
for v in head prefix; do
  f=$(cat "$LAB/cmp-$v.out")
  python3 -I - "$v" "$f" "$LAB/cmp-$v.time" <<'PY'
import json, os, re, sys
v, path, timing = sys.argv[1:4]
c = json.load(open(path))
rss = re.search(r"(\d+)\s+maximum resident set size", open(timing).read())
print("  %-6s bytes=%d processes=%d by_parent_chain=%d longest_chain_chars=%d cost_ms=%s cpu_ms=%s peak_rss_mb=%.1f" % (
    v, os.path.getsize(path), c["census_processes"], len(c["by_parent_chain"]),
    max(len(e["chain"]) for e in c["by_parent_chain"] + c["deepest_chains"]),
    c["census_cost_ms"], c.get("census_cpu_ms"), int(rss.group(1)) / 1048576 if rss else -1))
PY
done
log "alternating pile still alive after both censuses: pile=$(pile_n) (never kills)"
kill_pile

log "== S8 retire stops the standing runner"
"$ADAPTER" retire; echo "retire exit=$?"
for _ in $(seq 1 150); do kill -0 "$RUNNER" 2>/dev/null || break; sleep 0.2; done
log "runner alive after retire: $(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no); census files kept=$(census_n)"
log "lab removed at exit: $LAB"
