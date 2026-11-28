#!/usr/bin/env bash
# Live driver for the merged disk-floor hunks of bin/fm-cpu-pass.py pipeline-start
# and bin/fm-mem-guard.sh run. Runs the real repository entrypoints against a
# disposable sandbox: a private HOME (its ~/.no-mistakes/state.sqlite is a fixture
# run database), a private FM_HOME with its own config/disk-free-floor, a private
# FM_CPU_POOL_DIR, native memory facts through FM_MEMORY_FIXTURE_DIR, and a stub
# `no-mistakes` first on PATH, so no real pipeline run can start. The real `df`
# measures the real volume; the floor file moves the threshold above or below it.
# Usage: drive-disk-floor.sh <repo> <sandbox-root>
set -u
REPO=$1
ROOT=$2
rm -rf "$ROOT"; mkdir -p "$ROOT"
GIB=$((1024 * 1024 * 1024))

setup() { # <name>
  S="$ROOT/$1"
  mkdir -p "$S/home/.no-mistakes" "$S/fmhome/config" "$S/pool" "$S/native" "$S/bin" "$S/wt"
  python3 - "$S/home/.no-mistakes/state.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER, repo_id TEXT, worktree_dir TEXT, branch TEXT, intent TEXT, created_at INTEGER DEFAULT (CAST(strftime('%s', 'now') AS INTEGER)), launch_nonce TEXT, head_sha TEXT, submitted_head_sha TEXT)")
c.execute('CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL, agent_pid INTEGER, round_started_at INTEGER)')
c.execute('CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL)')
c.execute("CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, purpose TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, exit_status TEXT, session_key TEXT, agent TEXT DEFAULT 'claude')")
c.commit()
PY
  printf '%d\n1\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' $((128 * GIB)) >"$S/native/sysctl"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: %d.\nPages purgeable: 100.\nPages occupied by compressor: 32768.\n' $((40 * GIB / 16384 - 1100)) >"$S/native/vm_stat"
  echo '[{"pid":101,"ppid":1,"comm":"daemon","started":"s101","rss_bytes":1073741824,"fleet":false,"run":null}]' >"$S/native/processes.json"
  cat >"$S/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
echo "stub no-mistakes ran: \$*" >>"$S/stub.log"
exit 3
EOF
  chmod +x "$S/bin/no-mistakes"
  rm -f "$S/stub.log"
}

floor() { printf '%s\n' "$1" >"$S/fmhome/config/disk-free-floor"; }

run() { # <label> <command...>
  local label=$1; shift
  echo "=== $label"
  echo "\$ $*"
  ( cd "$S/wt" && env -u NO_MISTAKES_GATE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE -u FM_CPU_PASS_HELD -u FM_CPU_PASS_TOKENS \
      HOME="$S/home" FM_HOME="$S/fmhome" FM_CPU_POOL_DIR="$S/pool" FM_MEMORY_FIXTURE_DIR="$S/native" \
      FM_DURATION_FILE=off PATH="$S/bin:$PATH" "$@" ) >"$S/$label.out" 2>"$S/$label.err"
  local rc=$?
  echo "exit=$rc"
  echo "--- stderr"; cat "$S/$label.err"
  echo "--- stdout"; cat "$S/$label.out"
  echo "--- stub.log"; cat "$S/stub.log" 2>/dev/null || echo "(stub never ran)"
  echo "--- pool entries"; ls "$S/pool"
  echo
}

FREE=$(bash "$REPO/bin/fm-disk-floor-lib.sh" free "$ROOT")
echo "real df: $FREE GiB free on the volume holding $ROOT"
echo "stub check: $(PATH="$ROOT/x/bin:$PATH" command -v no-mistakes || true)"
echo

setup s1-fresh-below; floor 999999
echo "stub resolves to: $(PATH="$S/bin:$PATH" command -v no-mistakes)"
run s1 python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start -- no-mistakes axi run --intent floor-fresh

setup s2-fresh-above; floor 1
run s2 bash "$REPO/bin/fm-cpu-pass.sh" pipeline-start -- no-mistakes axi run --intent floor-fresh

setup s3-reattach-below; floor 999999
run s3 python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start --only-fresh -- no-mistakes axi run --wait

setup s4-memguard-fresh-below; floor 999999
run s4 bash "$REPO/bin/fm-mem-guard.sh" run -- no-mistakes axi run --intent floor-memguard

setup s5-memguard-other-above; floor 1
run s5 bash "$REPO/bin/fm-mem-guard.sh" run -- bash -c 'echo other-command-ran; exit 4'

setup s6-malformed; floor 'twenty'
run s6 python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start -- no-mistakes axi run --intent floor-malformed

setup s7-duration-below; floor 999999
run s7 python3 "$REPO/bin/fm-duration.py" run --pipeline-priority machinery floor-key -- no-mistakes axi run --intent floor-duration

setup s7b-duration-reattach-below; floor 999999
run s7b python3 "$REPO/bin/fm-duration.py" run --pipeline-priority machinery floor-key -- no-mistakes axi run --wait

setup s8-nested-fresh-floor-drops; floor 1
# The outer fresh start is admitted above the floor; inside it the floor rises above
# the real free space, and a second fresh client reached through the interception
# meets the floor again (merge hunk M1 (2)).
run s8 python3 "$REPO/bin/fm-cpu-pass.py" pipeline-start -- bash -c "echo 999999 >'$S/fmhome/config/disk-free-floor'; no-mistakes axi run --intent nested-second; echo inner-exit=\$?"

setup s9-memguard-reattach-below; floor 999999
run s9 bash "$REPO/bin/fm-mem-guard.sh" run -- no-mistakes axi run --wait

setup s10-memguard-fresh-above; floor 1
run s10 bash "$REPO/bin/fm-mem-guard.sh" run -- no-mistakes axi run --intent floor-memguard-above
