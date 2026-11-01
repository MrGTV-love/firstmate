#!/usr/bin/env bash
# M3 variant: registered local home exists but its backlog is unreadable; a second readable lane must still get its card.
set -uo pipefail
ROOT=${1:?worktree}
T=$(mktemp -d "$HOME/tmp/fm-slack-live3.XXXXXX"); trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
unset FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_SLACK_FAULT NO_MISTAKES_GATE
export SLACK_BOT_TOKEN="xoxb-m3b-$$" FM_SLACK_DM_USER=U0TESTOWNER FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER
in_home() { local h=$1; shift; FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$@"; }
for h in "$T/main" "$T/ok" "$T/bad"; do
  in_home "$h" bash "$ROOT/tests/fixtures/slack/make-home.sh" config "$h" >/dev/null 2>&1
  printf 'config-call\tdone\t\tdone\n' | in_home "$h" bash "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source fixture >/dev/null
done
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z in_home "$T/ok" bash "$ROOT/bin/fm-captain-hold.sh" hold ok-call --title OK --reason 'Ok?' >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z in_home "$T/bad" bash "$ROOT/bin/fm-captain-hold.sh" hold bad-call --title Bad --reason 'Bad?' >/dev/null
printf -- '- bad - Bad lane (home: %s; scope: b; projects: sample; added 2026-10-01)\n- ok - Ok lane (home: %s; scope: o; projects: sample; added 2026-10-01)\n' "$T/bad" "$T/ok" > "$T/main/data/secondmates.md"
chmod 000 "$T/bad/data/backlog.md"
echo '=== mirror with bad lane backlog unreadable (registered first)'
in_home "$T/main" bash "$ROOT/bin/fm-slack-mirror.sh" --replay "$ROOT/tests/fixtures/slack/card-payload/transcript.json"; echo "[exit $?]"
python3 -c "import json,sys; [print('card:', r['key'], 'owner=', (r.get('owner') or {}).get('id','main')) for r in json.load(open(sys.argv[1]))['threads'].values()]" "$T/main/state/slack-watch/state.json"
