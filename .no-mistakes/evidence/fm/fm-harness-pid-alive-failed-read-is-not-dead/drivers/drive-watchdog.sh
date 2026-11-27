#!/usr/bin/env bash
# drive-watchdog.sh <repo-root>: real bin/fm-watchdog-check.sh against a live harness lock holder, readable vs unreadable
set -u
R=$1
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8DMW2J1VQGF3NPHWTC2G695
eval "$("$W/bin/fm-lab-home.sh" env 2>/tmp/fm-drv/lab3.err)"
echo "lab FM_HOME=$FM_HOME  repo=$R"
D=$(mktemp -d /tmp/fm-drv/wd.XXXX)
ln -s /bin/bash "$D/claude"
REAL_PS=$(command -v ps)
cat > "$D/ps" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ -n "\${FAIL_PID:-}" ] && [ "\$a" = "\$FAIL_PID" ]; then echo 'ps: operation not permitted' >&2; exit 2; fi
done
exec "$REAL_PS" "\$@"
SH
chmod +x "$D/ps"
printf '#!/bin/sh\necho "$@" >> %s/arm.calls\n' "$D" > "$D/arm.sh"; chmod +x "$D/arm.sh"
printf '#!/bin/sh\necho "$*" >> %s/alarm.calls\n' "$D" > "$D/alarm.sh"; chmod +x "$D/alarm.sh"
"$D/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 & H=$!
sleep 0.3
mkdir -p "$FM_HOME/state" "$FM_HOME/config"
printf 'window=firstmate:fm-task\nkind=ship\n' > "$FM_HOME/state/task.meta"
printf 'echo "$FM_WATCHDOG_REASON" >> %s/resume.calls; touch "%s/state/.last-watcher-beat"\n' "$D" "$FM_HOME" > "$FM_HOME/config/watchdog-resume"
for mode in unreadable readable; do
  rm -f "$D"/*.calls "$FM_HOME/state/.watchdog-episode" "$FM_HOME/state/.watchdog.log"
  printf '%s\n' "$H" > "$FM_HOME/state/.lock"
  printf 'epoch=7 owner_pid=999999 outcome=rewake updated_at=1\n' > "$FM_HOME/state/.claude-autoarm-epoch"
  touch -t 201901010000 "$FM_HOME/state/.last-watcher-beat"
  printf 'attempts=1 last_attempt=1 last_alarm=0\n' > "$FM_HOME/state/.watchdog-episode"
  before=$(cat "$FM_HOME/state/.watchdog-episode")
  fp=; [ "$mode" = unreadable ] && fp=$H
  echo "=== $mode: live harness holder pid $H, stale beacon, ps for holder $( [ -n "$fp" ] && echo FAILS || echo works)"
  env -u NO_MISTAKES_GATE FM_HOME="$FM_HOME" PATH="$D:$PATH" FAIL_PID="$fp" FM_WATCHDOG_ARM="$D/arm.sh" FM_WATCHDOG_VERIFY_SECS=1 \
    FM_WATCHDOG_STEP_SECS=20 FM_WEDGE_ALARM_EXEC="$D/alarm.sh" FM_WEDGE_ALARM_CHANNEL='command:true' \
    "$R/bin/fm-watchdog-check.sh" 2>&1
  echo "watchdog exit=$?"
  echo "resume command runs: $(cat "$D/resume.calls" 2>/dev/null | tr '\n' ' ' || true)$( [ -f "$D/resume.calls" ] || echo none)"
  echo "watcher arm calls: $( [ -f "$D/arm.calls" ] && tr '\n' ' ' < "$D/arm.calls" || echo none)"
  echo "episode unchanged: $( [ "$before" = "$(cat "$FM_HOME/state/.watchdog-episode" 2>/dev/null)" ] && echo yes || echo "NO -> $(cat "$FM_HOME/state/.watchdog-episode" 2>/dev/null)")"
  echo "watchdog.log tail: $(tail -2 "$FM_HOME/state/.watchdog.log" 2>/dev/null | tr '\n' '|')"
done
kill $H 2>/dev/null; wait 2>/dev/null
bash -c "$(grep -o '[^ ]*fm-lab-home.sh teardown.*' /tmp/fm-drv/lab3.err)" && echo "lab torn down"
