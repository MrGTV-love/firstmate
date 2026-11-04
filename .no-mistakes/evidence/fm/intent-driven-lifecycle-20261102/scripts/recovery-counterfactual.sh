#!/usr/bin/env bash
# Owned counterfactual for the recovery adopt case.
# Usage: <tree> <collider-session|own|none> <steady|late> <label> [late-after-status-reads, default 3]
#   steady: the collider runs for the whole case.
#   own:    (late only) collide on the session the case's own record binds.
#   late:   the collider starts once the case's fake log shows N status reads
#           (default 3: after the agent-state absence proof already passed and
#           server_ensure read stopped, before the start helper's locked proof).
set -u
tree=$1 ses=$2 when=$3 label=$4 after=${5:-3} case=test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
d=$(mktemp -d /tmp/fm-nm-collide.XXXXXX); pid= watcher=
mkdir "$d/tmp"
# The collider stays a bash process (comm=bash, argv `<dir>/herdr server ...`)
# like the fixture's own fake, and reaps its sleep child when terminated.
printf '#!/usr/bin/env bash\ntrap '"'"'kill "$c" 2>/dev/null; wait "$c"; exit 143'"'"' TERM\n/bin/sleep 120 & c=$!\nwait "$c"\n' > "$d/herdr"; chmod +x "$d/herdr"
start_collider() { "$d/herdr" server --session "$ses" & pid=$!; echo "$pid" > "$d/pid"; }
echo "== $label: tree=$tree collider=$ses when=$when${after:+/after=$after} head=$(git -C "$tree" rev-parse --short HEAD) dirty=$(git -C "$tree" status --short | wc -l | tr -d ' ') =="
if [ "$ses" != none ] && [ "$when" = steady ]; then
  start_collider; /bin/sleep 0.5; echo "collider: $(ps -o pid=,command= -p "$pid")"
elif [ "$ses" != none ]; then
  (
    while :; do
      log=$(find "$d/tmp" -path '*gone-herdr-*/fake/herdr-log' 2>/dev/null | head -1)
      if [ -n "$log" ] && [ "$(grep -c '^status --json' "$log" 2>/dev/null)" -ge "$after" ]; then
        target=$ses
        if [ "$ses" = own ]; then
          meta=$(find "$d/tmp" -path '*gone-herdr-*/home/state/*.meta' 2>/dev/null | head -1)
          target=$(sed -n 's/^herdr_session=//p' "$meta")
        fi
        "$d/herdr" server --session "$target" & echo $! > "$d/pid"; wait; exit 0
      fi
      /bin/sleep 0.005
    done
  ) & watcher=$!
fi
(cd "$tree" && TMPDIR="$d/tmp" bash tests/fm-control-relaunch-recovery.test.sh "$case"); rc=$?
echo "== $label: case exit=$rc"
[ -s "$d/pid" ] && echo "collider: $(ps -o pid=,command= -p "$(cat "$d/pid")")"
[ ! -s "$d/pid" ] || kill "$(cat "$d/pid")" 2>/dev/null
[ -z "$pid" ] || { wait "$pid" 2>/dev/null; echo "collider wait=$?"; }
[ -z "$watcher" ] || { kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null; echo "watcher reaped"; }
rm -rf "$d"
exit 0
