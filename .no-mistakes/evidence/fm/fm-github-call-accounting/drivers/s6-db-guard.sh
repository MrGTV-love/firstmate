#!/usr/bin/env bash
# Guard github-accounting-foreign-database: nonempty foreign files are refused unchanged; a zero-size file is new.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
S="$FM_HOME/state/github-accounting"; DB="$S/observations.sqlite"; mkdir -p "$S"
try() { for c in start prune records; do python3 "$OWNER" "$c" >"$FIX/o" 2>&1; echo "  $c exit=$? $(tail -1 "$FIX/o")"; done
        python3 "$OWNER" run --duration 1 >"$FIX/o" 2>&1; echo "  run exit=$? $(tail -1 "$FIX/o")"; }
echo "=== foreign SQLite with a row"; /usr/bin/sqlite3 "$DB" "CREATE TABLE theirs(v); INSERT INTO theirs VALUES('keep me');"
b=$(shasum -a 256 "$DB"); try; a=$(shasum -a 256 "$DB"); [ "$a" = "$b" ] && echo "  bytes identical" || echo "  BYTES CHANGED"; /usr/bin/sqlite3 "$DB" 'SELECT * FROM theirs;'
python3 "$OWNER" status
rm -f "$DB"
echo "=== nonempty garbage"; printf 'not a database' > "$DB"
b=$(shasum -a 256 "$DB"); try; a=$(shasum -a 256 "$DB"); [ "$a" = "$b" ] && echo "  bytes identical" || echo "  BYTES CHANGED"
rm -f "$DB"
echo "=== symlink at the database path"; echo target > "$FIX/target"; ln -s "$FIX/target" "$DB"; try; cat "$FIX/target"; rm -f "$DB"
echo "=== symlink state directory"; mv "$S" "$S.real"; ln -s "$S.real" "$S"; python3 "$OWNER" status; echo "  status exit=$?"; rm -f "$S"; mv "$S.real" "$S"
echo "=== zero-size file (interrupted start): treated as new"; : > "$DB"; ls -l "$DB" | awk '{print "  size",$5}'
python3 "$OWNER" start; echo "  start exit=$?"; sleep 1; python3 "$OWNER" stop >/dev/null; /usr/bin/sqlite3 "$DB" 'PRAGMA application_id; SELECT count(*) FROM observations;'
echo "=== owner's own populated database reopens and keeps rows"
n=$(/usr/bin/sqlite3 "$DB" 'SELECT count(*) FROM observations;'); python3 "$OWNER" prune; echo "  prune exit=$?"; python3 "$OWNER" start >/dev/null; python3 "$OWNER" stop >/dev/null; m=$(/usr/bin/sqlite3 "$DB" 'SELECT count(*) FROM observations;'); echo "  rows before=$n after=$m"
echo "--- owner.log (fixed text only)"; sort "$S/owner.log" | uniq -c
pgrep -fl "$FM_HOME" | grep -v pgrep || echo "no lab processes left"
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
