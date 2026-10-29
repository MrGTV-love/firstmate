# Lab helpers: drive the real firstmate ledger CLI in a disposable FM_HOME.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M63AKW2M2FYTG5FKEZ8T6BB7
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.Ifehcr
export TMUX_TMPDIR=/tmp/fml.6PWtgI
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ROWS=$FM_HOME/lab-rows.json
# publish: write state/open-loops.json from lab-rows.json (as a heartbeat would), keeping the handling object.
publish() {
  python3 -I - "$FM_HOME" "$ROWS" <<'PY'
import json, sys, time, os
home, rows_path = sys.argv[1:]
now = int(os.environ.get("LAB_NOW", time.time()))
target = os.path.join(home, "state/open-loops.json")
prev = json.load(open(target)) if os.path.exists(target) else {}
rows = json.load(open(rows_path))
for r in rows:
    r.setdefault("informational", False)
    # As the real collector does: age is measured from a fixed obligation start.
    r["age_seconds"] = now - r.pop("start_epoch")
    r["overdue"] = r["age_seconds"] >= r["limit_seconds"]
report = dict(schema="fm-open-loops.v1", generated_epoch=now, home=home, complete=True, rows=rows)
if "handling" in prev:
    report["handling"] = prev["handling"]
tmp = target + ".tmp"
json.dump(report, open(tmp, "w")); os.replace(tmp, target)
PY
}
enqueue() {  # <key> <reason>
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check "$2" "$3"' _ "$W" "$1" "$2"
}
# drain_and_capture: run a drain, keep its output in $DRAIN_OUT, print it.
drain_and_capture() {
  DRAIN_OUT=$(drain "$@" 2>&1); local rc=$?
  printf '$ fm-wake-drain.sh %s\n%s\n[exit %s]\n' "$*" "$DRAIN_OUT" "$rc"
}
# ack: acknowledge using the WAKE_ACK_REQUIRED line of the last drain.
ack() {
  local cmd; cmd=$(printf '%s\n' "$DRAIN_OUT" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  printf '$ fm-wake-drain.sh %s\n' "$cmd"
  # shellcheck disable=SC2086
  drain $cmd 2>&1; printf '[exit %s]\n' "$?"
}
ol() { "$W/bin/fm-open-loops.sh" "$@"; }
drain() { "$W/bin/fm-wake-drain.sh" "$@"; }
step() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
