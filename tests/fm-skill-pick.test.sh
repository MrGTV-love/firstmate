#!/usr/bin/env bash
# Public skill-pick behavior: the cookbook's two requests on the vendored
# client, no-fit, TypeSafe direct first with the OpenRouter fallback, the
# shared never-send and key boundary, chunking past 255 skills, and the
# launch-instructions section every ship and scout spawn receives.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v node >/dev/null 2>&1 || { printf 'ok - skipped: node is not installed\n'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-skill-pick)
TOOL="$ROOT/bin/fm-skill-pick.sh"
HOME_DIR="$TMP_ROOT/home"
COPY="$TMP_ROOT/project"
LOG="$TMP_ROOT/requests.jsonl"
FAKE_FETCH="$TMP_ROOT/fake-fetch.mjs"
mkdir -p "$HOME_DIR/config" "$COPY"
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE

# The vendored client calls global fetch; this stand-in answers every question
# shape it receives and logs which endpoint and key each request used.
cat > "$FAKE_FETCH" <<'JS'
import { appendFileSync } from 'node:fs';
const env = process.env;
globalThis.fetch = async (url, init) => {
  const provider = String(url).includes('openrouter') ? 'openrouter' : 'typesafe';
  const body = JSON.parse(init.body);
  appendFileSync(env.FAKE_LOG, JSON.stringify({ provider, auth: init.headers.Authorization, body }) + '\n');
  const mode = provider === 'openrouter' ? env.FAKE_OPENROUTER || 'ok' : env.FAKE_TYPESAFE || 'ok';
  if (mode === 'hang') {
    return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(init.signal.reason)));
  }
  if (mode !== 'ok') return new Response('{}', { status: Number(mode) });
  const answers = {};
  for (const [id, q] of Object.entries(body.questions)) {
    if (q.type === 'noul') {
      const gate = Number(env.FAKE_GATE || 0.8);
      const value = id === 'gate::prose_suffices' ? 1 - gate : id.startsWith('gate::') ? gate : Number(env.FAKE_FIT || 0.7);
      answers[id] = { type: 'noul', noul: value };
    } else {
      const keys = Object.keys(q.criteria);
      const pick = keys.includes(env.FAKE_PICK) ? env.FAKE_PICK : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1,
        probabilities: Object.fromEntries(keys.map((k) => [k, k === pick ? 1 : 0])) };
    }
  }
  return new Response(JSON.stringify({ model: `${provider}-jev-test`, answers, usage: { input_tokens: 1, output_tokens: 1 } }));
};
JS

skill() { # <dir> <name> <description-line>
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\n%s\n---\n# %s\nOpening instructions for %s.\n' "$2" "$3" "$2" "$2" > "$1/$2/SKILL.md"
}
git init -q "$COPY"
skill "$COPY/.agents/skills" alpha 'description: Use for alpha work.'
skill "$COPY/.agents/skills" beta 'description: >
  Use for beta work: folded
  over two lines [with brackets].'
skill "$COPY/.agents/skills" gamma 'description: "Use for gamma work."'
skill "$COPY/.claude/skills" beta 'description: CLAUDE-COPY-DESCRIPTION'
skill "$COPY/.claude/skills" delta "description: 'Use for delta work.'"
git -C "$COPY" add -- .agents .claude
skill "$COPY/.agents/skills" scratch 'description: Untracked local skill.'

cat > "$TMP_ROOT/brief.md" <<'EOF'
# Task
## Captain's intent
Make the alpha report export faster.

## Firstmate spec
Measure before and after.

## Standard boilerplate
BOILERPLATE-NOT-SENT
EOF

reset() { : > "$LOG"; rm -f "$TMP_ROOT/record"; printf '' > "$HOME_DIR/config/dispatch-never-send"; }
keys() { printf 'TYPESAFE_API_KEY=ts-test-key\nOPENROUTER_API_KEY=%s\n' "${1-or-test-key}" > "$HOME_DIR/.env"; }
pick() {
  env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" "$@" \
    bash "$TOOL" --brief "$TMP_ROOT/brief.md" \
    --catalog "$COPY/.agents/skills" --catalog "$COPY/.claude/skills" --record "$TMP_ROOT/record"
}
requests() { jq -s length "$LOG"; }

reset; keys
out=$(pick FAKE_PICK=beta)
assert_contains "$out" "# Skill selection" "the launch section is printed"
assert_contains "$out" "Existing mandatory skill triggers in these instructions and your skill index still apply first and unchanged." "mandatory triggers stay first"
assert_contains "$out" "read this skill in full and follow it" "the pick is to be loaded and followed"
assert_contains "$out" "- Picked for this task: beta - read $(cd "$COPY" && pwd -P)/.agents/skills/beta/SKILL.md" "the pick resolves inside the project copy"
assert_contains "$out" "Picked by typesafe-jev-test through typesafe" "the resolved model and provider are named"
assert_contains "$out" "Not judged, so check them yourself if relevant: scratch (not a Git-tracked file in this project)." "an unsent skill is listed, not dropped"
assert_equals "status=picked" "$(sed -n 1p "$TMP_ROOT/record")" "the record carries the status"
assert_equals "picked=beta" "$(sed -n 3p "$TMP_ROOT/record")" "the record carries the pick"
assert_equals 2 "$(requests)" "the cookbook makes two requests"
jq -se 'all(.[]; .provider == "typesafe" and .auth == "Bearer ts-test-key")' "$LOG" >/dev/null \
  || fail "TypeSafe is asked directly with the home key"
jq -se '.[0].body | (.questions.which.criteria | keys) == ["alpha","beta","delta","gamma"]
  and .questions.which.criteria.beta == "Use for beta work: folded over two lines [with brackets]."
  and ([.questions | keys[] | select(startswith("gate::"))] | length) == 3
  and .questions.which.instructions == "Which of these skills, if any, is the right one to load to help with the user'"'"'s latest request?"
  and .state.recent_context == "" and .model == "jev-latest"' "$LOG" >/dev/null \
  || fail "request 1 ranks each tracked skill once, the earlier folder winning, with the three gates"
jq -se '.[1].body.questions | (.which.criteria | length) == 3
  and (.which.criteria.beta | startswith("Use for beta work: folded over two lines [with brackets]. — # beta"))
  and has("fits::alpha") and has("fits::beta") and has("fits::gamma")' "$LOG" >/dev/null \
  || fail "request 2 rereads the top three with excerpts and one fits noul each"
sent=$(jq -r '.body.state.request' "$LOG")
assert_contains "$sent" "Make the alpha report export faster." "the captain's intent is sent"
assert_not_contains "$sent" BOILERPLATE-NOT-SENT "only the dispatch-permitted task text is sent"
assert_not_contains "$(cat "$LOG")" CLAUDE-COPY-DESCRIPTION "a later folder's copy of a name is not sent"
assert_not_contains "$out" ts-test-key "the key is never printed"
pass "a clear task picks one project skill through TypeSafe direct"

reset; keys
out=$(pick FAKE_GATE=0.1)
assert_contains "$out" "Skill selection found no project skill that fits this task (need 0.10 below 0.3)" "a low need picks nothing"
assert_equals 1 "$(requests)" "a low need stops after request 1"
reset; keys
out=$(pick FAKE_FIT=0.2)
assert_contains "$out" "(best fit 0.20 below 0.3)" "a low best fit picks nothing"
assert_equals "status=none" "$(sed -n 1p "$TMP_ROOT/record")" "no fit is recorded as none"
pass "the cookbook's two thresholds can each pick nothing"

reset; keys
out=$(pick FAKE_TYPESAFE=500 FAKE_PICK=gamma)
assert_contains "$out" "- Picked for this task: gamma" "the OpenRouter fallback still picks"
assert_contains "$out" "through openrouter" "the fallback provider is named"
jq -se '.[0].provider == "typesafe" and .[0].auth == "Bearer ts-test-key"
  and .[1].provider == "openrouter" and .[1].auth == "Bearer or-test-key" and .[1].body.model == "~typesafe/jev-latest"
  and .[2].provider == "openrouter" and length == 3' "$LOG" >/dev/null \
  || fail "a failed direct call is asked again through OpenRouter, which serves the rest of the run"
assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "TypeSafe direct failed (typesafe HTTP 500.; used OpenRouter)" "the record says why OpenRouter was used"
reset; keys ''
out=$(pick FAKE_TYPESAFE=500)
assert_contains "$out" "Skill selection was unavailable for this task (typesafe HTTP 500.)" "without an OpenRouter key a direct failure is unavailable"
assert_equals "status=unavailable" "$(sed -n 1p "$TMP_ROOT/record")" "the failure is recorded"
reset; printf 'OPENROUTER_API_KEY=or-test-key\n' > "$HOME_DIR/.env"
out=$(pick)
assert_contains "$out" "through openrouter" "an OpenRouter key alone is used"
reset; : > "$HOME_DIR/.env"
out=$(pick)
assert_contains "$out" "(no TypeSafe or OpenRouter key)" "no key is unavailable"
assert_equals 0 "$(requests)" "no key sends nothing"
reset; keys
out=$(OPENROUTER_API_KEY=ambient-key pick FAKE_TYPESAFE=500)
assert_not_contains "$(cat "$LOG")" ambient-key "an ambient OpenRouter key is never used"
pass "TypeSafe direct first, OpenRouter on a failed direct call, keys from the home .env only"

reset; keys
printf 'Use for delta work\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(pick)
assert_contains "$out" "withheld by dispatch-never-send policy" "a never-send literal in a skill description withholds the request"
assert_equals 0 "$(requests)" "a withheld request sends nothing"
reset; keys
printf 'alpha report export\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(pick)
assert_contains "$out" "withheld by dispatch-never-send policy" "a never-send literal in the task withholds the request"
assert_equals 0 "$(requests)" "a withheld task sends nothing"
pass "the dispatch-never-send policy covers every string a request can carry"

reset; keys
BIG="$TMP_ROOT/big"
git init -q "$BIG"
for i in $(seq 1 300); do skill "$BIG/skills" "skill-$i" "description: Use for numbered task $i."; done
git -C "$BIG" add -- skills
out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" FAKE_PICK=skill-7 \
  bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$BIG/skills")
assert_contains "$out" "- Picked for this task: skill-7" "a skill in a later chunk can win"
jq -se '.[0].body.questions | (keys | map(select(startswith("which"))) | sort) == ["which::1","which::2"]
  and ([.["which::1"].criteria, .["which::2"].criteria | keys | length] | add) == 300' "$LOG" >/dev/null \
  || fail "300 skills are split into Choice questions of at most 255, none dropped"
pass "a roster above 255 skills is ranked in chunks"

reset; keys
out=$(pick FAKE_TYPESAFE=hang FAKE_PICK=alpha)
assert_contains "$out" "- Picked for this task: alpha" "a hung direct call falls back after its own deadline"
assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "TypeSafe direct failed" "the hang is recorded"
pass "a hung TypeSafe call is bounded and falls back"

# A real ship launch: the section lands in the launch instructions before the
# no-mistakes intent overlay, and the task record carries the outcome.
spawn_case() { # <id> -> sets SPAWN_HOME SPAWN_POOL SPAWN_PROJECT SPAWN_FAKEBIN
  local dir="$TMP_ROOT/spawn-$1"
  SPAWN_HOME="$dir/home" SPAWN_PROJECT="$dir/project" SPAWN_POOL="$dir/pool"
  SPAWN_FAKEBIN=$(make_spawn_fakebin "$dir/fake")
  mkdir -p "$SPAWN_HOME/data/$1" "$SPAWN_HOME/projects" "$SPAWN_HOME/state" "$SPAWN_HOME/config"
  printf 'codex\n' > "$SPAWN_HOME/config/crew-harness"
  fm_test_spawn_brief "$SPAWN_HOME" "$1" "Make the alpha report export faster."
  touch "$SPAWN_HOME/state/.last-watcher-beat"
  git init --quiet -b main "$SPAWN_PROJECT"
  skill "$SPAWN_PROJECT/.agents/skills" alpha 'description: Use for alpha work.'
  skill "$SPAWN_PROJECT/.agents/skills" beta 'description: Use for beta work.'
  git -C "$SPAWN_PROJECT" add .agents
  git -C "$SPAWN_PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$SPAWN_PROJECT" worktree add --quiet --detach "$SPAWN_POOL" HEAD
}
reset
spawn_case pick-ship
printf 'TYPESAFE_API_KEY=ts-spawn-key\n' > "$SPAWN_HOME/.env"
out=$(FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FAKE_PICK=alpha \
  fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_POOL" "$SPAWN_FAKEBIN" pick-ship "$SPAWN_PROJECT" --mode no-mistakes --yolo off)
assert_contains "$out" "spawned pick-ship" "the ship launches"
assert_contains "$out" "skill selection for pick-ship: picked (alpha)" "the spawn reports the pick"
launch="$SPAWN_HOME/data/pick-ship/launch-brief.md"
assert_contains "$(cat "$launch")" "- Picked for this task: alpha - read $SPAWN_POOL/.agents/skills/alpha/SKILL.md" "the pick is in the launch instructions, inside the task copy"
section=$(grep -n '^# Skill selection$' "$launch" | cut -d: -f1)
overlay=$(grep -n '^# Current no-mistakes intent contract$' "$launch" | cut -d: -f1)
[ -n "$section" ] && [ -n "$overlay" ] && [ "$section" -lt "$overlay" ] \
  || fail "the skill section precedes the intent overlay, so it never becomes --intent text"
grep -qx 'skill_selection=picked' "$SPAWN_HOME/state/pick-ship.meta" || fail "the task record carries the status"
grep -qx 'skill_selection_picked=alpha' "$SPAWN_HOME/state/pick-ship.meta" || fail "the task record carries the pick"
assert_not_contains "$(cat "$launch" "$SPAWN_HOME/state/pick-ship.meta")" ts-spawn-key "the key never reaches the launch or the record"
pass "a ship launch adds the pick to its instructions and task record"

reset
spawn_case nokey-scout
out=$(FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" \
  fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_POOL" "$SPAWN_FAKEBIN" nokey-scout "$SPAWN_PROJECT" --scout)
assert_contains "$out" "spawned nokey-scout" "a scout launches without a key"
assert_contains "$(cat "$SPAWN_HOME/data/nokey-scout/launch-brief.md")" "Skill selection was unavailable for this task (no TypeSafe or OpenRouter key)." "the instructions say why"
grep -qx 'skill_selection=unavailable' "$SPAWN_HOME/state/nokey-scout.meta" || fail "the task record says unavailable"
grep -qx 'skill_selection_reason=no TypeSafe or OpenRouter key' "$SPAWN_HOME/state/nokey-scout.meta" || fail "the task record says why"
assert_equals 0 "$(requests)" "nothing is sent without a key"
pass "a launch with no key proceeds and records why nothing was picked"

printf '# all fm-skill-pick tests passed\n'
