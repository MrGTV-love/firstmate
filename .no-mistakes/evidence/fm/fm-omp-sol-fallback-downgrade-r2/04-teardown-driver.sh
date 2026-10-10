#!/usr/bin/env bash
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4HZH01Q50QVT91QE6CCTFYA
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-ev-td)
trap 'fm_test_cleanup' EXIT
export NODE_NO_WARNINGS=1 OMP_PROFILE='' PI_PROFILE=''
show() { sed "s|$TMP_ROOT|<lab>|g; s|$ROOT|<repo>|g"; }
id=sol-lane-q3; home="$TMP_ROOT/home"; proj="$TMP_ROOT/proj"; wt="$TMP_ROOT/wt"
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_spawn_home "$home" omp
fm_git_worktree "$proj" "$wt" wt-td
fm_test_spawn_brief "$home" "$id" "Reply with the single word ack."
agent="$TMP_ROOT/agent"; mkdir -p "$agent"; printf 'setupVersion: 2\n' > "$agent/config.yml"
out=$(PI_CODING_AGENT_DIR="$agent" FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness omp --model openai-codex/gpt-6.1-sol --effort high --scout)
echo "spawn rc=$?"; printf '%s\n' "$out" | show
printf 'model=openai-codex/gpt-6.1-sol\nerror=ChatGPT rate limit exceeded. retry-after-ms=3600000\n' > "$home/state/$id.live-model"
printf '# Report\nack\n' > "$home/data/$id/report.md"
echo "before teardown:"; ls "$home/state" | grep "$id" | sed 's/^/  /'
out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1)
echo "\$ bin/fm-teardown.sh $id $*  (rc=$?)"; printf '%s\n' "$out" | show | sed 's/^/  /'
echo "after teardown:"; ls "$home/state" | grep "$id" | sed 's/^/  /'
[ ! -e "$home/state/$id.live-model" ] && echo "PASS - teardown removed the live-model record" || echo "FAIL - the live-model record is still there"
