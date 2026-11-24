#!/usr/bin/env bash
# Portable regression for the omp identity rule (bin/fm-omp-identity.py): the
# installed omp can run as its Bun runtime on an entry script, so its process is
# named bun and only its executable path, script and role identify it.
# The one trusted installed identity is held in bin/fm-omp-identity.py
# (installed_identity()) and no environment variable moves it; this suite points the rule
# at the scratch tree $TREE through the test-only runner of tests/lib.sh fm_test_omp_root_shim
# (FM_TEST_OMP_ROOT, read only by that runner).
# Real processes only: a compiled stand-in "bun" under a scratch runtime root, a
# launcher that execs it as the host's does, and pseudo-terminal or pipe standard
# input. No harness runs and no model is called. macOS only (libproc facts).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Darwin ] || ! command -v cc >/dev/null 2>&1; then
  printf 'skip: omp identity fixtures need macOS libproc and a C compiler\n'
  exit 0
fi
TMP=$(fm_test_tmproot fm-omp-identity)
TMP=$(cd "$TMP" && pwd -P) # the rule compares raw argument bytes with a canonical path, so the fixtures live under one
HOLDERS=()
cleanup() {
  local pid
  for pid in "${HOLDERS[@]:-}"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup EXIT
IDENT="$ROOT/bin/fm-omp-identity.py"
PROCINFO="$ROOT/bin/fm-proc-info.py"

# --- the installed tree, as the host builds it --------------------------------
build_tree() { # <root> -> a runtime stub, an entry script and a launcher
  local root=$1 bun=$1/runtime/node_modules/@oven/bun-darwin-aarch64/bin
  mkdir -p "$bun" "$root/src/node_modules/@oh-my-pi/pi-coding-agent/src"
  cat > "$root/stub.c" <<'C'
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static volatile sig_atomic_t switched;
static void on_usr1(int sig) { (void)sig; switched = 1; }
int main(int c, char **v) {
  for (int i = 1; i < c; i++) if (!strcmp(v[i], "--version")) { puts("9.9.9"); return 0; }
  signal(SIGUSR1, on_usr1);
  alarm(900);
  for (;;) {
    pause();
    if (!switched) continue;
    switched = 0;
    /* a session switch in this same process: open the next file; optionally release the old descriptor */
    const char *next = getenv("SWITCH_TO"), *old = getenv("HELD_FD");
    if (next) open(next, O_WRONLY | O_APPEND);
    if (getenv("SWITCH_RELEASE") && old) close(atoi(old));
  }
}
C
  cc -o "$bun/bun" "$root/stub.c" || fail "could not compile the runtime stand-in"
  printf '{"name":"@oven/bun-darwin-aarch64"}\n' > "${bun%/bin}/package.json"
  local package="$root/src/node_modules/@oh-my-pi/pi-coding-agent"
  printf '{"name":"@oh-my-pi/pi-coding-agent"}\n' > "$package/package.json"
  : > "$package/src/cli.ts"
  : > "$package/src/cli-commands.ts"
  : > "$package/src/main.ts"
  cat > "$root/omp" <<EOF
#!/bin/sh
# stand-in omp launcher shaped like the host's
R=$root
exec "\$R/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun" "\$R/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts" "\$@"
EOF
  chmod +x "$root/omp"
}
TREE="$TMP/tree"; build_tree "$TREE"
ORIG_PATH=$PATH # without the root shim: what production sees
fm_test_omp_root_shim "$TMP/root-shim" || fail "could not build the test-only root shim"
PATH="$TMP/root-shim:$PATH"; export PATH
export FM_TEST_OMP_ROOT="$TREE"
BUN="$TREE/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun"
SCRIPT="$TREE/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
REAL_BUN=$(python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BUN")
# A native omp stand-in: the compiled stub under the name omp.
NATIVE_BIN="$TMP/native-bin"
mkdir -p "$NATIVE_BIN"
cp "$BUN" "$NATIVE_BIN/omp"
native_first() { PATH="$NATIVE_BIN:$PATH" "$@"; }

# spawn.py holds a process's standard input (tty, open or empty pipe, null) and
# execs argv with an optional different executable, then stays alive until killed.
cat > "$TMP/spawn.py" <<'PY'
import os, pty, signal, subprocess, sys, time
kind, pidfile, executable = sys.argv[1], sys.argv[2], sys.argv[3] or None
argv = sys.argv[4:]
keep = []
if kind == "tty":
    master, slave = pty.openpty(); keep.append(master); stdin = slave
elif kind == "pipe":
    stdin = subprocess.PIPE
elif kind == "pipe-empty":
    read, write = os.pipe(); os.close(write); stdin = read
else:
    stdin = subprocess.DEVNULL
hold = os.environ.get("HOLD_FILE")
held = [os.open(hold, os.O_WRONLY | os.O_APPEND)] if hold else []
env = dict(os.environ)
if held:
    env["HELD_FD"] = str(held[0])
child = subprocess.Popen(argv, executable=executable, stdin=stdin, stdout=subprocess.DEVNULL, pass_fds=held, env=env)
signal.signal(signal.SIGTERM, lambda *_: (child.kill(), os._exit(0)))
open(pidfile, "w").write(str(child.pid))
time.sleep(600)
PY
# pair.py starts two identical launches back to back, so both start inside one whole
# second unless the clock ticks between them (the caller then retries).
cat > "$TMP/pair.py" <<'PY'
import os, pty, signal, subprocess, sys, time
files, argv = sys.argv[1:3], sys.argv[3:]
masters, children = [], []
for path in files:
    master, slave = pty.openpty(); masters.append(master)
    children.append(subprocess.Popen(argv, stdin=slave, stdout=subprocess.DEVNULL))
for path, child in zip(files, children):
    open(path, "w").write(str(child.pid))
signal.signal(signal.SIGTERM, lambda *_: ([c.kill() for c in children], os._exit(0)))
time.sleep(600)
PY
FIXTURE_N=0
spawn() { # <stdin-kind> <executable|-> <argv...> -> $SPAWNED (pid) after the exec settled
  local kind=$1 exe=$2 file
  shift 2
  FIXTURE_N=$((FIXTURE_N + 1)); file="$TMP/pid.$FIXTURE_N"
  [ "$exe" != - ] || exe=
  python3 -I "$TMP/spawn.py" "$kind" "$file" "$exe" "$@" &
  HOLDERS+=($!)
  for _ in $(seq 1 100); do [ -s "$file" ] && break; sleep 0.05; done
  [ -s "$file" ] || fail "fixture process was not started"
  SPAWNED=$(cat "$file")
  for _ in $(seq 1 100); do
    [ "$(python3 -I "$PROCINFO" exe "$SPAWNED" 2>/dev/null)" != /bin/sh ] && break
    sleep 0.05
  done
  HOLDERS+=("$SPAWNED")
}
launch() { # <stdin-kind> <omp args...> : the launcher execs the stand-in, as the host's does
  local kind=$1; shift
  spawn "$kind" /bin/sh /bin/sh "$TREE/omp" "$@"
}
verdict() { # <pid> -> exit code of the interactive verdict (stdout/stderr kept in $OUT)
  OUT=$(python3 -I "$IDENT" interactive "$1" 2>&1); return $?
}
assert_verdict() { # <expected-code> <pid> <message>
  local rc=0
  verdict "$2" || rc=$?
  [ "$rc" -eq "$1" ] || fail "$3: expected exit $1, got $rc ($OUT)"
}

# --- 1. the process facts the rule rests on, from the kernel ---------------------
test_proc_info_facts_are_kernel_facts() {
  local pid out boundary
  boundary=$'two words\nand a newline'
  launch tty --system-prompt "$boundary" ''
  pid=$SPAWNED
  [ "$(python3 -I "$PROCINFO" exe "$pid")" = "$REAL_BUN" ] || [ "$(python3 -I "$PROCINFO" exe "$pid")" = "$BUN" ] \
    || fail "exe must be the kernel executable path, got $(python3 -I "$PROCINFO" exe "$pid")"
  out=$(python3 -I "$PROCINFO" argv "$pid")
  [ "$(printf '%s' "$out" | python3 -I -c 'import json,sys;a=json.load(sys.stdin);print(len(a),a[-2]==sys.argv[1],a[-1]=="")' "$boundary")" = "5 True True" ] \
    || fail "argv must keep every boundary, including a newline and an empty argument: $out"
  [ "$(python3 -I "$PROCINFO" stdin "$pid")" = tty ] || fail "a pseudo-terminal standard input is tty"
  launch pipe --no-title; [ "$(python3 -I "$PROCINFO" stdin "$SPAWNED")" = pipe ] || fail "a pipe standard input is pipe"
  launch null --no-title; [ "$(python3 -I "$PROCINFO" stdin "$SPAWNED")" = other ] || fail "/dev/null is not a terminal"
  python3 -I "$PROCINFO" exe 2000000000 >/dev/null 2>&1 && fail "a nonexistent pid must print nothing and fail"
  python3 -I "$PROCINFO" stdin 2000000000 >/dev/null 2>&1 && fail "a nonexistent pid must fail for stdin"
  pass "proc-info exe, argv, stdin read kernel facts with argument boundaries and fail for a missing process"
}

# --- 2. incarnation: two processes inside one whole second ---------------------
same_second_pair() { # sets PAIR_A and PAIR_B started inside one whole second
  local a b file_a file_b
  for _ in 1 2 3 4 5 6 7 8; do
    FIXTURE_N=$((FIXTURE_N + 1)); file_a="$TMP/pair.$FIXTURE_N.a"; file_b="$TMP/pair.$FIXTURE_N.b"
    python3 -I "$TMP/pair.py" "$file_a" "$file_b" /bin/sh "$TREE/omp" --no-title &
    HOLDERS+=($!)
    for _ in $(seq 1 100); do [ -s "$file_a" ] && [ -s "$file_b" ] && break; sleep 0.05; done
    a=$(cat "$file_a"); b=$(cat "$file_b")
    HOLDERS+=("$a" "$b")
    for _ in $(seq 1 100); do
      [ "$(python3 -I "$PROCINFO" exe "$a" 2>/dev/null)" != /bin/sh ] && [ "$(python3 -I "$PROCINFO" exe "$b" 2>/dev/null)" != /bin/sh ] && break
      sleep 0.05
    done
    if [ "$(python3 -I "$PROCINFO" lstart "$a")" = "$(python3 -I "$PROCINFO" lstart "$b")" ]; then
      PAIR_A=$a PAIR_B=$b; return 0
    fi
  done
  fail "could not start two scratch processes inside one whole second"
}
distinguishes() { # <start-id function> : succeeds when it tells the same-second pair apart
  local a b
  a=$("$1" "$PAIR_A"); b=$("$1" "$PAIR_B")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}
test_incarnation_tells_same_second_processes_apart() {
  local a1 a2 mutant_distinguishes=no
  # shellcheck source=bin/fm-launch-proof-lib.sh
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-launch-proof-lib.sh"
  same_second_pair
  [ "$(python3 -I "$PROCINFO" lstart "$PAIR_A")" = "$(python3 -I "$PROCINFO" lstart "$PAIR_B")" ] \
    || fail "the pair must share one whole-second lstart or the case is vacuous"
  distinguishes fm_launch_proof_pid_start_id || fail "the delivered start identity must differ for two processes started in one second"
  a1=$(fm_launch_proof_pid_start_id "$PAIR_A"); a2=$(fm_launch_proof_pid_start_id "$PAIR_A")
  fm_launch_proof_same_incarnation "$a1" "$a2" || fail "one process read twice must be the same incarnation"
  fm_launch_proof_same_incarnation "$a1" "$(fm_launch_proof_pid_start_id "$PAIR_B")" \
    && fail "the comparator must treat the fine start identities of the pair as different incarnations"
  fm_launch_proof_same_incarnation '' "$a1" && fail "an unreadable incarnation never matches"
  # A whole-second (PID, lstart) source is the mutant this check must catch.
  whole_second() { python3 -I "$PROCINFO" lstart "$1"; }
  ! distinguishes whole_second && mutant_distinguishes=no || mutant_distinguishes=yes
  [ "$mutant_distinguishes" = no ] || fail "a whole-second start source must fail the same-second check"
  pass "incarnation: the delivered start identity separates same-second processes; a whole-second source cannot"
}

# --- session binding: the process must hold the task's session file open --------------
test_session_binding_needs_the_session_file_held_open_for_writing() {
  local t="$TMP/session" pid rc
  mkdir -p "$t"; : > "$t/task.jsonl"; : > "$t/personal.jsonl"
  HOLD_FILE="$t/task.jsonl" launch tty --no-title; pid=$SPAWNED
  python3 -I "$IDENT" holds "$pid" "$t/task.jsonl" || fail "a process holding the task session open for writing is tied to it"
  rc=0; python3 -I "$IDENT" holds "$pid" "$t/personal.jsonl" || rc=$?
  [ "$rc" -eq 1 ] || fail "a registration naming a session the process does not hold is not proof (exit $rc)"
  # the wrong-live-session process: the same argv and cwd, but it holds a different session
  HOLD_FILE="$t/personal.jsonl" launch tty --no-title
  rc=0; python3 -I "$IDENT" holds "$SPAWNED" "$t/task.jsonl" || rc=$?
  [ "$rc" -eq 1 ] || fail "a process that switched to another session is not tied to the task session (exit $rc)"
  # a process holding nothing, and a process that cannot be read
  launch tty --no-title
  rc=0; python3 -I "$IDENT" holds "$SPAWNED" "$t/task.jsonl" || rc=$?
  [ "$rc" -eq 1 ] || fail "a process with no session open is not tied to the task session (exit $rc)"
  rc=0; python3 -I "$IDENT" holds 2000000000 "$t/task.jsonl" || rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable process leaves the session unresolved (exit $rc)"
  # replay over captured facts: the same answer without a live process
  python3 -I "$IDENT" facts "$pid" > "$t/facts.json" || fail "facts must be capturable"
  python3 -I "$IDENT" holds --facts "$t/facts.json" "$t/task.jsonl" || fail "captured facts keep the holding"
  rc=0; python3 -I "$IDENT" holds --facts "$t/facts.json" "$t/personal.jsonl" || rc=$?
  [ "$rc" -eq 1 ] || fail "captured facts keep the refusal for another session (exit $rc)"
  pass "session binding: only a process holding the task session open for writing is tied to it; another session, none and unreadable are not"
}

# --- 3. the installed identity, read from the process's own tree -----------------
tree_launch() { # <tree> <args...> -> SPAWNED: the tree's own runtime on its own script, on a terminal
  local tree=$1
  shift
  spawn tty /bin/sh /bin/sh "$tree/omp" "$@"
}
assert_tree() { # <expected-interactive-exit> <expected-writer-exit> <pid> <message>
  local rc=0
  python3 -I "$IDENT" interactive "$3" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$1" ] || fail "$4: expected interactive exit $1, got $rc"
  rc=0
  python3 -I "$IDENT" writer "$3" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$2" ] || fail "$4: expected writer exit $2, got $rc"
}
test_identity_comes_from_the_process_tree() {
  local t="$TMP/trees" name script_pkg runtime_pkg old_pid
  mkdir -p "$t"
  runtime_pkg=runtime/node_modules/@oven/bun-darwin-aarch64
  script_pkg=src/node_modules/@oh-my-pi/pi-coding-agent
  # the installed tree itself, and a complete omp-shaped tree at another path
  tree_launch "$TREE" --no-title
  assert_tree 0 0 "$SPAWNED" "the process of the one installed tree is the interactive agent"
  build_tree "$t/good"
  tree_launch "$t/good" --no-title
  assert_tree 1 0 "$SPAWNED" "a complete omp-shaped tree at another path is refused as the interactive agent but may still own a record"
  # the same foreign tree is recognized when it is the installed identity: the identity is the only difference
  FM_TEST_OMP_ROOT="$t/good" assert_tree 0 0 "$SPAWNED" "the same tree is the interactive agent once it is the installed identity"
  # a Bun on another script of the installed tree, and on another script of a foreign tree
  spawn tty "$BUN" "$BUN" "$TREE/$script_pkg/src/main.ts" --no-title
  assert_tree 1 1 "$SPAWNED" "a bun on src/main.ts of the installed tree is another program"
  spawn tty "$t/good/$runtime_pkg/bin/bun" "$t/good/$runtime_pkg/bin/bun" "$t/good/$script_pkg/src/main.ts" --no-title
  assert_tree 1 1 "$SPAWNED" "a bun on src/main.ts of a complete foreign tree is another program"
  # the installed identity cannot be derived: nothing is admitted and a live process may still own a record
  tree_launch "$TREE" --no-title
  FM_TEST_OMP_ROOT="$t/no-such-root" assert_tree 2 0 "$SPAWNED" "no installed tree: unresolved, never interactive"
  FM_TEST_OMP_ROOT=relative/root assert_tree 2 0 "$SPAWNED" "a relative installed root is no identity"
  # a trusted root that is itself a link must not re-anchor the identity on whatever it points at
  build_tree "$t/real-root"
  ln -s "$t/real-root" "$t/root-link"
  tree_launch "$t/real-root" --no-title
  FM_TEST_OMP_ROOT="$t/root-link" assert_tree 2 0 "$SPAWNED" "a redirected installed root is no identity, whatever complete tree it points at"
  FM_TEST_OMP_ROOT="$t/real-root" assert_tree 0 0 "$SPAWNED" "the same tree named directly is the installed identity (the legitimate pair)"
  build_tree "$t/linked"; build_tree "$t/away"
  rm "$t/linked/$script_pkg/src/cli.ts"
  ln -s "$t/away/$script_pkg/src/cli.ts" "$t/linked/$script_pkg/src/cli.ts"
  tree_launch "$t/linked" --no-title
  FM_TEST_OMP_ROOT="$t/linked" assert_tree 2 0 "$SPAWNED" "an installed script that links out of its root is no identity"

  # What the files around a process say NOW refuses adoption but is never proof the process is not an omp
  # session writer: a running Bun keeps what it loaded after those files change.
  build_tree "$t/wrong-script-package"
  printf '{"name":"some-other-package"}\n' > "$t/wrong-script-package/$script_pkg/package.json"
  tree_launch "$t/wrong-script-package" --no-title
  assert_tree 1 0 "$SPAWNED" "a wrong script package name refuses adoption and may still own a record"

  build_tree "$t/wrong-runtime-package"
  printf '{"name":"not-bun"}\n' > "$t/wrong-runtime-package/$runtime_pkg/package.json"
  tree_launch "$t/wrong-runtime-package" --no-title
  assert_tree 1 0 "$SPAWNED" "a wrong runtime package name refuses adoption and may still own a record"

  for name in cli-commands.ts main.ts; do
    build_tree "$t/missing-$name"
    rm "$t/missing-$name/$script_pkg/src/$name"
    tree_launch "$t/missing-$name" --no-title
    assert_tree 1 0 "$SPAWNED" "a missing $name marker refuses adoption and may still own a record"
  done

  build_tree "$t/no-package"
  rm "$t/no-package/$script_pkg/package.json"
  tree_launch "$t/no-package" --no-title
  assert_tree 1 0 "$SPAWNED" "a cli.ts outside any omp package refuses adoption and may still own a record"

  # D1: a live writer from a previously complete tree, whose files change only after it started
  build_tree "$t/old"
  tree_launch "$t/old" --no-title; old_pid=$SPAWNED
  FM_TEST_OMP_ROOT="$t/old" assert_tree 0 0 "$old_pid" "the control: the old tree's process, while its tree is complete, is the installed agent"
  assert_tree 1 0 "$old_pid" "the control: the old tree's process is not the installed identity, and may own a record"
  rm "$t/old/$script_pkg/src/cli-commands.ts"
  assert_tree 1 0 "$old_pid" "a live writer whose tree lost cli-commands.ts after it started may still own a record"
  printf '{"name":"rewritten"}\n' > "$t/old/$script_pkg/package.json"
  assert_tree 1 0 "$old_pid" "a live writer whose package.json was rewritten after it started may still own a record"
  rm "$t/old/$runtime_pkg/package.json"
  assert_tree 1 0 "$old_pid" "a live writer whose runtime package.json was removed after it started may still own a record"

  build_tree "$t/malformed"
  printf 'not json' > "$t/malformed/$script_pkg/package.json"
  tree_launch "$t/malformed" --no-title
  assert_tree 2 0 "$SPAWNED" "a package.json that cannot be parsed is unresolved, and may still own a record"

  build_tree "$t/unreadable"
  chmod 000 "$t/unreadable/$script_pkg/package.json"
  if [ ! -r "$t/unreadable/$script_pkg/package.json" ]; then
    tree_launch "$t/unreadable" --no-title
    assert_tree 2 0 "$SPAWNED" "an unreadable package.json is unresolved, and may still own a record"
  fi
  chmod 644 "$t/unreadable/$script_pkg/package.json"

  build_tree "$t/removed"
  tree_launch "$t/removed" --no-title
  rm "$t/removed/$script_pkg/src/cli.ts"
  assert_tree 2 0 "$SPAWNED" "a script that no longer exists is unresolved, and a live process of it may still own a record"

  build_tree "$t/not-bun"
  cp "$t/not-bun/$runtime_pkg/bin/bun" "$t/not-bun/$runtime_pkg/bin/node"
  spawn tty "$t/not-bun/$runtime_pkg/bin/node" "$t/not-bun/$runtime_pkg/bin/node" "$t/not-bun/$script_pkg/src/cli.ts" --no-title
  assert_tree 1 1 "$SPAWNED" "the genuine script on an executable not named bun is another program"

  mkdir -p "$t/loose/bin"; cp "$BUN" "$t/loose/bin/bun"
  spawn tty "$t/loose/bin/bun" "$t/loose/bin/bun" "$t/good/$script_pkg/src/cli.ts" --no-title
  assert_tree 1 0 "$SPAWNED" "the genuine script on a bun outside a runtime package refuses adoption and may still own a record"
  pass "identity: the process's own tree decides; a wrong package or a missing marker is foreign, and unreadable evidence is unresolved"
}

test_captured_facts_replay_without_the_tree() {
  local t="$TMP/replay" rc
  mkdir -p "$t"
  build_tree "$t/tree"
  export FM_TEST_OMP_ROOT="$t/tree"
  tree_launch "$t/tree" --no-title
  python3 -I "$IDENT" facts "$SPAWNED" > "$t/good.json" || fail "facts must be capturable"
  tree_launch "$t/tree" __omp_worker_daemon_broker
  python3 -I "$IDENT" facts "$SPAWNED" > "$t/worker.json" || fail "facts must be capturable"
  cp "$BUN" "$t/foreign-runtime"
  spawn tty "$t/foreign-runtime" "$t/tree/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun" \
    "$t/tree/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts" --no-title
  python3 -I "$IDENT" facts "$SPAWNED" > "$t/foreign.json" || fail "facts must be capturable"
  python3 -I -c 'import json,sys;f=json.load(open(sys.argv[1]));f["installed"]["runtime"]+=".other";json.dump(f,open(sys.argv[2],"w"))' "$t/good.json" "$t/other-install.json"
  python3 -I -c 'import json,sys;f=json.load(open(sys.argv[1]));f.pop("installed");json.dump(f,open(sys.argv[2],"w"))' "$t/good.json" "$t/no-installed.json"
  python3 -I -c 'import json,sys;f=json.load(open(sys.argv[1]));f.pop("exe");json.dump(f,open(sys.argv[2],"w"))' "$t/good.json" "$t/no-exe.json"
  python3 -I -c 'import json,sys;f=json.load(open(sys.argv[1]));f.pop("evidence");json.dump(f,open(sys.argv[2],"w"))' "$t/good.json" "$t/no-evidence.json"
  rm -rf "$t/tree"
  export FM_TEST_OMP_ROOT="$TREE"
  replay() { # <file> <interactive-exit> <writer-exit> <message>
    rc=0; python3 -I "$IDENT" interactive --facts "$t/$1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$2" ] || fail "replay: $4: expected interactive exit $2, got $rc"
    rc=0; python3 -I "$IDENT" writer --facts "$t/$1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$3" ] || fail "replay: $4: expected writer exit $3, got $rc"
  }
  replay good.json 0 0 "the genuine process replays as recognized with its tree gone"
  replay worker.json 1 0 "a worker role replays as refused, and may still own a record"
  replay foreign.json 1 0 "a foreign executable presenting the installed words replays as refused, and may still own a record (its path is read now, not held by the kernel)"
  replay no-exe.json 2 0 "a capture without the executable path is unresolved"
  replay no-evidence.json 2 0 "a capture without the tree evidence is unresolved"
  replay missing.json 2 0 "a capture that cannot be read is unresolved"
  replay other-install.json 1 0 "a capture whose recorded installed identity is another runtime is refused, and may still own a record"
  replay no-installed.json 2 0 "a capture without its installed identity is unresolved"
  pass "replay: a capture is judged from its stored evidence alone, with the tree gone"
}

# --- 4. the role, from the installed CLI's own dispatch -------------------------
ROLE_BASE=
role() { # <expected-exit> <stdin> <description> -- <omp args...>
  local expected=$1 stdin=$2 description=$3 rc=0
  shift 4
  if [ -z "$ROLE_BASE" ]; then
    launch tty --no-title
    ROLE_BASE="$TMP/role-base.json"
    python3 -I "$IDENT" facts "$SPAWNED" > "$ROLE_BASE" || fail "role: the base facts must be capturable"
  fi
  python3 -I - "$ROLE_BASE" "$TMP/role.json" "$stdin" "$@" <<'PY' || fail "role: could not write the case facts"
import json, sys
facts = json.load(open(sys.argv[1]))
facts["argv"] = facts["argv"][:2] + sys.argv[4:]
facts["stdin"] = None if sys.argv[3] == "-" else sys.argv[3]
json.dump(facts, open(sys.argv[2], "w"))
PY
  python3 -I "$IDENT" interactive --facts "$TMP/role.json" >"$TMP/role.out" 2>&1 || rc=$?
  [ "$rc" -eq "$expected" ] || fail "role: $description: expected exit $expected, got $rc ($(cat "$TMP/role.out"))"
}
test_role_follows_the_cli_dispatch() {
  local launch_args=(--config /x/session.yml --auto-approve --cwd /wt --config /x/fallback.yml --no-title --model m --thinking high 'Read the brief and begin')
  role 0 tty "the canonical worker launch" -- "${launch_args[@]}"
  role 0 tty "extra non-selector arguments" -- --resume /s.jsonl "${launch_args[@]}"
  role 1 tty "a daemon broker worker role" -- __omp_worker_daemon_broker
  role 1 tty "the tiny inference worker role" -- __omp_worker_tiny_inference
  role 1 tty "the js eval process worker role" -- __omp_worker_js_eval_process
  role 1 tty "a worker role behind a global profile flag" -- --profile work __omp_worker_daemon_broker
  role 0 tty "a selector-looking value of a string flag is not a selector" -- --system-prompt __omp_worker_daemon_broker 'hi'
  role 1 tty "print mode" -- -p 'hi'
  role 1 tty "long print flag" -- --print 'hi'
  role 1 tty "protocol mode" -- --mode rpc
  role 1 tty "protocol mode, equals form" -- --mode=rpc
  role 1 tty "split protocol mode words" -- --system-prompt hello --mode rpc
  role 0 tty "one argument value that merely contains --mode rpc" -- --system-prompt 'hello --mode rpc'
  role 1 tty "acp without terminal auth" -- acp
  role 0 tty "acp with terminal auth" -- acp --acp-terminal-auth
  role 0 tty "the launch with terminal auth" -- --acp-terminal-auth --no-title
  role 1 tty "a long-lived non-launch subcommand" -- browser-relay
  role 1 tty "a non-launch subcommand behind leading global flags" -- --no-title --cwd /wt browser-relay
  role 0 tty "the same leading flags on the genuine launch" -- --no-title --cwd /wt 'hello'
  role 1 tty "help" -- --help
  role 1 tty "alias installation" -- --alias x
  role 1 pipe "implicit headless mode: a prompt with piped standard input" -- "${launch_args[@]}"
  role 1 pipe "implicit headless mode: a positional prompt with a pipe" -- 'do this'
  role 1 other "standard input is not a terminal" -- "${launch_args[@]}"
  role 2 - "standard input cannot be read is unresolved, never a terminal" -- "${launch_args[@]}"
  # the divergence between signals: the same argv flips with only the standard-input type
  role 0 tty "control for the standard-input divergence" -- "${launch_args[@]}"
  pass "role: worker roles, print, protocol, acp, subcommands and headless input are refused; the worker launch is admitted"
}

# --- 5. real processes ---------------------------------------------------------
test_live_processes_are_judged_by_their_actual_executable_and_script() {
  local foreign t="$TMP/live" pid
  mkdir -p "$t"
  # the compliant restored agent
  launch tty --config /x.yml --auto-approve --cwd /wt --no-title 'Read the brief'
  assert_verdict 0 "$SPAWNED" "the installed runtime on the installed script with a terminal is admitted"
  pid=$SPAWNED
  [ "$(printf '%s' "$OUT" | jq -r .start)" = "$(python3 -I "$PROCINFO" startid "$pid")" ] || fail "the verdict must carry the process start identity"
  # a shell still running the launcher before its exec
  spawn tty /bin/sh /bin/sh -c 'sleep 600' "$TREE/omp"
  assert_verdict 1 "$SPAWNED" "a shell is not the runtime"
  # a foreign executable that presents the installed words as its argv
  cp "$BUN" "$t/foreign-runtime"
  spawn tty "$t/foreign-runtime" "$BUN" "$SCRIPT" --no-title
  foreign=$SPAWNED
  assert_verdict 1 "$foreign" "a foreign executable using the installed paths as argument words is refused"
  # the right script run by an interpreter that is not the installed runtime
  spawn tty "$t/foreign-runtime" "$t/foreign-runtime" "$SCRIPT" --no-title
  assert_verdict 1 "$SPAWNED" "the right script on another interpreter is refused"
  # the installed runtime on another script, one named cli.ts outside the tree, and a link to elsewhere
  mkdir -p "$t/elsewhere"; : > "$t/elsewhere/cli.ts"; : > "$t/elsewhere/other.ts"
  ln -s "$t/elsewhere/cli.ts" "$t/link-cli.ts"
  spawn tty "$BUN" "$BUN" "$t/elsewhere/other.ts" --no-title; assert_verdict 1 "$SPAWNED" "a bun on any other script is refused"
  spawn tty "$BUN" "$BUN" "$t/elsewhere/cli.ts" --no-title; assert_verdict 1 "$SPAWNED" "a cli.ts outside the installed tree is refused"
  spawn tty "$BUN" "$BUN" "$t/link-cli.ts" --no-title; assert_verdict 1 "$SPAWNED" "a link whose real path is elsewhere is refused"
  # a path that only contains the root's name
  mkdir -p "$t/omp-promax-fix/src/node_modules/@oh-my-pi/pi-coding-agent/src"; : > "$t/omp-promax-fix/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  spawn tty "$BUN" "$BUN" "$t/omp-promax-fix/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  assert_verdict 1 "$SPAWNED" "a lookalike path is refused"
  # roles and standard input on real processes
  launch tty __omp_worker_daemon_broker; assert_verdict 1 "$SPAWNED" "the real worker-role process is refused"
  launch tty --mode rpc; assert_verdict 1 "$SPAWNED" "the real protocol process is refused"
  launch pipe --no-title 'a prompt'; assert_verdict 1 "$SPAWNED" "headless print mode (open pipe, nothing written) is refused by its standard-input type"
  launch pipe-empty --no-title; assert_verdict 1 "$SPAWNED" "empty closed input is not a terminal"
  launch tty --system-prompt 'hello --mode rpc'; assert_verdict 0 "$SPAWNED" "one argument value containing --mode rpc is the interactive agent"
  launch tty --system-prompt hello --mode rpc; assert_verdict 1 "$SPAWNED" "separate --mode rpc words are protocol mode"
  # an exited process names nothing
  assert_verdict 2 2000000000 "a missing process is unresolved"
  pass "live processes: actual executable, resolved script and role decide; foreign look-alikes, helpers and headless runs are refused"
}

test_fail_closed_runs_recover_when_the_evidence_returns() {
  local t="$TMP/fail" pid helper foreign rc=0 script_pkg=src/node_modules/@oh-my-pi/pi-coding-agent
  mkdir -p "$t"
  build_tree "$t/tree"
  export FM_TEST_OMP_ROOT="$t/tree"
  spawn tty /bin/sh /bin/sh "$t/tree/omp" --no-title; pid=$SPAWNED
  spawn tty /bin/sh /bin/sh "$t/tree/omp" __omp_worker_daemon_broker; helper=$SPAWNED
  cp "$BUN" "$t/foreign-runtime"
  spawn tty "$t/foreign-runtime" "$t/foreign-runtime" "$t/tree/$script_pkg/src/cli.ts" --no-title; foreign=$SPAWNED
  mv "$t/tree/$script_pkg/package.json" "$t/saved.json"
  printf 'not json' > "$t/tree/$script_pkg/package.json"
  rc=0; verdict "$pid" || rc=$?
  [ "$rc" -eq 2 ] || fail "unreadable evidence must leave the compliant process unresolved (exit $rc)"
  rc=0; verdict "$helper" || rc=$?
  [ "$rc" -ne 0 ] || fail "a helper must be refused with the evidence unreadable"
  rc=0; verdict "$foreign" || rc=$?
  [ "$rc" -ne 0 ] || fail "a foreign process must be refused with the evidence unreadable"
  mv "$t/saved.json" "$t/tree/$script_pkg/package.json"
  # The tree changed after these processes started, so the compliant one cannot be tied to what it loaded:
  # it stays unresolved. A fresh launch from the restored tree is admitted again.
  assert_verdict 2 "$pid" "the process that started before the tree changed stays unresolved once the evidence returns"
  spawn tty /bin/sh /bin/sh "$t/tree/omp" --no-title
  assert_verdict 0 "$SPAWNED" "a fresh launch from the restored tree is admitted"
  assert_verdict 1 "$helper" "a helper stays refused once the evidence returns"
  assert_verdict 1 "$foreign" "a foreign process stays refused once the evidence returns"
  export FM_TEST_OMP_ROOT="$TREE"
  pass "fail closed: unreadable evidence admits nothing; a process that started before the tree changed stays unresolved, and a fresh launch is admitted once the evidence returns"
}

# --- 6. record ownership and the library predicates -----------------------------
test_record_writer_check_fails_open_and_adoption_target_fails_closed() {
  local pid dead
  # shellcheck source=bin/fm-launch-proof-lib.sh
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-launch-proof-lib.sh"
  ps() { # a fake process table over scratch pids only, answering through the kernel reader
    case "$*" in
      '-p '*' -o comm=') python3 -I "$PROCINFO" comm "$2" ;;
      '-p '*' -o args=') python3 -I "$PROCINFO" args "$2" ;;
      *) return 1 ;;
    esac
  }
  launch tty --config /x.yml --no-title 'brief'; pid=$SPAWNED
  fm_launch_proof_pid_is_omp "$pid" || fail "the installed Bun agent is an omp adoption target"
  [ -n "$FM_LAUNCH_PROOF_OMP_START" ] || fail "the predicate must hand back the incarnation it accepted"
  fm_launch_proof_pid_may_own_record "$pid" || fail "the installed Bun agent may own a record"
  launch tty __omp_worker_daemon_broker; pid=$SPAWNED
  fm_launch_proof_pid_is_omp "$pid" && fail "a worker-role Bun process is never an adoption target"
  fm_launch_proof_pid_may_own_record "$pid" || fail "a worker-role Bun process of the installed omp may still own a record, whatever its role"
  # unreadable evidence: a live process the fake table names as bun but the kernel cannot read
  ps() { case "$*" in '-p 2000000000 -o comm=') echo /x/bun ;; '-p 2000000000 -o args=') echo '/x/bun /x/cli.ts' ;; *) return 1 ;; esac; }
  fm_launch_proof_pid_is_omp 2000000000 && fail "unreadable identity evidence is not an adoption target"
  fm_launch_proof_pid_may_own_record 2000000000 || fail "unreadable identity evidence is not proof that no writer owns the record"
  # D2: a live writer whose process-table entry cannot be read is not an absent writer
  launch tty --config /x.yml --no-title 'brief'; pid=$SPAWNED
  ps() { return 1; }
  fm_launch_proof_pid_may_own_record "$pid" || fail "a live Bun omp whose table entry cannot be read may still own the record"
  (exit 0) & dead=$!
  wait "$dead"
  fm_launch_proof_pid_may_own_record "$dead" && fail "a proven-dead pid is no writer even when the table cannot be read"
  fm_launch_proof_pid_may_own_record 2000000001 && fail "a pid the kernel reports gone is no writer"
  # genuinely unrelated programs and dead pids may be replaced
  spawn tty /bin/sh /bin/sh -c 'sleep 600'
  ps() { case "$*" in '-p '*' -o comm=') python3 -I "$PROCINFO" comm "$2" ;; '-p '*' -o args=') python3 -I "$PROCINFO" args "$2" ;; esac; }
  fm_launch_proof_pid_may_own_record "$SPAWNED" && fail "an unrelated shell is not a record writer"
  mkdir -p "$TMP/fb"; cp "$BUN" "$TMP/fb/bun"
  spawn tty "$TMP/fb/bun" "$TMP/fb/bun" /elsewhere/cli.ts
  fm_launch_proof_pid_may_own_record "$SPAWNED" && fail "a positively read foreign bun is an unrelated reused pid"
  ps() { return 1; }
  fm_launch_proof_pid_may_own_record 2000000001 && fail "a dead pid is no writer"
  pass "writer check fails open on any role or unreadable identity; adoption target fails closed; unrelated and dead pids may be replaced"
}

test_verdict_does_not_depend_on_the_omp_on_path() {
  local pid foreign dead rc
  # shellcheck source=bin/fm-launch-proof-lib.sh
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-launch-proof-lib.sh"
  # shellcheck disable=SC2329 # Invoked only through native_first, which shellcheck cannot follow; the sourced library calls it.
  ps() { case "$*" in '-p '*' -o comm=') python3 -I "$PROCINFO" comm "$2" ;; '-p '*' -o args=') python3 -I "$PROCINFO" args "$2" ;; *) return 1 ;; esac; }
  [ "$(native_first python3 -I -c 'import shutil;print(shutil.which("omp"))')" = "$NATIVE_BIN/omp" ] \
    || fail "the native stand-in must come first on PATH or the case is vacuous"
  launch tty --config /x.yml --no-title 'brief'; pid=$SPAWNED
  mkdir -p "$TMP/native-fb"; cp "$BUN" "$TMP/native-fb/bun"
  spawn tty "$TMP/native-fb/bun" "$TMP/native-fb/bun" /elsewhere/cli.ts; foreign=$SPAWNED
  native_first fm_launch_proof_pid_is_omp "$pid" || fail "a native omp first on PATH must not stop recognition of the Bun agent"
  native_first fm_launch_proof_pid_may_own_record "$pid" || fail "a live Bun omp with a native omp first on PATH may own the record"
  rc=0; native_first fm_launch_proof_pid_may_own_record "$foreign" || rc=$?
  [ "$rc" -ne 0 ] || fail "a positively foreign Bun stays unrelated with a native omp first on PATH"
  (exit 0) & dead=$!
  wait "$dead"
  rc=0; native_first fm_launch_proof_pid_may_own_record "$dead" || rc=$?
  [ "$rc" -ne 0 ] || fail "a proven-dead recorded writer stays free with a native omp first on PATH"
  pass "PATH: a native omp first changes nothing: the Bun agent is recognized, a foreign Bun stays unrelated and a dead writer stays free"
}

test_a_helper_failure_is_never_proof_of_no_writer() {
  local t="$TMP/crash" pid foreign rc
  mkdir -p "$t/no-python" "$t/fb"
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  cat > "$t/run.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("oi", sys.argv[1])
oi = importlib.util.module_from_spec(spec); spec.loader.exec_module(oi)
_installed = oi.installed_identity
oi.installed_identity = lambda: _installed(os.environ["FM_TEST_OMP_ROOT"])  # the test-only root seam
kind, args = sys.argv[2], sys.argv[3:]
def boom(*_args, **_kwargs):
    raise RuntimeError("simulated crash")
def no_strict_type_error(*_args, **_kwargs):
    raise TypeError("realpath() got an unexpected keyword argument 'strict'")
real = os.path.realpath
if kind == "decide-crash":
    oi.decide = boom
elif kind == "realpath-type-error":
    os.path.realpath = no_strict_type_error
elif kind == "python-3.9-realpath":
    os.path.realpath = lambda path: real(path)
sys.exit(oi.main(["fm-omp-identity.py", *args]))
PY
  launch tty --no-title; pid=$SPAWNED
  cp "$BUN" "$t/fb/bun"
  spawn tty "$t/fb/bun" "$t/fb/bun" /elsewhere/cli.ts; foreign=$SPAWNED
  for kind in decide-crash realpath-type-error; do
    rc=0; python3 -I "$t/run.py" "$IDENT" "$kind" writer "$pid" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "writer under $kind must answer may own (exit $rc)"
    rc=0; python3 -I "$t/run.py" "$IDENT" "$kind" writer "$foreign" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "writer under $kind has no proof even for a foreign Bun (exit $rc)"
    rc=0; python3 -I "$t/run.py" "$IDENT" "$kind" interactive "$pid" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "interactive under $kind is unresolved, never admitted (exit $rc)"
  done
  python3 -I "$t/run.py" "$IDENT" python-3.9-realpath interactive "$pid" >/dev/null 2>&1 \
    || fail "a Python whose realpath has no strict argument must still recognize the agent"
  rc=0; python3 -I "$t/run.py" "$IDENT" python-3.9-realpath writer "$foreign" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a Python whose realpath has no strict argument must still prove a foreign Bun (exit $rc)"
  PATH="$t/no-python" fm_agent_process_bun_may_be_omp bun bun "$foreign" \
    || fail "with python3 missing a Bun process must read as may own"
  rc=0; fm_agent_process_bun_may_be_omp bun bun "$foreign" || rc=$?
  [ "$rc" -eq 1 ] || fail "with python3 present the same foreign Bun is unrelated, or the case is vacuous (exit $rc)"
  pass "helper failure: a crash, a TypeError or a missing python3 is may-own in the writer check and never admits an adoption"
}

# --- 7. the Herdr descendant walk ---------------------------------------------------
test_descendant_walk_never_reports_a_live_bun_agent_as_agent_free() {
  local dir="$TMP/walk" bunpid foreignpid out oldbun oldscript oldpid
  mkdir -p "$dir"
  # shellcheck source=bin/backends/herdr.sh
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/backends/herdr.sh"
  launch tty --config /x.yml --no-title 'brief'; bunpid=$SPAWNED
  mkdir -p "$dir/fb"; cp "$BUN" "$dir/fb/bun"
  spawn tty "$dir/fb/bun" "$dir/fb/bun" /elsewhere/cli.ts; foreignpid=$SPAWNED
  fm_backend_herdr_cli() { # a pane whose shell is in the foreground
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"zsh","argv0":"zsh","argv":["zsh"]}]}}}'
  }
  # the pane's descendant table and a ps that reports it
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *-axo*) printf '4242 1 zsh\n'; [ -z "${WALK_PID:-}" ] || printf '%s 4242 %s\n' "$WALK_PID" "${WALK_COMM:-bun}" ;;
  *-p*-o\ args=*) printf '%s\n' "${WALK_ARGS:-bun /x/cli.ts}" ;;
esac
SH
  chmod +x "$dir/ps"
  walk() { FM_HERDR_PS_BIN="$dir/ps" WALK_PID=$1 WALK_COMM=$2 WALK_ARGS=$3 fm_backend_herdr_pane_process_state_sample fmtest w1:p1; }
  out=$(walk '' bun ''); [ "$out" = shell ] || fail "a pane with no descendants is agent-free (shell), got $out"
  out=$(walk "$bunpid" "$BUN" "$BUN $SCRIPT --no-title"); [ "$out" = other ] || fail "a live restored Bun agent descendant must keep the pane occupied, got $out"
  out=$(walk 2000000000 /x/bun '/x/bun /x/cli.ts'); [ "$out" = other ] || fail "a Bun descendant whose identity cannot be read must keep the pane occupied, got $out"
  out=$(walk "$foreignpid" "$dir/fb/bun" "$dir/fb/bun /elsewhere/cli.ts"); [ "$out" = shell ] || fail "an unrelated Bun job keeps today's outcome, got $out"
  out=$(walk 4243 less 'less x'); [ "$out" = shell ] || fail "a non-Bun descendant keeps today's outcome, got $out"
  out=$(native_first walk "$bunpid" "$BUN" "$BUN $SCRIPT --no-title"); [ "$out" = other ] || fail "a live Bun omp descendant keeps the pane occupied with a native omp first on PATH, got $out"
  out=$(native_first walk "$foreignpid" "$dir/fb/bun" "$dir/fb/bun /elsewhere/cli.ts"); [ "$out" = shell ] || fail "an unrelated Bun job keeps today's outcome with a native omp first on PATH, got $out"
  out=$(native_first walk '' bun ''); [ "$out" = shell ] || fail "a pane with no descendants stays agent-free with a native omp first on PATH, got $out"
  # D1: a live Bun omp from a previously complete tree, whose files change only after it started
  build_tree "$dir/old"
  oldbun="$dir/old/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun"
  oldscript="$dir/old/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  spawn tty "$oldbun" "$oldbun" "$oldscript" --no-title; oldpid=$SPAWNED
  out=$(walk "$oldpid" "$oldbun" "$oldbun $oldscript --no-title"); [ "$out" = other ] || fail "the old tree's live omp keeps the pane occupied while its tree is complete, got $out"
  rm "$dir/old/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli-commands.ts"
  out=$(walk "$oldpid" "$oldbun" "$oldbun $oldscript --no-title"); [ "$out" = other ] || fail "a live omp whose tree lost cli-commands.ts after it started must still keep the pane occupied, got $out"
  # N1: its script link retargeted to a foreign file after it started
  mv "$oldscript" "$oldscript.orig"
  ln -s main.ts "$oldscript"
  out=$(walk "$oldpid" "$oldbun" "$oldbun $oldscript --no-title"); [ "$out" = other ] || fail "a live omp whose script link was retargeted after it started must still keep the pane occupied, got $out"
  pass "walk: a live or unreadable Bun descendant keeps the pane occupied; an unrelated Bun job and an empty shell keep today's outcome"
}

write_dispatch_tables() { # <tree>: source files shaped like the installed CLI's, generated from the role port's own tables
  local src=$1/src/node_modules/@oh-my-pi/pi-coding-agent/src
  mkdir -p "$src/cli"
  python3 -I - "$IDENT" "$src" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("oi", sys.argv[1])
oi = importlib.util.module_from_spec(spec); spec.loader.exec_module(oi)
src = sys.argv[2]
open(src + "/cli-commands.ts", "w").write("".join('\t\tname: "%s",\n' % n for n in sorted(oi.SUBCOMMANDS)))
strings = "".join('\t"%s": setter,\n' % n for n in sorted(oi.STRING_VALUE_FLAGS))
valueless = "".join('\t"%s",\n' % n for n in sorted(oi.VALUELESS_FLAGS))
open(src + "/cli/flag-tables.ts", "w").write("export const STRING_SETTERS = {\n" + strings + "};\nexport const OPTIONAL_FLAGS = new Set([]);\nexport const VALUELESS_FLAGS = new Set([\n" + valueless + "]);\n")
PY
}
make_guard_copy() { # <dest>: a scratch copy of the live guard beside the real helpers, so its logic runs on a stand-in tree
  mkdir -p "$1/tests"
  cp -R "$ROOT/bin" "$1/bin"
  cp "$ROOT/tests/lib.sh" "$1/tests/"
  cp "$ROOT/tests/fm-omp-identity-live-e2e.test.sh" "$1/tests/fm-omp-identity-live-e2e.test.sh"
  return 0
}
test_production_ignores_fm_omp_installed_root() {
  # An environment variable that moves the trusted root would let any caller point the
  # identity at another tree. Production reads none: the stand-in tree is the installed
  # identity only through the test-only root shim (the control), never through the old variable.
  local out rc facts_root
  tree_launch "$TREE" --no-title
  FM_TEST_OMP_ROOT="$TREE" assert_tree 0 0 "$SPAWNED" "control: through the test-only root shim the stand-in tree is the installed identity"
  out=$(env -u FM_TEST_OMP_ROOT FM_OMP_INSTALLED_ROOT="$TREE" PATH="$ORIG_PATH" python3 -I "$IDENT" interactive "$SPAWNED" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "FM_OMP_INSTALLED_ROOT in the environment must not make a stand-in tree the installed identity: $out"
  facts_root=$(env -u FM_TEST_OMP_ROOT FM_OMP_INSTALLED_ROOT="$TREE" PATH="$ORIG_PATH" python3 -I "$IDENT" facts "$SPAWNED" \
    | python3 -I -c 'import json,sys;i=json.load(sys.stdin).get("installed");print(i["root"] if i else "none")') || fail "facts must still be readable"
  [ "$facts_root" != "$TREE" ] || fail "the installed root in the facts must not follow FM_OMP_INSTALLED_ROOT"
  pass "production ignores FM_OMP_INSTALLED_ROOT: the variable neither admits a stand-in nor moves the reported installed root"
}
test_live_guard_starts_a_bun_omp_or_fails_naming_the_launcher_variable() {
  local base realbase out mutant copy notables
  base=$(fm_test_base_path_sans "$PATH" omp)
  realbase=$(fm_test_base_path_sans "$ORIG_PATH" omp) # no root shim: what an operator's guard run sees
  write_dispatch_tables "$TREE"
  # The real guard, with no root shim and the old override variable set: production ignores
  # it, so a stand-in launcher is compared with the real installed identity and never certified.
  guard() { # <PATH> <env assignments...>
    local path=$1
    shift
    env -u FM_LIVE -u FM_TEST_OMP_ROOT FM_OMP_IDENTITY_LIVE=1 FM_OMP_INSTALLED_ROOT="$TREE" "$@" PATH="$path" bash "$ROOT/tests/fm-omp-identity-live-e2e.test.sh" 2>&1
  }
  if out=$(guard "$TREE:$NATIVE_BIN:$realbase"); then
    fail "the real live guard must not certify a stand-in whatever FM_OMP_INSTALLED_ROOT says: $out"
  fi
  assert_not_contains "$out" "checked " "a run that certified nothing claims no check"
  if out=$(guard "$TREE:$NATIVE_BIN:$realbase" FM_OMP_IDENTITY_LIVE_STANDIN=1); then
    fail "an ambient stand-in marker must not make the live guard certify a stand-in: $out"
  fi
  assert_not_contains "$out" "checked " "a run under a stand-in marker claims no check"
  out=$(env -u FM_LIVE FM_OMP_IDENTITY_LIVE=0 PATH="$TREE:$base" bash "$ROOT/tests/fm-omp-identity-live-e2e.test.sh" 2>&1) || fail "an explicit opt-out must end cleanly: $out"
  assert_contains "$out" "skip: live: disabled by FM_OMP_IDENTITY_LIVE=0" "an opt-out is reported as an opt-out"
  assert_not_contains "$out" "checked " "an opt-out claims no check"
  assert_not_contains "$out" "ok - " "an opt-out is never a pass"
  if out=$(env -u FM_LIVE -u FM_TEST_OMP_ROOT FM_OMP_IDENTITY_LIVE=1 PATH="$NATIVE_BIN:$base" bash "$ROOT/tests/fm-omp-identity-live-e2e.test.sh" 2>&1); then
    fail "a native omp alone cannot exercise the Bun rule and must fail, never skip or pass: $out"
  fi
  assert_contains "$out" "FM_OMP_IDENTITY_LIVE_LAUNCHER" "the failure names the variable that supplies the Bun launcher"
  assert_not_contains "$out" "checked " "a native omp alone checks nothing and claims nothing"

  # The guard's own logic, on a stand-in tree, through a scratch copy that cannot be mistaken for the real guard.
  copy="$TMP/guard-copy"
  make_guard_copy "$copy"
  copy_guard() { # <PATH> <env assignments...>
    local path=$1
    shift
    env -u FM_LIVE FM_OMP_IDENTITY_LIVE=1 "$@" PATH="$path" bash "$copy/tests/fm-omp-identity-live-e2e.test.sh" 2>&1
  }
  out=$(copy_guard "$NATIVE_BIN:$TREE:$base") || fail "a native omp first must not stop the guard from starting the later Bun launcher: $out"
  assert_contains "$out" "$TREE/omp" "the live guard names the Bun launcher that is not first"
  assert_contains "$out" "checked " "the guard exercised the Bun rule on the later launcher"
  out=$(copy_guard "$TREE:$NATIVE_BIN:$base") || fail "the Bun launcher first must run the live guard to its end: $out"
  assert_contains "$out" "checked " "the guard exercised the Bun rule on the first launcher"
  out=$(copy_guard "$NATIVE_BIN:$base" FM_OMP_IDENTITY_LIVE_LAUNCHER="$TREE/omp") || fail "the named launcher must run the live guard to its end: $out"
  assert_contains "$out" "checked " "the guard exercised the Bun rule on the named launcher"
  # The stand-in on a different installed identity must not be recognized, or the binding is vacuous.
  if out=$(copy_guard "$TREE:$NATIVE_BIN:$base" FM_TEST_OMP_ROOT="$TMP/no-such-install"); then
    fail "a stand-in that is not the installed identity must fail the live guard: $out"
  fi
  assert_contains "$out" "OMP IDENTITY DRIFT" "the guard reports the unrecognized process by name"
  # Dispatch tables that cannot be read leave the role port unchecked: that fails, it does not pass with fewer checks.
  notables="$TMP/no-tables-tree"
  build_tree "$notables"
  if out=$(copy_guard "$notables:$NATIVE_BIN:$base" FM_TEST_OMP_ROOT="$notables"); then
    fail "a missing dispatch source must fail the live guard, not pass with fewer checks: $out"
  fi
  assert_contains "$out" "dispatch tables cannot be read" "the failure names the missing dispatch evidence"
  assert_not_contains "$out" "checked " "an unchecked role port claims no completed check"
  # A guard that cannot fail proves nothing: a rule that rejects the installed shape must fail it.
  mutant="$TMP/mutant-root"
  make_guard_copy "$mutant"
  sed 's/^SCRIPT_PACKAGE = .*/SCRIPT_PACKAGE = "not-the-omp-package"/' "$ROOT/bin/fm-omp-identity.py" > "$mutant/bin/fm-omp-identity.py"
  if out=$(env -u FM_LIVE FM_OMP_IDENTITY_LIVE=1 PATH="$TREE:$NATIVE_BIN:$base" bash "$mutant/tests/fm-omp-identity-live-e2e.test.sh" 2>&1); then
    fail "a rule that rejects the installed shape must fail the live guard: $out"
  fi
  assert_contains "$out" "OMP IDENTITY DRIFT" "the guard reports the drift by name"
  pass "live guard: no ambient variable certifies a stand-in, an opt-out is an opt-out, a missing launcher or dispatch source fails, and its logic holds on a scratch copy"
}

test_classifier_keeps_its_names_and_the_bun_shape_stays_other() {
  local rc
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "omp is an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "an omp path is an agent"
  [ "$(fm_agent_process_classify_name ompd)" = other ] || fail "ompd is not an agent"
  [ "$(fm_agent_process_classify_name comp)" = other ] || fail "comp is not an agent"
  [ "$(fm_agent_process_classify_name bun)" = other ] || fail "a bare bun stays other: a name match would claim every Bun program"
  [ "$(fm_agent_process_classify bun "$BUN" "$BUN $SCRIPT --no-title")" = other ] || fail "the installed Bun shape keeps its classification; identity is the identity rule's"
  [ "$(fm_agent_process_classify bun "$BUN" "$BUN $SCRIPT __omp_worker_daemon_broker")" = other ] || fail "a worker-role invocation stays other"
  [ "$(fm_agent_process_classify zsh -zsh -zsh)" = shell ] || fail "a login shell stays a shell"
  [ "$(fm_agent_process_classify claude claude 'claude --resume x')" = agent ] || fail "another harness keeps its name"
  declare -F fm_agent_process_bun_may_be_omp >/dev/null || fail "fm_agent_process_bun_may_be_omp must exist"
  rc=0; fm_agent_process_bun_may_be_omp zsh zsh 1 || rc=$?
  [ "$rc" -eq 1 ] || fail "only bun-named processes reach the identity rule (exit $rc)"
  rc=0; fm_agent_process_bun_may_be_omp ompd ompd 1 || rc=$?
  [ "$rc" -eq 1 ] || fail "ompd never reaches the identity rule (exit $rc)"
  pass "classifier: every recognized name keeps its verdict and the installed Bun shape stays other, owned by the identity rule"
}


# --- N1: a script path resolved after launch is not evidence of what the process loaded ---
# One case per direction, so each is red or green on its own.
n1_script_pkg=src/node_modules/@oh-my-pi/pi-coding-agent
test_a_writer_whose_script_link_is_retargeted_after_launch_stays_a_writer() {
  local t="$TMP/n1a" a rc
  mkdir -p "$t"
  # shellcheck source=bin/fm-launch-proof-lib.sh
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-launch-proof-lib.sh"
  ps() { case "$*" in '-p '*' -o comm=') python3 -I "$PROCINFO" comm "$2" ;; '-p '*' -o args=') python3 -I "$PROCINFO" args "$2" ;; *) return 1 ;; esac; }
  build_tree "$t/a"
  tree_launch "$t/a" --no-title; a=$SPAWNED
  FM_TEST_OMP_ROOT="$t/a" assert_tree 0 0 "$a" "control: before the retarget the process is the installed agent"
  mv "$t/a/$n1_script_pkg/src/cli.ts" "$t/a/$n1_script_pkg/src/cli.ts.orig"
  ln -s main.ts "$t/a/$n1_script_pkg/src/cli.ts"
  assert_tree 1 0 "$a" "a script link retargeted after launch is never proof the process is another program"
  FM_TEST_OMP_ROOT="$t/a" assert_tree 1 0 "$a" "a script link retargeted after launch is not admitted even where its tree is the installed one"
  fm_launch_proof_pid_may_own_record "$a" || fail "a live writer whose script link was retargeted after launch may still own its record"
  # the genuinely unrelated control: the raw arguments name no omp entry at all
  mkdir -p "$t/other/bin"; cp "$BUN" "$t/other/bin/bun"
  spawn tty "$t/other/bin/bun" "$t/other/bin/bun" /elsewhere/app.ts
  assert_tree 1 1 "$SPAWNED" "a bun on a script that is lexically not the entry is unrelated"
  rc=0; fm_launch_proof_pid_may_own_record "$SPAWNED" || rc=$?
  [ "$rc" -ne 0 ] || fail "a bun on a script that is lexically not the entry may be replaced as an unrelated reused pid"
  pass "N1 A: a writer whose script link was retargeted after launch stays a possible writer; a bun on a script that is lexically not the entry is unrelated"
}
test_a_foreign_process_whose_link_is_retargeted_to_the_installed_entry_stays_refused() {
  local t="$TMP/n1b" b
  mkdir -p "$t/foreign" "$t/lnk/src"
  : > "$t/foreign/cli.ts"
  ln -s "$t/foreign/cli.ts" "$t/lnk/src/cli.ts"
  spawn tty "$BUN" "$BUN" "$t/lnk/src/cli.ts" --no-title; b=$SPAWNED
  assert_verdict 1 "$b" "control: a process started on a link to a foreign script is refused"
  ln -sfn "$SCRIPT" "$t/lnk/src/cli.ts"
  assert_verdict 1 "$b" "a link retargeted to the installed entry after launch must not admit the process"
  assert_tree 1 0 "$b" "and it may still own a record, because only its raw arguments could prove otherwise"
  pass "N1 B: a foreign process whose link is retargeted to the installed entry after launch stays refused"
}
test_a_directory_swapped_into_the_installed_path_after_launch_is_not_admitted() {
  local t="$TMP/n1c" c
  mkdir -p "$t"
  build_tree "$t/c"
  mv "$t/c/$n1_script_pkg/src" "$t/c/real-src"
  mkdir -p "$t/c/foreign-src"; : > "$t/c/foreign-src/cli.ts"
  ln -s "$t/c/foreign-src" "$t/c/$n1_script_pkg/src"
  tree_launch "$t/c" --no-title; c=$SPAWNED
  rm "$t/c/$n1_script_pkg/src"
  mv "$t/c/real-src" "$t/c/$n1_script_pkg/src"
  FM_TEST_OMP_ROOT="$t/c" assert_tree 2 0 "$c" "a directory swapped into the installed path after launch leaves the process unresolved, never admitted"
  pass "N1 C: a directory swapped into the installed path after launch is not admitted"
}
test_a_write_into_the_installed_path_after_launch_fails_closed() {
  local t="$TMP/n1d" d
  mkdir -p "$t"
  build_tree "$t/d"
  tree_launch "$t/d" --no-title; d=$SPAWNED
  FM_TEST_OMP_ROOT="$t/d" assert_tree 0 0 "$d" "control: an untouched installed tree admits"
  : > "$t/d/$n1_script_pkg/src/extra.txt"
  FM_TEST_OMP_ROOT="$t/d" assert_tree 2 0 "$d" "a write into a directory of the installed path after launch fails closed (named policy)"
  pass "N1 D: an unrelated write into a directory of the installed path after launch fails closed (named policy)"
}

# --- N3: which session a process currently writes cannot be read from one descriptor ---
test_a_process_that_switched_sessions_is_not_tied_to_the_old_one() {
  local t="$TMP/switch" mode pid rc
  mkdir -p "$t/task"; : > "$t/task.jsonl"; : > "$t/personal.jsonl"; : > "$t/task/__advisor.jsonl"
  holds_rc() { rc=0; python3 -I "$IDENT" holds "$1" "$2" >/dev/null 2>&1 || rc=$?; }
  wait_for_switch() { # <pid> <file>: the same process now holds <file>
    for _ in $(seq 1 100); do
      holds_rc "$1" "$2"
      [ "$rc" -ne 1 ] && return 0
      sleep 0.05
    done
    fail "the stand-in did not switch sessions"
  }
  # the real shape (three of the eleven captures): the task session and its own advisor file
  HOLD_FILE="$t/task.jsonl" SWITCH_TO="$t/task/__advisor.jsonl" launch tty --no-title; pid=$SPAWNED
  kill -USR1 "$pid"
  for _ in $(seq 1 100); do
    [ "$(python3 -I "$PROCINFO" writable "$pid" | python3 -I -c 'import json,sys;print(sum(1 for e in json.load(sys.stdin) if e["path"].endswith("__advisor.jsonl")))')" = 1 ] && break
    sleep 0.05
  done
  holds_rc "$pid" "$t/task.jsonl"; [ "$rc" -eq 0 ] || fail "a process holding its task session and that session's own advisor file is tied to the task session (exit $rc)"
  for mode in retain release; do
    if [ "$mode" = release ]; then
      HOLD_FILE="$t/task.jsonl" SWITCH_TO="$t/personal.jsonl" SWITCH_RELEASE=1 launch tty --no-title
    else
      HOLD_FILE="$t/task.jsonl" SWITCH_TO="$t/personal.jsonl" launch tty --no-title
    fi
    pid=$SPAWNED
    holds_rc "$pid" "$t/task.jsonl"; [ "$rc" -eq 0 ] || fail "before the switch ($mode) the process holds the task session (exit $rc)"
    holds_rc "$pid" "$t/personal.jsonl"; [ "$rc" -eq 1 ] || fail "before the switch ($mode) the process does not hold the other session (exit $rc)"
    kill -USR1 "$pid"
    wait_for_switch "$pid" "$t/personal.jsonl"
    case "$mode" in
      retain)
        holds_rc "$pid" "$t/task.jsonl"; [ "$rc" -eq 2 ] || fail "a process that switched but kept its old descriptor cannot prove the task session is current (exit $rc)"
        holds_rc "$pid" "$t/personal.jsonl"; [ "$rc" -eq 2 ] || fail "a process holding two sessions cannot prove either is current (exit $rc)" ;;
      release)
        holds_rc "$pid" "$t/task.jsonl"; [ "$rc" -eq 1 ] || fail "a process that switched and released the old descriptor no longer holds the task session (exit $rc)"
        holds_rc "$pid" "$t/personal.jsonl"; [ "$rc" -eq 0 ] || fail "a process that released the old descriptor holds only the new session (exit $rc)" ;;
    esac
  done
  pass "session binding: a retained old descriptor cannot prove the current session (fails closed), a released one does, and a session's own advisor file is not another session"
}

fm_test_only
test_classifier_keeps_its_names_and_the_bun_shape_stays_other
test_session_binding_needs_the_session_file_held_open_for_writing
test_proc_info_facts_are_kernel_facts
test_incarnation_tells_same_second_processes_apart
test_identity_comes_from_the_process_tree
test_captured_facts_replay_without_the_tree
test_role_follows_the_cli_dispatch
test_live_processes_are_judged_by_their_actual_executable_and_script
test_fail_closed_runs_recover_when_the_evidence_returns
test_record_writer_check_fails_open_and_adoption_target_fails_closed
test_verdict_does_not_depend_on_the_omp_on_path
test_a_helper_failure_is_never_proof_of_no_writer
test_descendant_walk_never_reports_a_live_bun_agent_as_agent_free
test_production_ignores_fm_omp_installed_root
test_live_guard_starts_a_bun_omp_or_fails_naming_the_launcher_variable
test_a_writer_whose_script_link_is_retargeted_after_launch_stays_a_writer
test_a_foreign_process_whose_link_is_retargeted_to_the_installed_entry_stays_refused
test_a_directory_swapped_into_the_installed_path_after_launch_is_not_admitted
test_a_write_into_the_installed_path_after_launch_fails_closed
test_a_process_that_switched_sessions_is_not_tied_to_the_old_one
