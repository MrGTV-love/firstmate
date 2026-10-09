#!/usr/bin/env bash
# Behavioral tests for bin/fm-proc-guard.sh: the per-user process count, the
# pile-up threshold and hold, the one-shot census, and the one-census-per-episode
# gate. Controlled Python cases cover platform reads and exact boundaries. The
# shell cases drive the public CLI against real processes, moving thresholds
# with --limit; the dip case uses a large real burst with wide margins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-proc-guard.sh"
LAB=$(fm_test_tmproot fm-proc-guard)
STATE="$LAB/state"
mkdir -p "$STATE"

# Everything this suite starts runs through a symlink under $LAB, so one pattern
# names exactly this suite's processes and nothing else.
ln -s "$(command -v bash)" "$LAB/nestbash"
ln -s "$(command -v sleep)" "$LAB/nestsleep"
ln -s "$(command -v sleep)" "$LAB/burstsleep"
cat > "$LAB/nest.sh" <<'SH'
#!/bin/sh
# A self-recursive tree: every level waits for the next, the last level sleeps.
depth=$1
if [ "$depth" -gt 0 ]; then
  "$BASH" "$0" $((depth - 1)) &
  wait
else
  exec "$NESTSLEEP" 120
fi
SH
cat > "$LAB/burst.sh" <<'SH'
#!/bin/sh
# Starts $1 sleepers and exits; they outlive it until the suite kills them.
i=0
while [ "$i" -lt "$1" ]; do
  "$BURSTSLEEP" 60 &
  i=$((i + 1))
done
SH

stop_lab_processes() { pkill -f "$LAB/(nestbash|nestsleep|burstsleep)" >/dev/null 2>&1; return 0; }
cleanup() { stop_lab_processes; fm_test_cleanup; }
trap cleanup EXIT INT TERM

jq_py() {  # <json-file> <python expression over j>
  python3 -I - "$1" "$2" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PY
}
census_files() { ls "$1"/proc-census.*.json 2>/dev/null; }
census_count() { census_files "$1" | grep -c . || true; }
now() { python3 -I -c 'import time; print(time.time())'; }
since() { python3 -I -c 'import sys, time; print(round(time.time() - float(sys.argv[1]), 2))' "$1"; }
num_ge() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }

python3 -I "$ROOT/tests/fm-proc-guard.behavior.test.py" || fail "controlled guard behavior tests failed"
pass "guard real-UID, limit, privacy, and fixed-boundary behavior"

# --- check ------------------------------------------------------------------

out=$("$GUARD" check --json) || fail "check exited nonzero"
status=$(printf '%s\n' "$out" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])')
case "$status" in
  OK|WARNING|CRITICAL|UNKNOWN) ;;
  *) fail "check returned an invalid status ($status): $out" ;;
esac
printf '%s\n' "$out" | python3 -I -c '
import json, sys
j = json.load(sys.stdin)
assert j["count"] > 0, j
if j["limit"] is None:
    assert j["status"] == "UNKNOWN" and "unlimited" in j["reason"], j
else:
    assert j["limit"] > j["count"] // 100, j
assert j["name"] == "fm-proc-guard" and "recommendation" in j, j
' || fail "check --json did not report a positive count and a limit or UNKNOWN: $out"
pass "check reads the user's process count and reports its limit or UNKNOWN"

[ "$("$GUARD" check --json --limit 1000000000 | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])')" = OK ] \
  || fail "a huge limit was not OK"
"$GUARD" check --check --limit 1000000000 >/dev/null || fail "--check failed on an OK verdict"
[ "$("$GUARD" check --json --limit 1 | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])')" = CRITICAL ] \
  || fail "a limit below the count was not CRITICAL"
if "$GUARD" check --check --limit 1 >/dev/null; then fail "--check exited zero on a CRITICAL verdict"; fi
[ "$("$GUARD" check --json --limit 1 --crit-pct 100 | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])')" = CRITICAL ] \
  || fail "a count above 100% of the limit was not CRITICAL"
pass "check classifies the count against the limit and --check exits on WARNING or CRITICAL"

for command in check census watch; do
  for bad in "--warn-pct 60" "--clear-pct 50"; do
    # shellcheck disable=SC2086
    if "$GUARD" "$command" $bad >/dev/null 2>&1; then fail "$command accepted $bad"; fi
  done
done
for bad in "--crit-pct 0" "--crit-pct 101" "--limit x"; do
  # shellcheck disable=SC2086
  if "$GUARD" check $bad >/dev/null 2>&1; then fail "check accepted $bad"; fi
done
for bad in "--hold 0" "--interval 0"; do
  # shellcheck disable=SC2086
  if "$GUARD" watch --state-dir "$STATE" $bad >/dev/null 2>&1; then fail "watch accepted $bad"; fi
done
pass "warning and clear customization are refused, as are invalid remaining options"

# --- census of a real self-recursive tree -----------------------------------

export NESTSLEEP="$LAB/nestsleep" BURSTSLEEP="$LAB/burstsleep"
"$LAB/nestbash" "$LAB/nest.sh" 60 --user alice:secret >/dev/null 2>&1 &
ROOT_PID=$!
fm_test_wait_until 20 pgrep -f "$LAB/nestsleep 120" || fail "the recursive tree never reached its leaf"

path=$("$GUARD" census --state-dir "$STATE/census" --limit 1000000) || fail "census exited nonzero"
[ -f "$path" ] || fail "census did not print an existing file: $path"
mode=$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$path")
[ "$mode" = 0o600 ] || fail "census file mode is $mode, not 0600"
python3 -I - "$path" <<'PY' || fail "census did not describe the recursive tree"
import json, re, sys
c = json.load(open(sys.argv[1]))
cmds = {e["command"]: e["count"] for e in c["by_command"]}
# The kernel names a process after the binary it runs on macOS and after the path it
# was started through on Linux, so the shell and sleeper may carry either name.
shells = sum(n for name, n in cmds.items() if "bash" in name)
assert shells >= 60, "bash-named processes: %d" % shells
assert any("sleep" in name for name in cmds), "no sleep in by_command"
assert any(re.search(r"bash\+", e["chain"]) and e["count"] >= 59 for e in c["by_parent_chain"]), \
    c["by_parent_chain"][:5]
deepest = c["deepest_chains"]
assert 1 <= len(deepest) <= 5, len(deepest)
top = deepest[0]
assert "sleep" in top["leaf"]["executable"] and top["leaf"]["script"] == "", top["leaf"]
runs = [int(n) for n in re.findall(r"bash\(x(\d+)\)", top["chain"])]
assert runs and max(runs) >= 60, top["chain"]
assert top["run_length"] >= 60 and top["depth"] >= 61, top
assert any(sample["script"] == "nest.sh" for sample in top["run_samples"]), top["run_samples"]
assert c["schema"] == 2, c
assert all("argv" not in entry for entry in c["oldest"] + c["newest"])
assert [d["depth"] for d in deepest] == sorted((d["depth"] for d in deepest), reverse=True)
assert 1 <= len(c["oldest"]) <= 5 and 1 <= len(c["newest"]) <= 5
assert c["oldest"][0]["age_seconds"] >= c["newest"][0]["age_seconds"]
assert c["oldest"][0]["started"] <= c["newest"][0]["started"]
assert c["census_processes"] >= 61 and c["user_process_count"] >= 61
assert c["census_cost_ms"] >= 0 and "summary" in c and c["platform"] in ("darwin", "linux")
PY
pass "census names the tree: command counts, parent chains, deepest chains with run samples and leaf, oldest and newest"

kill -0 "$ROOT_PID" 2>/dev/null || fail "census disturbed the tree it measured"
pgrep -f "$LAB/nestsleep 120" >/dev/null || fail "census killed a measured process"
stop_lab_processes
pass "census only reads: every measured process is still alive"

for _ in 1 2 3 4; do "$GUARD" census --state-dir "$STATE/prune" --limit 1000000 --keep 2 >/dev/null; sleep 1; done
[ "$(census_count "$STATE/prune")" = 2 ] || fail "census kept $(census_count "$STATE/prune") files, not 2"
pass "census keeps only the newest files"

# --- watch: threshold, hold, one census per episode --------------------------

W="$STATE/watch"
start=$(now)
out=$("$GUARD" watch --state-dir "$W" --limit 1 --hold 2 --interval 0.2 --source-id t-pile) \
  || fail "watch exited nonzero"
elapsed=$(since "$start")
printf '%s\n' "$out" | grep -qx 'proc-guard: t-pile' || fail "result did not echo the source id: $out"
printf '%s\n' "$out" | grep -qx 'status: pileup' || fail "a count above the threshold did not report a pile-up: $out"
census=$(printf '%s\n' "$out" | sed -n 's/^census: //p')
[ -f "$census" ] || fail "result named a missing census: $census"
held=$(printf '%s\n' "$out" | sed -n 's/^held_seconds: //p')
num_ge "$held" 2 || fail "pile-up reported after only $held s held, hold was 2"
num_ge "$elapsed" 2 || fail "watch returned after $elapsed s, before the 2 s hold passed"
for field in count limit threshold summary sampler_samples sampler_cpu_ms_per_sample sampler_peak_rss_kb; do
  printf '%s\n' "$out" | grep -q "^$field: ." || fail "result omitted $field: $out"
done
[ "$(jq_py "$census" 'j["trigger"]["reason"]')" = "count above threshold" ] || fail "census omitted its trigger"
[ -f "$W/proc-guard.episode" ] || fail "no episode record was left for the next watch"
[ "$(census_count "$W")" = 1 ] || fail "expected exactly one census"
pass "a count above the threshold for more than the hold writes one census and reports it"

out=$("$GUARD" watch --state-dir "$W" --limit 1 --hold 1 --interval 0.2 --duration 3 --source-id t-pile) \
  || fail "watch with an open episode exited nonzero"
printf '%s\n' "$out" | grep -qx 'status: idle' || fail "an open episode produced a second report: $out"
printf '%s\n' "$out" | grep -qx 'armed: no' || fail "an open episode re-armed while the count was still high: $out"
[ "$(census_count "$W")" = 1 ] || fail "an open episode wrote a second census"
pass "while the count stays high an open episode keeps watch silent: one census per episode"

out=$("$GUARD" watch --state-dir "$W" --limit 1000000000 --hold 1 --interval 0.2 --duration 4 --source-id t-pile) \
  || fail "watch after the pile-up exited nonzero"
printf '%s\n' "$out" | grep -qx 'armed: yes' || fail "the episode did not close after the count fell: $out"
[ ! -e "$W/proc-guard.episode" ] || fail "the closed episode record was left behind"
[ "$(census_count "$W")" = 1 ] || fail "closing an episode wrote a census"
pass "an episode closes once the count stays at or below the clear threshold"

out=$("$GUARD" watch --state-dir "$W" --limit 1 --hold 1 --interval 0.2 --source-id t-pile) || fail "second pile-up watch exited nonzero"
printf '%s\n' "$out" | grep -qx 'status: pileup' || fail "a new pile-up after the episode closed was not reported: $out"
[ "$(census_count "$W")" = 2 ] || fail "the second pile-up did not write its own census"
pass "a pile-up after the episode closed is reported again"

out=$("$GUARD" watch --state-dir "$STATE/quiet" --limit 1000000000 --hold 1 --interval 0.2 --duration 2 --source-id t-quiet) \
  || fail "quiet watch exited nonzero"
printf '%s\n' "$out" | grep -qx 'status: idle' || fail "a low count produced a report: $out"
[ "$(census_count "$STATE/quiet")" = 0 ] || fail "a low count wrote a census"
[ ! -e "$STATE/quiet/proc-guard.episode" ] || fail "a low count opened an episode"
pass "a count below the threshold writes nothing"

# A census that cannot be saved must not hide the pile-up itself.
: > "$LAB/not-a-directory"
out=$("$GUARD" watch --state-dir "$LAB/not-a-directory/state" --limit 1 --hold 1 --interval 0.2 --source-id t-unwritable) \
  || fail "an unwritable state directory made watch exit nonzero"
printf '%s\n' "$out" | grep -qx 'status: pileup' || fail "an unwritable state directory hid the pile-up: $out"
printf '%s\n' "$out" | grep -q '^census_error: .' || fail "the unsaved census was not explained: $out"
if printf '%s\n' "$out" | grep -q '^census: '; then fail "a census path was reported though nothing was saved: $out"; fi
pass "a census that cannot be saved still reports the pile-up, with the reason"

# --- watch: a dip below the threshold resets the hold ------------------------

burst_ready() { [ "$(pgrep -f "$LAB/burstsleep" | wc -l)" -ge "$burst" ]; }
limit_now=$(ulimit -u)
base=$("$GUARD" check --json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["count"])')
case "$limit_now" in
  unlimited) room=1 ;;
  *[!0-9]*) room=0 ;;
  *) if [ "$limit_now" -gt $((base + 2500)) ]; then room=1; else room=0; fi ;;
esac
if [ "$room" = 1 ]; then
  burst=1000
  # The threshold sits $burst/2 above today's count: a burst crosses it by half the
  # burst, and dropping the burst returns well below it, however busy the host is.
  limit=$(python3 -I -c 'import sys; print(int((int(sys.argv[1]) + int(sys.argv[2]) // 2) / 0.6) + 1)' "$base" "$burst")
  D="$STATE/dip"
  "$GUARD" watch --state-dir "$D" --limit "$limit" --hold 4 --interval 0.2 --source-id t-dip > "$LAB/dip.out" &
  WATCH_PID=$!
  sleep 1
  "$LAB/nestbash" "$LAB/burst.sh" "$burst"
  fm_test_wait_until 60 burst_ready || fail "the first burst never started"
  sleep 0.5
  stop_lab_processes
  sleep 1.5
  kill -0 "$WATCH_PID" 2>/dev/null || fail "a burst shorter than the hold ended the watch: $(cat "$LAB/dip.out")"
  second=$(now)
  "$LAB/nestbash" "$LAB/burst.sh" "$burst"
  wait "$WATCH_PID" || fail "watch exited nonzero after the second burst"
  waited=$(since "$second")
  stop_lab_processes
  grep -qx 'status: pileup' "$LAB/dip.out" || fail "a held burst was not reported: $(cat "$LAB/dip.out")"
  num_ge "$waited" 3.5 || fail "watch fired $waited s into the second burst: the first burst counted toward the hold"
  pass "a dip below the threshold resets the hold, so only a continuous pile-up reports"
else
  pass "dip case skipped: this host's own process limit leaves no room for a real burst"
fi

# --- never kills -------------------------------------------------------------

"$LAB/nestbash" "$LAB/nest.sh" 5 >/dev/null 2>&1 &
fm_test_wait_until 20 pgrep -f "$LAB/nestsleep 120" || fail "the survivor tree never reached its leaf"
"$GUARD" watch --state-dir "$STATE/survivors" --limit 1 --hold 1 --interval 0.2 >/dev/null || fail "watch exited nonzero over the survivor tree"
pgrep -f "$LAB/nestsleep 120" >/dev/null || fail "watch killed a process of the tree it reported"
pass "a reported pile-up is never killed"
