#!/usr/bin/env bash
# Retirement test for jev-belay-stop. A completion Stop is a lifecycle event,
# not a second evidence gate: even an installed vendor hook that would reject
# the turn must not run or strand the worker busy. Review and DoD judge proof.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-belay-stop)
trap fm_test_cleanup EXIT

home="$TMP_ROOT/home"
project="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
id=retired-stop
fm_test_spawn_home "$home" claude
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_git_worktree "$project" "$wt" wt-stop
fm_test_spawn_brief "$home" "$id" 'Fix the badge refresh.'
# A deterministic local rejection, with no API call or real credential.
vendor="$home/data/vendor/jev-belay/belay.mjs"
mkdir -p "$(dirname "$vendor")"
printf 'TYPESAFE_API_KEY=retirement-fixture-key\n' > "$home/.env"
cat > "$vendor" <<'JS'
import { writeFileSync } from 'node:fs';
writeFileSync(process.env.FM_TEST_BELAY_SEEN, 'called');
process.stderr.write('completion needs evidence\n');
process.exit(2);
JS
blob=$(git hash-object -- "$vendor") || fail 'cannot pin synthetic rejection'
out=$(FM_BACKEND=tmux fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$project" --mode no-mistakes --yolo off) \
  || fail "Claude fixture did not spawn: $out"
settings="$wt/.claude/settings.local.json"
run_event() {
  local command
  while IFS= read -r command; do
    [ -n "$command" ] || fail "missing $1 command"
    printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done. The badge refresh is fixed."}' \
      | FM_HOME="$home" FM_TEST_SEAM=1 FM_JEV_BELAY_BLOB="$blob" \
        FM_TEST_BELAY_SEEN="$TMP_ROOT/vendor-called" bash -c "$command" || return $?
  done <<EOF
$(jq -er --arg event "$1" '.hooks[$event][].hooks[].command' "$settings")
EOF
}
run_event UserPromptSubmit || fail 'submit hook failed'
state=$(fm_busy_classify tmux fake:w claude "$id" "$home/state")
[ "$state" = 'busy claude-hook' ] || fail "submit did not open the turn: $state"
rm -f "$home/state/$id.turn-ended"
run_event Stop || fail 'a completion Stop was still rejected by an evidence judgment'
assert_absent "$TMP_ROOT/vendor-called" 'Stop still invoked the retired vendor judgment'
assert_present "$home/state/$id.turn-ended" 'Stop did not publish the completion notification'
state=$(fm_busy_classify tmux fake:w claude "$id" "$home/state")
[ "$state" = 'idle claude-hook' ] || fail "Stop stranded the worker busy: $state"
pass 'Claude completion Stop closes the turn without consulting the installed evidence judgment'
