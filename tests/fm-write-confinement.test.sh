#!/usr/bin/env bash
# macOS kernel-level acceptance for T5, including actual production busy writes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Darwin ]; then
  printf 'skip: macOS Seatbelt acceptance; Linux remains unconfined\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-write-confinement)
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/project/.claude/worktrees/fm-task" fm/task
mkdir -p "$TMP_ROOT/data/task" "$TMP_ROOT/state/task.inbox/handled" "$TMP_ROOT/temp" "$TMP_ROOT/agent"
export OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp
python3 "$ROOT/tests/fm-write-confinement.py" "$ROOT" "$TMP_ROOT"
pass "T5 a-e: inherited filesystem enforcement, declared nested worktree, state isolation and real busy writer"
