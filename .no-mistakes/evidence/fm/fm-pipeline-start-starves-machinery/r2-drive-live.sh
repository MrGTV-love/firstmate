#!/usr/bin/env bash
# Round-2 live driver at head f526ab865: drives the real bin/fm-cpu-pass.sh /
# fm-cpu-pass.py / fm-mem-guard.sh entrypoints in a disposable sandbox.
# Private HOME (fixture ~/.no-mistakes/state.sqlite), private FM_HOME, private
# FM_CPU_POOL_DIR, native memory facts via FM_MEMORY_FIXTURE_DIR, and stub
# `no-mistakes` and `agent` executables, so no real run or agent starts.
# Usage: r2-drive-live.sh <repo> <sandbox-root>
set -u
REPO=$1
ROOT=$2
rm -rf "$ROOT"; mkdir -p "$ROOT"
GIB=$((1024 * 1024 * 1024))

setup() { # <name>
  S="$ROOT/$1"
  mkdir -p "$S/home/.no-mistakes" "$S/fmhome/config" "$S/fmhome/state" "$S/pool" "$S/native" "$S/bin" "$S/wt" "$S/unmapped"
  echo 1 >"$S/fmhome/config/disk-free-floor"
  python3 - "$S/home/.no-mistakes/state.sqlite" "$S/wt" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT, worktree_dir TEXT, branch TEXT, intent TEXT, created_at INTEGER DEFAULT (CAST(strftime('%s', 'now') AS INTEGER)), launch_nonce TEXT, head_sha TEXT, submitted_head_sha TEXT)")
c.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER, round_started_at INTEGER)')
c.execute('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL)')
c.execute("CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, exit_status TEXT, session_key TEXT, agent TEXT DEFAULT 'claude')")
# One counted run at the review step whose worktree is $S/wt.
c.execute("INSERT INTO runs (id, status, repo_id, worktree_dir, branch) VALUES ('run-rev', 'running', 'repo1', ?, 'fm/rev')", (sys.argv[2],))
c.execute("INSERT INTO step_results VALUES ('s1', 'run-rev', 'review', 3, 'running', NULL, CAST(strftime('%s','now') AS INTEGER))")
c.commit()
PY
  pressure 1
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: %d.\nPages purgeable: 100.\nPages occupied by compressor: 32768.\n' $((40 * GIB / 16384 - 1100)) >"$S/native/vm_stat"
  echo '[{"pid":101,"ppid":1,"comm":"daemon","started":"s101","rss_bytes":1073741824,"fleet":false,"run":null}]' >"$S/native/processes.json"
  cat >"$S/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
echo "stub no-mistakes ran: \$*" >>"$S/stub.log"
exit 3
EOF
  cat >"$S/bin/agent" <<EOF
#!/usr/bin/env bash
read -r line
echo "stub agent ran in \$PWD with args: \$* stdin=\$line" >>"$S/stub.log"
exit 7
EOF
  chmod +x "$S/bin/no-mistakes" "$S/bin/agent"
  rm -f "$S/stub.log"
}

pressure() { printf '%d\n%s\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' $((128 * GIB)) "$1" >"$S/native/sysctl"; }

envrun() { # <dir> <command...>
  local dir=$1; shift
  ( cd "$dir" && env -u NO_MISTAKES_GATE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE -u FM_CPU_PASS_HELD -u FM_CPU_PASS_TOKENS -u FM_PIPELINE_START_PRIORITY \
      HOME="$S/home" FM_HOME="$S/fmhome" FM_CPU_POOL_DIR="$S/pool" FM_MEMORY_FIXTURE_DIR="$S/native" \
      FM_DURATION_FILE=off PATH="$S/bin:$PATH" "$@" )
}

show() { # <label> <rc>
  echo "exit=$2"
  echo "--- stderr"; cat "$S/$1.err"
  echo "--- stdout"; cat "$S/$1.out"
  echo "--- stub.log"; cat "$S/stub.log" 2>/dev/null || echo "(stub never ran)"
  echo "--- pool entries"; ls "$S/pool"
  echo
}

run() { # <label> <dir> <command...>
  local label=$1 dir=$2; shift 2
  echo "=== $label"
  echo "\$ (cd $dir) $*"
  echo "hello-stdin" | envrun "$dir" "$@" >"$S/$label.out" 2>"$S/$label.err"
  show "$label" $?
}

# G1: launch-gate from a directory no run records -> refuses visibly, agent never starts.
setup g1-unmapped
run g1 "$S/unmapped" bash "$REPO/bin/fm-cpu-pass.sh" launch-gate -- agent --print
echo "--- durable status records under FM_HOME"; grep -rh "launch-gate" "$S/fmhome" 2>/dev/null || echo "(none)"; echo

# G2: launch-gate from the worktree of a counted run at the review step -> passes through, stdin and exit status kept.
setup g2-review-passthrough
run g2 "$S/wt" bash "$REPO/bin/fm-cpu-pass.sh" launch-gate -- agent --print

# G3: ambiguous worktree: two runs record the same directory -> refuses.
setup g3-ambiguous
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"INSERT INTO runs (id,status,repo_id,worktree_dir,branch) VALUES ('run-dup','running','repo1',?,'fm/dup')\",(sys.argv[2],)); c.commit()" "$S/home/.no-mistakes/state.sqlite" "$S/wt"
run g3 "$S/wt" bash "$REPO/bin/fm-cpu-pass.sh" launch-gate -- agent --print

# G4: unreadable run database -> refuses.
setup g4-db-unreadable
printf 'not a sqlite database' >"$S/home/.no-mistakes/state.sqlite"
run g4 "$S/wt" bash "$REPO/bin/fm-cpu-pass.sh" launch-gate -- agent --print

# H1: pressure-2 hold: a fresh start waits while native pressure is 2, then is admitted by itself once it is 1.
setup h1-pressure-hold
pressure 2
echo "=== h1"
echo "\$ (cd $S/wt) bash bin/fm-cpu-pass.sh pipeline-start -- no-mistakes axi run --intent held   [native pressure 2]"
( echo x | envrun "$S/wt" bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- no-mistakes axi run --intent held >"$S/h1.out" 2>"$S/h1.err"; echo $? >"$S/h1.rc" ) &
sleep 8
echo "--- after 8 s at pressure 2: still running=$( [ -e "$S/h1.rc" ] && echo no || echo yes )"
echo "--- stub.log so far"; cat "$S/stub.log" 2>/dev/null || echo "(stub never ran)"
echo "--- stderr so far"; cat "$S/h1.err"
echo "--- flip native pressure to 1 at $(date -u +%H:%M:%SZ)"
pressure 1
for _ in $(seq 1 30); do [ -e "$S/h1.rc" ] && break; sleep 1; done
wait
show h1 "$(cat "$S/h1.rc" 2>/dev/null || echo still-running)"

# H2: control for H1: pressure 1 throughout -> admitted at once.
setup h2-pressure-control
run h2 "$S/wt" bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- no-mistakes axi run --intent control

# F1..F5: fresh-run shapes join admission; reattach shapes do not (--only-fresh).
setup f1-intent-equals
run f1 "$S/wt" python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- no-mistakes axi run --intent=fresh-eq
setup f2-rerun
run f2 "$S/wt" python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- no-mistakes rerun
setup f3-abs-path-intent-file
echo intent >"$S/intent.txt"
run f3 "$S/wt" python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- env "$S/bin/no-mistakes" axi run --intent-file "$S/intent.txt"
setup f4-reattach-status
run f4 "$S/wt" python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- no-mistakes axi status
setup f5-respond
run f5 "$S/wt" python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- no-mistakes axi respond --action approve
# M1: fresh start through fm-mem-guard.sh run joins pipeline-start; M2: another command keeps memory-only admission.
setup m1-memguard-fresh
run m1 "$S/wt" bash "$REPO/bin/fm-mem-guard.sh" run -- no-mistakes axi run --intent via-memguard
setup m2-memguard-other
run m2 "$S/wt" bash "$REPO/bin/fm-mem-guard.sh" run -- bash -c 'echo other-command-ran; exit 4'
