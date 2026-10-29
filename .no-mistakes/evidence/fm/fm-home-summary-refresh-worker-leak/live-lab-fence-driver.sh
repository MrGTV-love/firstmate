#!/usr/bin/env bash
# Live driver: a real detached home-summary refresh against a disposable lab home.
# Usage: live-lab-fence-driver.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 2
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
echo "lab home: $LAB"
# Keep the lab owned while the scenario runs: a live private tmux server is the
# runtime evidence bin/fm-test-reap-orphans.sh honors, so concurrent test runs on
# this host do not reap this lab's detached refresh as an orphan.
tmux -L fm-lab new-session -d -s keep "sleep 3600" && echo "lab tmux server up on $TMUX_TMPDIR"
mkdir -p "$LAB/code-root"; ln -s "$WT/bin" "$LAB/code-root/bin"
REF="$LAB/code-root/bin/fm-home-summary-refresh.sh"
procs() { pgrep -f -- "$LAB/code-root/bin/fm-home-summary-refresh\\.sh" 2>/dev/null | tr '\n' ' '; }
show() { local p; for p in $(procs); do ps -o pid=,ppid=,stat=,etime=,command= -p "$p"; done; }
wait_gone() { local i=0; while [ -n "$(procs)" ] && [ $i -lt "$1" ]; do sleep 1; i=$((i+1)); done; echo "waited ${i}s"; [ -z "$(procs)" ]; }
hold_fence() {  # <lab> [<dir whose removal ends the holder>] -> holder pid in $HOLDER
  # A pre-started holder that takes the fence the moment the worker has released
  # its hand-off fence and created its publication temp file, so the worker meets
  # a held fence when it reaches for it again to publish. No stub, no override.
  rm -f "$1/state/.holder" "$1/state/.armed"
  nohup bash -c '. "$1"; st=${2%/*}; : > "$st/.armed"
    while :; do for f in "$st"/.home-summary.json.?*; do [ -e "$f" ] && break 2; done; done
    fm_lock_acquire_wait "$2"; [ -e "$st/home-summary.json" ] && echo late > "$st/.late"; echo $$ > "$3"
    while [ ! -e "$4" ] && [ -d "$5" ]; do sleep 0.2; done; fm_lock_release "$2"' \
    _ "$WT/bin/fm-wake-lib.sh" "$1/state/.home-summary-refresh.lock.steal" "$1/state/.holder" "$1/state/.release" "${2:-$1/state}" >/dev/null 2>&1 </dev/null &
  HOLDER_JOB=$!
  local i=0; while [ ! -e "$1/state/.armed" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
}
holder_took() {  # waits for the holder to take the fence; sets HOLDER
  local i=0; while [ ! -s "$LAB/state/.holder" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  HOLDER=$(cat "$LAB/state/.holder" 2>/dev/null)
  if [ -e "$LAB/state/.late" ]; then echo "SETUP: worker published before the holder took the fence (race lost)"; return 1; fi
  [ -n "$HOLDER" ] && echo "holder pid $HOLDER took $LAB/state/.home-summary-refresh.lock.steal while the worker held its publication temp file"
}
reset_home() { echo "state before reset: $(ls -A "$LAB/state" | tr '\n' ' ')"; rm -rf "$LAB"/state/.home-summary.json.* "$LAB"/state/.home-summary-error.*;  rm -rf "$LAB/state/home-summary.json" "$LAB/state/.holder" "$LAB/state/.release" "$LAB/state/.late" "$LAB/state/.armed" "$LAB/state/.home-summary-refresh.log"; }
RC=0

if [ -z "${ONLY_S4:-}" ]; then
echo; echo "=== S-live-1 (M4): plain detached refresh of a real home publishes"
FM_HOME=$LAB "$REF" --detach; echo "detach rc=$?"
i=0; while ! jq -e '.schema=="fm-secondmate-home-summary.v1"' "$LAB/state/home-summary.json" >/dev/null 2>&1 && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
jq -c '{schema, generated, generated_epoch}' "$LAB/state/home-summary.json" 2>&1 || RC=1
wait_gone 30 && echo "PASS no refresh process left" || { echo "FAIL processes left: $(procs)"; RC=1; }

echo; echo "=== S-live-2: worker waits on a LIVE fence holder (no clock cut), then publishes after release"
reset_home; hold_fence "$LAB"
FM_HOME=$LAB "$REF" --detach
holder_took || RC=1
sleep 8; echo "after 8s with live holder:"; show
[ -n "$(procs)" ] && echo "PASS worker still waiting on live holder" || { echo "FAIL worker gave up on a live holder"; RC=1; }
: > "$LAB/state/.release"
i=0; while ! jq -e '.schema' "$LAB/state/home-summary.json" >/dev/null 2>&1 && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
[ -s "$LAB/state/home-summary.json" ] && echo "PASS published ${i}s after release" || { echo "FAIL not published"; RC=1; cat "$LAB/state/.home-summary-refresh.log"; }
wait_gone 30 && echo "PASS no refresh process left" || { echo "FAIL processes left: $(procs)"; RC=1; }

echo; echo "=== S-live-3: fence holder SIGKILLed -> stale reclaim -> publish"
reset_home; hold_fence "$LAB"
FM_HOME=$LAB "$REF" --detach
holder_took || RC=1
sleep 3; show; kill -KILL "$HOLDER"; echo "killed holder $HOLDER (I started it)"
i=0; while ! jq -e '.schema' "$LAB/state/home-summary.json" >/dev/null 2>&1 && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
[ -s "$LAB/state/home-summary.json" ] && echo "PASS published ${i}s after holder died" || { echo "FAIL not published"; RC=1; cat "$LAB/state/.home-summary-refresh.log"; }
wait_gone 30 && echo "PASS no refresh process left" || { echo "FAIL processes left: $(procs)"; RC=1; }

fi
echo; echo "=== S-live-4 (M3, adversarial): home state removed while worker waits on a holder that stays alive"
reset_home; hold_fence "$LAB" "$WT"
FM_HOME=$LAB "$REF" --detach
holder_took || RC=1
sleep 4; echo "waiting processes before removal:"; show
[ -n "$(procs)" ] || { echo "FAIL no waiting worker to test"; RC=1; ls -la "$LAB/state"; cat "$LAB/state/.home-summary-refresh.log" 2>&1; }
mv "$LAB/state" "$LAB/state.removed.$$" && rm -rf "$LAB/state.removed.$$"; echo "removed $LAB/state at $(date +%T)"
if wait_gone 20; then echo "PASS worker ended after home state removal"; else echo "FAIL worker still running: "; show; RC=1; fi
kill -0 "$HOLDER" 2>/dev/null && { echo "holder $HOLDER still alive (my own), stopping it"; kill "$HOLDER"; }

echo; echo "=== teardown"
mkdir -p "$LAB/state"
[ -n "${HOLDER_JOB:-}" ] && kill -0 "$HOLDER_JOB" 2>/dev/null && { echo "stopping my holder job $HOLDER_JOB"; kill -KILL "$HOLDER_JOB"; }
for p in $(procs); do echo "killing leftover $p"; kill -KILL "$p"; done
tmux -L fm-lab kill-server 2>/dev/null; TEARDOWN="$WT/bin/fm-lab-home.sh teardown $LAB && rm -rf $LAB"
echo "$TEARDOWN"; "$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "teardown rc=$?"
[ ! -e "$LAB" ] && echo "lab removed"
echo "OVERALL RC=$RC"; exit $RC
