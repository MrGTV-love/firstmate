#!/usr/bin/env bash
# S6: one owner, supported start/stop path, and DB guard, in a marked lab home with fake gh-axi.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
mklab; mkfix
trap 'python3 "$OWNER" stop >/dev/null 2>&1; cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
mkdir "$FIX/bin"; printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$FIX/bin/gh-axi"; chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
A="$FM_HOME/state/github-accounting"; own(){ python3 "$OWNER" "$@"; rc=$?; echo "  -> exit=$rc"; }
echo "--- status before"; own status
echo "--- start"; own start; P=$(python3 -c "import json;print(json.load(open('$A/owner.lock'))['pid'])")
echo "--- start again (idempotent, same run_id)"; own start
echo "--- second run refused"; own run --duration 1
echo "--- records while running is busy"; own records --kind owner
echo "--- prune while running is busy"; own prune
sleep 1
echo "--- owner count for this home: $(pgrep -f "$OWNER run" | while read p; do lsof -p "$p" 2>/dev/null | grep -q "$A/owner.lock" && echo "$p"; done | wc -l | tr -d ' ')"
echo "--- stop"; own stop; kill -0 "$P" 2>/dev/null && echo "owner alive after stop" || echo "owner pid $P gone after stop"
echo "--- stop again"; own stop
echo "--- start then SIGKILL then start: new run recovers"; own start; P2=$(python3 -c "import json;print(json.load(open('$A/owner.lock'))['pid'])"); kill -9 "$P2"; sleep 0.3; own status; own start; own stop
echo "--- zero-size db from an interrupted start: start recovers"
rm -f "$A/observations.sqlite"; : > "$A/observations.sqlite"; own start; own stop; python3 "$OWNER" records --kind owner | wc -l | sed 's/^/  owner rows: /'
python3 -c "import sqlite3;d=sqlite3.connect('$A/observations.sqlite');print('  application_id',hex(d.execute('PRAGMA application_id').fetchone()[0]),'auto_vacuum',d.execute('PRAGMA auto_vacuum').fetchone()[0])"
for case in foreign text; do
  rm -f "$A/observations.sqlite"
  if [ $case = foreign ]; then python3 -c "import sqlite3;d=sqlite3.connect('$A/observations.sqlite');d.execute('create table theirs(x)');d.execute(\"insert into theirs values('keep')\");d.commit()"; else printf 'not a database, keep me\n' > "$A/observations.sqlite"; fi
  B=$(shasum -a 256 "$A/observations.sqlite" | cut -d' ' -f1)
  echo "--- $case nonempty db: start refused, bytes unchanged"; own start
  [ "$B" = "$(shasum -a 256 "$A/observations.sqlite" | cut -d' ' -f1)" ] && echo "  bytes identical" || echo "  BYTES CHANGED"
  own status
done
echo "--- owner.log tail"; tail -2 "$A/owner.log"
rm -f "$A/observations.sqlite"; ln -s "$FIX/elsewhere" "$A/observations.sqlite"; echo "--- symlink db refused"; own start; [ -e "$FIX/elsewhere" ] && echo "  target CREATED" || echo "  target not created"
rm -f "$A/observations.sqlite"
