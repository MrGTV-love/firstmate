#!/usr/bin/env bash
# Real no-mistakes daemon (foreground, disposable NM_HOME) + real admission CLI.
# No service install, no pipeline, no operator state. Requires: LAB, REPO.
set -u
BIN=/Users/charlesabrooker/.no-mistakes/bin/no-mistakes
PYDIR=/Users/charlesabrooker/.pyenv/versions/3.13.6/bin
T=$LAB/realdaemon; rm -rf "$T"; mkdir -p "$T/home/.no-mistakes" "$T/repo"; (cd "$T/repo"; git init -q .)
H=$T/home; NM=$H/.no-mistakes; DB=$NM/state.sqlite
cli() { env -i HOME="$H" NM_HOME="$NM" PATH="$PYDIR:/usr/bin:/bin" "$@"; }
ls_state() { ls "$NM" | grep state | tr '\n' ' '; echo; }
sql() { sqlite3 -cmd '.timeout 5000' "$DB" "$1"; }
# Admission reads DB and native cores/load only. Expected limit from native cores.
echo "native: cores=$(sysctl -n hw.ncpu) loadavg=$(sysctl -n vm.loadavg)"
echo "== 1. real daemon up, in foreground, disposable NM_HOME"
cd "$T/repo"
cli perl -e 'alarm 120; exec @ARGV' "$BIN" daemon run >"$T/daemon.out" 2>"$T/daemon.err" &
DPID=$!
for _ in $(seq 1 100); do cli "$BIN" daemon status 2>/dev/null | grep -qi 'running\|pid' && break; sleep 0.1; done
cli "$BIN" daemon status 2>&1 | head -3
echo "state files with live daemon: $(ls_state)"
sql "INSERT OR IGNORE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r','/lab','u',1);"
add() { for i in $(seq "$1" "$2"); do sql "INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES ('live$i','r','b','h','b','running',1,1);"; done; }
add 1 2
echo "== 2. two counted runs, real daemon live: third start"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/third" ; echo "exit=$? marker=$([ -e "$T/third" ] && echo yes || echo no)"
add 3 3
echo "== 3. three counted runs, real daemon live: fourth start queues"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/fourth" 2>"$T/fourth.err" &
Q=$!
sleep 3
cat "$T/fourth.err"; echo "alive=$(kill -0 $Q 2>/dev/null && echo yes || echo no) marker=$([ -e "$T/fourth" ] && echo yes || echo no)"
sql "UPDATE runs SET status='completed' WHERE id='live3';"
wait $Q; echo "after release exit=$? marker=$([ -e "$T/fourth" ] && echo yes || echo no)"; tail -1 "$T/fourth.err"
sql "UPDATE runs SET status='completed' WHERE status='running';"
echo "== 4. clean daemon stop with the real CLI"
cli "$BIN" daemon stop 2>&1 | head -3
wait $DPID 2>/dev/null
echo "daemon status: $(cli "$BIN" daemon status 2>&1 | head -1)"
echo "state files after clean stop: $(ls_state)"
echo "== 5. fresh start with the daemon stopped"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/after-stop"; echo "exit=$? marker=$([ -e "$T/after-stop" ] && echo yes || echo no)"
echo "state files: $(ls_state)"
echo "== 6. does a read-only real CLI call heal it?"
(cd "$T/repo"; cli "$BIN" stats >/dev/null 2>&1; echo "stats exit=$?")
echo "state files after real stats: $(ls_state)"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/after-stats"; echo "exit=$? marker=$([ -e "$T/after-stats" ] && echo yes || echo no)"
echo "== 7. real daemon back up: fresh start works again"
cli perl -e 'alarm 60; exec @ARGV' "$BIN" daemon run >"$T/daemon2.out" 2>"$T/daemon2.err" &
DPID=$!
for _ in $(seq 1 100); do cli "$BIN" daemon status 2>/dev/null | grep -qi 'running\|pid' && break; sleep 0.1; done
echo "state files: $(ls_state)"
cli bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- touch "$T/after-restart"; echo "exit=$? marker=$([ -e "$T/after-restart" ] && echo yes || echo no)"
cli "$BIN" daemon stop 2>&1 | head -1
wait $DPID 2>/dev/null
echo "== leftover processes for this home:"; ps -axo pid,command | grep "$T" | grep -v grep; echo "(end)"
