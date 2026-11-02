. "$(dirname "$0")/common.sh"
banner
BASEPATH=$PATH
for mode in stop verdict; do
R=$(mktemp -d "$(dirname "$0")/g.XXXX"); export FM_STATE_OVERRIDE="$R/state" FIXTURE_ROOT="$R" PATH="$R/bin:$BASEPATH"; mkdir -p "$R/state" "$R/bin"
printf '#!/bin/sh\n[ -e "$FIXTURE_ROOT/kids" ] && { printf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"; exit 0; }\necho $$ >> "$FIXTURE_ROOT/kids"\nsleep 600 &\necho $! >> "$FIXTURE_ROOT/kids"\nwait\n' > "$R/bin/gh-axi"; chmod +x "$R/bin/gh-axi"
if [ $mode = stop ]; then
  echo "=== G1 normal stop: quota child and its grandchild both end"
  "$PY" "$OWNER" start >/dev/null; sleep 2; "$PY" "$OWNER" stop
else
  echo "=== G2 no-progress verdict (labelled 5 s interval): quota child and its grandchild both end, owner keeps running"
  FM_DURATION_NO_PROGRESS_SECS=5 "$PY" "$OWNER" start >/dev/null; sleep 9; "$PY" "$OWNER" status | cut -c1-20
  alive=0; while read -r k; do kill -0 "$k" 2>/dev/null && alive=$((alive+1)); done < "$R/kids"; echo "  alive while owner still runs: $alive of $(wc -l < "$R/kids" | tr -d ' ')"
  "$PY" "$OWNER" stop; "$PY" "$OWNER" records --kind quota | "$PY" -c 'import json,sys
for l in sys.stdin:
    r=json.loads(l); print("  quota",r["status"],"reason",r.get("reason"),"exit",r.get("exit_code"))'
fi
sleep 0.5; alive=0; while read -r k; do kill -0 "$k" 2>/dev/null && { alive=$((alive+1)); kill -9 "$k"; }; done < "$R/kids"; echo "  alive after: $alive of $(wc -l < "$R/kids" | tr -d ' ')"
done
