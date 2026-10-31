#!/usr/bin/env bash
# Real mirror CLI with an armed token lacking reaction scopes (replay sandbox, throwaway home).
set -euo pipefail
ROOT=${1:?worktree}; FIX="$ROOT/tests/fixtures/slack"; H="$ROOT/tests/fm_slack_watch_test.py"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-card-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
bash "$FIX/make-home.sh" card-payload "$LAB" >/dev/null
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" FM_CONFIG_OVERRIDE="$LAB/config"
cp "$FIX/card-payload/transcript.json" "$LAB/t.json"
python3 "$H" set-scopes "$LAB/t.json" 'chat:write,im:write,im:history'
"$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold with-options --reason $'Decision sought: Ship now?\nBrief: Release is ready.\nRecommendation: Ship, tests are green.\nAlternatives: Waiting gains nothing.' >/dev/null
printf -- '--- mirror stdout ---\n'; "$ROOT/bin/fm-slack-mirror.sh" --replay "$LAB/t.json"
R=$(python3 "$H" replay-file "$LAB/state/slack-watch")
for k in with-options no-options; do printf -- '--- card %s ---\n' "$k"; python3 "$H" card-text "$R" "$k"; done
