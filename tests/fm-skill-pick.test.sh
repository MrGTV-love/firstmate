#!/usr/bin/env bash
# Public skill-pick behavior: the cookbook's two requests on the vendored
# client, no-fit, TypeSafe direct first with the OpenRouter fallback, the
# shared never-send and key boundary, chunking past 255 skills, and the
# launch-instructions section every ship and scout spawn receives.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v node >/dev/null 2>&1 || { printf 'skip: node not found\n'; exit 0; }
if prerequisite=$(node "$ROOT/bin/fm-skill-pick.mjs" check 2>&1); then
  :
else
  prerequisite_status=$?
  if [ "$prerequisite_status" -eq 77 ]; then
    printf 'skip: unsupported Node runtime\n%s\n' "$prerequisite"
    exit 0
  fi
  printf '%s\n' "$prerequisite" >&2
  exit "$prerequisite_status"
fi
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
let directCalls = 0;
globalThis.fetch = async (url, init) => {
  const provider = String(url).includes('openrouter') ? 'openrouter' : 'typesafe';
  const body = JSON.parse(init.body);
  appendFileSync(env.FAKE_LOG, JSON.stringify({ provider, auth: init.headers.Authorization, body }) + '\n');
  if (provider === 'typesafe') directCalls++;
  const mode = provider === 'openrouter' ? env.FAKE_OPENROUTER || 'ok' :
    env.FAKE_RERANK_FAIL && directCalls > 1 ? env.FAKE_RERANK_FAIL : env.FAKE_TYPESAFE || 'ok';
  if (mode === 'hang') {
    return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(init.signal.reason)));
  }
  if (mode !== 'ok') return new Response('{}', { status: Number(mode) });
  const answers = {};
  for (const [id, q] of Object.entries(body.questions)) {
    if (q.type === 'noul') {
      const gate = Number(env.FAKE_GATE || 0.8);
      const fits = JSON.parse(env.FAKE_FITS || '{}');
      const value = id === 'gate::prose_suffices' ? 1 - gate : id.startsWith('gate::') ? gate :
        fits[id.slice('fits::'.length)] ?? Number(env.FAKE_FIT || 0.7);
      answers[id] = { type: 'noul', noul: value };
    } else {
      const keys = Object.keys(q.criteria);
      const pick = keys.includes(env.FAKE_PICK) ? env.FAKE_PICK : keys[0];
      let probabilities = Object.fromEntries(keys.map((k) => [k, k === pick ? 1 : 0]));
      if (env.FAKE_WEIGHTED) {
        if (id === 'which::1') {
          const leading = [0.30, 0.29, 0.28];
          probabilities = Object.fromEntries(keys.map((k, i) => [k, leading[i] ?? 0.13 / (keys.length - 3)]));
        } else if (id === 'which::2') {
          probabilities = Object.fromEntries(keys.map((k, i) => [k, [0.34, 0.33, 0.33][i]]));
        } else {
          probabilities = Object.fromEntries(keys.map((k) => [k, k === 'skill-1' ? 0.60 : 0.40 / (keys.length - 1)]));
        }
      }
      const winner = Object.entries(probabilities).sort((a, b) => b[1] - a[1])[0][0];
      answers[id] = { type: 'choice', choice: winner, confidence: probabilities[winner], probabilities };
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

for whitespace in spaces tab newline; do
  reset; keys
  case "$whitespace" in
    spaces) path_project="$TMP_ROOT/project  repeated  spaces" ;;
    tab) path_project="$TMP_ROOT/"$'project\twith\ttabs' ;;
    newline) path_project="$TMP_ROOT/"$'Client  Reports\tQuarter\nNotes' ;;
  esac
  git init -q "$path_project"
  skill "$path_project/skills" alpha 'description: Use for alpha work.'
  git -C "$path_project" add -- skills
  selected_path="$(cd "$path_project" && pwd -P)/skills/alpha/SKILL.md"
  out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" \
    bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$path_project/skills" --record "$TMP_ROOT/record")
  assert_contains "$out" "- Picked for this task: alpha - read $selected_path" "the launch instruction preserves $whitespace in the project path"
  [ -f "$selected_path" ] || fail "the emitted selected path identifies the existing skill"
  grep -qx 'status=picked' "$TMP_ROOT/record" || fail "the whitespace project selection is recorded"
  assert_equals 2 "$(requests)" "a whitespace project path completes selection"
done
pass "selected paths preserve repeated spaces, tabs and embedded newlines"

for roster_case in absent empty untracked undescribed partial; do
  roster="$TMP_ROOT/roster-$roster_case"
  git init -q "$roster"
  case "$roster_case" in
    absent) ;;
    empty) mkdir -p "$roster/skills" ;;
    untracked) skill "$roster/skills" scratch 'description: Untracked local skill.' ;;
    undescribed) skill "$roster/skills" blank ''; git -C "$roster" add -- skills ;;
    partial)
      skill "$roster/skills" alpha 'description: Use for alpha work.'
      skill "$roster/skills" blank ''
      git -C "$roster" add -- skills
      skill "$roster/skills" scratch 'description: Untracked local skill.'
      ;;
  esac
  thresholds=(gate)
  [ "$roster_case" != partial ] || thresholds+=(fit)
  for threshold in "${thresholds[@]}"; do
    reset; keys
    if [ "$threshold" = gate ]; then threshold_env=FAKE_GATE=0.1
    else threshold_env=FAKE_FIT=0.2; fi
    out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" "$threshold_env" \
      bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$roster/skills" --record "$TMP_ROOT/record")
    case "$roster_case" in
      absent|empty)
        status=none; reason='this project has no skills to judge'; count=0
        assert_contains "$out" "Skill selection found no fit among the judged project skills ($reason)" "an $roster_case roster reports no skills"
        ;;
      untracked|undescribed)
        status=unavailable; count=0
        if [ "$roster_case" = untracked ]; then excluded='scratch (not a Git-tracked file in this project)'
        else excluded='blank (no readable description)'; fi
        reason="no project skills could be judged: $excluded"
        assert_contains "$out" "Skill selection was unavailable for this task ($reason)" "an entirely excluded roster is unavailable"
        assert_contains "$out" "Not judged, so check them yourself if relevant: $excluded." "excluded skills remain visible"
        ;;
      partial)
        status=none
        if [ "$threshold" = gate ]; then reason='no judged project skill fits this task: need 0.10 below 0.3'; count=1
        else reason='no judged project skill fits this task: best fit 0.20 below 0.3'; count=2; fi
        assert_contains "$out" "Skill selection found no fit among the judged project skills ($reason)" "a low $threshold applies only to judged skills"
        assert_contains "$out" "blank (no readable description)" "an undescribed skill remains visible beside a low $threshold"
        assert_contains "$out" "scratch (not a Git-tracked file in this project)" "an untracked skill remains visible beside a low $threshold"
        jq -se 'all(.[]; (.body.questions.which.criteria | keys) == ["alpha"])' "$LOG" >/dev/null \
          || fail "only the judged skill enters requests"
        ;;
    esac
    grep -Fqx "status=$status" "$TMP_ROOT/record" || fail "the $roster_case $threshold status is recorded"
    grep -Fqx "reason=$reason" "$TMP_ROOT/record" || fail "the $roster_case $threshold reason is recorded"
    assert_equals "$count" "$(requests)" "the $roster_case $threshold request count"
  done
done
pass "empty, excluded and partially judged rosters have distinct outcomes"

reset; keys
out=$(pick FAKE_GATE=0.1)
assert_contains "$out" "Skill selection found no fit among the judged project skills (no judged project skill fits this task: need 0.10 below 0.3)" "a low need picks nothing"
assert_equals 1 "$(requests)" "a low need stops after request 1"
reset; keys
out=$(pick FAKE_FIT=0.2)
assert_contains "$out" "Skill selection found no fit among the judged project skills (no judged project skill fits this task: best fit 0.20 below 0.3)" "a low best fit is limited to judged skills"
assert_equals "status=none" "$(sed -n 1p "$TMP_ROOT/record")" "no fit is recorded as none"
pass "the cookbook's two thresholds can each pick nothing"

reset; keys
out=$(pick FAKE_PICK=alpha FAKE_FITS='{"alpha":0.1,"beta":0.8,"gamma":0.4}')
assert_contains "$out" "- Picked for this task: beta" "the highest fitting shortlist skill wins even when Choice prefers a low-fit skill"
reset; keys
out=$(pick FAKE_FIT=0.30)
assert_equals "status=picked" "$(sed -n 1p "$TMP_ROOT/record")" "a fit exactly at .30 is accepted"
pass "selection uses the highest fit and the inclusive threshold"

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

for exit_case in gate fit picked unavailable; do
  reset; keys
  case "$exit_case" in
    gate) out=$(pick FAKE_TYPESAFE=500 FAKE_GATE=0.1) ;;
    fit) out=$(pick FAKE_TYPESAFE=500 FAKE_FIT=0.1) ;;
    picked) out=$(pick FAKE_TYPESAFE=500) ;;
    unavailable) out=$(pick FAKE_TYPESAFE=500 FAKE_OPENROUTER=500) ;;
  esac
  assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "TypeSafe direct failed" "fallback provenance survives $exit_case finalization"
done
reset; keys
out=$(pick FAKE_RERANK_FAIL=500)
assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "TypeSafe direct failed" "rerank fallback provenance is attached"
assert_contains "$out" "through openrouter" "rerank fallback serves the final pick"
pass "fallback provenance is finalized for every outcome"

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

for forbidden in "It is described as: Use for alpha work." "Use for alpha work. — # alpha" "Exactly one of these skills" "Is the assistant being asked" "jev-latest"; do
  reset; keys
  printf '%s\n' "$forbidden" > "$HOME_DIR/config/dispatch-never-send"
  out=$(pick)
  assert_contains "$out" "withheld by dispatch-never-send policy" "the assembled body checks $forbidden"
  case "$forbidden" in
    "It is described"*|"Use for alpha"*|"Exactly one"*) expected=1 ;;
    *) expected=0 ;;
  esac
  assert_equals "$expected" "$(requests)" "withheld assembled bodies never reach either provider"
done
reset; keys
printf '~typesafe/jev-latest\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(pick FAKE_TYPESAFE=500)
assert_equals 1 "$(requests)" "the fallback model is separately checked before transport"
assert_contains "$out" "withheld by dispatch-never-send policy" "fallback privacy rejection is reported"
assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "TypeSafe direct failed" "fallback privacy rejection retains direct provenance"
pass "actual assembled criteria, instructions and both provider models are checked"
reset; keys
skill "$COPY/.agents/skills" gamma 'description: Use for report work.'
printf 'gamma\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(pick)
assert_contains "$out" "withheld by dispatch-never-send policy" "skill identities in Choice keys are checked"
assert_equals 0 "$(requests)" "a forbidden Choice key stops the first request"
skill "$COPY/.agents/skills" gamma 'description: "Use for gamma work."'

reset; keys
BIG="$TMP_ROOT/big"
git init -q "$BIG"
for i in $(seq 1 258); do skill "$BIG/skills" "skill-$i" "description: Use for numbered task $i."; done
git -C "$BIG" add -- skills
out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" FAKE_WEIGHTED=1 \
  FAKE_FITS='{"skill-1":0.9}' FAKE_FIT=0.1 bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$BIG/skills")
assert_contains "$out" "- Picked for this task: skill-1" "a lower local probability survives into a common ranking"
jq -se '.[0].body.questions | (keys | map(select(startswith("which"))) | sort) == ["which::1","which::2"]
  and ([.["which::1"].criteria, .["which::2"].criteria | keys | length] | add) == 258' "$LOG" >/dev/null \
  || fail "258 skills are split into Choice questions of at most 255, none dropped"
jq -se '.[1].body.questions.which.criteria | has("skill-1") and has("skill-99") and length == 6' "$LOG" >/dev/null \
  || fail "chunk shortlists enter a common ranking before detailed rerank"
jq -se 'all(.[]; all(.body.questions[]; .type != "choice" or (.criteria | length) <= 255))' "$LOG" >/dev/null \
  || fail "every Choice stays within the transport limit"
assert_equals 3 "$(requests)" "a chunked roster adds the common ranking request"
pass "non-point-mass chunk probabilities are not globally flattened"

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


reset; keys
out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" \
  bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$TMP_ROOT/missing" --catalog "$COPY/.agents/skills")
assert_contains "$out" "- Picked for this task:" "a missing optional catalog is skipped"
reset; keys
out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FM_HOME="$HOME_DIR" \
  bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$TMP_ROOT/brief.md")
assert_contains "$out" "could not enumerate skill catalog" "an existing non-directory catalog is unavailable"
assert_contains "$out" "$TMP_ROOT/brief.md" "the catalog failure identifies its path"
assert_equals 0 "$(requests)" "a broken catalog never sends a partial roster"
cat > "$TMP_ROOT/io-failure.mjs" <<'JS'
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const original = fs[process.env.FAIL_OPERATION];
fs[process.env.FAIL_OPERATION] = (path, ...args) => {
  if (String(path) === process.env.FAIL_PATH) {
    throw Object.assign(new Error(`permission denied: ${path}`), { code: 'EACCES' });
  }
  return original(path, ...args);
};
syncBuiltinESMExports();
JS
for operation in readdirSync openSync; do
  reset; keys
  case "$operation" in
    readdirSync) failure_path="$(cd "$COPY" && pwd -P)/.agents/skills" ;;
    openSync) failure_path="$(cd "$COPY" && pwd -P)/.agents/skills/alpha/SKILL.md" ;;
  esac
  out=$(env FAIL_OPERATION="$operation" FAIL_PATH="$failure_path" FAKE_LOG="$LOG" \
    NODE_OPTIONS="--import=$FAKE_FETCH --import=$TMP_ROOT/io-failure.mjs" FM_HOME="$HOME_DIR" \
    bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$COPY/.agents/skills")
  assert_contains "$out" "permission denied" "existing catalog I/O failures remain actionable"
  assert_contains "$out" "$failure_path" "the unreadable entry is identified"
  assert_equals 0 "$(requests)" "I/O errors prevent transport"
done
pass "only absent catalogs are optional"

cat > "$TMP_ROOT/unsupported-loader.mjs" <<'JS'
export async function resolve(specifier, context, nextResolve) {
  if (specifier.endsWith('.ts')) {
    throw Object.assign(new Error('Unknown file extension ".ts"'), { code: 'ERR_UNKNOWN_FILE_EXTENSION' });
  }
  return nextResolve(specifier, context);
}
JS
reset; keys
out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH --loader=$TMP_ROOT/unsupported-loader.mjs" FM_HOME="$HOME_DIR" \
  bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$COPY/.agents/skills")
assert_contains "$out" "unsupported Node runtime" "failed imports explain the TypeScript runtime prerequisite"
assert_equals 0 "$(requests)" "unsupported runtimes never start selection"
pass "the prerequisite imports the actual vendored modules"
cat > "$TMP_ROOT/missing-module-loader.mjs" <<'JS'
export async function resolve(specifier, context, nextResolve) {
  if (specifier.endsWith('.ts')) {
    throw Object.assign(new Error('Cannot find vendored TypeScript module'), { code: 'ERR_MODULE_NOT_FOUND' });
  }
  return nextResolve(specifier, context);
}
JS
for loader_case in unsupported missing-module; do
  loader_options="--no-warnings --loader=$TMP_ROOT/$loader_case-loader.mjs"
  if check_out=$(env NODE_OPTIONS="$loader_options" node "$ROOT/bin/fm-skill-pick.mjs" check 2>&1); then
    check_status=0
  else check_status=$?; fi
  if [ "$loader_case" = unsupported ]; then
    assert_equals 77 "$check_status" "unsupported TypeScript imports have a distinct check exit"
    assert_contains "$check_out" "unsupported Node runtime:" "the executable check diagnoses an unsupported runtime"
    expected_suite_status=0
  else
    assert_equals 1 "$check_status" "missing modules fail the executable check"
    assert_contains "$check_out" "could not load vendored TypeScript client: Cannot find vendored TypeScript module" "missing modules are loading failures"
    assert_not_contains "$check_out" "unsupported Node runtime" "a missing module is not an unsupported runtime"
    expected_suite_status=1
  fi
  reset; keys
  out=$(env FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH $loader_options" FM_HOME="$HOME_DIR" \
    bash "$TOOL" --brief "$TMP_ROOT/brief.md" --catalog "$COPY/.agents/skills" --record "$TMP_ROOT/record")
  assert_contains "$out" "$check_out" "the picker reports the actual loader failure"
  grep -qx 'status=unavailable' "$TMP_ROOT/record" || fail "loader failure is recorded as unavailable"
  assert_equals 0 "$(requests)" "loader failures send no requests"
  if suite_out=$(env NODE_OPTIONS="$loader_options" bash "$ROOT/tests/fm-skill-pick.test.sh" 2>&1); then
    suite_status=0
  else suite_status=$?; fi
  assert_equals "$expected_suite_status" "$suite_status" "the suite distinguishes $loader_case prerequisites"
  if [ "$loader_case" = unsupported ]; then
    assert_equals "skip: unsupported Node runtime"$'\n'"$check_out" "$suite_out" "unsupported runtime suite skips are canonical"
  else
    assert_equals "$check_out" "$suite_out" "a broken vendored import fails the suite without skipping"
  fi
done
mkdir -p "$TMP_ROOT/no-node-bin"
ln -s "$(command -v dirname)" "$TMP_ROOT/no-node-bin/dirname"
suite_out=$(env PATH="$TMP_ROOT/no-node-bin" ROOT="$ROOT" FM_TEST_LIB_SOURCED=1 FM_TEST_FIXTURES_SOURCED=1 \
  /bin/bash "$ROOT/tests/fm-skill-pick.test.sh" 2>&1)
assert_equals 'skip: node not found' "$suite_out" "a missing Node executable produces the canonical suite skip"
pass "check and suite entry distinguish unsupported runtimes from broken imports"

for exit_case in gate fit picked unavailable; do
  reset
  printf 'OPENROUTER_API_KEY=or-test-key\n' > "$HOME_DIR/.env"
  case "$exit_case" in
    gate) out=$(pick FAKE_GATE=0.1) ;;
    fit) out=$(pick FAKE_FIT=0.1) ;;
    picked) out=$(pick) ;;
    unavailable) out=$(pick FAKE_OPENROUTER=500) ;;
  esac
  assert_contains "$(sed -n 2p "$TMP_ROOT/record")" "no TypeSafe key; used OpenRouter" "key-only fallback provenance survives $exit_case"
done
pass "OpenRouter key-only fallback retains provenance"

cp "$TMP_ROOT/brief.md" "$TMP_ROOT/ordinary-brief.md"
cat > "$TMP_ROOT/brief.md" <<'EOF'
# Task
This is a SCOUT task: the deliverable is a written report, not a PR.
## Captain's intent
PERMITTED-ORIGINAL-INTENT
## Firstmate spec
STALE-SCOUT-SPEC
# Current ship Firstmate spec
PERMITTED-CURRENT-SHIP-SPEC
EOF
reset; keys
out=$(pick)
sent=$(jq -r '.body.state.request' "$LOG")
assert_contains "$sent" PERMITTED-ORIGINAL-INTENT "promoted ships keep the original intent"
assert_contains "$sent" PERMITTED-CURRENT-SHIP-SPEC "promoted ships send the current spec"
assert_not_contains "$sent" STALE-SCOUT-SPEC "promoted ships omit the stale scout spec"
assert_not_contains "$sent" "Brief kind: scout" "promoted ships omit the scout tag"
. "$ROOT/bin/fm-typesafe-lib.sh"
fm_typesafe_brief_task "$TMP_ROOT/brief.md" "$HOME_DIR/config/dispatch-never-send" "$TMP_ROOT/default-task"
assert_contains "$(cat "$TMP_ROOT/default-task")" STALE-SCOUT-SPEC "dispatch's three-argument extraction remains unchanged"
assert_contains "$(cat "$TMP_ROOT/default-task")" "Brief kind: scout" "dispatch retains the scout tag"
assert_not_contains "$(cat "$TMP_ROOT/default-task")" PERMITTED-CURRENT-SHIP-SPEC "dispatch does not switch specs"
fm_typesafe_brief_task "$TMP_ROOT/brief.md" "$HOME_DIR/config/dispatch-never-send" "$TMP_ROOT/scout-task" scout
assert_contains "$(cat "$TMP_ROOT/scout-task")" STALE-SCOUT-SPEC "explicit scouts retain their spec"
for hidden in whole partial; do
  reset; keys
  printf '# dispatch-never-send marked-sections\n' > "$HOME_DIR/config/dispatch-never-send"
  case "$hidden" in
    whole) marker='<!-- dispatch-never-send:start -->'$'\n''# Current ship Firstmate spec' ;;
    partial) marker='# Current ship Firstmate spec'$'\n''<!-- dispatch-never-send:start -->' ;;
  esac
  printf '# Task\n## Captain'"'"'s intent\nPERMITTED-ORIGINAL-INTENT\n## Firstmate spec\nSTALE-SCOUT-SPEC\n%s\nHIDDEN-CURRENT-SPEC\n<!-- dispatch-never-send:end -->\n' "$marker" > "$TMP_ROOT/brief.md"
  [ "$hidden" != partial ] || printf 'PERMITTED-SPEC-REMAINDER\n' >> "$TMP_ROOT/brief.md"
  out=$(pick)
  sent=$(jq -r '.body.state.request' "$LOG")
  assert_contains "$sent" PERMITTED-ORIGINAL-INTENT "hidden overrides retain permitted intent"
  assert_not_contains "$sent" HIDDEN-CURRENT-SPEC "marked override text never leaves"
  assert_not_contains "$sent" STALE-SCOUT-SPEC "hidden overrides never revive stale instructions"
  [ "$hidden" != partial ] || assert_contains "$sent" PERMITTED-SPEC-REMAINDER "permitted override remainder is retained"
done
mv "$TMP_ROOT/ordinary-brief.md" "$TMP_ROOT/brief.md"
pass "promotion and marked regions preserve effective task privacy"

for raw in plain brief; do
  reset
  spawn_case "raw-$raw"
  printf 'TYPESAFE_API_KEY=ts-spawn-key\n' > "$SPAWN_HOME/.env"
  case "$raw" in
    plain) harness='custom-agent --flag' ;;
    brief) harness='custom-agent --brief __BRIEF__' ;;
  esac
  out=$(FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FAKE_PICK=alpha FM_FAKE_LAUNCH_LOG="$TMP_ROOT/raw-$raw.launch" \
    fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_POOL" "$SPAWN_FAKEBIN" "raw-$raw" "$SPAWN_PROJECT" --harness "$harness" --mode no-mistakes --yolo off)
  meta="$SPAWN_HOME/state/raw-$raw.meta"
  case "$raw" in
    plain)
      assert_equals 0 "$(requests)" "raw launches without brief transport do not invoke the picker"
      grep -qx 'skill_selection=undelivered' "$meta" || fail "raw launch records undelivered"
      assert_not_contains "$(cat "$meta")" "skill_selection_picked=" "undelivered launches never record a pick"
      assert_contains "$(cat "$TMP_ROOT/raw-$raw.launch")" 'custom-agent --flag' "the raw command is retained"
      ;;
    brief)
      assert_equals 2 "$(requests)" "raw launches with a brief perform normal selection"
      grep -qx 'skill_selection=picked' "$meta" || fail "raw brief launch records the pick"
      assert_contains "$(cat "$SPAWN_HOME/data/raw-$raw/launch-brief.md")" "- Picked for this task: alpha" "raw brief transport receives the section"
      ;;
  esac
done
pass "raw launch records match delivery capability"

reset
spawn_case failed-overlay
printf 'TYPESAFE_API_KEY=ts-spawn-key\n' > "$SPAWN_HOME/.env"
real_mv=$(command -v mv)
cat > "$SPAWN_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
if [[ "${2:-}" == */launch-brief.md ]]; then
  if [ -e "$PUBLICATION_COUNT" ]; then exit 1; fi
  : > "$PUBLICATION_COUNT"
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$SPAWN_FAKEBIN/mv"
out=$(FAKE_LOG="$LOG" NODE_OPTIONS="--import=$FAKE_FETCH" FAKE_PICK=alpha \
  REAL_MV="$real_mv" PUBLICATION_COUNT="$TMP_ROOT/publications" \
  fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_POOL" "$SPAWN_FAKEBIN" failed-overlay "$SPAWN_PROJECT" --mode no-mistakes --yolo off)
assert_equals 2 "$(requests)" "selection completed before the overlay publication failed"
grep -qx 'skill_selection=undelivered' "$SPAWN_HOME/state/failed-overlay.meta" || fail "overlay failure is recorded as undelivered"
assert_not_contains "$(cat "$SPAWN_HOME/state/failed-overlay.meta")" "skill_selection_picked=" "an unpublished pick is not recorded"
assert_not_contains "$(cat "$SPAWN_HOME/data/failed-overlay/launch-brief.md")" "# Skill selection" "publication failure retains the original launch brief"
pass "successful picks are not claimed when overlay publication fails"

reset; keys
fm_typesafe_brief_task "$TMP_ROOT/brief.md" "$HOME_DIR/config/dispatch-never-send" "$TMP_ROOT/explicit-scout-task" scout
assert_contains "$(cat "$TMP_ROOT/explicit-scout-task")" "Brief kind: scout" "recorded scout kind does not depend on a brief sentinel"
cat > "$TMP_ROOT/fully-hidden.md" <<'EOF'
# Task
This is a SCOUT task: the deliverable is a written report, not a PR.
<!-- dispatch-never-send:start -->
## Captain's intent
HIDDEN-INTENT
<!-- dispatch-never-send:end -->
## Firstmate spec
STALE-SCOUT-SPEC
<!-- dispatch-never-send:start -->
# Current ship Firstmate spec
HIDDEN-CURRENT-SPEC
<!-- dispatch-never-send:end -->
EOF
printf '# dispatch-never-send marked-sections\n' > "$HOME_DIR/config/dispatch-never-send"
fm_typesafe_brief_task "$TMP_ROOT/fully-hidden.md" "$HOME_DIR/config/dispatch-never-send" "$TMP_ROOT/hidden-task" ship
assert_equals "" "$(cat "$TMP_ROOT/hidden-task")" "fully hidden effective promoted task does not fall back to stale boilerplate"
pass "explicit kind and entirely hidden promotion preserve task semantics"

printf '# all fm-skill-pick tests passed\n'
