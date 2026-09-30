#!/usr/bin/env bash
# Behavior tests for model-index checking, role selection, and inheritance.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-index)
TOOL="$ROOT/bin/fm-model-index.sh"
HOME_DIR="$TMP_ROOT/home"
CATALOGS="$TMP_ROOT/catalogs"
mkdir -p "$HOME_DIR/config" "$CATALOGS"
export FM_HOME="$HOME_DIR" FM_MODEL_CATALOG_DIR="$CATALOGS"
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
INDEX="$HOME_DIR/config/model-index.json"
BASE="$TMP_ROOT/base.json"
cat > "$BASE" <<'JSON'
{"version":1,"roles":{"strong":{"codex":{"model":"current"},"claude":{"model":"opus"}},"routine":{"omp":{"model":"provider/current","stand_in":"openrouter/vendor/stand-in"}}},"retired":["old"]}
JSON
cp "$BASE" "$INDEX"
printf '%s\n' '{"models":[{"id":"current"},{"id":"old"},{"id":"next"}]}' > "$CATALOGS/codex.json"
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"}]}' > "$CATALOGS/claude.json"
printf '%s\n' '{"models":[{"id":"provider/current"},{"id":"openrouter/vendor/stand-in"}]}' > "$CATALOGS/omp.json"
printf '%s\n' '{"data":[{"id":"vendor/stand-in"}]}' > "$CATALOGS/openrouter.json"

refuses() {
  local code=0 out
  out=$("$TOOL" "$@" 2>&1) || code=$?
  [ "$code" -ne 0 ] || fail "unexpected acceptance: $* ($out)"
  [ -n "$out" ] || fail "refusal did not report its cause: $*"
}

[ "$("$TOOL" resolve codex strong)" = current ] || fail 'wrong per-harness role id'
[ "$("$TOOL" resolve claude strong)" = opus ] || fail 'role selected another harness model'
[ "$("$TOOL" model omp role:routine)" = provider/current ] || fail 'spawn role reference not resolved'
[ "$("$TOOL" resolve omp routine --stand-in)" = openrouter/vendor/stand-in ] || fail 'explicit stand-in not resolved'
[ "$("$TOOL" model omp stand-in:routine)" = openrouter/vendor/stand-in ] || fail 'spawn stand-in reference not resolved'
refuses resolve pi strong
refuses resolve codex missing
refuses resolve codex strong --stand-in
pass 'roles select the correct harness id and only explicitly configured stand-ins'

printf '%s\n' '{"rules":[{"when":"hard","use":[{"harness":"codex","role":"strong","effort":"high"},{"harness":"claude","model":"literal"}]}],"default":{"harness":"omp","role":"routine","stand_in":true,"provider":"vendor"}}' > "$TMP_ROOT/dispatch.json"
"$TOOL" profiles "$TMP_ROOT/dispatch.json" > "$TMP_ROOT/concrete.json"
jq -e '.rules[0].use[0] == {harness:"codex",model:"current",effort:"high"} and .rules[0].use[1].model == "literal" and .default == {harness:"omp",model:"openrouter/vendor/stand-in",provider:"vendor"}' "$TMP_ROOT/concrete.json" >/dev/null || fail 'concrete profiles lose policy fields or select wrong ids'
jq '.roles.strong.codex.model = "next"' "$BASE" > "$INDEX"
[ "$("$TOOL" resolve codex strong)" = next ] || fail 'index edit did not change role selection'
cp "$BASE" "$INDEX"
pass 'one index edit changes the next selection without editing dispatch profiles'

refuses model codex old
refuses model omp provider/old
jq '.roles.strong.codex.model = "old"' "$BASE" > "$INDEX"
refuses check
jq '.retired += ["claude-current"]' "$BASE" > "$INDEX"
refuses check
cp "$BASE" "$INDEX"
pass 'retired literals, qualified ids, index entries, and alias targets are refused'

jq '.roles.strong.codex.model = "absent"' "$BASE" > "$INDEX"
refuses check
jq '.roles.routine.omp.stand_in = "provider/absent"' "$BASE" > "$INDEX"
refuses resolve codex strong
cp "$BASE" "$INDEX"
printf '%s\n' '{"data":[]}' > "$CATALOGS/openrouter.json"
refuses check
printf '%s\n' '{"data":[{"id":"vendor/stand-in"}]}' > "$CATALOGS/openrouter.json"
rm "$CATALOGS/claude.json"
refuses resolve codex strong
"$TOOL" profiles "$TMP_ROOT/dispatch.json" --schema-only > "$TMP_ROOT/offline.json"
jq -e '.rules[0].use[0].model == "current"' "$TMP_ROOT/offline.json" >/dev/null || fail 'offline bootstrap inspection lost role resolution'
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"}]}' > "$CATALOGS/claude.json"
pass 'absent models, unselected absent stand-ins, missing exports, and OpenRouter omissions refuse the entire index'

for profile in \
  '{"harness":"codex","role":"strong","model":"current"}' \
  '{"harness":"codex","role":"strong","stand_in":"yes"}' \
  '{"harness":"codex","model":"current","stand_in":true}'; do
  printf '{"default":%s}\n' "$profile" > "$TMP_ROOT/bad-profile.json"
  refuses profiles "$TMP_ROOT/bad-profile.json"
done
jq '.roles.strong.codex.stand_ins = ["next"]' "$BASE" > "$INDEX"
refuses check
cp "$BASE" "$INDEX"
pass 'conflicting profile axes and misspelled index fields are actionable errors'

rm "$INDEX"
[ "$("$TOOL" model codex old)" = old ] || fail 'literal compatibility without index changed'
"$TOOL" profiles "$TMP_ROOT/concrete.json" > "$TMP_ROOT/literals.json"
jq -e --slurpfile expected "$TMP_ROOT/concrete.json" '. == $expected[0]' "$TMP_ROOT/literals.json" >/dev/null || fail 'literal profile compatibility changed'
refuses resolve codex strong
pass 'homes without an index keep literal compatibility but cannot resolve roles'

# Exercise native catalog adapters, not just normalized exports. The CLIs are
# fixture producers, and the public checker consumes their native protocols.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/native")
mkdir -p "$TMP_ROOT/codex"
printf '%s\n' '{"models":[{"slug":"current"}]}' > "$TMP_ROOT/codex/models_cache.json"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
read -r request
printf '%s\n' "$request" > "$MODEL_INIT_LOG"
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"model-index","response":{"models":[{"value":"opus","resolvedModel":"claude-current"}]}}}'
SH
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"models":[{"provider":"provider","id":"current","selector":"provider/current"},{"provider":"openrouter","id":"vendor/stand-in","selector":"openrouter/vendor/stand-in"}]}'
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"vendor/stand-in"}]}'
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/omp" "$FAKEBIN/curl"
cp "$BASE" "$INDEX"
PATH="$FAKEBIN:$PATH" CODEX_HOME="$TMP_ROOT/codex" FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_MODEL_CATALOG_DIR='' MODEL_INIT_LOG="$TMP_ROOT/init.json" "$TOOL" check
jq -e '.type == "control_request" and .request.subtype == "initialize"' "$TMP_ROOT/init.json" >/dev/null || fail 'Claude catalog query sent something other than token-free initialization'
printf '%s\n' '{"models":[{"slug":"another"}]}' > "$TMP_ROOT/codex/models_cache.json"
refuses_native=0
PATH="$FAKEBIN:$PATH" CODEX_HOME="$TMP_ROOT/codex" FM_MODEL_CATALOG_DIR='' MODEL_INIT_LOG="$TMP_ROOT/init.json" "$TOOL" check >/dev/null 2>&1 || refuses_native=$?
[ "$refuses_native" -ne 0 ] || fail 'native Codex cache omission accepted'
pass 'native Codex, Claude initialization, omp selectors, and OpenRouter catalog protocols are checked'

# The inherited file is consumed in the destination home, proving policy
# convergence rather than just allowlist membership or copied text.
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"
SECOND="$TMP_ROOT/second"
mkdir -p "$SECOND/config"
git -C "$SECOND" init -q
printf 'config/\n' > "$SECOND/.gitignore"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND/config"
[ "$(FM_HOME="$SECOND" "$TOOL" resolve codex strong)" = current ] || fail 'second home did not consume inherited model policy'
jq '.roles.strong.codex.model = "next"' "$BASE" > "$INDEX"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND/config"
[ "$(FM_HOME="$SECOND" "$TOOL" resolve codex strong)" = next ] || fail 'second home did not consume the index update'
pass 'secondmate inheritance changes the model selected by the destination home'
printf '# all fm-model-index tests passed\n'
