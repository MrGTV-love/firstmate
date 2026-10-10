#!/usr/bin/env bash
# Behavior tests for bin/fm-model-freshness.sh: a configured or requested model
# that a newer model of the same family has passed in its harness's own catalog.
# Catalogs are fixtures (FM_MODEL_CATALOG_DIR) except where a case runs the real
# discovery path against a stub `agy` on PATH.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-freshness)
TOOL="$ROOT/bin/fm-model-freshness.sh"
HOME_DIR="$TMP_ROOT/home"
CATALOGS="$TMP_ROOT/catalogs"
mkdir -p "$HOME_DIR/config" "$CATALOGS"
export FM_HOME="$HOME_DIR" FM_MODEL_CATALOG_DIR="$CATALOGS" FM_MODEL_FRESHNESS=1
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
DISPATCH="$HOME_DIR/config/crew-dispatch.json"

printf '%s\n' '{"models":[{"id":"gemini-3.1-pro-high"},{"id":"gemini-3.1-pro-low"},{"id":"gemini-3.7-flash-high"},{"id":"gemini-3.8-flash-high"},{"id":"gemini-3.8-flash-low"}]}' > "$CATALOGS/agy.json"
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-opus-5-5"},{"id":"claude-opus-5-5"},{"id":"sonnet","resolved_id":"claude-sonnet-5[1m]"},{"id":"claude-sonnet-5[1m]"},{"id":"claude-sonnet-5-5[1m]","resolved_id":"claude-sonnet-5-5"},{"id":"claude-sonnet-5-5"},{"id":"claude-haiku-5-5"}]}' > "$CATALOGS/claude.json"
printf '%s\n' '{"models":[{"id":"openai-codex/gpt-6.1-sol"},{"id":"openai-codex/gpt-6-luna"},{"id":"openai-codex/gpt-5.6-luna"},{"id":"openrouter/z-ai/glm-5.3"},{"id":"openrouter/z-ai/glm-5.4"},{"id":"openrouter/deepseek/deepseek-v4-flash"},{"id":"anthropic/claude-sonnet-5-5"}]}' > "$CATALOGS/omp.json"
printf '%s\n' '{"models":[{"id":"gpt-5.6-luna"},{"id":"gpt-6.1-sol"}]}' > "$CATALOGS/codex.json"

# check_line <harness> <model>: stdout of a single-model check; stderr is kept apart.
check_line() { "$TOOL" check "$1" "$2" 2> "$TMP_ROOT/stderr"; }
assert_stale() { # <harness> <model> <expected-line>
  local out
  out=$(check_line "$1" "$2")
  [ "$out" = "$3" ] || fail "expected [$3] for $1 $2, got [$out]"
}
assert_current() { # <harness> <model>
  local out
  out=$(check_line "$1" "$2")
  [ -z "$out" ] || fail "$1 $2 is current but was reported: $out"
}

# The case that started this: gemini-3.1-pro-high was launched while the agy
# catalog already listed gemini-3.8-flash-high.
assert_stale agy gemini-3.1-pro-high 'MODEL_FRESHNESS: gemini-3.1-pro-high on agy is older than gemini-3.8-flash-high in the agy catalog (other tier: flash)'
assert_stale agy gemini-3.1-pro-low 'MODEL_FRESHNESS: gemini-3.1-pro-low on agy is older than gemini-3.8-flash-low in the agy catalog (other tier: flash)'
assert_stale agy gemini-3.7-flash-high 'MODEL_FRESHNESS: gemini-3.7-flash-high on agy is older than gemini-3.8-flash-high in the agy catalog'
assert_current agy gemini-3.8-flash-high
assert_current agy gemini-3.8-flash-low
[ ! -s "$TMP_ROOT/stderr" ] || fail "a current model drew a notice: $(cat "$TMP_ROOT/stderr")"
pass 'a fixture catalog listing gemini-3.8-flash-high flags a requested gemini-3.1-pro-high and spares current models'

# Aliases the harness keeps current are current; versions compare as numbers, in
# either spelling Claude uses (5-5 and 5.5), and a context suffix does not count.
assert_current claude opus
assert_current claude 'opus[1m]'
assert_current claude sonnet
assert_stale claude 'claude-sonnet-5[1m]' 'MODEL_FRESHNESS: claude-sonnet-5[1m] on claude is older than claude-sonnet-5-5[1m] in the claude catalog'
assert_current claude 'claude-sonnet-5-5[1m]'
assert_current claude claude-haiku-5-5
assert_current omp openai-codex/gpt-6.1-sol
assert_current omp openai-codex/gpt-6.1-sol:high
assert_stale omp openai-codex/gpt-5.6-luna 'MODEL_FRESHNESS: openai-codex/gpt-5.6-luna on omp is older than openai-codex/gpt-6-luna in the omp catalog'
assert_stale omp openrouter/z-ai/glm-5.3 'MODEL_FRESHNESS: openrouter/z-ai/glm-5.3 on omp is older than openrouter/z-ai/glm-5.4 in the omp catalog'
pass 'aliases and context suffixes count as current; versions compare as numbers across spellings'

# A newer model from another provider route or another family is not a
# replacement: the same family under a different provider prefix is not offered.
assert_current omp openrouter/deepseek/deepseek-v4-flash
assert_current omp anthropic/claude-sonnet-5-5
mkdir -p "$TMP_ROOT/routes"
printf '%s\n' '{"models":[{"id":"openai-codex/gpt-6.1-sol"},{"id":"openrouter/openai/gpt-7-sol"}]}' > "$TMP_ROOT/routes/omp.json"
out=$(FM_MODEL_CATALOG_DIR="$TMP_ROOT/routes" "$TOOL" check omp openai-codex/gpt-6.1-sol 2>/dev/null)
[ -z "$out" ] || fail "a newer model on another provider route was offered as a replacement: $out"
pass 'a newer model under a different provider prefix is not a replacement'

# The harness decides. A harness with no readable catalog is a notice, never a guess.
out=$("$TOOL" check grok grok-3 2> "$TMP_ROOT/stderr")
[ -z "$out" ] || fail "a harness without a catalog produced a verdict: $out"
assert_contains "$(cat "$TMP_ROOT/stderr")" "grok catalog unavailable" 'a missing catalog must say so'
pass 'a harness without a readable catalog is a notice, not a verdict'

# scan: every model in config/crew-dispatch.json, role references resolved
# through the model index, nothing written, exit 0 whatever it finds.
cat > "$DISPATCH" <<'JSON'
{"rules":[
  {"when":"review","use":[{"harness":"agy","model":"gemini-3.1-pro-high","effort":"high"},{"harness":"claude","model":"opus"}]},
  {"when":"build","use":{"harness":"omp","role":"routine","effort":"high"}},
  {"when":"easy","use":{"harness":"codex","effort":"low"}}
 ],
 "default":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"agy","model":"gemini-3.1-pro-high"}]}
JSON
printf '%s\n' '{"version":1,"roles":{"routine":{"omp":{"model":"openai-codex/gpt-5.6-luna"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
cp "$DISPATCH" "$TMP_ROOT/dispatch-before.json"
cp "$HOME_DIR/config/model-index.json" "$TMP_ROOT/index-before.json"
status=0
"$TOOL" scan > "$TMP_ROOT/scan.out" 2> "$TMP_ROOT/scan.err" || status=$?
[ "$status" = 0 ] || fail "scan exited $status: $(cat "$TMP_ROOT/scan.err")"
[ "$(wc -l < "$TMP_ROOT/scan.out" | tr -d ' ')" = 2 ] || fail "scan must print one line per stale model, once each: $(cat "$TMP_ROOT/scan.out")"
assert_contains "$(cat "$TMP_ROOT/scan.out")" 'MODEL_FRESHNESS: gemini-3.1-pro-high on agy is older than gemini-3.8-flash-high in the agy catalog' 'the configured review model was not flagged'
assert_contains "$(cat "$TMP_ROOT/scan.out")" 'MODEL_FRESHNESS: openai-codex/gpt-5.6-luna on omp is older than openai-codex/gpt-6-luna in the omp catalog' 'a role-resolved model was not flagged'
cmp -s "$DISPATCH" "$TMP_ROOT/dispatch-before.json" || fail 'scan edited crew-dispatch.json'
cmp -s "$HOME_DIR/config/model-index.json" "$TMP_ROOT/index-before.json" || fail 'scan edited the model index'
pass 'scan names every stale configured model once, resolves roles, edits no config, and exits 0'

# A default-only dispatch file (no rules at all) is still scanned.
printf '%s\n' '{"default":[{"harness":"agy","model":"gemini-3.1-pro-high"}]}' > "$DISPATCH"
out=$("$TOOL" scan 2>/dev/null)
assert_contains "$out" 'gemini-3.1-pro-high on agy' 'a dispatch file with only a default was not scanned'
printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"agy","model":"gemini-3.1-pro-high"}}]}' > "$DISPATCH"
out=$("$TOOL" scan 2>/dev/null)
assert_contains "$out" 'gemini-3.1-pro-high on agy' 'a dispatch file with only rules was not scanned'

# A home without dispatch config, and a file the index refuses, stay quiet and exit 0.
rm -f "$HOME_DIR/config/model-index.json"
out=$("$TOOL" scan 2>/dev/null)
assert_contains "$out" 'gemini-3.1-pro-high on agy' 'literal models must still be checked without an index'
rm -f "$DISPATCH"
out=$("$TOOL" scan 2>&1) || fail 'scan without dispatch config exited non-zero'
[ -z "$out" ] || fail "scan without dispatch config was not silent: $out"
printf '%s\n' 'not json' > "$DISPATCH"
"$TOOL" scan > "$TMP_ROOT/scan.out" 2> "$TMP_ROOT/scan.err" || fail 'scan of a malformed dispatch file exited non-zero'
[ ! -s "$TMP_ROOT/scan.out" ] || fail 'scan of a malformed dispatch file printed a verdict'
rm -f "$DISPATCH"
pass 'scan is silent and exits 0 without a usable dispatch file'

# Usage errors are the only non-zero exit, and FM_MODEL_FRESHNESS=0 silences it.
status=0
"$TOOL" check agy >/dev/null 2>&1 || status=$?
[ "$status" = 2 ] || fail "a malformed call exited $status, not 2"
out=$(FM_MODEL_FRESHNESS=0 "$TOOL" check agy gemini-3.1-pro-high)
[ -z "$out" ] || fail 'FM_MODEL_FRESHNESS=0 did not turn the check off'
pass 'only a malformed call exits non-zero; FM_MODEL_FRESHNESS=0 turns the check off'

# Real discovery: `agy models` is the harness's own catalog, and a command that
# fails is a notice, never a verdict.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/agy" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = models ] || exit 2
[ -z "${FM_FAKE_AGY_FAIL:-}" ] || exit 1
printf '%s\n' 'Fetching available models...' \
  "gemini-3.8-flash-high	Gemini 3.8 Flash (High)" \
  "gemini-3.1-pro-high	Gemini 3.1 Pro (High)"
SH
chmod +x "$FAKEBIN/agy"
out=$(env -u FM_MODEL_CATALOG_DIR PATH="$FAKEBIN:$PATH" "$TOOL" check agy gemini-3.1-pro-high 2>/dev/null)
assert_contains "$out" 'gemini-3.1-pro-high on agy is older than gemini-3.8-flash-high' 'the live agy catalog path did not flag the stale model'
out=$(env -u FM_MODEL_CATALOG_DIR PATH="$FAKEBIN:$PATH" FM_FAKE_AGY_FAIL=1 "$TOOL" check agy gemini-3.1-pro-high 2> "$TMP_ROOT/stderr")
[ -z "$out" ] || fail "a failing catalog produced a verdict: $out"
assert_contains "$(cat "$TMP_ROOT/stderr")" 'agy catalog unavailable' 'a failing catalog must be reported as unavailable'
pass 'live discovery reads the harness catalog and a failing command is a notice, not a verdict'

# A catalog handed over on stdin is compared as-is: no discovery runs, and an
# unreadable one is a notice.
out=$(env -u FM_MODEL_CATALOG_DIR PATH="$TMP_ROOT/no-such-bin:/usr/bin:/bin" FM_MODEL_FRESHNESS_CATALOG=stdin "$TOOL" check agy gemini-3.1-pro-high < "$CATALOGS/agy.json" 2>/dev/null)
assert_contains "$out" 'gemini-3.1-pro-high on agy is older than gemini-3.8-flash-high' 'a catalog on stdin was not compared'
out=$(printf '%s\n' '{"models":[]}' | FM_MODEL_FRESHNESS_CATALOG=stdin "$TOOL" check agy gemini-3.1-pro-high 2> "$TMP_ROOT/stderr")
[ -z "$out" ] || fail "an empty catalog on stdin produced a verdict: $out"
assert_contains "$(cat "$TMP_ROOT/stderr")" 'agy catalog unavailable' 'an empty catalog on stdin must be reported as unavailable'
pass 'a catalog on stdin is compared without discovery, and an empty one is a notice'

# Spawn: the warning is advisory (the spawn succeeds, nothing is refused), it is
# printed for the supervisor, and it is recorded on the task.
CASE="$TMP_ROOT/spawn"
SPAWN_HOME="$CASE/home"
fm_test_spawn_home "$SPAWN_HOME" codex
fm_git_worktree "$CASE/project" "$CASE/wt" wt-freshness
fm_test_spawn_brief "$SPAWN_HOME" freshness-z1
SPAWN_FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
out=$(fm_test_run_spawn "$SPAWN_HOME" "$CASE/wt" "$SPAWN_FAKEBIN" freshness-z1 "$CASE/project" --mode no-mistakes --yolo off --model gpt-5.6-luna) \
  || fail "a stale model must not refuse the spawn: $out"
assert_contains "$out" 'warning: model is stale - gpt-5.6-luna on codex is older than gpt-6.1-sol in the codex catalog (other tier: sol)' 'spawn did not warn about the stale model'
assert_grep 'model_stale=gpt-5.6-luna on codex is older than gpt-6.1-sol in the codex catalog (other tier: sol)' "$SPAWN_HOME/state/freshness-z1.meta" 'the task record did not keep the warning'
crew=$(FM_HOME="$SPAWN_HOME" FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" freshness-z1 2>&1 || true)
assert_contains "$crew" 'model-stale: gpt-5.6-luna on codex is older than gpt-6.1-sol' 'the crew state line did not carry the stale-model note'

CASE2="$TMP_ROOT/spawn-current"
SPAWN_HOME2="$CASE2/home"
fm_test_spawn_home "$SPAWN_HOME2" codex
fm_git_worktree "$CASE2/project" "$CASE2/wt" wt-freshness-current
fm_test_spawn_brief "$SPAWN_HOME2" freshness-z2
SPAWN_FAKEBIN2=$(fm_test_make_spawn_fakebin "$CASE2/fake")
out=$(fm_test_run_spawn "$SPAWN_HOME2" "$CASE2/wt" "$SPAWN_FAKEBIN2" freshness-z2 "$CASE2/project" --mode no-mistakes --yolo off --model gpt-6.1-sol) \
  || fail "a current-model spawn failed: $out"
assert_not_contains "$out" 'model is stale' 'a current model drew the stale warning'
assert_no_grep 'model_stale=' "$SPAWN_HOME2/state/freshness-z2.meta" 'a current model left a stale record'
pass 'spawn warns, records the warning on the task, surfaces it in the crew state, and never refuses'

# Spawn reads each catalog at most once. A claude spawn under a worker account
# pin runs the model-index check against the real discovery path; a recording
# fake `claude` counts every catalog read, so the number is observable.
make_claude_fake() { # <fakebin> <read-log> <catalog-ids-file>
  cat > "$1/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
if [ "\${1:-}" = -p ] && [ "\${2:-}" = --input-format ]; then
  printf 'read\n' >> '$2'
  [ -f '$3' ] || exit 1
  jq -Rsc '{type:"control_response",response:{subtype:"success",request_id:"model-index",
    response:{models:[split("\n")[] | select(length > 0) | {value:., resolvedModel:.}]}}}' '$3'
  exit 0
fi
exit 0
SH
  chmod +x "$1/claude"
}
# claude_spawn_case <name> -> sets CASE SPAWN_HOME FAKE READS; the home pins a
# signed-in worker account and owns an index whose routine role is claude-sonnet-5.
claude_spawn_case() {
  CASE="$TMP_ROOT/$1"
  SPAWN_HOME="$CASE/home"
  READS="$CASE/reads"
  fm_test_spawn_home "$SPAWN_HOME" claude
  fm_git_worktree "$CASE/project" "$CASE/wt" "wt-$1"
  fm_test_spawn_brief "$SPAWN_HOME" "$1"
  FAKE=$(fm_test_make_spawn_fakebin "$CASE/fake")
  mkdir -p "$CASE/work"
  printf '{}\n' > "$CASE/work/.credentials.json"
  printf '%s\n' "$CASE/work" > "$SPAWN_HOME/config/claude-account"
  printf '%s\n' claude-sonnet-5 claude-sonnet-5-5 > "$CASE/catalog"
  printf '%s\n' '{"version":1,"roles":{"routine":{"claude":{"model":"claude-sonnet-5"}}},"retired":[]}' > "$SPAWN_HOME/config/model-index.json"
  : > "$READS"
  make_claude_fake "$FAKE" "$READS" "$CASE/catalog"
}
reads_of() { wc -l < "$1" | tr -d ' '; }
run_claude_spawn() { # <id> [spawn args...]
  local id=$1
  shift
  (unset FM_MODEL_CATALOG_DIR; fm_test_run_spawn "$SPAWN_HOME" "$CASE/wt" "$FAKE" "$id" "$CASE/project" --mode no-mistakes --yolo off "$@")
}

claude_spawn_case reads-indexed
out=$(run_claude_spawn reads-indexed --model role:routine) || fail "an indexed stale model must not refuse the spawn: $out"
assert_contains "$out" 'warning: model is stale - claude-sonnet-5 on claude is older than claude-sonnet-5-5 in the claude catalog' 'the indexed model was not flagged from the shared catalog read'
[ "$(reads_of "$READS")" = 1 ] || fail "an indexed model's catalog must be read once per spawn, read $(reads_of "$READS") times"
assert_grep 'model_stale=claude-sonnet-5 on claude' "$SPAWN_HOME/state/reads-indexed.meta" 'the shared read did not reach the task record'

claude_spawn_case reads-literal
printf '%s\n' '{"version":1,"roles":{"routine":{"claude":{"model":"claude-sonnet-5-5"}}},"retired":[]}' > "$SPAWN_HOME/config/model-index.json"
out=$(run_claude_spawn reads-literal --model claude-sonnet-5) || fail "a literal stale model must not refuse the spawn: $out"
assert_contains "$out" 'warning: model is stale - claude-sonnet-5 on claude is older than claude-sonnet-5-5' 'a model outside the index was not checked'
[ "$(reads_of "$READS")" = 1 ] || fail "a literal model's catalog must be read once per spawn, read $(reads_of "$READS") times"

claude_spawn_case reads-unreadable
rm -f "$CASE/catalog"
out=$(run_claude_spawn reads-unreadable --model role:routine) || fail "an unreadable catalog must not refuse the spawn: $out"
assert_not_contains "$out" 'model is stale' 'an unreadable catalog drew a stale warning'
[ "$(reads_of "$READS")" = 1 ] || fail "a failed catalog read must not be repeated by the freshness check, read $(reads_of "$READS") times"
pass 'a spawn reads the harness catalog once, for an indexed model, a literal model, and an unreadable catalog'

# The freshness check follows the model-index rule: a custom Claude launcher
# runs a catalog the plain claude binary does not hold, so nothing is read and
# nothing is reported or recorded.
claude_spawn_case reads-launcher
fm_test_fake_teamclaude "$FAKE"
make_claude_fake "$FAKE" "$READS" "$CASE/catalog"
printf 'teamclaude\n' > "$SPAWN_HOME/config/claude-launcher"
rm -f "$SPAWN_HOME/config/claude-account"
out=$(run_claude_spawn reads-launcher --model claude-sonnet-5) || fail "a launcher spawn failed: $out"
assert_not_contains "$out" 'model is stale' 'a custom launcher spawn reported a stale model from the plain claude catalog'
[ "$(reads_of "$READS")" = 0 ] || fail "a custom launcher spawn read the plain claude catalog $(reads_of "$READS") times"
assert_no_grep 'model_stale=' "$SPAWN_HOME/state/reads-launcher.meta" 'a custom launcher spawn recorded a stale model'
pass 'a spawn through a custom Claude launcher reads no catalog and records no stale model'

echo "# all fm-model-freshness tests passed"
