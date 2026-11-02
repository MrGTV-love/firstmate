. "$(dirname "$0")/common.sh"
banner
BASEPATH=$PATH
fresh() { R=$(mktemp -d "$(dirname "$0")/c.XXXX"); export FM_STATE_OVERRIDE="$R/state"; mkdir -p "$R/state" "$R/bin"; export PATH="$R/bin:$BASEPATH"; }
tool() { printf '#!/bin/sh\n%s\n' "$2" > "$R/bin/$1"; chmod +x "$R/bin/$1"; }
quota() { "$PY" "$OWNER" records --kind quota | "$PY" -c 'import json,sys
for l in sys.stdin:
    r=json.loads(l); print("  quota",r["status"],"reason",r.get("reason"),"exit",r.get("exit_code"),"graphql",r.get("graphql"),"pid",r.get("request_pid"))'; }
samp() { "$PY" "$OWNER" records --kind sampling | "$PY" -c 'import json,sys
for l in sys.stdin:
    r=json.loads(l); print("  sampling scans",r["scans"],"failures",r["failures"],"max_gap",round(r["max_gap_seconds"],3))'; }
stoptime() { s=$("$PY" -c 'import time;print(time.time())'); "$PY" "$OWNER" stop; rc=$?; e=$("$PY" -c 'import time;print(time.time())'); "$PY" -c "print('  stop exit',$rc,'took',round($e-$s,2),'s')"; }

echo "=== C1 gh-axi not on PATH: unavailable with command_unavailable, owner still runs"
fresh; export PATH=/usr/bin:/bin; command -v gh-axi || echo "  gh-axi absent from PATH"
"$PY" "$OWNER" start; echo "  start exit=$?"; sleep 17; "$PY" "$OWNER" status; stoptime; quota; samp

echo "=== C2 gh-axi exits nonzero with a rate-limit error: unavailable, never zero"
fresh; tool gh-axi 'echo "API rate limit already exceeded" >&2; printf "error: rate limited\n"; exit 1'
"$PY" "$OWNER" run --duration 17; echo "  run exit=$?"; quota

echo "=== C3 gh-axi exits 0 with a malformed body: unavailable, never zero"
fresh; tool gh-axi 'printf "api_response:\n  body: used=garbage reset=x limit=y remaining=z\n"'
"$PY" "$OWNER" run --duration 2; echo "  run exit=$?"; quota

echo "=== C4 hung gh-axi with a grandchild: pending ticks, no overlap, killed only on no-progress verdict, next tick sends a new request"
fresh; export FM_DURATION_NO_PROGRESS_SECS=20; tool gh-axi "n=\$(cat $R/n 2>/dev/null || echo 0); echo \$((n+1)) > $R/n; if [ \$n = 0 ]; then sleep 600 & wait; fi; printf 'api_response:\n  body: used=7 reset=1794000000 limit=5000 remaining=4993\n'"
"$PY" "$OWNER" run --duration 48; echo "  run exit=$?"; quota; echo "  requests sent: $(cat $R/n)"; unset FM_DURATION_NO_PROGRESS_SECS
sleep 1; echo "  hung children left: $(pgrep -f "$R/bin/gh-axi" | wc -l | tr -d ' ')"

echo "=== C5 slow gh-axi still using CPU: not killed, its result is recorded"
fresh; export FM_DURATION_NO_PROGRESS_SECS=5; tool gh-axi "n=\$(cat $R/n 2>/dev/null || echo 0); echo \$((n+1)) > $R/n; end=\$((\$(date +%s)+22)); while [ \$(date +%s) -lt \$end ]; do :; done; printf 'api_response:\n  body: used=9 reset=1794000000 limit=5000 remaining=4991\n'"
"$PY" "$OWNER" run --duration 25; echo "  run exit=$?"; quota; unset FM_DURATION_NO_PROGRESS_SECS

echo "=== C6 stop during a hung gh-axi: group is killed, stop returns"
fresh; tool gh-axi "sleep 600 & wait"
"$PY" "$OWNER" start >/dev/null; sleep 2; echo "  hung before stop: $(pgrep -f "$R/bin/gh-axi" | wc -l | tr -d ' ')"; stoptime; sleep 1; echo "  hung after stop: $(pgrep -f "$R/bin/gh-axi" | wc -l | tr -d ' ')"; quota

echo "=== C7 ps hangs for every caller: quota continues, stop works, waiting ps stays bounded, normal stop ends it"
fresh; tool gh-axi "printf 'api_response:\n  body: used=11 reset=1794000000 limit=5000 remaining=4989\n'"
tool ps "#fake-hung-ps $R
exec sleep 900"
printf '#!/bin/sh\nexec -a fake-hung-ps-%s /bin/sleep 900\n' x >/dev/null
"$PY" "$OWNER" start >/dev/null; echo "  start exit=$?"; sleep 33
echo "  ps fakes waiting at 33 s (children of owner named sleep 900): $(pgrep -f 'sleep 900' -P "$("$PY" "$OWNER" status | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["pid"])')" | wc -l | tr -d ' ')"
OP=$("$PY" "$OWNER" status | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["pid"])')
stoptime; sleep 1; echo "  owner alive after stop: $(kill -0 $OP 2>/dev/null && echo yes || echo no)"; quota; samp

echo "=== C8 ps hangs only for the table read (CPU read still works): killed on no-progress, failure counted, quota continues"
fresh; export FM_DURATION_NO_PROGRESS_SECS=5; tool gh-axi "printf 'api_response:\n  body: used=13 reset=1794000000 limit=5000 remaining=4987\n'"
tool ps 'case "$*" in *lstart*command*) exec sleep 900;; *) exec /bin/ps "$@";; esac'
"$PY" "$OWNER" run --duration 18; echo "  run exit=$?"; quota; samp; unset FM_DURATION_NO_PROGRESS_SECS

echo "=== C9 SIGKILL of the owner, then a new start"
fresh; tool gh-axi "printf 'api_response:\n  body: used=15 reset=1794000000 limit=5000 remaining=4985\n'"
"$PY" "$OWNER" start > "$R/s"; cat "$R/s"; OP=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$R/s"); kill -9 "$OP"; sleep 0.3; "$PY" "$OWNER" status
"$PY" "$OWNER" start; echo "  restart exit=$?"; stoptime; "$PY" "$OWNER" records --kind owner | "$PY" -c 'import json,sys
for l in sys.stdin:
    r=json.loads(l); print("  owner",r.get("action"),r["run_id"][:8])'
echo "=== C10 concurrent starts share one owner"
fresh; tool gh-axi "printf 'api_response:\n  body: used=17 reset=1794000000 limit=5000 remaining=4983\n'"
for i in 1 2 3 4 5 6; do ( "$PY" "$OWNER" start >"$R/out$i" 2>&1; echo "$?" > "$R/rc$i" ) & done; wait
sleep 0.5; echo "  exits: $(cat "$R"/rc* | tr '\n' ' ')"; "$PY" "$OWNER" status; "$PY" "$OWNER" stop; "$PY" "$OWNER" records --kind owner | grep -c '"action": "start"' | sed 's/^/  owner starts recorded: /'
