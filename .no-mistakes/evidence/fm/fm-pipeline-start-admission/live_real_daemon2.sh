#!/usr/bin/env bash
# Real daemon state changes seen by real queued starts. Disposable NM_HOME only.
set -u
BIN=/Users/charlesabrooker/.no-mistakes/bin/no-mistakes
PYDIR=/Users/charlesabrooker/.pyenv/versions/3.13.6/bin
T=$LAB/realdaemon2; rm -rf "$T"; mkdir -p "$T/home/.no-mistakes" "$T/repo"; (cd "$T/repo"; git init -q .)
H=$T/home; NM=$H/.no-mistakes; DB=$NM/state.sqlite
cli() { env -i HOME="$H" NM_HOME="$NM" PATH="$PYDIR:/usr/bin:/bin" "$@"; }
ls_state() { ls "$NM" | grep state | tr '\n' ' '; echo; }
sql() { sqlite3 -cmd '.timeout 5000' "$DB" "$1"; }
up() { cli perl -e 'alarm 120; exec @ARGV' "$BIN" daemon run >>"$T/daemon.out" 2>>"$T/daemon.err" & DPID=$!; for _ in $(seq 1 100); do cli "$BIN" daemon status 2>/dev/null | grep -qi 'daemon running' && break; sleep 0.1; done; }
cd "$T/repo"
up
sql "INSERT OR IGNORE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r','$T/repo','u',1);"
for i in 1 2 3; do sql "INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES ('stale$i','r','b','h','b','running',1,1);"; done
echo "native: cores=$(sysctl -n hw.ncpu) loadavg=$(sysctl -n vm.loadavg)"
echo "== A. a start is queued at full count. The real daemon then stops cleanly."
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/a" 2>"$T/a.err" &
Q=$!
sleep 3; cat "$T/a.err"; echo "queued alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no)"
cli "$BIN" daemon stop --force 2>&1 | head -1; wait $DPID 2>/dev/null
echo "state files: $(ls_state)"
for _ in $(seq 1 40); do kill -0 $Q 2>/dev/null || break; sleep 0.25; done
if kill -0 $Q 2>/dev/null; then echo "queued start still waiting"; kill -KILL $Q; else wait $Q; echo "queued start ended exit=$? marker=$([ -e "$T/a" ] && echo yes || echo no)"; fi
cat "$T/a.err"
echo "== B. the real daemon dies by SIGKILL, with runs marked running."
up
sql "UPDATE runs SET status='running';"
echo "running rows: $(sql "SELECT count(*) FROM runs WHERE status='running'")"
pkill -KILL -f "$BIN daemon run" -P $DPID 2>/dev/null; kill -KILL $DPID 2>/dev/null; wait $DPID 2>/dev/null
RP=$(cat "$NM"/*.pid 2>/dev/null | head -1); ps -axo pid,command | grep "$T" | grep -v grep | head -3
echo "state files after SIGKILL: $(ls_state)"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/b" 2>"$T/b.err" &
Q=$!
sleep 3; cat "$T/b.err"; echo "queued alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no) marker=$([ -e "$T/b" ] && echo yes || echo no)"
echo "== C. the real daemon restarts. Its own recovery moves runs out of running."
up
for _ in $(seq 1 60); do kill -0 $Q 2>/dev/null || break; sleep 0.25; done
if kill -0 $Q 2>/dev/null; then echo "still queued; rows: $(sql "SELECT id,status FROM runs" | tr '\n' ' ')"; kill -KILL $Q; else wait $Q; echo "queued start exit=$? marker=$([ -e "$T/b" ] && echo yes || echo no)"; tail -1 "$T/b.err"; echo "rows: $(sql "SELECT id,status FROM runs" | tr '\n' ' ')"; fi
cli "$BIN" daemon stop --force 2>&1 | head -1; wait $DPID 2>/dev/null
echo "== leftovers:"; ps -axo pid,command | grep "$T" | grep -v grep; echo "(end)"
