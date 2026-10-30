#!/usr/bin/env bash
# Live driver: the REAL bin/fm-crew-state.sh reads a finished no-mistakes ship
# whose daemon answers the first `axi status` (no active run) and then goes
# silent on every later one, which is the completion gate's read. Only FM_CREW_STATE_NM_TIMEOUT=3 is
# set (FM_DOD_NM_STALL_SECS is NOT set). Each `axi status` call logs when it
# starts and is stopped, so the transcript shows how long the completion gate's
# read waited.
# Usage: live-crew-state.sh <bin-root> <out-file>
set -u
BIN_ROOT=$1 OUT=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-crew.XXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/data" "$T/config" "$T/home" "$T/bin"
git init -q -b main "$T/repo"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/repo" worktree add -q -b fm/ship1 "$T/wt" main
cat > "$T/bin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "axi status" ]; then
  if [ ! -e "$T/answered" ]; then
    : > "$T/answered"
    printf '%s axi status answered: no active run\n' "\$(date +%s)" >> "$T/nm.log"
    exit 0
  fi
  printf '%s axi status start, silent (pid %s)\n' "\$(date +%s)" "\$\$" >> "$T/nm.log"
  trap 'printf "%s axi status stopped\n" "\$(date +%s)" >> "$T/nm.log"; exit 143' TERM
  sleep 1200 & wait
fi
exit 0
SH
chmod +x "$T/bin/no-mistakes"
# Stand-in tmux pane (copied from tests/fm-crew-state.test.sh make_fakebin): the
# crew's window is alive and idle, so crew-state reaches the status-log done line.
cat > "$T/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'ship1\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$T/bin/tmux"
url=https://review.example.com/c/proj/+/43
printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\npr=%s\nharness=claude\nwindow=fm:ship1\n' \
  "$T/wt" "$T/repo" "$url" > "$T/state/ship1.meta"
printf 'done [at=%s]: PR %s published for review\n' "$(date +%s)" "$url" > "$T/state/ship1.status"
gen=$("$BIN_ROOT/bin/fm-busy-event.sh" arm "$T/state" ship1)
"$BIN_ROOT/bin/fm-busy-event.sh" apply "$T/state" ship1 idle --gen "$gen" --source claude-hook --event stop >/dev/null
t0=$(date +%s)
out=$(env -u FM_DOD_NM_STALL_SECS FM_HOME="$T/home" FM_STATE_OVERRIDE="$T/state" FM_DATA_OVERRIDE="$T/data" \
  FM_CONFIG_OVERRIDE="$T/config" FM_CREW_STATE_NO_FORGE=1 FM_CREW_STATE_NM_TIMEOUT=3 \
  PATH="$T/bin:$PATH" perl -e 'alarm 120; exec @ARGV' "$BIN_ROOT/bin/fm-crew-state.sh" ship1 2>&1)
rc=$?
{
  echo "\$ FM_CREW_STATE_NM_TIMEOUT=3 fm-crew-state.sh ship1   (bin: $BIN_ROOT; FM_DOD_NM_STALL_SECS unset; outer kill at 120 s)"
  echo "exit=$rc  wall=$(( $(date +%s) - t0 ))s"
  echo "--- output ---"
  printf '%s\n' "$out"
  echo "--- axi status calls (epoch seconds) ---"
  cat "$T/nm.log" 2>/dev/null || echo "(none)"
} | tee "$OUT"
