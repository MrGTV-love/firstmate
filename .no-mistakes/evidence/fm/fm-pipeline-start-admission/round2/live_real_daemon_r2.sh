#!/usr/bin/env bash
# Real no-mistakes daemon (foreground, disposable NM_HOME) + real admission CLI at head.
# Usage: LAB=<lab> REPO=<worktree> PYDIR=<dir holding python3> TAG=<name> live_real_daemon_r2.sh
# `daemon start/restart` and `update` are NOT driven: they install a launchd service, which is host state.
set -u
BIN=/Users/charlesabrooker/.no-mistakes/bin/no-mistakes
T=$LAB/rd-$TAG; rm -rf "$T"; mkdir -p "$T/home/.no-mistakes" "$T/repo" "$T/stub"; (cd "$T/repo"; git init -q .)
H=$T/home; NM=$H/.no-mistakes; DB=$NM/state.sqlite
cli() { env -i HOME="$H" NM_HOME="$NM" PATH="$T/stub:$PYDIR:/usr/bin:/bin" "$@"; }
ls_state() { ls -a "$NM" | grep state | tr '\n' ' '; echo; }
sql() { /opt/homebrew/bin/sqlite3 -cmd '.timeout 5000' "$DB" "$1" 2>/dev/null || sqlite3 -cmd '.timeout 5000' "$DB" "$1"; }
up() { cli perl -e 'alarm 120; exec @ARGV' "$BIN" daemon run >>"$T/daemon.out" 2>>"$T/daemon.err" & DPID=$!; for _ in $(seq 1 100); do cli "$BIN" daemon status 2>/dev/null | grep -qi 'daemon running' && break; sleep 0.1; done; }
down() { cli "$BIN" daemon stop --force 2>&1 | tail -1; wait $DPID 2>/dev/null; }
hash() { shasum -a 256 "$DB" | cut -c1-16; }
add() { for i in $(seq "$1" "$2"); do sql "INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES ('$3$i','r','b','h','b','running',1,1);"; done; }
start() { local m=$1; shift; cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/$m"; }
echo "python: $(cli python3 -c 'import sys,sqlite3;print(sys.executable,sys.version.split()[0],"sqlite",sqlite3.sqlite_version)')"
echo "native: cores=$(sysctl -n hw.ncpu) loadavg=$(sysctl -n vm.loadavg)"
cd "$T/repo"
up; sql "INSERT OR IGNORE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r','$T/repo','u',1);"
echo "state files with live daemon: $(ls_state)"
echo "== 1. clean real stop, empty host. Fresh start must read zero and run."
down; echo "daemon: $(cli "$BIN" daemon status 2>&1 | head -1)"; echo "state files: $(ls_state)"; h0=$(hash)
start one; echo "exit=$? marker=$([ -e "$T/one" ] && echo yes || echo no)"
echo "state files after start: $(ls_state) hash-same=$([ "$h0" = "$(hash)" ] && echo yes || echo no)"
echo "== 2. real stats exit also leaves no side files. Fresh start still runs."
cli "$BIN" stats >/dev/null 2>&1; echo "stats exit=$? files: $(ls_state)"
start two; echo "exit=$? marker=$([ -e "$T/two" ] && echo yes || echo no)"
echo "== 3. measured runner with fresh inputs on a stopped daemon. Client is a lab stub (this phase may not start pipelines)."
printf '#!/bin/sh\necho "$@" >> "%s/client.log"\n' "$T" > "$T/stub/no-mistakes"; chmod +x "$T/stub/no-mistakes"
cli env FM_DURATION_FILE="$T/d.jsonl" python3 "$REPO/bin/fm-duration.py" run --pipeline-priority machinery no-mistakes.run -- no-mistakes axi run --intent x; echo "exit=$? client=$(cat "$T/client.log")"
grep -c no-mistakes.run "$T/d.jsonl" | sed 's/^/samples=/'
rm "$T/stub/no-mistakes"
echo "== 4. real stop with rows still running. The stopped read must count them, not read zero."
up; add 1 3 stale; echo "rows: $(sql "SELECT count(*) FROM runs WHERE status='running'")"
down; echo "state files: $(ls_state)"; h1=$(hash)
start four 2>"$T/four.err" & Q=$!
sleep 3; cat "$T/four.err"; echo "alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no) marker=$([ -e "$T/four" ] && echo yes || echo no) hash-same=$([ "$h1" = "$(hash)" ] && echo yes || echo no)"
echo "== 5. real daemon returns. Its recovery moves the runs out of running. The queued start proceeds."
up
for _ in $(seq 1 80); do kill -0 $Q 2>/dev/null || break; sleep 0.25; done
if kill -0 $Q 2>/dev/null; then echo "STILL QUEUED rows: $(sql "SELECT id,status FROM runs" | tr '\n' ' ')"; pkill -KILL -P $Q; kill -KILL $Q; else wait $Q; echo "exit=$? marker=$([ -e "$T/four" ] && echo yes || echo no)"; tail -1 "$T/four.err"; echo "rows: $(sql "SELECT id,status FROM runs" | tr '\n' ' ')"; fi
echo "== 6. start queued at full count on a LIVE daemon. Real clean stop happens. Place is kept. Real restart releases it."
add 1 3 q
start six 2>"$T/six.err" & Q=$!
sleep 3; cat "$T/six.err"; echo "queued alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no)"
down; echo "state files: $(ls_state)"
sleep 3; echo "after stop alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no) marker=$([ -e "$T/six" ] && echo yes || echo no) refused=$(grep -c refused "$T/six.err")"
up
for _ in $(seq 1 80); do kill -0 $Q 2>/dev/null || break; sleep 0.25; done
if kill -0 $Q 2>/dev/null; then echo "STILL QUEUED"; pkill -KILL -P $Q; kill -KILL $Q; else wait $Q; echo "exit=$? marker=$([ -e "$T/six" ] && echo yes || echo no)"; cat "$T/six.err"; fi
echo "== 7. real SIGKILL with rows running. Side files stay. mode=ro path counts them."
add 1 3 k
RP=$(cli "$BIN" daemon status 2>&1 | sed -n 's/.*pid \([0-9]*\).*/\1/p' | head -1); echo "real daemon pid=$RP"; kill -KILL "$RP"; wait $DPID 2>/dev/null; sleep 0.3
ps -axo pid,command | grep "$T" | grep -v grep | head -3
echo "state files: $(ls_state)"
start seven 2>"$T/seven.err" & Q=$!
sleep 3; cat "$T/seven.err"; echo "alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no) marker=$([ -e "$T/seven" ] && echo yes || echo no)"
up
for _ in $(seq 1 80); do kill -0 $Q 2>/dev/null || break; sleep 0.25; done
if kill -0 $Q 2>/dev/null; then echo "STILL QUEUED"; pkill -KILL -P $Q; kill -KILL $Q; else wait $Q; echo "exit=$? marker=$([ -e "$T/seven" ] && echo yes || echo no)"; tail -1 "$T/seven.err"; fi
down
echo "== 8. missing database, stopped daemon: refuse. No file created."
mv "$DB" "$DB.gone"
start eight; echo "exit=$? marker=$([ -e "$T/eight" ] && echo yes || echo no) files: $(ls_state)"
mv "$DB.gone" "$DB"
echo "== leftovers:"; ps -axo pid,command | grep "$T" | grep -v grep; echo "(end)"
pkill -f "daemon log-sink --root $T" 2>/dev/null; exit 0
