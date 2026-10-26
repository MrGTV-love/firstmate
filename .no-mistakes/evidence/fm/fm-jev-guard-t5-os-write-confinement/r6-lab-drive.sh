#!/usr/bin/env bash
# Round 6 live lab driver (runs inside a pane of the lab's private tmux server).
# Real bin/fm-spawn.sh from the gate worktree, real treehouse, real sandbox-exec.
# The claude CLI is a model-free stand-in on PATH; no provider call is made.
# The tmux server env carries CURSOR_AGENT=1 GEMINI_CLI=1 LAB_MARK=1 so the probe
# shows whether fm-spawn's unset reaches the claude command.
# Usage: r6-lab-drive.sh <worktree> <lab> <out>
set -u
ROOT=$1 LAB=$2 OUT=$3
H=$LAB/home U=$LAB/user-home FB=$LAB/fakebin
export HOME=$U PATH="$FB:$PATH" TREEHOUSE_ROOT=.claude/worktrees FM_HOME=$H
unset CLAUDE_CONFIG_DIR PI_CODING_AGENT_DIR OMP_PROFILE PI_PROFILE
exec >"$OUT" 2>&1

brief() {
  mkdir -p "$H/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nLab probe %s.\n\n## Firstmate spec\nRun the probe.\n' "$1" > "$H/data/$1/brief.md"
}

spawn() { # id harness
  local id=$1 harness=$2 rc
  brief "$id"
  echo "=== $id raw/named launch: $harness"
  "$ROOT/bin/fm-spawn.sh" "$id" "$H/projects/notes" --harness "$harness" --mode local-only --yolo on > "$LAB/spawn.$id" 2>&1
  rc=$?
  echo "spawn rc=$rc"
  grep -E 'confinement audit|^spawned|error|malformed|refus|cannot|fm-raw-launch' "$LAB/spawn.$id" | grep -v '^fm-gate-refuse' | head -6
  if [ -f "$H/state/$id.meta" ]; then
    grep -E '^(harness|write_confinement|claude_session_id)=' "$H/state/$id.meta"
  else
    echo "no state/$id.meta (no launch)"
  fi
  for _ in $(seq 1 40); do [ -s "$H/data/$id/probe.txt" ] && grep -q '^done' "$H/data/$id/probe.txt" && break; sleep 0.5; done
  if [ -s "$H/data/$id/probe.txt" ]; then
    echo "--- stand-in probe for $id:"
    cat "$H/data/$id/probe.txt"
  else
    echo "--- no stand-in probe for $id (claude never ran in the task pane)"
  fi
  echo
}

fixtures() {
  mkdir -p "/private/tmp/claude-$(id -u)/base.r6o" "$HOME/tmp/fixture-r6o"
  echo keep > "/private/tmp/claude-$(id -u)/base.r6o/payload"
  echo keep > "$HOME/tmp/fixture-r6o/payload"
  touch -t 202001010000 "$HOME/tmp/fixture-r6o" "$HOME/tmp/fixture-r6o/payload"
  echo keep > "$H/data/r6o/eval-target"
  [ -f "$H/state/r6o.status" ] || echo 'working: other task' > "$H/state/r6o.status"
}
check_other() {
  echo "--- other task r6o after $1:"
  echo "base.r6o payload: $(cat /private/tmp/claude-$(id -u)/base.r6o/payload 2>/dev/null || echo MISSING)"
  echo "~/tmp fixture-r6o payload: $(cat $HOME/tmp/fixture-r6o/payload 2>/dev/null || echo MISSING)"
  echo "data/r6o/eval-target: $(cat $H/data/r6o/eval-target 2>/dev/null || echo MISSING)"
  echo "state/r6o.status: $(cat $H/state/r6o.status 2>/dev/null || echo MISSING)"
  echo "primary README: $(tr '\n' '|' < $H/projects/notes/README.md)"
  echo
}

spawn r6o claude
fixtures; check_other setup
# decision 044 accepted compound forms, now spawned for real
spawn r6c3 '[[ -f README.md ]] && claude --print hi'
spawn r6c1 '[ -d src ] && cd src; claude --print hi'
spawn r6c2 'true && claude --print hi'
spawn r6c5 'export X=1 && claude --print hi'
spawn r6p 'claude --print hi'
check_other "accepted compound spawns"
# adversarial: uncertain constructs after a leading command must refuse, never run unconfined
spawn r6x1 'true && claude --print "$(date)"'
spawn r6x2 'true && claude --print `date`'
spawn r6x3 'true && (claude --print hi)'
spawn r6x4 'claude --print "$(date)"'
spawn r6x5 '[[ -f README.md ]] && claude --print hi $X'
check_other "adversarial spawns"
# a leading command with no claude at all keeps the unmeasured path
spawn r6n 'true && echo no-claude-here'
# documented: any first program, scanner-unreadable text refuses on macOS
spawn r6n2 'true && echo "$(date)"'
echo "=== lab driver finished"
