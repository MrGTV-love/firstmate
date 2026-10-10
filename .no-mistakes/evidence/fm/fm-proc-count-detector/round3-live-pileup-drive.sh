#!/usr/bin/env bash
# Live drive of the process pile-up detector against a real self-recursive
# process tree, through the real adapter and the real process-event runner.
# Usage: live-pileup-drive.sh <firstmate-worktree>
# Isolation: a disposable lab home under $TMPDIR and a private claim root.
# The threshold is moved with --limit so a pile of ~1200 real processes crosses
# 60% of the limit; production hold (5 s) and interval (1 s) are used.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
H="$LAB/home"
mkdir -p "$H"
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/claims" "$LAB/shim"
export FM_HOME="$H" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ADAPTER="$ROOT/bin/fm-procevent-proc.sh"
GUARD="$ROOT/bin/fm-proc-guard.sh"
S="$H/state"

# A self-recursive "basename" shim, like the incident's: each level runs the
# next level of itself and waits; the last level sleeps.
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
chmod +x "$LAB/shim/basename"
ln -s /bin/sleep "$LAB/shim/pilesleep"
export PILE_SLEEP="$LAB/shim/pilesleep"
DEPTH=1200

t() { python3 -I -c 'import time; print(f"{time.time():.2f}")'; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pile_n() { pgrep -f "$LAB/shim/basename" | grep -c . ; }
status_at() { "$GUARD" check --json --limit "$LIMIT" | python3 -I -c 'import json,sys; j=json.load(sys.stdin); print(j["status"], j["count"], j["percent_of_limit"])'; }
kill_pile() { for _ in $(seq 1 200); do pkill -f "$LAB/shim/"; [ "$(pgrep -f "$LAB/shim/" | grep -c .)" = 0 ] && break; sleep 0.1; done; true; }
kill_until_below() { for _ in $(seq 1 200); do pkill -f "$LAB/shim/"; case "$(status_at)" in OK*) return 0 ;; esac; done; return 1; }
start_pile() { PILE_DEPTH=$DEPTH "$LAB/shim/basename" >/dev/null 2>&1 & }
wait_above() { for _ in $(seq 1 600); do case "$(status_at)" in WARNING*|CRITICAL*) return 0 ;; esac; sleep 0.1; done; return 1; }
census_n() { ls "$S"/proc-census.*.json 2>/dev/null | grep -c . ; }
cleanup() {
  kill_pile
  "$ADAPTER" retire >/dev/null 2>&1
  "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

BASE=$("$GUARD" check --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["count"])')
LIMIT=$(python3 -I -c 'import sys; print(int((int(sys.argv[1]) + int(sys.argv[2]) // 2) / 0.6) + 1)' "$BASE" "$DEPTH")
log "base user process count=$BASE; drive limit=$LIMIT (60% threshold = base + $((DEPTH / 2))); hold=5s interval=1s (production defaults)"

log "== S1 arm the standing detector in the lab home"
"$ADAPTER" arm --limit "$LIMIT"; echo "arm exit=$?"
for _ in $(seq 1 300); do [ -s "$S/procevent/proc-guard.runner" ] && break; sleep 0.1; done
RUNNER=$(cat "$S/procevent/proc-guard.runner")
log "runner pid=$RUNNER alive=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no); claim owner home=$(sed -n 1p "$LAB/claims/proc-guard.claim")"
log "registration:"; sed 's/^/  | /' "$S/procevent/proc-guard.source"

log "== S2 adversarial: a pile that stays high for less than the 5 s hold"
start_pile
wait_above || log "pile never crossed threshold"
log "crossed: $(status_at) pile=$(pile_n)"
up=$(t); sleep 2
kill_until_below
log "count back below threshold $(python3 -I -c "import time; print(round(time.time()-$up,2))") s after it crossed; now $(status_at)"
kill_pile
sleep 8
log "after 8 s quiet: inbox result=$( [ -e "$S/procevent-inbox/proc-guard.1.result" ] && echo PRESENT || echo none ) census_files=$(census_n) episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo none )"

log "== S3 a real self-recursive pile held above 60% for more than 5 s"
start_pile
wait_above || log "pile never crossed threshold"
cross=$(t)
log "crossed: $(status_at) pile=$(pile_n)"
for _ in $(seq 1 600); do [ -e "$S/procevent-inbox/proc-guard.1.result" ] && break; sleep 0.1; done
got=$(t)
for _ in $(seq 1 300); do awk -F '\t' '$4=="procevent:proc-guard:1"{f=1} END{exit !f}' "$S/.wake-queue" 2>/dev/null && break; sleep 0.1; done
log "result captured $(python3 -I -c "print(round($got-$cross,2))") s after the threshold was crossed"
log "captured result document:"; sed 's/^/  | /' "$S/procevent-inbox/proc-guard.1.result"
CENSUS=$(sed -n 's/^census: //p' "$S/procevent-inbox/proc-guard.1.result")
log "census file: $CENSUS mode=$(stat -f %Lp "$CENSUS")"
cp "$CENSUS" "$(dirname "$0")/round3-live-census.json"
python3 -I - "$CENSUS" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("  census schema", c["schema"], "platform", c["platform"], "user_process_count", c["user_process_count"], "limit", c.get("limit"))
print("  trigger:", c["trigger"])
print("  census cost ms:", c["census_cost_ms"], "cpu ms:", c.get("census_cpu_ms"))
print("  summary:", c["summary"])
print("  by_command top 3:", [(e["command"], e["count"]) for e in c["by_command"][:3]])
print("  by_parent_chain top 2:", [(e["chain"][:120], e["count"]) for e in c["by_parent_chain"][:2]])
print("  deepest chains:", len(c["deepest_chains"]), "first depth", c["deepest_chains"][0]["depth"], "chain", c["deepest_chains"][0]["chain"][:160])
print("  oldest:", len(c["oldest"]), "newest:", len(c["newest"]))
PY
log "durable wake queue rows:"; sed 's/^/  | /' "$S/.wake-queue"
log "pile still alive after census: pile=$(pile_n) (never kills)"

log "== S4 the pile stays high 12 s more: no second census or wake"
sleep 12
log "result.2=$( [ -e "$S/procevent-inbox/proc-guard.2.result" ] && echo PRESENT || echo none ) census_files=$(census_n) check_wakes=$(awk -F '\t' '$3=="check"' "$S/.wake-queue" | grep -c .) episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo none ) runner_alive=$(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no) pile=$(pile_n)"

log "== S5 the pile ends; the episode closes after >5 s quiet; a new pile is reported again"
kill_pile
log "pile killed; now $(status_at)"
for _ in $(seq 1 200); do [ -e "$LAB/claims/proc-guard.episode" ] || break; sleep 0.1; done
log "episode=$( [ -e "$LAB/claims/proc-guard.episode" ] && echo open || echo closed )"
start_pile
wait_above
log "second pile crossed: $(status_at)"
for _ in $(seq 1 600); do [ -e "$S/procevent-inbox/proc-guard.2.result" ] && break; sleep 0.1; done
for _ in $(seq 1 300); do awk -F '\t' '$4=="procevent:proc-guard:2"{f=1} END{exit !f}' "$S/.wake-queue" 2>/dev/null && break; sleep 0.1; done
log "result.2=$( [ -e "$S/procevent-inbox/proc-guard.2.result" ] && echo PRESENT || echo none ) census_files=$(census_n) check_wakes=$(awk -F '\t' '$3=="check"' "$S/.wake-queue" | grep -c .)"
log "durable wake queue rows:"; sed 's/^/  | /' "$S/.wake-queue"
kill_pile

log "== S6 retire stops the standing runner"
"$ADAPTER" retire; echo "retire exit=$?"
for _ in $(seq 1 150); do kill -0 "$RUNNER" 2>/dev/null || break; sleep 0.2; done
log "runner alive after retire: $(kill -0 "$RUNNER" 2>/dev/null && echo yes || echo no)"
log "lab removed at exit: $LAB"
