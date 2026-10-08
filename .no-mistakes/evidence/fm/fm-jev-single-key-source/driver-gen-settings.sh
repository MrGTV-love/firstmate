#!/usr/bin/env bash
set -eu
. ./tests/fixtures.sh
base="$PWD/.live-validation/stop-fixture"
mkdir -p "$base"
home="$base/home"
fm_test_spawn_home "$home" claude
fm_git_worktree "$base/project" "$base/wt" live-stop
fm_test_spawn_brief "$home" live-stop 'Change the disposable code file and verify the change.'
fakebin=$(make_spawn_fakebin "$base/fake" claude)
fm_test_run_spawn "$home" "$base/wt" "$fakebin" live-stop "$base/project" --mode local-only --yolo off
cp "$base/wt/.claude/settings.local.json" "$PWD/.live-validation/generated-settings.json"
printf 'Generated settings persisted inside disposable workspace.\n'
