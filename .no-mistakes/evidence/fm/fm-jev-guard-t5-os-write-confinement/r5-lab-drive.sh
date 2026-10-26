#!/usr/bin/env bash
# Round 5 live lab driver (runs inside a pane of the lab's private tmux server).
# Real bin/fm-spawn.sh from the gate worktree, real treehouse, real sandbox-exec.
# The claude CLI is a model-free stand-in on PATH; no provider call is made.
# Usage: r5-lab-drive.sh <worktree> <lab> <out>
set -u
ROOT=$1 LAB=$2 OUT=$3
H=$LAB/home U=$LAB/user-home FB=$LAB/fakebin
export HOME=$U PATH="$FB:$PATH" TREEHOUSE_ROOT=.claude/worktrees
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
  grep -E 'confinement audit|^spawned|error|malformed|refus' "$LAB/spawn.$id" | grep -v '^fm-gate-refuse' | head -6
  if [ -f "$H/state/$id.meta" ]; then
    grep -E '^(harness|write_confinement|claude_session_id)=' "$H/state/$id.meta"
  else
    echo "no state/$id.meta (no launch)"
  fi
  # wait for the stand-in probe, if one runs
  for _ in $(seq 1 40); do [ -s "$H/data/$id/probe.txt" ] && grep -q '^done' "$H/data/$id/probe.txt" && break; sleep 0.5; done
  if [ -s "$H/data/$id/probe.txt" ]; then
    echo "--- stand-in probe for $id:"
    cat "$H/data/$id/probe.txt"
  else
    echo "--- no stand-in probe for $id (claude never ran in the task pane)"
  fi
  echo
}

spawn t5o claude
spawn t5c1 '[ -d src ] && cd src; claude --print hi'
spawn t5c2 'true && claude --print hi'
spawn t5c3 '[[ -f x ]] && claude --print hi'
spawn t5c4 'true; FOO=1 claude --print hi'
spawn t5p 'claude --print hi'
# adversarial: an uncertain construct after a leading command
spawn t5x1 'true && claude --print "$(date)"'
spawn t5x2 'true && claude --print `date`'
spawn t5x3 'true && (claude --print hi)'
spawn t5x4 'claude --print "$(date)"'
# a leading command with no claude at all keeps the unmeasured path
spawn t5n 'true && echo no-claude-here'
echo "=== lab driver finished"
