#!/usr/bin/env bash
# Usage: gen-settings.sh <worktree-root> <lab>
set -u
. "$1/tests/fixtures.sh"
lab=$2
fm_test_spawn_home "$lab/home" claude
fm_git_worktree "$lab/project" "$lab/wt" wt-t4-claude
fm_test_spawn_brief "$lab/home" t4claude
out=$(fm_test_run_spawn "$lab/home" "$lab/wt" "$(make_spawn_fakebin "$lab/fake" claude)" t4claude "$lab/project" --mode no-mistakes --yolo off) \
  || { echo "spawn failed: $out"; exit 1; }
echo "$out" | tail -5
ls -la "$lab/wt/.claude/settings.local.json"
