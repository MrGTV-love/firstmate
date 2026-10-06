#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49B0KN51DPCGNZVG2F29T2D/tests/fixtures.sh"
BASE="$HERE/generated"
fm_git_worktree "$BASE/source" "$BASE/code" guardrail-source
CODE="$BASE/code"
cp -R "$ROOT/bin" "$CODE/"
mkdir -p "$CODE/.omp/extensions" "$CODE/.claude" "$CODE/.agents/skills" "$BASE/tmp"
cp "$ROOT/.omp/fm-worker-overlay.yml" "$ROOT/.omp/fm-session-overlay.yml" "$CODE/.omp/"
cp "$ROOT/.omp/extensions/fm-jev-guardrail.ts" "$CODE/.omp/extensions/"
cp "$ROOT/.claude/settings.json" "$CODE/.claude/"
for harness in claude omp; do
 CASE="$BASE/$harness"
 OWNER="$CASE/owner's \"home\""
 CONFIG_DIR="$CASE/effective \"config\"\\tail"
 STATE_DIR="$CASE/effective-state"
 id="current-r27-native-$harness"
 if [ ! -d "$CASE/wt" ]; then
   fm_test_spawn_home "$OWNER" "$harness"
   fm_test_spawn_brief "$OWNER" "$id" 'Native guardrail acceptance using synthetic lab files only.'
   mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$CASE/pane-home" "$CASE/hostile-home/config" "$CASE/hostile-state"
   cp "$OWNER/config/crew-harness" "$CONFIG_DIR/crew-harness"
   touch "$STATE_DIR/.last-watcher-beat"
   fm_test_make_spawn_fakebin "$CASE/fake" claude omp > /dev/null
   fm_test_fake_no_mistakes "$CASE/fake/fakebin"
   fm_git_worktree "$CASE/project" "$CASE/wt" "native-$harness"
 fi
 mkdir -p "$CASE/tmp"
 printf '.env.owner-private\n' > "$CONFIG_DIR/dispatch-never-send"
 printf '.env.parent-private\n' > "$OWNER/config/dispatch-never-send"
 printf '.env.allowed\n' > "$CASE/hostile-home/config/dispatch-never-send"
 (cd "$CASE" && FM_ROOT_OVERRIDE='' FM_HOME="$OWNER" HOME="$CASE/pane-home" \
 CLAUDE_CONFIG_DIR='' FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$OWNER/data" \
 FM_PROJECTS_OVERRIDE="$OWNER/projects" FM_CONFIG_OVERRIDE="${CONFIG_DIR#"$CASE/"}" \
 FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_FAKE_PANE_PATH="$CASE/wt" \
 FM_FAKE_LAUNCH_LOG="$CASE/launch.log" TMPDIR="$CASE/tmp" TMUX=fake,1,0 PATH="$CASE/fake/fakebin:$PATH" \
 "$CODE/bin/fm-spawn.sh" "$id" "$CASE/project" --harness "$harness" --backend tmux --mode no-mistakes --yolo off) > "$CASE/generation.log" 2>&1
 printf '%s generated\n' "$harness"
done
