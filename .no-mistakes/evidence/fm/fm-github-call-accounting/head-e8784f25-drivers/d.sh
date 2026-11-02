. "$(dirname "$0")/common.sh"
banner
BASEPATH=$PATH
fresh() { R=$(mktemp -d "$(dirname "$0")/d.XXXX"); export FM_STATE_OVERRIDE="$R/state"; mkdir -p "$R/state" "$R/bin"; export PATH="$R/bin:$BASEPATH"; printf "#!/bin/sh\nprintf 'api_response:\\\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\\\n'\n" > "$R/bin/gh-axi"; chmod +x "$R/bin/gh-axi"; G="$R/state/github-accounting"; DB="$G/observations.sqlite"; }
sha() { shasum -a 256 "$1" | cut -c1-16; }
pragma() { "$PY" -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); print("  application_id",hex(d.execute("PRAGMA application_id").fetchone()[0]),"auto_vacuum",d.execute("PRAGMA auto_vacuum").fetchone()[0],"tables",[r[0] for r in d.execute("select name from sqlite_master where type=\"table\"")])' "$1"; }
echo "=== D1 exact 48 h boundary (labelled frozen clock 1794000000; cutoff 1793827200), convention: strictly older expires"
fresh; "$PY" "$OWNER" prune; echo "unrelated" > "$R/state/unrelated"; echo keep > "$G/foreign-sibling"
"$PY" - "$DB" <<'P'
import sqlite3,sys,json
d=sqlite3.connect(sys.argv[1]); now=1794000000
for delta in (-1,0,1):
    s=now-172800+delta; d.execute("INSERT INTO observations VALUES (?,?,?)",(s,"fixture",json.dumps({"delta":delta,"observed_at":s,"kind":"fixture"})))
d.commit()
P
echo "before:"; "$PY" "$OWNER" records --kind fixture
printf 'import sys,time,runpy\ntime.time=lambda:1794000000\nsys.argv=[sys.argv[1],"prune"]\nrunpy.run_path(sys.argv[0],run_name="__main__")\n' > "$R/clock.py"
"$PY" "$R/clock.py" "$OWNER"; echo "prune exit=$?"
echo "after:"; "$PY" "$OWNER" records --kind fixture
echo "unrelated: $(cat "$R/state/unrelated"), sibling: $(cat "$G/foreign-sibling")"
echo "=== D2 running owner with real clock: start prunes expired, the 15 s tick prunes a row that crosses the 48 h line"
fresh; "$PY" "$OWNER" prune >/dev/null
"$PY" - "$DB" <<'P'
import sqlite3,sys,json,time
d=sqlite3.connect(sys.argv[1]); now=time.time()
for name,off in (("older",-172800-60),("crosses",-172800+8),("newer",-172800+600)):
    s=now+off; d.execute("INSERT INTO observations VALUES (?,?,?)",(s,"fixture",json.dumps({"name":name,"observed_at":s,"kind":"fixture"})))
d.commit()
P
list() { "$PY" -c 'import sqlite3,sys,json; d=sqlite3.connect(sys.argv[1]); print("  ",sys.argv[2],[json.loads(r[0])["name"] for r in d.execute("select payload from observations where kind=\"fixture\" order by observed")])' "$DB" "$1"; }
list "before start"; "$PY" "$OWNER" start >/dev/null; sleep 3; list "3 s after start"; sleep 18; list "21 s after start"; "$PY" "$OWNER" stop >/dev/null
"$PY" "$OWNER" records --kind fixture | wc -l | sed 's/^/  rows after stop: /'
echo "=== D3 zero-size database, as an interrupted start leaves"
fresh; mkdir -p "$G"; : > "$DB"; chmod 644 "$DB"; ls -l "$DB" | awk '{print "  before",$1,$5}'
"$PY" "$OWNER" start; echo "  start exit=$?"; sleep 2; "$PY" "$OWNER" status; "$PY" "$OWNER" stop; pragma "$DB"; ls -l "$DB" | awk '{print "  after",$1}'; "$PY" "$OWNER" records --kind owner | wc -l | sed 's/^/  owner rows: /'
fresh; mkdir -p "$G"; : > "$DB"; "$PY" "$OWNER" prune; echo "  prune on zero-size exit=$?"; pragma "$DB"
fresh; mkdir -p "$G"; : > "$DB"; "$PY" "$OWNER" records; echo "  records on zero-size exit=$? (no rows)"; pragma "$DB"
echo "=== D4 file with bytes and no owner id, foreign SQLite, foreign id: refused and byte-identical"
check() { b=$(sha "$DB"); for c in start prune records "run --duration 1"; do "$PY" "$OWNER" $c >"$R/o" 2>&1; echo "  $c exit=$? : $(tail -1 "$R/o")"; done; a=$(sha "$DB"); [ "$a" = "$b" ] && echo "  bytes unchanged $a" || echo "  CHANGED $b -> $a"; "$PY" "$OWNER" status; }
fresh; mkdir -p "$G"; printf 'not a database, one line of data\n' > "$DB"; echo " non-database bytes:"; check
fresh; mkdir -p "$G"; "$PY" -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("create table customer(v)"); d.execute("insert into customer values (1)"); d.commit()' "$DB"; echo " foreign sqlite, application_id 0:"; check
fresh; mkdir -p "$G"; "$PY" -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("PRAGMA application_id=1234"); d.execute("create table customer(v)"); d.commit()' "$DB"; echo " foreign sqlite, other application_id:"; check
echo "=== D5 symlinks: refused, target unchanged"
fresh; mkdir -p "$G"; echo target > "$R/t"; ln -s "$R/t" "$DB"; for c in start prune; do "$PY" "$OWNER" $c >"$R/o" 2>&1; echo "  db symlink $c exit=$? : $(tail -1 "$R/o")"; done; echo "  target: $(cat "$R/t")"
fresh; mkdir -p "$R/elsewhere"; ln -s "$R/elsewhere" "$G"; "$PY" "$OWNER" start >"$R/o" 2>&1; echo "  state-dir symlink start exit=$? : $(tail -1 "$R/o")"; echo "  elsewhere entries: $(ls "$R/elsewhere" | wc -l | tr -d ' ')"
fresh; mkdir -p "$G"; : > "$R/z"; ln -s "$R/z" "$DB"; "$PY" "$OWNER" start >"$R/o" 2>&1; echo "  symlink to zero-size file start exit=$? : $(tail -1 "$R/o")"; echo "  target size: $(wc -c < "$R/z" | tr -d ' ')"
echo "=== D6 owner's populated database survives a restart: no rows lost"
fresh; "$PY" "$OWNER" run --duration 1; n1=$("$PY" "$OWNER" records | wc -l | tr -d ' '); "$PY" "$OWNER" run --duration 1; n2=$("$PY" "$OWNER" records --kind owner | wc -l | tr -d ' '); echo "  rows after first run $n1; owner rows after second run $n2 (want 4)"; pragma "$DB"
