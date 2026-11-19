#!/usr/bin/env bash
# Live join of the REAL watcher (bin/fm-watch.sh) to the REAL reaper (bin/fm-scratch-reaper.sh).
# Everything runs in one disposable world. The watcher gets its own state, config and home, and a
# private TMUX_TMPDIR so no tmux call can reach an operator server. The only wrapper is the reaper
# path, which refuses any run whose config or home lies outside the world, then execs the real script.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7SPWYTNRFX8SACE90CH6NJ7
RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-watch.XXXXXX") || exit 1
W="$RUN/w"
WPID=
FAILS=0
cleanup() {
  [ -z "$WPID" ] || kill "$WPID" 2>/dev/null
  [ -z "$WPID" ] || wait "$WPID" 2>/dev/null
  rm -rf -- "$RUN"
}
trap cleanup EXIT
pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
age() { find "$1" -exec touch -h -t 202501010000 {} + ; }

mkdir -p "$W/home" "$W/tmux" "$W/tmp" "$W/fm/state" "$W/fm/data" "$W/fm/config" "$W/root" "$W/bin"
printf '%s fm-*\n' "$W/root" > "$W/fm/config/scratch-reaper"
mkdir -p "$W/root/fm-wlive" && printf 'w\n' > "$W/root/fm-wlive/run.log" && age "$W/root"
R=$(cd -P "$W/root" && pwd -P)

# The guard: the real reaper runs only for a config and home inside this world.
cat > "$W/bin/reaper-guard.sh" <<SH
#!/usr/bin/env bash
case "\${FM_CONFIG_OVERRIDE:-}\${FM_HOME:-}" in *"$W"*) ;; *) echo "guard: refused, config/home outside world" >&2; exit 99 ;; esac
case "\${FM_CONFIG_OVERRIDE:-}" in "$W"/*) ;; *) echo "guard: refused, config outside world" >&2; exit 99 ;; esac
printf '%s\n' "\$*" >> "$W/reaper-calls.txt"
exec bash "$WT/bin/fm-scratch-reaper.sh" "\$@"
SH
chmod +x "$W/bin/reaper-guard.sh"

# The open-loop reconciler is an unrelated watcher check that ends the watcher on its own in an empty
# world (its ledger reports the backlog unavailable). A no-op stand-in keeps the poll running.
printf '#!/bin/sh\nexit 0\n' > "$W/bin/open-loops-noop.sh" && chmod +x "$W/bin/open-loops-noop.sh"

# Start the real watcher. Every other cadence is switched off so only the reaper offer can act.
env -i PATH="$PATH" HOME="$W/home" TMPDIR="$W/tmp" TMUX_TMPDIR="$W/tmux" \
  FM_OPEN_LOOPS_BIN="$W/bin/open-loops-noop.sh" \
  FM_HOME="$W/fm" FM_STATE_OVERRIDE="$W/fm/state" FM_CONFIG_OVERRIDE="$W/fm/config" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
  FM_SCRATCH_REAPER_TICK=1 FM_SCRATCH_REAPER_BIN="$W/bin/reaper-guard.sh" \
  bash "$WT/bin/fm-watch.sh" > "$W/watch.out" 2> "$W/watch.err" &
WPID=$!
# The host is under heavy load (load average near 100), so each watcher prelude step is slow. Wait,
# up to 150 s, until the first removal is logged and at least two offers have reached the guard.
for _ in $(seq 1 75); do
  if grep -qF 'removed ' "$W/fm/state/scratch-reaper.log" 2>/dev/null \
    && [ "$(wc -l < "$W/reaper-calls.txt" 2>/dev/null | tr -d ' ')" -ge 2 ]; then break; fi
  kill -0 "$WPID" 2>/dev/null || break
  sleep 2
done
printf '\n--- watcher stdout (tail) ---\n'; tail -5 "$W/watch.out"
printf '\n--- watcher stderr (tail) ---\n'; tail -5 "$W/watch.err"
printf '\n--- reaper offers received by the guard (count %s) ---\n' "$(wc -l < "$W/reaper-calls.txt" 2>/dev/null | tr -d ' ')"
head -3 "$W/reaper-calls.txt" 2>/dev/null
printf '\n--- decision log ---\n'; cat "$W/fm/state/scratch-reaper.log" 2>/dev/null
printf '\n--- next-run marker ---\n'; cat "$W/fm/state/.scratch-reaper-next" 2>/dev/null
printf '\n--- world state folder ---\n'; ls -la "$W/fm/state" 2>/dev/null
printf '\n--- open-loops.json (head) ---\n'; head -c 600 "$W/fm/state/open-loops.json" 2>/dev/null; echo
printf '\n--- watcher still running: %s ---\n' "$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"

check "WATCH the real watcher offers the reaper with --scheduled" grep -qx -- '--scheduled' "$W/reaper-calls.txt"
check "WATCH the first tick's reaper removes the aged fm-wlive directory" [ ! -e "$R/fm-wlive" ]
check "WATCH the removal is logged as one removed line" grep -qF "removed $R/fm-wlive " "$W/fm/state/scratch-reaper.log"
check "WATCH the next-run marker is set one window ahead" [ -s "$W/fm/state/.scratch-reaper-next" ]
# The watcher ends on its own on the first actionable wake, which an empty world always raises.
# Those two facts are reported, not asserted: the repeat-per-tick behavior is covered by the suite.
printf 'OBSERVED - offers received by the guard: %s\n' "$(wc -l < "$W/reaper-calls.txt" | tr -d ' ')"
printf 'OBSERVED - the first actionable wake from the watcher stdout: %s\n' "$(head -1 "$W/watch.out")"
printf 'OBSERVED - watcher still running at the end of the run: %s\n' "$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"

kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
printf '\n=== watch-live summary: %s failing check(s) ===\n' "$FAILS"
exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
