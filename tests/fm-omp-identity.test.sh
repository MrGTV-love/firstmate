#!/usr/bin/env bash
# Portable regression for the omp identity rule (bin/fm-omp-identity.py): the
# installed omp can run as its Bun runtime on an entry script, so its process is
# named bun and only its executable path, script and role identify it.
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
  printf '#include <unistd.h>\nint main(void){for(;;)pause();}\n' > "$root/stub.c"
  cc -o "$bun/bun" "$root/stub.c" || fail "could not compile the runtime stand-in"
  : > "$root/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  cat > "$root/omp" <<EOF
#!/bin/sh
# stand-in omp launcher shaped like the host's
R=$root
exec "\$R/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun" "\$R/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts" "\$@"
EOF
  chmod +x "$root/omp"
}
TREE="$TMP/tree"; build_tree "$TREE"
BUN="$TREE/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun"
SCRIPT="$TREE/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
export FM_OMP_LAUNCHER="$TREE/omp"
REAL_BUN=$(python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BUN")
REAL_SCRIPT=$(python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SCRIPT")

# spawn.py holds a process's standard input (tty, open or empty pipe, null) and
# execs argv with an optional different executable, then stays alive until killed.
cat > "$TMP/spawn.py" <<'PY'
import os, pty, subprocess, sys, time
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
child = subprocess.Popen(argv, executable=executable, stdin=stdin, stdout=subprocess.DEVNULL)
open(pidfile, "w").write(str(child.pid))
time.sleep(600)
PY
FIXTURE_N=0
spawn() { # <stdin-kind> <executable|-> <argv...> -> $SPAWNED (pid) after the exec settled
  local kind=$1 exe=$2 file expect
  shift 2
  FIXTURE_N=$((FIXTURE_N + 1)); file="$TMP/pid.$FIXTURE_N"
  [ "$exe" != - ] || exe=
  python3 -I "$TMP/spawn.py" "$kind" "$file" "$exe" "$@" &
  HOLDERS+=($!)
  for _ in $(seq 1 100); do [ -s "$file" ] && break; sleep 0.05; done
  [ -s "$file" ] || fail "fixture process was not started"
  SPAWNED=$(cat "$file")
  expect=${FM_SPAWN_EXPECT_EXE:-}
  for _ in $(seq 1 100); do
    [ "$(python3 -I "$PROCINFO" exe "$SPAWNED" 2>/dev/null)" != /bin/sh ] && break
    sleep 0.05
  done
  : "$expect"
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
  local try a b
  for try in 1 2 3 4 5 6 7 8; do
    launch tty --no-title; a=$SPAWNED
    launch tty --no-title; b=$SPAWNED
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
  local lib a1 a2 mutant_distinguishes=no
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
  lib=$a1
  : "$lib"
  pass "incarnation: the delivered start identity separates same-second processes; a whole-second source cannot"
}

# --- 3. the installed identity ----------------------------------------------------
test_identity_derivation_fails_closed() {
  local t="$TMP/derive"
  mkdir -p "$t/out"
  facts() { # <exe> <argv-json> <stdin> -> a facts file
    printf '{"pid":1,"start":"1.000001","exe":"%s","argv":%s,"stdin":"%s"}' "$1" "$2" "$3" > "$t/facts.json"
  }
  facts "$BUN" "[\"$BUN\",\"$SCRIPT\",\"--no-title\"]" tty
  python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 || fail "the derived identity must admit the compliant facts"
  # a launcher naming another runtime: the process no longer matches
  sed "s#^R=.*#R=$t/other#" "$TREE/omp" > "$t/other-launcher"
  FM_OMP_LAUNCHER="$t/other-launcher" python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 && fail "a launcher for a missing tree must admit nothing"
  # a launcher that cannot be read, is binary, is another form, or leaves its own tree
  FM_OMP_LAUNCHER="$t/missing" python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 && fail "an unreadable launcher must admit nothing"
  FM_OMP_LAUNCHER="$BUN" python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 && fail "a binary launcher must admit nothing"
  printf '#!/bin/sh\nexec "$HOME/bin/other" "$@"\n' > "$t/odd"
  FM_OMP_LAUNCHER="$t/odd" python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 && fail "another launcher form must admit nothing"
  mkdir -p "$t/evil"; : > "$t/evil/cli.ts"
  build_tree "$t/linked"
  rm "$t/linked/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  ln -s "$t/evil/cli.ts" "$t/linked/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
  facts "$t/linked/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun" "[\"x\",\"$t/linked/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts\"]" tty
  FM_OMP_LAUNCHER="$t/linked/omp" python3 -I "$IDENT" interactive --facts "$t/facts.json" >/dev/null 2>&1 && fail "an installed path that links outside its tree must admit nothing"
  pass "identity: a changed, unreadable, binary, foreign-form or tree-escaping launcher recognizes nothing"
}

# --- 4. the role, from the installed CLI's own dispatch -------------------------
role() { # <expected-exit> <stdin> <description> -- <omp args...>
  local expected=$1 stdin=$2 description=$3 rc=0 args
  shift 4
  if [ "$stdin" = - ]; then stdin=null; else stdin="\"$stdin\""; fi
  args=$(python3 -I -c 'import json,sys;print(json.dumps(sys.argv[1:]))' "$@")
  printf '{"pid":1,"start":"1.000001","exe":"%s","argv":%s,"stdin":%s}' "$BUN" \
    "$(python3 -I -c 'import json,sys;print(json.dumps([sys.argv[1],sys.argv[2]]+json.loads(sys.argv[3])))' "$BUN" "$SCRIPT" "$args")" "$stdin" > "$TMP/role.json"
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
  local foreign other t="$TMP/live" pid
  mkdir -p "$t"
  # the compliant restored agent
  launch tty --config /x.yml --auto-approve --cwd /wt --no-title 'Read the brief'
  assert_verdict 0 "$SPAWNED" "the installed runtime on the installed script with a terminal is admitted"
  pid=$SPAWNED
  [ "$(printf '%s' "$OUT" | jq -r .start)" = "$(python3 -I "$IDENT" startid "$pid")" ] || fail "the verdict must carry the process start identity"
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
  other=$SPAWNED; : "$other"
  # an exited process names nothing
  assert_verdict 2 2000000000 "a missing process is unresolved"
  pass "live processes: actual executable, resolved script and role decide; foreign look-alikes, helpers and headless runs are refused"
}

test_fail_closed_runs_recover_when_the_evidence_returns() {
  local t="$TMP/fail" pid rc=0
  mkdir -p "$t"
  launch tty --no-title; pid=$SPAWNED
  FM_OMP_LAUNCHER="$t/missing" verdict "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable launcher must not admit the compliant process"
  printf '#!/bin/sh\nexec "$@"\n' > "$t/odd"
  rc=0; FM_OMP_LAUNCHER="$t/odd" verdict "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "an underivable launcher must not admit the compliant process"
  assert_verdict 0 "$pid" "the same process is admitted again once the launcher is derivable"
  # a foreign process and a helper stay refused whatever the launcher state
  launch tty __omp_worker_daemon_broker
  rc=0; FM_OMP_LAUNCHER="$t/missing" verdict "$SPAWNED" || rc=$?
  [ "$rc" -ne 0 ] || fail "a helper must be refused with the launcher unreadable"
  pass "fail closed: an unreadable or underivable launcher admits nothing and the compliant process is admitted again once it returns"
}

# --- 6. record ownership and the library predicates -----------------------------
test_record_writer_check_fails_open_and_adoption_target_fails_closed() {
  local pid
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
  # genuinely unrelated programs and dead pids may be replaced
  spawn tty /bin/sh /bin/sh -c 'sleep 600'
  ps() { case "$*" in '-p '*' -o comm=') python3 -I "$PROCINFO" comm "$2" ;; '-p '*' -o args=') python3 -I "$PROCINFO" args "$2" ;; esac; }
  fm_launch_proof_pid_may_own_record "$SPAWNED" && fail "an unrelated shell is not a record writer"
  cp "$BUN" "$TMP/foreign-bun"; mkdir -p "$TMP/fb"; cp "$BUN" "$TMP/fb/bun"
  spawn tty "$TMP/fb/bun" "$TMP/fb/bun" /elsewhere/cli.ts
  fm_launch_proof_pid_may_own_record "$SPAWNED" && fail "a positively read foreign bun is an unrelated reused pid"
  ps() { return 1; }
  fm_launch_proof_pid_may_own_record 2000000001 && fail "a dead pid is no writer"
  pass "writer check fails open on any role or unreadable identity; adoption target fails closed; unrelated and dead pids may be replaced"
}

# --- 7. the Herdr descendant walk ---------------------------------------------------
test_descendant_walk_never_reports_a_live_bun_agent_as_agent_free() {
  local dir="$TMP/walk" bunpid foreignpid out
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
  pass "walk: a live or unreadable Bun descendant keeps the pane occupied; an unrelated Bun job and an empty shell keep today's outcome"
}

fm_test_only
test_proc_info_facts_are_kernel_facts
test_incarnation_tells_same_second_processes_apart
test_identity_derivation_fails_closed
test_role_follows_the_cli_dispatch
test_live_processes_are_judged_by_their_actual_executable_and_script
test_fail_closed_runs_recover_when_the_evidence_returns
test_record_writer_check_fails_open_and_adoption_target_fails_closed
test_descendant_walk_never_reports_a_live_bun_agent_as_agent_free
