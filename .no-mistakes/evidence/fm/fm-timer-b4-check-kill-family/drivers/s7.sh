#!/usr/bin/env bash
# Scenario 7: tool-update check armed in a lab and run by the real watcher.
# slowtool answers --version only after ~40 s of steady stderr progress (5x a ~8 s probe).
# mutetool never answers (silent, CPU-idle). Expect: slow tool reported; mute tool unknown.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh" "$1"; L=$2
mklab; mkdir -p "$FM_HOME/config" "$FM_HOME/fixbin"
cat > "$FM_HOME/fixbin/slowtool-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  for ((i=0;i<10;i++)); do printf 'resolving %s\n' "$i" >&2; sleep 4; done
  printf 'slowtool 1.0.0\n'
else
  printf 'A new version of slowtool is available: v1.0.0 -> v2.0.0\n' >&2
fi
SH
cat > "$FM_HOME/fixbin/mutetool-fixture" <<'SH'
#!/usr/bin/env bash
exec sleep 600
SH
chmod 0755 "$FM_HOME/fixbin/"*
printf '%s\n' '{"tools":[{"name":"mutetool","command":"mutetool-fixture","version_args":["--version"]},{"name":"slowtool","command":"slowtool-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of slowtool is available: [^ ]+ -> [^ ]+"}]}' > "$FM_HOME/config/watched-tools.json"
env -u FM_STATE_OVERRIDE FM_HOME="$FM_HOME" "$ROOT/bin/fm-tool-update-check.sh" arm 2>&1 | sed "s#$FM_HOME#\$FM_HOME#g"
echo "== $L: watcher sweep (default FM_CHECK_TIMEOUT, default probe settings) started $(ts)"
startwatch "$D/s7-$L" FM_CHECK_INTERVAL=999999 FM_TOOL_UPDATE_INTERVAL=0 PATH="$FM_HOME/fixbin:$PATH"
s=$SECONDS; waitsweep 400; echo "sweep ${SECONDS-s}s"; el=$((SECONDS-s)); echo "sweep took ${el}s"; stopwatch
echo "-- wake queue:"; cut -f5 "$FM_HOME/state/.wake-queue" 2>/dev/null | sed "s#$FM_HOME#\$FM_HOME#g"
echo "-- triage:"; sed "s#$FM_HOME#\$FM_HOME#g" "$FM_HOME/state/.watch-triage.log" 2>/dev/null
echo "-- leftover fixture processes: $(pgrep -f "$FM_HOME/fixbin" | wc -l | tr -d ' ')"
pkill -KILL -f "$FM_HOME/fixbin" 2>/dev/null
droplab
