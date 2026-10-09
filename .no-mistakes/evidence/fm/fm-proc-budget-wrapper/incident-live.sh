#!/usr/bin/env bash
set -u
ROOT=$PWD
FIX="$ROOT/.gate-proc-budget-validation/incident"
mkdir -p "$FIX/bomb"
cat > "$FIX/bomb/shim.sh" <<'SH'
#!/usr/bin/env bash
SHIM_DEPTH=$(( ${SHIM_DEPTH:-0} + 1 )); export SHIM_DEPTH
printf '%s\n' "$SHIM_DEPTH" >> "$SHIM_LOG"
[ "$SHIM_DEPTH" -le 1500 ] || exit 99
n=$(basename "$0")
exec "$n" "$@"
SH
chmod +x "$FIX/bomb/shim.sh"
ln -s shim.sh "$FIX/bomb/basename"
ln -s shim.sh "$FIX/bomb/date"
parent_soft=$(ulimit -S -u)
printf 'outside parent soft=%s hard=%s\n' "$parent_soft" "$(ulimit -H -u)"
bash -c 'n=0; while [ ! -e "$1/stop" ]; do /usr/bin/true || exit 3; n=$((n + 1)); done; printf "outside probe completed %s successful forks\n" "$n" > "$1/probe.out"' _ "$FIX" 2>"$FIX/probe.err" &
probe_pid=$!
trap 'touch "$FIX/stop"; wait "$probe_pid" 2>/dev/null || true' EXIT
. "$ROOT/bin/fm-timeout-lib.sh"
fm_run_timed 90 "$ROOT/bin/fm-proc-budget.sh" 300 -- bash -c 'printf "inside soft=%s hard=%s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"; exec env PATH="$1:$PATH" SHIM_LOG="$2" date +%s' _ "$FIX/bomb" "$FIX/depth.log" >"$FIX/bomb.out" 2>"$FIX/bomb.err"
rc=$?
touch "$FIX/stop"
wait "$probe_pid"; probe_rc=$?
trap - EXIT
printf 'runaway tree exit=%s; outside probe exit=%s\n' "$rc" "$probe_rc"
cat "$FIX/bomb.out" "$FIX/probe.out"
python3 - "$FIX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); depths=[int(x) for x in (p/'depth.log').read_text().splitlines()]
e=(p/'bomb.err').read_text(); outside=(p/'probe.err').read_text()
print('runaway maximum recursion depth=%s' % max(depths))
print('runaway fork diagnostics:'); print('\n'.join(e.splitlines()[:12]))
print('outside probe stderr=%r' % outside)
assert 20 < max(depths) < 1500
assert 'Resource temporarily unavailable' in e
assert not outside
assert (p/'probe.out').read_text().startswith('outside probe completed ')
PY
check_rc=$?
[ "$probe_rc" -eq 0 ] && [ "$check_rc" -eq 0 ] && [ "$rc" -ne 124 ] && [ "$(ulimit -S -u)" = "$parent_soft" ]
