#!/usr/bin/env bash
# S7: quota failures stay explicit. argv: <label>; real owner, real ps, disposable gh-axi state.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
LABEL=$1
mklab; mkfix
trap 'python3 "$OWNER" stop >/dev/null 2>&1; cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
PY=$(command -v python3)
mkdir "$FIX/bin"
case $LABEL in
  absent) export PATH="/usr/bin:/bin" ;;
  fails) printf '#!/bin/sh\necho "API rate limit already exceeded" >&2\nexit 1\n' > "$FIX/bin/gh-axi"; chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:/usr/bin:/bin" ;;
  malformed) printf '#!/bin/sh\nprintf "api_response:\\n  body: {oops: 1}\\n"\n' > "$FIX/bin/gh-axi"; chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:/usr/bin:/bin" ;;
  nulllimit) printf '#!/bin/sh\nprintf "api_response:\\n  body: used=7 reset=1794000000 limit=null remaining=null\\n"\n' > "$FIX/bin/gh-axi"; chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:/usr/bin:/bin" ;;
esac
"$PY" "$OWNER" start >/dev/null; echo "[$LABEL] start exit=$?"
sleep 17
echo "[$LABEL] status while running: $("$PY" "$OWNER" status | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["state"])')"
"$PY" "$OWNER" stop >/dev/null
"$PY" "$OWNER" records --kind quota | "$PY" -c '
import json,sys
for l in sys.stdin:
  r=json.loads(l); print("['"$LABEL"'] quota:",{k:r.get(k) for k in("status","reason","exit_code","graphql")})'
"$PY" "$OWNER" records --kind sampling | "$PY" -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin]; print("['"$LABEL"'] scans",sum(r["scans"] for r in rows),"failures",sum(r["failures"] for r in rows))'
