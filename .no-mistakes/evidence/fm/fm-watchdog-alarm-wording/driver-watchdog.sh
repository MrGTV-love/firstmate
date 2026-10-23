#!/usr/bin/env bash
# Live drive of bin/fm-watchdog-check.sh against a disposable lab home.
# No test seams (FM_TEST_SEAM unset): real clock, real fm-watch-arm, production
# notifier path (FM_WEDGE_ALARM_EXEC unset). osascript/herdr on PATH are argv
# recorders so no real alert is posted.
set -u
WT=$1; EV=$2
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-wd-scr.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
export HOME="$SCR/home"; mkdir -p "$HOME"
export FM_TELEMETRY_DIR="$SCR/telemetry"
mkdir -p "$SCR/shims"
cat > "$SCR/shims/osascript" <<S
#!/bin/sh
{ printf 'osascript argv:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$SCR/notify.calls"
S
cat > "$SCR/shims/herdr" <<S
#!/bin/sh
{ printf 'herdr argv:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$SCR/notify.calls"
S
chmod +x "$SCR/shims/"*
cat > "$SCR/cmd-recorder.sh" <<S
#!/bin/sh
printf 'command channel \$1: %s\n' "\$1" >> "$SCR/notify.calls"
S
chmod +x "$SCR/cmd-recorder.sh"
printf 'osascript\nherdr\ncommand:%s "$1"\n' "$SCR/cmd-recorder.sh" > "$LAB/config/wedge-alarm"
: > "$SCR/notify.calls"
# A home with work that needs supervision; session lock points at a dead pid.
printf 'window=firstmate:fm-task\nkind=ship\n' > "$LAB/state/task.meta"
/bin/sleep 0 & dp=$!; wait $dp
echo "$dp" > "$LAB/state/.lock"
: > "$LAB/state/.last-watcher-beat"
run() {
  echo "\$ FM_HOME=\$LAB bin/fm-watchdog-check.sh   ($1)"
  out=$(env -u FM_WEDGE_ALARM_EXEC -u FM_TEST_SEAM -u FM_WEDGE_ALARM_CHANNEL PATH="$SCR/shims:$PATH" \
    FM_HOME="$LAB" FM_WATCHDOG_VERIFY_SECS=1 FM_WATCHDOG_RETRY_SECS=1 \
    nice -n 20 "$WT/bin/fm-watchdog-check.sh" 2>&1); code=$?
  echo "$out"; echo "exit=$code"
  echo "episode: $(cat "$LAB/state/.watchdog-episode" 2>/dev/null || echo '<none>')"
  echo "notifications so far: $(wc -l < "$SCR/notify.calls" 2>/dev/null | tr -d ' ' || echo 0)"
  echo
}
echo "=== S1: no-op attempts (no watcher, no config/watchdog-resume) ==="
rm -f "$LAB/config/watchdog-resume"
run "attempt 1, no-op"
sleep 2
run "attempt 2, no-op -> alarm"
echo "--- notifier calls ---"; cat "$SCR/notify.calls" 2>/dev/null; echo
echo "=== S2: retry interval still holds (immediate rerun) ==="
env -u FM_WEDGE_ALARM_EXEC -u FM_TEST_SEAM PATH="$SCR/shims:$PATH" FM_HOME="$LAB" FM_WATCHDOG_VERIFY_SECS=1 FM_WATCHDOG_RETRY_SECS=600 \
  "$WT/bin/fm-watchdog-check.sh"; echo "exit=$?"; echo
echo "=== S3: resume command that runs but does not heal -> recovery failed ==="
printf 'true\n' > "$LAB/config/watchdog-resume"
sleep 2
: > "$SCR/notify.calls"
run "attempt 3, resume ran; alarm rate-limited by 3600s interval"
echo "--- notifier calls (expect none: rate limit) ---"; cat "$SCR/notify.calls"; echo
echo "--- rerun with FM_WATCHDOG_ALARM_INTERVAL_SECS=1 to see the failed-recovery alarm ---"
sleep 2
out=$(env -u FM_WEDGE_ALARM_EXEC -u FM_TEST_SEAM PATH="$SCR/shims:$PATH" FM_HOME="$LAB" FM_WATCHDOG_VERIFY_SECS=1 \
  FM_WATCHDOG_RETRY_SECS=1 FM_WATCHDOG_ALARM_INTERVAL_SECS=1 nice -n 20 "$WT/bin/fm-watchdog-check.sh" 2>&1); c=$?; echo "$out"; echo "exit=$c"
echo "--- notifier calls ---"; cat "$SCR/notify.calls"; echo
echo "=== S4: comment-only config/watchdog-resume is a no-op ==="
printf '# nothing here\n' > "$LAB/config/watchdog-resume"
: > "$SCR/notify.calls"; sleep 2
out=$(env -u FM_WEDGE_ALARM_EXEC -u FM_TEST_SEAM PATH="$SCR/shims:$PATH" FM_HOME="$LAB" FM_WATCHDOG_VERIFY_SECS=1 \
  FM_WATCHDOG_RETRY_SECS=1 FM_WATCHDOG_ALARM_INTERVAL_SECS=1 nice -n 20 "$WT/bin/fm-watchdog-check.sh" 2>&1); c=$?; echo "$out"; echo "exit=$c"
echo "--- notifier calls ---"; cat "$SCR/notify.calls"; echo
echo "=== S5: work finishes (no task left) -> idle clears the episode ==="
rm -f "$LAB/state/task.meta"
run "idle"
echo "=== watchdog log ==="; cat "$LAB/state/.watchdog.log"
pkill -f 'fm-wd-never-match' 2>/dev/null
lp=$(cat "$LAB/state/.lock" 2>/dev/null); [ -n "$lp" ] && kill "$lp" 2>/dev/null
rm -rf "$LAB" "$SCR"
echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
