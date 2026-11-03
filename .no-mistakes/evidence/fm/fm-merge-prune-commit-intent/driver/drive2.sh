#!/usr/bin/env bash
# Adversarial drives of the real bin/fm-merge-prune.sh in throwaway worlds.
# Usage: drive2.sh <repo-root> <head-bin> <base-bin> <test-file> <tmp>
set -u
ROOT=$1; HEAD_BIN=$2; BASE_BIN=$3; TF=$4; T=$5
sed -e '/^if \[ "\$#" -gt 0 \]; then$/,$d' -e "s|\"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|\"$ROOT/tests/lib.sh\"|" "$TF" > "$T/suite-helpers.sh"
. "$T/suite-helpers.sh"
intent() { jq -n --arg e "$1" --arg b "$2" '{artifacttype:"CommitIntent",schemaversion:"1.0.0",branch:$b,head_sha:"cd916701e5388f24c741a905c7be6a1348cf4e03",owned_paths:["docs/a.md"],validators:["ruff-check"],expires_at_iso:$e,base_ref:"origin/main"}'; }
world() {
  make_world
  printf '%s\n' '.claude/' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'branch=fm/t1\n' >> "$STATE/t1.meta"
  printf 'ok\n' > "$W/stub.mode"
  mkdir -p "$COPY/.claude"
}
show() {  # <label> <want>
  local got; if [ -e "$COPY" ]; then got=kept; else got=removed; fi
  echo "  copy: $got | destroy calls: $(destroy_calls) | wakes: $(wake_count) | record: $(tr '\n' ' ' < "$STATE/t1.merge-prune" 2>/dev/null)"
  [ ! -s "$STATE/.wake-queue" ] || sed 's/^/  wake: /' "$STATE/.wake-queue"
  if [ "$got" = "$2" ]; then echo "RESULT $1: PASS ($got)"; else echo "RESULT $1: FAIL (got $got, want $2)"; fi
}
upgrade_case() {  # <label> <want> <expires> <branch>
  world
  intent "$3" "$4" > "$COPY/.claude/commit-intent.json"
  echo "=== $1 (want $2)"
  BIN_DIR=$BASE_BIN
  echo "\$ [base code] fm-merge-prune.sh arm t1; run t1 --now"
  prune arm t1 >/dev/null 2>&1; prune run t1 --now >/dev/null 2>&1
  echo "  after base: copy exists=$([ -e "$COPY" ] && echo yes || echo no) task meta exists=$([ -e "$STATE/t1.meta" ] && echo yes || echo no) wakes=$(wake_count)"
  echo "  base record: $(tr '\n' ' ' < "$STATE/t1.merge-prune")"
  set_rec t1 next_at 0
  BIN_DIR=$HEAD_BIN
  echo "\$ [head code] fm-merge-prune.sh run t1   (due retry of the retained record)"
  prune run t1 2>&1 | sed 's/^/  /'
  show "$1" "$2"
}
upgrade_case "U1 old retained record, expired intent, head retry" removed 2000-01-01T00:00:00+00:00 other/branch
upgrade_case "U2 old retained record (no branch=), unexpired intent naming fm/t1, head retry" kept 2999-01-01T00:00:00+00:00 fm/t1

BIN_DIR=$HEAD_BIN
world
intent 2999-01-01T00:00:00+00:00 other/branch > "$COPY/.claude/commit-intent.json"
echo "=== X1 FM_MP_TASK_BRANCH=other/branch in the caller env, record says fm/t1, intent unexpired names other/branch (want kept)"
export FM_MP_TASK_BRANCH=other/branch
prune arm t1 >/dev/null 2>&1; prune run t1 --now 2>&1 | sed 's/^/  /'
unset FM_MP_TASK_BRANCH
show "X1 caller env cannot widen the branch rule" kept

world
mkfifo "$COPY/.claude/commit-intent.json"
echo "=== X2 FIFO at .claude/commit-intent.json, full flow under a 120 s bound (want kept, no hang)"
start=$(date +%s)
prune arm t1 >/dev/null 2>&1
( prune run t1 --now >/dev/null 2>&1 ) & pid=$!
( sleep 120; kill $pid 2>/dev/null ) & guard=$!
wait $pid; rc=$?; kill $guard 2>/dev/null
echo "  run exit=$rc elapsed=$(( $(date +%s) - start ))s"
show "X2 FIFO keeps the copy without hanging" kept
