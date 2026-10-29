#!/usr/bin/env bash
# Live lab scenario: real fm-fleet-snapshot.sh against a disposable lab home and a
# real tmux pane on the lab's private socket. Slow sources are real head/tail/tmux
# wrapped by a silent delay (no output, no CPU) of DELAY seconds; a CPU-burn
# neighbour loads the host. Usage: live-lab-scenario.sh <repo-root> <delay> [hang-terminal-timeout]
set -u
ROOT=$1 DELAY=$2 HANG=${3:-}
SHIM=$(mktemp -d /tmp/fm-b2-shim.XXXX)
REAL_TMUX=$(command -v tmux) REAL_HEAD=$(command -v head) REAL_TAIL=$(command -v tail)
cat > "$SHIM/head" <<SH
#!/usr/bin/env bash
case "\$*" in *secondmates.md) sleep $DELAY ;; esac
exec "$REAL_HEAD" "\$@"
SH
cat > "$SHIM/tail" <<SH
#!/usr/bin/env bash
case "\$*" in '-c 65536 '*mate.status) sleep $DELAY ;; esac
exec "$REAL_TAIL" "\$@"
SH
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then
  if [ -n "$HANG" ]; then echo \$\$ > "$SHIM/hung.pid"; exec python3 -c 'import signal; signal.pause()'; fi
  sleep $DELAY
fi
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$SHIM"/*
H=$FM_HOME
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
printf 'kind=secondmate\nharness=codex\nbackend=tmux\nwindow=firstmate:fm-mate\n' > "$H/state/mate.meta"
printf 'working [key=review]: review underway\n' > "$H/state/mate.status"
printf -- '- mate (home: %s/missing; scope: reviews; projects: alpha; added 2026-10-01)\n' "$H" > "$H/data/secondmates.md"
"$REAL_TMUX" new-session -d -s firstmate -n fm-mate "printf 'review underway\n> \n'; exec sleep 600"
sleep 1
echo "tmux socket dir: $TMUX_TMPDIR"; "$REAL_TMUX" list-windows -a
# CPU-burn neighbours
BURN=(); for i in 1 2 3 4; do ( while :; do :; done ) & BURN+=($!); disown $!; done
echo "host load at start: $(sysctl -n vm.loadavg)"
EXTRA=(); [ -n "$HANG" ] && EXTRA=(FM_SNAPSHOT_TERMINAL_TIMEOUT=$HANG)
start=$(date +%s)
env -u NO_MISTAKES_GATE PATH="$SHIM:$PATH" FM_DURATION_FILE=off ${EXTRA[@]+"${EXTRA[@]}"} \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$SHIM/out.json" 2> "$SHIM/err"
rc=$?
end=$(date +%s)
kill "${BURN[@]}" 2>/dev/null
echo "snapshot rc=$rc wall=$((end-start))s"
[ -s "$SHIM/err" ] && { echo "stderr:"; head -5 "$SHIM/err"; }
jq '{registry:(.secondmate_current.registry|{available,complete,records:[.records[]?.id]}),
     activity_scan:(.secondmate_current.records[0].parent_event.activity_scan|{available,records:[.records[]?.key]}),
     terminal:(.secondmate_current.records[0].terminal_evidence|{captured,freshness,reason,event_note_seen}),
     current_state:.secondmate_current.records[0].current.state}' "$SHIM/out.json"
if [ -n "$HANG" ] && [ -s "$SHIM/hung.pid" ]; then
  p=$(cat "$SHIM/hung.pid"); if kill -0 "$p" 2>/dev/null; then echo "HUNG READER STILL ALIVE pid=$p"; kill "$p"; else echo "hung capture reader pid=$p was reaped"; fi
fi
"$REAL_TMUX" kill-server
rm -rf "$SHIM"
