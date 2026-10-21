#!/usr/bin/env bash
# Adopt smoke. Runs under a process named "omp" (the lock-owning main), drives the
# real bin/fm-control.sh against real "omp"-named sleep processes with real
# kernel cwds, real ps, real lsof and the real process-environment reader.
# Only the Herdr CLI is a private stand-in (read answers + call log).
# usage: smoke.sh <worktree> <runner-dir>
WT_SRC=$1
R=$2
export LC_ALL=C
PASS=0 FAIL=0
LABS=()
PIDS=()
cleanup() {
  local p l
  for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  for l in "${LABS[@]}"; do rm -rf "$l"; done
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "ok - $*"; }
bad() { FAIL=$((FAIL + 1)); say "NOT OK - $*"; }

mkdir -p "$R/fakebin"
ln -sf "$R/fake-herdr" "$R/fakebin/herdr"

# spawn_agent <name> <cwd> [pin] -> SPAWNED. "omp"/"python3" are symlinks to a real,
# non-platform interpreter: macOS hides the environment of Apple platform binaries.
spawn_agent() {
  local name=$1 cwd=$2 pin=${3-} env_args bin
  case "$name" in omp) bin=$R/bins/agent/omp ;; *) bin=$R/bins/plain/$name ;; esac
  env_args=(PATH="$PATH" HOME="${H:-/tmp}")
  [ -z "$pin" ] || env_args+=(FM_SPAWN_GEN="$pin")
  ( cd "$cwd" && exec env -i "${env_args[@]}" "$bin" -c 'import time; time.sleep(3000)' ) &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
  disown "$SPAWNED" 2>/dev/null
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(LC_ALL=C ps -p "$SPAWNED" -o comm= 2>/dev/null)" = "$bin" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  say "agent process $name did not settle: $(ps -p "$SPAWNED" -o comm=,args= 2>&1)"
  return 1
}

procinfo_one() { # <pid> <name>
  jq -cn --argjson pid "$1" --arg name "$2" --arg pane "$PANE" \
    '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:4242,foreground_processes:[{pid:$pid,name:$name,argv0:$name,argv:[$name,"3000"],cmdline:($name+" 3000")}]}}}'
}

# newcase <name> [pin]  -> H ID WTK FD S AGENT_PID RECORD META
newcase() {
  local name=$1 pin=${2-} dead
  FC_ENV=(); FC_PATH=
  H=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  LABS+=("$H")
  "$WT_SRC/bin/fm-lab-home.sh" create "$H" >/dev/null || { say "lab create failed"; return 1; }
  mkdir -p "$H/tmux" "$H/user-home" "$H/fake"
  FD=$H/fake
  ID=smoke-$name
  PANE='%7'
  SES=fmlab
  PROJ=$H/proj
  WTK=$H/wt
  git init -q "$PROJ" && git -C "$PROJ" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init \
    && git -C "$PROJ" worktree add -q "$WTK" -b "task-$ID" || { say "git setup failed"; return 1; }
  mkdir -p "$WTK/sub" "$H/data/$ID"
  printf '# Task\nsmoke\n' > "$H/data/$ID/brief.md"
  S=$WTK/session-task.jsonl
  printf '{"type":"session"}\n' > "$S"
  GEN=s1792361978.6048.2927
  META=$H/state/$ID.meta
  RECORD=$H/state/$ID.omp-session.json
  {
    echo "window=$SES:$PANE"; echo "endpoint_task_id=$ID"; echo "worktree=$WTK"; echo "project=$PROJ"
    echo "harness=omp"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "tasktmp=/tmp/fm-$ID"
    echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SES"
    echo "herdr_workspace_id=ws1"; echo "herdr_tab_id=tab1"; echo "herdr_pane_id=$PANE"
    echo "spawn_gen=$GEN"; echo "launch_proof=env-v1"
  } > "$META"
  # a dead pid: a child that has exited and been reaped
  /bin/sleep 0 & dead=$!; wait "$dead" 2>/dev/null
  DEAD=$dead
  jq -nc --arg gen "$GEN" --argjson pid "$DEAD" --arg task "$S" \
    '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:""}' > "$RECORD"
  printf '%s' "$PANE" > "$FD/pane"
  printf '%s' "$WTK/sub" > "$FD/cwd"
  printf '%s' "$S" > "$FD/agent-ref"
  : > "$FD/herdr-log"
  spawn_agent omp "$WTK/sub" "$pin" || return 1
  AGENT_PID=$SPAWNED
  procinfo_one "$AGENT_PID" omp > "$FD/procinfo"
}

# fc <args...> : the real fm-control.sh, child of an "omp"-named lock-owning main
fc() {
  (
    unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
      FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
      HERDR_TAB_ID HERDR_WORKSPACE_ID FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    export PATH="${FC_PATH:-$R/fakebin:$PATH}" FM_HOME="$H" FM_FAKE_DIR="$FD" HOME="$H/user-home" \
      FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=0.2 FM_CONTROL_LAUNCH_WAIT=0.2
    [ "${#FC_ENV[@]}" -eq 0 ] || export "${FC_ENV[@]}"
    exec -a omp /bin/bash "$R/runfc.sh" "$WT_SRC/bin/fm-control.sh" "$@"
  ) 2>&1
}
FC_ENV=()

sends() { grep -cE '^pane (send-keys|send-text|run)' "$FD/herdr-log" 2>/dev/null || true; }

# expect_refused <label> <needle> <verb...>  (record must stay byte-identical, no input sent)
expect_adopt_refused() {
  local label=$1 needle=$2 before after out rc=0 s0
  before=$(cat "$RECORD" 2>/dev/null; echo "<$?>")
  s0=$(sends)
  out=$(fc "$ID" adopt) || rc=$?
  after=$(cat "$RECORD" 2>/dev/null; echo "<$?>")
  say "  adopt> $out"
  if [ "$rc" -ne 0 ] && [[ "$out" == *"$needle"* ]] && [ "$before" = "$after" ] && [ "$(sends)" = "$s0" ] \
     && ! [[ "$out" == *"adopted:"* ]] && [ -z "$(find "$H/state" -maxdepth 1 -name '.*omp-session*' 2>/dev/null)" ]; then
    ok "$label"
  else
    bad "$label (rc=$rc same-record=$([ "$before" = "$after" ] && echo yes || echo NO) sends=$(sends) out=$out)"
  fi
}

expect_interrupt_refused() { # <label>
  local label=$1 out rc=0 s0
  s0=$(sends)
  out=$(fc "$ID" interrupt) || rc=$?
  say "  interrupt> $out"
  if [ "$rc" -ne 0 ] && ! [[ "$out" == *"interrupt-delivered"* ]] && [ "$(sends)" = "$s0" ]; then ok "$label"; else bad "$label (rc=$rc sends=$(sends) out=$out)"; fi
}

[ -z "${SMOKE_LIB_ONLY:-}" ] || return 0
say "=== SMOKE START $(date -u +%FT%TZ) head=$(git -C "$WT_SRC" rev-parse --short HEAD) ==="
say "main (lock owner) pid=$$ comm=$(ps -o comm= -p $$)"

############################################################################
say; say "--- S1 matching workspace: refused before adopt, repaired by adopt, interrupt works with no keystroke ---"
newcase s1 || exit 1
say "record before: $(cat "$RECORD")"
say "live pid $AGENT_PID comm=$(ps -o comm= -p $AGENT_PID) cwd=$(lsof -w -a -p $AGENT_PID -d cwd -Fn | sed -n 's/^n//p')"
expect_interrupt_refused "S1a interrupt refused before adopt (record names dead pid $DEAD, empty current)"
out=$(fc "$ID" adopt); rc=$?
say "  adopt> $out"
say "record after: $(cat "$RECORD")"
if [ "$rc" -eq 0 ] && [[ "$out" == *"adopted: $ID" ]] \
  && jq -e --argjson pid "$AGENT_PID" --arg gen "$GEN" --arg s "$S" \
     '(keys|sort) == ["current_session_file","pid","spawn_gen","task_session_file","version"] and .version == 1 and .pid == $pid and .spawn_gen == $gen and .task_session_file == $s and .current_session_file == $s' "$RECORD" >/dev/null \
  && [ "$(sends)" = 0 ]; then
  ok "S1b adopt writes exactly the five fields (live pid, same generation, task file, current=live file) and sends no input"
else bad "S1b adopt result rc=$rc"; fi
say "  (the process env carries no FM_SPAWN_GEN pin; the live reader must still authorize via the adoption route)"
out=$(fc "$ID" interrupt); rc=$?
say "  interrupt> $out"
say "  herdr calls that sent input: $(grep -E '^pane (send-keys|send-text)' "$FD/herdr-log" | tr '\n' '|')"
if [ "$rc" -eq 0 ] && [[ "$out" == *"interrupt-delivered $ID"* ]] && grep -qE '^pane send-keys %7 escape' "$FD/herdr-log"; then
  ok "S1c interrupt now delivers Escape to the recorded pane, no human keystroke"
else bad "S1c interrupt after adopt rc=$rc"; fi

# S1d: repeat adopt must not rewrite a record that names a live process
before=$(cat "$RECORD")
out=$(fc "$ID" adopt); rc=$?
say "  repeat adopt> $out"
if [ "$rc" -ne 0 ] && [ "$before" = "$(cat "$RECORD")" ] && [[ "$out" == *"record proof"* ]]; then ok "S1d repeat adopt refused with the record byte-identical"; else bad "S1d repeat adopt rc=$rc"; fi

# S1e: foreground replaced by another omp process -> repaired record stops authorizing
spawn_agent omp "$WTK/sub" || exit 1; OTHER=$SPAWNED
procinfo_one "$OTHER" omp > "$FD/procinfo"
expect_interrupt_refused "S1e repaired record stops authorizing when another process (pid $OTHER) takes the pane"

############################################################################
say; say "--- S2 workspace of another task (deeper worktree) refused ---"
newcase s2 || exit 1
OTH=other-task
mkdir -p "$WTK/sub/nested"
{
  echo "window=fmlab:%9"; echo "endpoint_task_id=$OTH"; echo "worktree=$WTK/sub"; echo "project=$PROJ"
  echo "harness=omp"; echo "kind=ship"; echo "mode=no-mistakes"; echo "backend=herdr"; echo "herdr_session=fmlab"
  echo "herdr_workspace_id=ws1"; echo "herdr_tab_id=tab2"; echo "herdr_pane_id=%9"; echo "spawn_gen=other-gen"
} > "$H/state/$OTH.meta"
expect_adopt_refused "S2 adopt refused: process cwd belongs to the deeper recorded worktree of another task" "workspace proof needs this task to be the unique deepest match; cwd belongs to $OTH"
expect_interrupt_refused "S2b interrupt still refused"

############################################################################
say; say "--- S3 two metas claim one pane ---"
newcase s3 || exit 1
{
  echo "window=fmlab:%7"; echo "endpoint_task_id=rival"; echo "worktree=$H/elsewhere"; echo "project=$PROJ"
  echo "harness=omp"; echo "kind=ship"; echo "mode=no-mistakes"; echo "backend=herdr"; echo "herdr_session=fmlab"
  echo "herdr_workspace_id=ws1"; echo "herdr_tab_id=tab1"; echo "herdr_pane_id=%7"; echo "spawn_gen=g"
} > "$H/state/rival.meta"
expect_adopt_refused "S3 adopt refused: unique-claim proof names the rival task" "unique-claim proof needs no other local task to claim this pane; claimed by rival"

############################################################################
say; say "--- S4 ambiguous foreground (two agent processes) ---"
newcase s4 || exit 1
spawn_agent omp "$WTK/sub" || exit 1; SECOND=$SPAWNED
jq -cn --argjson a "$AGENT_PID" --argjson b "$SECOND" --arg pane "$PANE" \
  '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:4242,foreground_processes:[{pid:$a,name:"omp",argv0:"omp"},{pid:$b,name:"omp",argv0:"omp"}]}}}' > "$FD/procinfo"
expect_adopt_refused "S4a adopt refused: two agent processes, no process-group leader" "foreground proof needs one uniquely resolved live process"
# S4b: a real shell is the foreground group leader and has two real agent children
LEADER_BIN=$R/bins/plain/bash
( cd "$WTK/sub" && exec env -i PATH="$PATH" HOME="$H" /bin/bash -c \
  "'$R/bins/agent/omp' -c 'import time; time.sleep(3000)' & '$R/bins/agent/omp' -c 'import time; time.sleep(3000)' & wait" ) &
LEADER=$!; PIDS+=("$LEADER"); disown "$LEADER" 2>/dev/null; sleep 1
KIDS=$(pgrep -P "$LEADER" | tr '\n' ' ')
set -- $KIDS
if [ "$#" -eq 2 ]; then
  jq -cn --argjson l "$LEADER" --argjson a "$1" --argjson b "$2" --arg pane "$PANE" \
    '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$l,foreground_process_group_id:$l,foreground_processes:[{pid:$l,name:"bash",argv0:"bash"},{pid:$a,name:"omp",argv0:"omp"},{pid:$b,name:"omp",argv0:"omp"}]}}}' > "$FD/procinfo"
  say "  shell leader $LEADER has agent children $1 $2"
  expect_adopt_refused "S4b adopt refused: shell leader with two agent children is ambiguous" "foreground proof needs one uniquely resolved live process"
else
  bad "S4b could not stage two agent children (got: $KIDS)"
fi

############################################################################
say; say "--- S5 record generation differs from metadata ---"
newcase s5 || exit 1
jq -c '.spawn_gen = "someone-elses-generation"' "$RECORD" > "$RECORD.new" && mv "$RECORD.new" "$RECORD"
expect_adopt_refused "S5 adopt refused: generation proof; nothing fabricated or unset" "generation proof needs the existing record spawn_gen to equal metadata spawn_gen"
jq -e '.spawn_gen == "someone-elses-generation"' "$RECORD" >/dev/null && ok "S5b record still carries its own generation" || bad "S5b generation changed"

############################################################################
say; say "--- S6 same live PID: extension's deliberate empty mark / personal activation ---"
newcase s6 "s1792361978.6048.2927" || exit 1
say "(process env is launch-pinned to the recorded generation, as a real launched omp is)"
jq -c --argjson pid "$AGENT_PID" '.pid = $pid | .current_session_file = ""' "$RECORD" > "$RECORD.new" && mv "$RECORD.new" "$RECORD"
expect_adopt_refused "S6a empty current for the live pinned pid refused (the extension's unproven mark)" "current-session proof for the live PID is empty or invalid, which the omp extension writes as unproven"
expect_interrupt_refused "S6b interrupt stays refused on the extension's unproven mark"
PERSONAL=$H/personal.jsonl; printf '{"type":"session"}\n' > "$PERSONAL"
jq -c --arg p "$PERSONAL" '.current_session_file = $p' "$RECORD" > "$RECORD.new" && mv "$RECORD.new" "$RECORD"
expect_adopt_refused "S6c personal current-session activation for the live pid refused" "current-session proof contradicts the registered task session for the live PID"
expect_interrupt_refused "S6d interrupt refused while the personal conversation is active"

############################################################################
say; say "--- S7 callers: worker, supervision branch, non-owner ---"
newcase s7 || exit 1
FC_ENV=(FM_TASK_ID="$ID")
expect_adopt_refused "S7a worker (FM_TASK_ID set) refused" "workers cannot adopt a session record"
FC_ENV=(FM_SUPERVISION_ACTOR=branch)
expect_adopt_refused "S7b supervision branch refused" "the supervision branch never performs this action"
FC_ENV=()
FC_ENV=(LOCKVAL=1)
expect_adopt_refused "S7c session that does not own the home lock refused" "requires the actual lock-owning main Firstmate"

############################################################################
say; say "--- S8 live process pinned to another launch generation ---"
newcase s8 "a-different-launch-generation" || exit 1
expect_adopt_refused "S8 adopt refused: generation proof names the other launch" "generation proof needs the live process not to be pinned to another launch generation"
expect_interrupt_refused "S8b interrupt stays refused"

############################################################################
say; say "--- S9 foreground is not an agent process ---"
newcase s9 || exit 1
spawn_agent python3 "$WTK/sub" || exit 1; NA=$SPAWNED
procinfo_one "$NA" python3 > "$FD/procinfo"
expect_adopt_refused "S9 adopt refused: process proof needs an agent" "process proof needs the resolved foreground process to be a readable agent process"

############################################################################
say; say "--- S10 process cwd outside the task worktree ---"
newcase s10 || exit 1
kill "$AGENT_PID"; mkdir -p "$H/outside"
spawn_agent omp "$H/outside" || exit 1; AGENT_PID=$SPAWNED
procinfo_one "$AGENT_PID" omp > "$FD/procinfo"
expect_adopt_refused "S10 adopt refused: workspace proof (kernel cwd read by real lsof)" "workspace proof needs the foreground cwd inside this task's recorded worktree"

############################################################################
say; say "--- S11 unreadable process environment stays unknown, then recovers ---"
newcase s11 || exit 1
mkdir -p "$H/shim"
cat > "$H/shim/python3" <<SH
#!/usr/bin/env bash
# fails only the environment reader (python3 - <pid>); everything else is real
if [ "\$#" = 2 ] && [ "\$1" = - ]; then exit 1; fi
exec $(command -v python3) "\$@"
SH
chmod +x "$H/shim/python3"
FC_PATH="$H/shim:$R/fakebin:$PATH"
out=$(fc "$ID" adopt); rc=$?
say "  adopt (env unreadable)> $out"
if [ "$rc" -eq 0 ]; then ok "S11a adopt proofs hold with an unreadable env (no pin visible)"; else say "  note: adopt refused with unreadable env (rc=$rc) -- also safe"; fi
expect_interrupt_refused "S11b interrupt refused while the environment is unreadable (verdict unknown, not promoted)"
FC_PATH=
if [ "$rc" -eq 0 ]; then
  out=$(fc "$ID" interrupt); rc2=$?
  say "  interrupt (env readable again)> $out"
  if [ "$rc2" -eq 0 ] && [[ "$out" == *"interrupt-delivered"* ]]; then ok "S11c authorization returns once the env is readable"; else bad "S11c rc=$rc2"; fi
fi

############################################################################
say; say "--- S12 claude harness, missing record, missing meta spawn_gen ---"
newcase s12 || exit 1
sed -i.bak 's/^harness=omp$/harness=claude/' "$META"; rm -f "$META.bak"
expect_adopt_refused "S12a non-omp harness refused" "adopt needs a local Herdr omp task"
sed -i.bak 's/^harness=claude$/harness=omp/' "$META"; rm -f "$META.bak"
mv "$RECORD" "$RECORD.held"
out=$(fc "$ID" adopt); rc=$?
say "  adopt (no record)> $out"
if [ "$rc" -ne 0 ] && [ ! -e "$RECORD" ] && [[ "$out" == *"existing readable session record"* ]]; then ok "S12b missing record refused; none created"; else bad "S12b rc=$rc"; fi
mv "$RECORD.held" "$RECORD"
grep -v '^spawn_gen=' "$META" > "$META.new" && mv "$META.new" "$META"
expect_adopt_refused "S12c missing metadata spawn_gen refused; none fabricated" "spawn_gen"
grep -c '^spawn_gen=' "$META" | grep -qx 0 && ok "S12d metadata still lacks spawn_gen (not fabricated)" || bad "S12d spawn_gen appeared"

say; say "=== SMOKE END pass=$PASS fail=$FAIL ==="
[ "$FAIL" -eq 0 ]
