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

refuses() {
  local code=0 out
  out=$("$TOOL" "$@" 2>&1) || code=$?
  [ "$code" -ne 0 ] || fail "unexpected acceptance: $* ($out)"
  [ -n "$out" ] || fail "refusal did not report its cause: $*"
}
# accepts_with_notice <needle> <args...>: exits 0 and reports why it could not validate.
accepts_with_notice() {
  local needle=$1 code=0 err
  shift
  "$TOOL" "$@" >/dev/null 2> "$TMP_ROOT/notice" || code=$?
  err=$(cat "$TMP_ROOT/notice")
  [ "$code" -eq 0 ] || fail "missing evidence refused: $* ($err)"
  assert_contains "$err" "$needle" "unvalidated acceptance must say why: $*"
}

[ "$("$TOOL" model codex role:strong)" = current ] || fail 'wrong per-harness role id'
[ "$("$TOOL" model claude role:strong)" = opus ] || fail 'role selected another harness model'
[ "$("$TOOL" model omp role:routine)" = provider/current ] || fail 'spawn role reference not resolved'
[ "$("$TOOL" model omp stand-in:routine)" = openrouter/vendor/stand-in ] || fail 'spawn stand-in reference not resolved'
refuses model pi role:strong
refuses model codex role:missing
refuses model codex stand-in:strong
pass 'roles select the correct harness id and only explicitly configured stand-ins'

[ "$("$TOOL" entry codex current)" = true ] || fail 'primary index entry was not recognized'
[ "$("$TOOL" entry omp openrouter/vendor/stand-in)" = true ] || fail 'stand-in index entry was not recognized'
[ "$("$TOOL" entry claude current)" = false ] || fail 'entry membership crossed harnesses'
[ "$("$TOOL" entry codex unlisted)" = false ] || fail 'nonentry literal was recognized'
mkdir -p "$TMP_ROOT/no-index/config"
[ "$(FM_HOME="$TMP_ROOT/no-index" "$TOOL" entry codex current)" = false ] || fail 'entry membership without an index was not false'
pass 'entry membership is exact, per-harness, and includes configured stand-ins'

printf '%s\n' '{"rules":[{"when":"hard","use":[{"harness":"codex","role":"strong","effort":"high"},{"harness":"claude","model":"literal"}]}],"default":{"harness":"omp","role":"routine","stand_in":true,"provider":"vendor"}}' > "$TMP_ROOT/dispatch.json"
"$TOOL" profiles "$TMP_ROOT/dispatch.json" > "$TMP_ROOT/concrete.json" 2> "$TMP_ROOT/profile-warnings"
jq -e '.rules[0].use[0] == {harness:"codex",model:"current",effort:"high"} and .rules[0].use[1].model == "literal" and .default == {harness:"omp",model:"openrouter/vendor/stand-in",provider:"vendor"}' "$TMP_ROOT/concrete.json" >/dev/null || fail 'concrete profiles lose policy fields or select wrong ids'
assert_contains "$(cat "$TMP_ROOT/profile-warnings")" "literal model 'literal' for claude is not an index entry" 'a literal profile id must draw a warning while an index exists'
[ "$(grep -c warning "$TMP_ROOT/profile-warnings")" = 1 ] || fail "role profiles must not draw literal warnings: $(cat "$TMP_ROOT/profile-warnings")"
[ "$("$TOOL" model codex unlisted 2> "$TMP_ROOT/model-warning")" = unlisted ] || fail 'a literal spawn model must still resolve to itself'
assert_contains "$(cat "$TMP_ROOT/model-warning")" "literal model 'unlisted' for codex" 'a literal spawn model must draw a warning while an index exists'
"$TOOL" model codex current >/dev/null 2> "$TMP_ROOT/entry-warning"
[ ! -s "$TMP_ROOT/entry-warning" ] || fail "a literal that is the harness's index entry must not warn: $(cat "$TMP_ROOT/entry-warning")"
jq '.roles.strong.codex.model = "next"' "$BASE" > "$INDEX"
[ "$("$TOOL" model codex role:strong)" = next ] || fail 'index edit did not change role selection'
cp "$BASE" "$INDEX"
pass 'one index edit changes the next selection; literal ids work but warn while an index exists'

for envelope in '' 'null' '[]' '{"default":{"harness":"codex","role":"strong"}} {"default":{"harness":"codex","role":"strong"},"approval":"captain"}'; do
  printf '%s\n' "$envelope" > "$TMP_ROOT/bad-dispatch.json"
  refuses profiles "$TMP_ROOT/bad-dispatch.json"
done
refuses profiles /dev/null
"$TOOL" profiles > "$TMP_ROOT/index-only.out"
[ ! -s "$TMP_ROOT/index-only.out" ] || fail 'index-only validation emitted dispatch profiles'
printf '%s\n' '{"version":2,"roles":{},"retired":[]}' > "$INDEX"
refuses profiles
cp "$BASE" "$INDEX"
pass 'present dispatch requires one object and explicit absence still validates the index offline'

refuses model codex old
refuses model omp provider/old
refuses model claude 'old[1m]'
refuses model omp 'provider/old[1m]'
refuses check codex 'old[1m]'
jq '.roles.strong.claude.model = "old[1m]"' "$BASE" > "$INDEX"
refuses check
refuses model claude role:strong
jq '.retired += ["claude-current"]' "$BASE" > "$INDEX"
refuses check
refuses check claude opus
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current[1m]"}]}' > "$CATALOGS/claude.json"
jq '.retired += ["claude-current"]' "$BASE" > "$INDEX"
refuses check claude opus
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"}]}' > "$CATALOGS/claude.json"
jq '.roles.strong.codex.model = "old"' "$BASE" > "$INDEX"
refuses check
jq '.roles.long = {claude:{model:"opus[1m]"},codex:{model:"current[1m]"}}' "$BASE" > "$INDEX"
"$TOOL" check claude 'opus[1m]' >/dev/null 2> "$TMP_ROOT/suffix-notice" || fail 'a context-suffixed Claude id was refused although its base is listed'
[ ! -s "$TMP_ROOT/suffix-notice" ] || fail "a listed Claude base must validate its suffixed id: $(cat "$TMP_ROOT/suffix-notice")"
refuses check codex 'current[1m]'
jq '.roles.long = {claude:{model:"opus[1m]"}} | .retired += ["claude-current"]' "$BASE" > "$INDEX"
refuses check claude 'opus[1m]'
# Claude's picker lists some canonical ids only with a context suffix.
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"},{"id":"sonnet","resolved_id":"claude-sonnet-current[1m]"},{"id":"claude-sonnet-current[1m]"}]}' > "$CATALOGS/claude.json"
jq '.roles.long = {claude:{model:"claude-sonnet-current"}}' "$BASE" > "$INDEX"
"$TOOL" check claude claude-sonnet-current >/dev/null 2> "$TMP_ROOT/suffix-notice" || fail "a canonical Claude id was refused although its suffixed form is listed: $(cat "$TMP_ROOT/suffix-notice")"
[ ! -s "$TMP_ROOT/suffix-notice" ] || fail "a listed suffixed Claude id must validate its base: $(cat "$TMP_ROOT/suffix-notice")"
jq '.roles.long = {claude:{model:"claude-sonnet-current"}} | .retired += ["claude-sonnet-current"]' "$BASE" > "$INDEX"
refuses check claude claude-sonnet-current
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"}]}' > "$CATALOGS/claude.json"
cp "$BASE" "$INDEX"
pass 'retired literals, qualified ids, context-suffixed ids, index entries, and alias targets are refused; Claude ids match listed suffixed or base forms'

REGISTRY="$TMP_ROOT/model_registry.json"
cat > "$REGISTRY" <<'JSON'
{"old":{"model":"current"},"models":["provider/old","old[1m]","provider/old[1m]","current"],"nested":{"provider/old[2m]":true},"description":"old is mentioned in prose","unrelated":"oldish"}
JSON
cp "$REGISTRY" "$TMP_ROOT/registry-before.json"
cp "$INDEX" "$TMP_ROOT/index-before-registry.json"
registry_status=0
"$TOOL" check-registry "$REGISTRY" > "$TMP_ROOT/registry-out" 2> "$TMP_ROOT/registry-errors" || registry_status=$?
[ "$registry_status" -ne 0 ] || fail 'registry with retired identifiers was accepted'
for id in old provider/old 'old[1m]' 'provider/old[1m]' 'provider/old[2m]'; do
  assert_contains "$(cat "$TMP_ROOT/registry-errors")" "retired id '$id'" 'every retired registry key and value must be reported'
done
[ "$(wc -l < "$TMP_ROOT/registry-errors" | tr -d ' ')" = 5 ] || fail 'registry scan reported prose or omitted a retired identifier'
cmp -s "$REGISTRY" "$TMP_ROOT/registry-before.json" || fail 'refused registry was modified'
cmp -s "$INDEX" "$TMP_ROOT/index-before-registry.json" || fail 'registry comparison modified the index'
printf '%s\n' '{"current":{"models":["provider/current","current[1m]"]},"description":"old is mentioned in prose","unrelated":"oldish"}' > "$REGISTRY"
cp "$REGISTRY" "$TMP_ROOT/registry-before.json"
FM_MODEL_CATALOG_DIR="$TMP_ROOT/no-registry-catalogs" "$TOOL" check-registry "$REGISTRY" > "$TMP_ROOT/registry-out" 2> "$TMP_ROOT/registry-errors" \
  || fail 'current-only registry failed offline comparison'
[ ! -s "$TMP_ROOT/registry-errors" ] || fail 'registry comparison attempted catalog checking or matched prose'
cmp -s "$REGISTRY" "$TMP_ROOT/registry-before.json" || fail 'accepted registry was modified'
cmp -s "$INDEX" "$TMP_ROOT/index-before-registry.json" || fail 'accepted registry comparison modified the index'
refuses check-registry
refuses check-registry "$REGISTRY" '.models'
refuses check-registry "$TMP_ROOT/missing-registry.json"
refuses check-registry "$TMP_ROOT"
ln -s "$TMP_ROOT/missing-registry.json" "$TMP_ROOT/unreadable-registry.json"
refuses check-registry "$TMP_ROOT/unreadable-registry.json"
for malformed in '{' '' '{} {}'; do
  printf '%s\n' "$malformed" > "$REGISTRY"
  cp "$REGISTRY" "$TMP_ROOT/registry-before.json"
  refuses check-registry "$REGISTRY"
  cmp -s "$REGISTRY" "$TMP_ROOT/registry-before.json" || fail 'malformed registry was modified'
done
printf '%s\n' '{"current":true}' > "$REGISTRY"
printf '%s\n' '{"version":1,"roles":{}}' > "$INDEX"
cp "$INDEX" "$TMP_ROOT/malformed-index-before.json"
refuses check-registry "$REGISTRY"
cmp -s "$INDEX" "$TMP_ROOT/malformed-index-before.json" || fail 'malformed index was modified'
FM_HOME="$TMP_ROOT/no-index" refuses check-registry "$REGISTRY"
cp "$BASE" "$INDEX"
pass 'registry comparison reports every retired token key and value offline, rejects invalid inputs and missing index, and leaves inputs unchanged'

for first_version in 1 2; do
  jq --argjson version "$first_version" '.version = $version | .retired = []' "$BASE" > "$INDEX"
  jq '.roles.strong.codex.model = "next" | .retired = ["current"]' "$BASE" >> "$INDEX"
  printf '%s\n' '{"model":"current"}' > "$REGISTRY"
  refuses model codex role:strong
  refuses model omp stand-in:routine
  refuses model codex current
  refuses entry codex current
  refuses check
  refuses check codex current
  refuses profiles "$TMP_ROOT/dispatch.json"
  refuses check-registry "$REGISTRY"
done
cp "$BASE" "$INDEX"
jq '.version = 2' "$BASE" >> "$INDEX"
refuses model codex role:strong
refuses check-registry "$REGISTRY"
cp "$BASE" "$INDEX"
pass 'concatenated valid or invalid index objects cannot split resolution, membership, catalog checking, and registry policy'

jq '.roles.strong.codex.model = "absent"' "$BASE" > "$INDEX"
refuses check
refuses check codex absent
"$TOOL" check claude opus >/dev/null || fail 'an absent unselected entry refused the selected one'
jq '.roles.routine.omp.stand_in = "provider/absent"' "$BASE" > "$INDEX"
refuses check
"$TOOL" check omp provider/current >/dev/null || fail 'an absent unselected stand-in refused the selected entry'
cp "$BASE" "$INDEX"
"$TOOL" check codex not-an-entry >/dev/null || fail 'a literal that is not an index entry must not be catalog-checked'
pass 'the index-edit check refuses any absent id; a selected-entry check reads only its own entry'

rm "$CATALOGS/claude.json"
accepts_with_notice 'claude catalog unavailable' check
accepts_with_notice 'claude catalog unavailable' check claude opus
printf '%s\n' '{"models":[]}' > "$CATALOGS/claude.json"
accepts_with_notice 'claude catalog unavailable' check claude opus
printf '%s\n' '{"models":[{"id":"opus","resolved_id":"claude-current"}]}' > "$CATALOGS/claude.json"
jq '.roles.strong.grok = {model:"grok-current"}' "$BASE" > "$INDEX"
accepts_with_notice 'grok catalog unavailable' check
jq '.roles.opus = {omp:{model:"claude-bridge/claude-opus-5-5"}}' "$BASE" > "$INDEX"
accepts_with_notice "omp provider 'claude-bridge' is not in 'omp models --json'" check
accepts_with_notice "omp provider 'claude-bridge'" check omp claude-bridge/claude-opus-5-5
jq '.roles.opus = {omp:{model:"provider/unlisted"}}' "$BASE" > "$INDEX"
refuses check omp provider/unlisted
cp "$BASE" "$INDEX"
pass 'unavailable, empty, undiscoverable, and extension-provider catalogs are notices; a listed provider with an absent id refuses'

for first_catalog in \
  '{"models":[{"id":"current"}]}' \
  '{"models":[{"id":"other"}]}' \
  '{"models":[{"id":"current","resolved_id":null}]}'; do
  printf '%s\n' "$first_catalog" '{"models":[{"id":"current"}]}' > "$CATALOGS/codex.json"
  accepts_with_notice 'codex catalog unavailable' check codex current
  accepts_with_notice 'codex catalog unavailable' check
done
printf '%s\n' '{"models":[{"id":"current"}]}' '{"models":[{"id":"other"}]}' > "$CATALOGS/codex.json"
accepts_with_notice 'codex catalog unavailable' check codex current
for malformed_catalog in \
  '[{"models":[{"id":"current"}]}]' \
  '{"models":[{"id":42}]}' \
  '{"models":[{"id":"current","resolved_id":null}]}'; do
  printf '%s\n' "$malformed_catalog" > "$CATALOGS/codex.json"
  accepts_with_notice 'codex catalog unavailable' check codex current
done
printf '%s\n' '{"models":[{"id":"current"},{"id":"old"},{"id":"next"}]}' > "$CATALOGS/codex.json"
"$TOOL" check codex current >/dev/null 2> "$TMP_ROOT/single-catalog-notice" || fail 'a valid single-object catalog must validate'
[ ! -s "$TMP_ROOT/single-catalog-notice" ] || fail 'a valid single-object catalog was treated as unavailable'
pass 'multi-document and malformed catalog exports remain unavailable evidence, not contradictory evidence'

for profile in \
  '{"harness":"codex","role":"strong","model":"current"}' \
  '{"harness":"codex","role":"strong","stand_in":"yes"}' \
  '{"harness":"codex","model":"current","stand_in":true}'; do
  printf '{"default":%s}\n' "$profile" > "$TMP_ROOT/bad-profile.json"
  refuses profiles "$TMP_ROOT/bad-profile.json"
done
jq '.roles.strong.codex.stand_ins = ["next"]' "$BASE" > "$INDEX"
refuses check
refuses model codex role:strong
cp "$BASE" "$INDEX"
pass 'conflicting profile axes and misspelled index fields are actionable errors'

rm "$INDEX"
[ "$("$TOOL" model codex old 2> "$TMP_ROOT/no-index-warning")" = old ] || fail 'literal compatibility without index changed'
[ ! -s "$TMP_ROOT/no-index-warning" ] || fail "a home without an index must not warn about literals: $(cat "$TMP_ROOT/no-index-warning")"
"$TOOL" profiles "$TMP_ROOT/concrete.json" > "$TMP_ROOT/literals.json"
jq -e --slurpfile expected "$TMP_ROOT/concrete.json" '. == $expected[0]' "$TMP_ROOT/literals.json" >/dev/null || fail 'literal profile compatibility changed'
refuses model codex role:strong
refuses check
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
# Cursor pads and colors its listing; the shared id parser must strip both.
cat > "$FAKEBIN/cursor-agent" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '2026.09.30' ;;
  --list-models) printf 'Available models\n\033[1mcursor-current\033[0m   - Cursor Current  \n  cursor-other - Other\n' ;;
esac
SH
cat > "$FAKEBIN/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
chmod +x "$FAKEBIN/claude" "$FAKEBIN/omp" "$FAKEBIN/cursor-agent" "$FAKEBIN/timeout"
jq '.roles.strong.cursor = {model:"cursor-current"} | .roles.long = {claude:{model:"opus[1m]"}}' "$BASE" > "$INDEX"
PATH="$FAKEBIN:$PATH" CODEX_HOME="$TMP_ROOT/codex" FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_MODEL_CATALOG_DIR='' MODEL_INIT_LOG="$TMP_ROOT/init.json" "$TOOL" check 2> "$TMP_ROOT/native-notices"
[ ! -s "$TMP_ROOT/native-notices" ] || fail "a native catalog was not read: $(cat "$TMP_ROOT/native-notices")"
jq -e '.type == "control_request" and .request.subtype == "initialize"' "$TMP_ROOT/init.json" >/dev/null || fail 'Claude catalog query sent something other than token-free initialization'
printf '%s\n' '{"models":[{"slug":"another"}]}' > "$TMP_ROOT/codex/models_cache.json"
refuses_native=0
PATH="$FAKEBIN:$PATH" CODEX_HOME="$TMP_ROOT/codex" FM_MODEL_CATALOG_DIR='' MODEL_INIT_LOG="$TMP_ROOT/init.json" "$TOOL" check >/dev/null 2>&1 || refuses_native=$?
[ "$refuses_native" -ne 0 ] || fail 'native Codex cache omission accepted'
cp "$BASE" "$INDEX"
pass 'native Codex, Claude initialization with a context-suffixed alias, omp selector, and padded, colored Cursor catalogs are checked'

# The inherited file is consumed in the destination home, proving policy
# convergence rather than just allowlist membership or copied text.
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"
SECOND="$TMP_ROOT/second"
mkdir -p "$SECOND/config"
git -C "$SECOND" init -q
printf 'config/\n' > "$SECOND/.gitignore"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND/config"
[ "$(FM_HOME="$SECOND" "$TOOL" model codex role:strong)" = current ] || fail 'second home did not consume inherited model policy'
jq '.roles.strong.codex.model = "next"' "$BASE" > "$INDEX"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND/config"
[ "$(FM_HOME="$SECOND" "$TOOL" model codex role:strong)" = next ] || fail 'second home did not consume the index update'
pass 'secondmate inheritance changes the model selected by the destination home'

PAIR_SOURCE="$TMP_ROOT/pair-source"
mkdir -p "$PAIR_SOURCE"
printf '%s\n' '{"version":1,"roles":{"retained":{"codex":{"model":"next"}}},"retired":[]}' > "$TMP_ROOT/retained-index.json"
printf '%s\n' '{"default":{"harness":"codex","role":"retained"}}' > "$TMP_ROOT/retained-dispatch.json"
printf '%s\n' '{"version":1,"roles":{"incoming":{"codex":{"model":"current"}}},"retired":[]}' > "$TMP_ROOT/incoming-index.json"
printf '%s\n' '{"default":{"harness":"codex","role":"incoming"}}' > "$TMP_ROOT/incoming-dispatch.json"
set_pair_source() {
  local presence=$1
  rm -f "$PAIR_SOURCE/model-index.json" "$PAIR_SOURCE/crew-dispatch.json"
  case "$presence" in
    both|index-only) cp "$TMP_ROOT/incoming-index.json" "$PAIR_SOURCE/model-index.json" ;;
  esac
  case "$presence" in
    both) cp "$TMP_ROOT/incoming-dispatch.json" "$PAIR_SOURCE/crew-dispatch.json" ;;
    dispatch-only) printf '%s\n' '{"default":{"harness":"codex","model":"current"}}' > "$PAIR_SOURCE/crew-dispatch.json" ;;
  esac
  printf '%s\n' "$presence" > "$PAIR_SOURCE/dispatch-never-send"
  printf 'retain-trailers\n' > "$PAIR_SOURCE/keep-ai-trailers"
}
assert_retained_pair() {
  local home=$1 label=$2
  cmp -s "$TMP_ROOT/retained-index.json" "$home/config/model-index.json" || fail "$label changed the retained index"
  cmp -s "$TMP_ROOT/retained-dispatch.json" "$home/config/crew-dispatch.json" || fail "$label changed the retained dispatch"
  [ "$(FM_HOME="$home" "$TOOL" profiles "$home/config/crew-dispatch.json" | jq -r '.default.model')" = next ] \
    || fail "$label left a pair that the destination profiles consumer cannot resolve"
}
for guarded in model-index.json crew-dispatch.json; do
  for local_guard in gitignore directory; do
    for presence in both index-only dispatch-only absent; do
      guard_home="$TMP_ROOT/local-pair-$guarded-$local_guard-$presence"
      mkdir -p "$guard_home/config"
      git -C "$guard_home" init -q
      printf 'config/\n' > "$guard_home/.gitignore"
      if [ "$local_guard" = gitignore ]; then
        printf 'config/*\n!config/%s\n' "$guarded" > "$guard_home/.gitignore"
      fi
      cp "$TMP_ROOT/retained-index.json" "$guard_home/config/model-index.json"
      cp "$TMP_ROOT/retained-dispatch.json" "$guard_home/config/crew-dispatch.json"
      if [ "$local_guard" = directory ]; then
        rm "$guard_home/config/$guarded"
        mkdir "$guard_home/config/$guarded"
        printf 'retain\n' > "$guard_home/config/$guarded/marker"
      fi
      set_pair_source "$presence"
      printf 'retain-trailers\n' > "$guard_home/config/keep-ai-trailers"
      FM_CONFIG_INHERIT_LIVE=1 FM_CONFIG_INHERIT_REPORT="$TMP_ROOT/local-pair-report" \
        propagate_inheritable_config "$PAIR_SOURCE" "$guard_home/config" 2> "$TMP_ROOT/local-pair-warning"
      assert_contains "$(cat "$TMP_ROOT/local-pair-warning")" "skipped model-index.json" 'local refusal must report the index'
      assert_contains "$(cat "$TMP_ROOT/local-pair-warning")" "skipped crew-dispatch.json" 'local refusal must report the dispatch'
      cmp -s "$PAIR_SOURCE/dispatch-never-send" "$guard_home/config/dispatch-never-send" || fail 'local pair refusal blocked unrelated propagation'
      [ "$(cat "$guard_home/config/keep-ai-trailers")" = retain-trailers ] || fail 'local pair refusal changed an unchanged trailer setting'
      if [ "$local_guard" = directory ]; then
        [ "$(cat "$guard_home/config/$guarded/marker")" = retain ] || fail 'local pair refusal changed the nonregular destination'
        rm "$guard_home/config/$guarded/marker"
        rmdir "$guard_home/config/$guarded"
        case "$guarded" in
          model-index.json) cp "$TMP_ROOT/retained-index.json" "$guard_home/config/$guarded" ;;
          crew-dispatch.json) cp "$TMP_ROOT/retained-dispatch.json" "$guard_home/config/$guarded" ;;
        esac
      fi
      assert_retained_pair "$guard_home" "local $guarded $local_guard $presence"
      printf 'config/\n' > "$guard_home/.gitignore"
      propagate_inheritable_config "$PAIR_SOURCE" "$guard_home/config"
      for member in model-index.json crew-dispatch.json; do
        if [ -f "$PAIR_SOURCE/$member" ]; then
          cmp -s "$PAIR_SOURCE/$member" "$guard_home/config/$member" || fail 'allowed local pair payload did not converge'
        else
          [ ! -e "$guard_home/config/$member" ] || fail 'allowed local pair absence did not converge'
        fi
      done
      if [ "$presence" = both ] || [ "$presence" = dispatch-only ]; then
        [ "$(FM_HOME="$guard_home" "$TOOL" profiles "$guard_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail 'allowed local pair did not reach the destination profiles consumer'
      fi
    done
  done
done
pass 'local pair guards retain both members in either direction for copy and absence while unrelated items converge'
for member in model-index.json crew-dispatch.json; do
  for link_kind in symlink hardlink; do
    for presence in both absent; do
      link_home="$TMP_ROOT/local-pair-$member-$link_kind-$presence"
      mkdir -p "$link_home/config"
      git -C "$link_home" init -q
      printf 'config/\n' > "$link_home/.gitignore"
      cp "$TMP_ROOT/retained-index.json" "$link_home/config/model-index.json"
      cp "$TMP_ROOT/retained-dispatch.json" "$link_home/config/crew-dispatch.json"
      mv "$link_home/config/$member" "$link_home/link-payload"
      case "$link_kind" in
        symlink) ln -s "$link_home/link-payload" "$link_home/config/$member" ;;
        hardlink) ln "$link_home/link-payload" "$link_home/config/$member" ;;
      esac
      set_pair_source "$presence"
      propagate_inheritable_config "$PAIR_SOURCE" "$link_home/config"
      case "$member" in
        model-index.json) retained_payload="$TMP_ROOT/retained-index.json" ;;
        crew-dispatch.json) retained_payload="$TMP_ROOT/retained-dispatch.json" ;;
      esac
      cmp -s "$retained_payload" "$link_home/link-payload" || fail 'local convergence modified the link target'
      if [ "$presence" = both ]; then
        cmp -s "$PAIR_SOURCE/$member" "$link_home/config/$member" || fail 'local convergence refused a replaceable link'
        [ ! -L "$link_home/config/$member" ] || fail 'local convergence retained a destination symlink'
        [ "$(fm_inherit_file_link_count "$link_home/config/$member")" = 1 ] || fail 'local convergence retained a destination hardlink'
        [ "$(FM_HOME="$link_home" "$TOOL" profiles "$link_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail 'locally replaced link pair did not reach the profiles consumer'
      else
        [ ! -e "$link_home/config/$member" ] && [ ! -L "$link_home/config/$member" ] || fail 'local convergence did not mirror absence over a link'
      fi
    done
  done
done
pass 'local pair propagation still safely replaces or removes destination symlinks and hardlinks'

COHERENCE_SOURCE="$TMP_ROOT/coherence-source"
COHERENCE_STAGE="$TMP_ROOT/coherence-stage"
COHERENCE_CATALOGS="$TMP_ROOT/coherence-catalogs"
mkdir -p "$COHERENCE_SOURCE/config" "$COHERENCE_SOURCE/data" "$COHERENCE_STAGE" "$COHERENCE_CATALOGS"
printf '%s\n' '{"models":[{"id":"unrelated-catalog-entry"}]}' > "$COHERENCE_CATALOGS/codex.json"
printf 'main-authoritative; read-only in secondmate homes; must not be edited there; edit in the main firstmate; document pointer\nshared preferences\n' \
  > "$COHERENCE_SOURCE/data/captain-shared.md"
printf 'on\n' > "$COHERENCE_SOURCE/config/trace-context"
set_incoherent_source() { # <removed-role|missing-index> <source|staged>
  local failure=$1 selection=$2 selected="$COHERENCE_SOURCE/config"
  cp "$TMP_ROOT/incoming-index.json" "$COHERENCE_SOURCE/config/model-index.json"
  cp "$TMP_ROOT/incoming-dispatch.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
  if [ "$selection" = staged ]; then selected=$COHERENCE_STAGE; fi
  cp "$TMP_ROOT/retained-dispatch.json" "$selected/crew-dispatch.json"
  case "$failure" in
    removed-role) printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$selected/model-index.json" ;;
    missing-index) rm -f "$selected/model-index.json" ;;
  esac
  printf '%s\n' "$failure-$selection" > "$COHERENCE_SOURCE/config/dispatch-never-send"
}
seed_coherent_destination() {
  local home=$1
  mkdir -p "$home/config"
  cp "$TMP_ROOT/retained-index.json" "$home/config/model-index.json"
  cp "$TMP_ROOT/retained-dispatch.json" "$home/config/crew-dispatch.json"
  printf 'prior\n' > "$home/config/dispatch-never-send"
  printf 'off\n' > "$home/config/trace-context"
}
assert_unrelated_coherence_material() { # <destination> <bootstrap|launch>
  local home=$1 mode=$2 expected_trace=on
  cmp -s "$COHERENCE_SOURCE/config/dispatch-never-send" "$home/config/dispatch-never-send" \
    || fail 'incoherent routing pair blocked unrelated config convergence'
  cmp -s "$COHERENCE_SOURCE/data/captain-shared.md" "$home/data/captain-shared.md" \
    || fail 'incoherent routing pair blocked shared captain convergence'
  [ "$mode" != bootstrap ] || expected_trace=off
  [ "$(cat "$home/config/trace-context")" = "$expected_trace" ] \
    || fail 'pair coherence changed the live versus launch inheritance mode'
}
for boundary_mode in bootstrap launch; do
  for pair_selection in source staged; do
    for failure in removed-role missing-index; do
      coherence_home="$TMP_ROOT/local-coherence-$boundary_mode-$pair_selection-$failure"
      seed_coherent_destination "$coherence_home"
      git -C "$coherence_home" init -q
      printf 'config/\n' > "$coherence_home/.gitignore"
      set_incoherent_source "$failure" "$pair_selection"
      : > "$TMP_ROOT/coherence-local-report"
      boundary_code=0
      (
        unset FM_CONFIG_INHERIT_LIVE FM_CONFIG_INHERIT_PAIR_DIR
        [ "$boundary_mode" != bootstrap ] || { FM_CONFIG_INHERIT_LIVE=1; export FM_CONFIG_INHERIT_LIVE; }
        [ "$pair_selection" != staged ] || { FM_CONFIG_INHERIT_PAIR_DIR="$COHERENCE_STAGE"; export FM_CONFIG_INHERIT_PAIR_DIR; }
        FM_MODEL_CATALOG_DIR="$COHERENCE_CATALOGS" FM_CONFIG_INHERIT_REPORT="$TMP_ROOT/coherence-local-report" \
          propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$coherence_home"
      ) > "$TMP_ROOT/coherence-local.out" 2>&1 || boundary_code=$?
      [ "$boundary_code" = 1 ] || fail "local $boundary_mode accepted $failure from $pair_selection"
      assert_retained_pair "$coherence_home" "local $boundary_mode $pair_selection $failure"
      assert_unrelated_coherence_material "$coherence_home" "$boundary_mode"
      assert_contains "$(cat "$TMP_ROOT/coherence-local.out")" 'role or stand-in not configured: codex:retained' \
        'local boundary refusal must explain the unresolved retained dispatch role'
      for member in model-index.json crew-dispatch.json; do
        assert_contains "$(cat "$TMP_ROOT/coherence-local-report")" "$member"$'\t'"skipped"$'\t' \
          'local boundary refusal must report both withheld routing members'
      done
      selected_pair="$COHERENCE_SOURCE/config"
      if [ "$pair_selection" = staged ]; then
        selected_pair=$COHERENCE_STAGE
        printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$COHERENCE_SOURCE/config/model-index.json"
        cp "$TMP_ROOT/retained-dispatch.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
      fi
      cp "$TMP_ROOT/incoming-index.json" "$selected_pair/model-index.json"
      cp "$TMP_ROOT/incoming-dispatch.json" "$selected_pair/crew-dispatch.json"
      (
        unset FM_CONFIG_INHERIT_LIVE FM_CONFIG_INHERIT_PAIR_DIR
        [ "$boundary_mode" != bootstrap ] || { FM_CONFIG_INHERIT_LIVE=1; export FM_CONFIG_INHERIT_LIVE; }
        [ "$pair_selection" != staged ] || { FM_CONFIG_INHERIT_PAIR_DIR="$COHERENCE_STAGE"; export FM_CONFIG_INHERIT_PAIR_DIR; }
        FM_MODEL_CATALOG_DIR="$COHERENCE_CATALOGS" \
          propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$coherence_home"
      ) > "$TMP_ROOT/coherence-local.out" 2>&1 \
        || fail "local $boundary_mode refused a coherent offline pair: $(cat "$TMP_ROOT/coherence-local.out")"
      for member in model-index.json crew-dispatch.json; do
        cmp -s "$selected_pair/$member" "$coherence_home/config/$member" || fail 'local selected coherent pair did not converge'
      done
      [ "$(FM_HOME="$coherence_home" "$TOOL" profiles "$coherence_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
        || fail 'local boundary coherent update did not reach the real profiles consumer'
    done
  done
done
pass 'bootstrap and local launch refuse removed-role and missing-index pairs offline, preserve resolvable destination routing, and honor selected frozen pairs'

for envelope in empty concatenated; do
  malformed_home="$TMP_ROOT/local-dispatch-envelope-$envelope"
  seed_coherent_destination "$malformed_home"
  git -C "$malformed_home" init -q
  printf 'config/\n' > "$malformed_home/.gitignore"
  cp "$TMP_ROOT/incoming-index.json" "$COHERENCE_SOURCE/config/model-index.json"
  : > "$COHERENCE_SOURCE/config/crew-dispatch.json"
  if [ "$envelope" = concatenated ]; then
    cat "$TMP_ROOT/incoming-dispatch.json" "$TMP_ROOT/incoming-dispatch.json" > "$COHERENCE_SOURCE/config/crew-dispatch.json"
  fi
  boundary_code=0
  propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$malformed_home" > "$TMP_ROOT/envelope.out" 2>&1 || boundary_code=$?
  [ "$boundary_code" = 1 ] || fail "inheritance accepted $envelope dispatch"
  assert_retained_pair "$malformed_home" "$envelope dispatch"
  assert_unrelated_coherence_material "$malformed_home" launch
done
pass 'malformed present dispatch retains both routing members without blocking unrelated inheritance'

# fm-config-push runs the full index check before the index reaches any home.
fm_git_identity fmtest fmtest@example.invalid
PUSH="$TMP_ROOT/push"
mkdir -p "$PUSH/home/state" "$PUSH/home/data" "$PUSH/home/config" "$PUSH/jqbin"
ln -s "$(command -v jq)" "$PUSH/jqbin/jq"
git init -q -b main "$PUSH/root"
printf '%s\n' .fm-secondmate-home data/ state/ config/ projects/ > "$PUSH/root/.gitignore"
printf 'instructions\n' > "$PUSH/root/AGENTS.md"
mkdir -p "$PUSH/root/bin"
printf 'echo spawn\n' > "$PUSH/root/bin/fm-spawn.sh"
cp "$ROOT/bin/fm-remote-inherit.sh" "$PUSH/root/bin/fm-remote-inherit.sh"
touch "$PUSH/home/state/.last-watcher-beat"
git -C "$PUSH/root" add -A
git -C "$PUSH/root" commit -qm initial
git -C "$PUSH/root" worktree add -q --detach "$PUSH/sm" HEAD
printf 'sm\n' > "$PUSH/sm/.fm-secondmate-home"
mkdir -p "$PUSH/sm/data" "$PUSH/sm/state" "$PUSH/sm/config"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$PUSH/sm" > "$PUSH/home/state/sm.meta"
printf '%s\n' '{"version":1,"roles":{"strong":{"codex":{"model":"prior"}}},"retired":[]}' > "$PUSH/sm/config/model-index.json"
cp "$PUSH/sm/config/model-index.json" "$PUSH/prior-index.json"
config_push() { # <catalog-dir>; output in $TMP_ROOT/push.out
  PATH="$PUSH/jqbin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" FM_HOME="$PUSH/home" FM_ROOT_OVERRIDE="$PUSH/root" \
    FM_MODEL_CATALOG_DIR="$1" "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/push.out" 2>&1 || true
}
printf '%s\n' '{"default":{"harness":"codex","role":"strong"}}' > "$PUSH/sm/config/crew-dispatch.json"
cp "$PUSH/sm/config/crew-dispatch.json" "$PUSH/prior-dispatch.json"
# A new role with a mistyped id, and dispatch profiles switched to it.
jq '.roles.fast = {codex:{model:"absent"}}' "$BASE" > "$PUSH/home/config/model-index.json"
printf '%s\n' '{"default":{"harness":"codex","role":"fast"}}' > "$PUSH/home/config/crew-dispatch.json"
printf 'codex\n' > "$PUSH/home/config/crew-harness"
config_push "$CATALOGS"
assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' 'an index with an absent id must be withheld with its dispatch profiles'
cmp -s "$PUSH/prior-index.json" "$PUSH/sm/config/model-index.json" || fail 'a refused index reached the secondmate home'
cmp -s "$PUSH/prior-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'dispatch profiles naming a withheld role reached the secondmate home'
cmp -s "$PUSH/home/config/crew-harness" "$PUSH/sm/config/crew-harness" || fail "a refused index must not withhold other inherited config: $(cat "$TMP_ROOT/push.out")"
mkdir -p "$TMP_ROOT/no-push-catalogs"
config_push "$TMP_ROOT/no-push-catalogs"
assert_contains "$(cat "$TMP_ROOT/push.out")" 'codex catalog unavailable' 'an unreadable catalog must be reported'
cmp -s "$PUSH/home/config/model-index.json" "$PUSH/sm/config/model-index.json" || fail 'an unreadable catalog blocked the index push'
cmp -s "$PUSH/home/config/crew-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'an unreadable catalog blocked the dispatch push'
jq '.roles.fast = {codex:{model:"current"}}' "$BASE" > "$PUSH/home/config/model-index.json"
config_push "$CATALOGS"
assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' 'a valid index must not be withheld'
cmp -s "$PUSH/home/config/model-index.json" "$PUSH/sm/config/model-index.json" || fail 'a valid index was not pushed'
cmp -s "$PUSH/home/config/crew-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'dispatch profiles for a valid index were not pushed'
[ "$(FM_HOME="$PUSH/sm" "$TOOL" profiles "$PUSH/sm/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
  || fail 'the pushed pair must resolve its role in the secondmate home'
# An index with no entries still has to be well formed to push.
cp "$PUSH/sm/config/model-index.json" "$PUSH/prior-index.json"
cp "$PUSH/sm/config/crew-dispatch.json" "$PUSH/prior-dispatch.json"
cp "$BASE" "$PUSH/home/config/model-index.json"
for envelope in empty concatenated; do
  : > "$PUSH/home/config/crew-dispatch.json"
  if [ "$envelope" = concatenated ]; then
    cat "$PUSH/prior-dispatch.json" "$PUSH/prior-dispatch.json" > "$PUSH/home/config/crew-dispatch.json"
  fi
  config_push "$CATALOGS"
  assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' "config-push accepted $envelope dispatch"
  cmp -s "$PUSH/prior-index.json" "$PUSH/sm/config/model-index.json" || fail "$envelope dispatch replaced the retained index"
  cmp -s "$PUSH/prior-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail "$envelope dispatch replaced the retained dispatch"
done
printf '%s\n' '{"default":{"harness":"codex","role":"fast"}}' > "$PUSH/home/config/crew-dispatch.json"
for malformed in '{"version":1,"roles":{}}' '{"version":2,"roles":{},"retired":[]}'; do
  printf '%s\n' "$malformed" > "$PUSH/home/config/model-index.json"
  config_push "$CATALOGS"
  assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' "a malformed empty index must be withheld: $malformed"
  cmp -s "$PUSH/prior-index.json" "$PUSH/sm/config/model-index.json" || fail "a malformed empty index reached the secondmate home: $malformed"
  cmp -s "$PUSH/prior-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail "dispatch profiles beside a malformed empty index reached the secondmate home: $malformed"
done
# Removing a role the dispatch profiles still name withholds the pair.
printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$PUSH/home/config/model-index.json"
config_push "$CATALOGS"
assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' 'an index missing a dispatch role must be withheld'
assert_contains "$(cat "$TMP_ROOT/push.out")" 'role or stand-in not configured: codex:fast' 'the refusal must name the unresolved dispatch role'
cmp -s "$PUSH/prior-index.json" "$PUSH/sm/config/model-index.json" || fail 'an index missing a dispatch role reached the secondmate home'
cmp -s "$PUSH/prior-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'dispatch profiles naming a removed role reached the secondmate home'
[ "$(FM_HOME="$PUSH/sm" "$TOOL" profiles "$PUSH/sm/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
  || fail 'the secondmate home must keep a pair that still resolves'
printf '%s\n' '{"default":{"harness":"codex","model":"current"}}' > "$PUSH/home/config/crew-dispatch.json"
config_push "$CATALOGS"
assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' 'a valid empty index with role-free dispatch profiles must push'
cmp -s "$PUSH/home/config/model-index.json" "$PUSH/sm/config/model-index.json" || fail 'a valid empty index was not pushed'
cmp -s "$PUSH/home/config/crew-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'role-free dispatch profiles were not pushed with the empty index'
printf '%s\n' '{"version":1,"roles":{"stable":{"codex":{"model":"current"}}},"retired":[]}' > "$PUSH/safe-index.json"
printf '%s\n' '{"default":{"harness":"codex","role":"stable"}}' > "$PUSH/safe-dispatch.json"
{ cat "$PUSH/safe-index.json"; printf '%1048577s\n' ''; } > "$PUSH/oversize-index.json"
{ cat "$PUSH/safe-dispatch.json"; printf '%1048577s\n' ''; } > "$PUSH/oversize-dispatch.json"
for oversized in "$PUSH/oversize-index.json" "$PUSH/oversize-dispatch.json"; do
  [ "$(wc -c < "$oversized")" -gt 1048576 ] || fail 'oversize fixture did not exceed the receiver limit'
  jq -e . "$oversized" >/dev/null || fail 'oversize routing fixture must be valid JSON'
done
for source_route in local remote; do
  if [ "$source_route" = remote ]; then
    printf 'window=firstmate:fm-remote\nkind=secondmate\nhome=%s\nremote_host=inherit-host\n' "$PUSH/remote" > "$PUSH/home/state/remote.meta"
  fi
  for source_member in model-index.json crew-dispatch.json; do
    for unsafe_source in symlink hardlink directory oversize; do
      cp "$PUSH/sm/config/model-index.json" "$PUSH/before-stage-index.json"
      cp "$PUSH/sm/config/crew-dispatch.json" "$PUSH/before-stage-dispatch.json"
      cp "$PUSH/safe-index.json" "$PUSH/home/config/model-index.json"
      cp "$PUSH/safe-dispatch.json" "$PUSH/home/config/crew-dispatch.json"
      safe_payload="$PUSH/safe-index.json"
      oversize_payload="$PUSH/oversize-index.json"
      if [ "$source_member" = crew-dispatch.json ]; then
        safe_payload="$PUSH/safe-dispatch.json"
        oversize_payload="$PUSH/oversize-dispatch.json"
      fi
      rm "$PUSH/home/config/$source_member"
      case "$unsafe_source" in
        symlink) ln -s "$safe_payload" "$PUSH/home/config/$source_member" ;;
        hardlink) ln "$safe_payload" "$PUSH/home/config/$source_member" ;;
        directory) mkdir "$PUSH/home/config/$source_member" ;;
        oversize) cp "$oversize_payload" "$PUSH/home/config/$source_member" ;;
      esac
      printf '%s\n' "$source_member-$unsafe_source" > "$PUSH/home/config/dispatch-never-send"
      config_push "$CATALOGS"
      if [ "$source_route" = local ] && [ "$unsafe_source" != directory ]; then
        assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' "local $source_member $unsafe_source regular target must still stage"
        [ "$(FM_HOME="$PUSH/sm" "$TOOL" profiles "$PUSH/sm/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail "local $source_member $unsafe_source did not reach real consumer"
      else
        assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' "unsafe $source_route $source_member $unsafe_source staging must withhold the pair"
        cmp -s "$PUSH/before-stage-index.json" "$PUSH/sm/config/model-index.json" || fail "unsafe $source_member $unsafe_source staging changed destination index"
        cmp -s "$PUSH/before-stage-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail "unsafe $source_member $unsafe_source staging changed destination dispatch"
        [ "$(FM_HOME="$PUSH/sm" "$TOOL" profiles "$PUSH/sm/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail "unsafe $source_member $unsafe_source staging left an unresolvable retained pair"
      fi
      cmp -s "$PUSH/home/config/dispatch-never-send" "$PUSH/sm/config/dispatch-never-send" || fail "unsafe $source_member $unsafe_source staging blocked unrelated config"
      if [ "$unsafe_source" = directory ]; then
        rmdir "$PUSH/home/config/$source_member"
      else
        rm "$PUSH/home/config/$source_member"
      fi
      cp "$safe_payload" "$PUSH/home/config/$source_member"
    done
  done
  [ "$source_route" != remote ] || rm "$PUSH/home/state/remote.meta"
done
cp "$PUSH/sm/config/model-index.json" "$PUSH/before-stage-index.json"
cp "$PUSH/sm/config/crew-dispatch.json" "$PUSH/before-stage-dispatch.json"
rm "$PUSH/home/config/model-index.json"
printf '%s\n' '{"default":{"harness":"codex","role":"stable"}}' > "$PUSH/home/config/crew-dispatch.json"
config_push "$CATALOGS"
assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' 'removed index cannot publish an unresolved role dispatch'
cmp -s "$PUSH/before-stage-index.json" "$PUSH/sm/config/model-index.json" || fail 'unresolved role dispatch removed destination index'
cmp -s "$PUSH/before-stage-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail 'unresolved role dispatch changed destination dispatch'
printf '%s\n' '{"default":{"harness":"codex","model":"current"}}' > "$PUSH/home/config/crew-dispatch.json"
config_push "$CATALOGS"
assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' 'removed index with literal dispatch must retain compatibility'
[ ! -e "$PUSH/sm/config/model-index.json" ] || fail 'staged index absence was not propagated'
[ "$(FM_HOME="$PUSH/sm" "$TOOL" profiles "$PUSH/sm/config/crew-dispatch.json" | jq -r '.default.model')" = current ] || fail 'literal dispatch without index no longer resolves'
mkdir -p "$PUSH/remote/config" "$PUSH/remote/state" "$PUSH/remote/data"
printf 'window=firstmate:fm-remote\nkind=secondmate\nhome=%s\nremote_host=inherit-host\n' "$PUSH/remote" > "$PUSH/home/state/remote.meta"
printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
  "$ROOT" "$PUSH/remote" > "$PUSH/home/data/secondmates.md"
cat > "$PUSH/jqbin/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
if [ -n "${PAIR_SSH_LOG:-}" ]; then
  printf '%s %s\n' "${args[1]}" "${args[2]}" >> "$PAIR_SSH_LOG"
fi
if [ "${args[1]}" = check ] && [ -n "${PAIR_RACE_MARKER:-}" ] && [ ! -e "$PAIR_RACE_MARKER" ]; then
  for member in model-index.json crew-dispatch.json; do
    if [ "$PAIR_RACE_ACTION" = remove ] && [ -e "$PAIR_RACE_SOURCE/$member" ]; then
      rm "$PAIR_RACE_SOURCE/$member"
    else
      cp "$PAIR_RACE_LATER/$member" "$PAIR_RACE_SOURCE/$member"
    fi
  done
  printf 'mutated\n' > "$PAIR_RACE_MARKER"
fi
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
cat > "$PUSH/jqbin/omp" <<'SH'
#!/usr/bin/env bash
set -eu
cp "$MODEL_RACE_INDEX" "$MODEL_RACE_CONFIG/model-index.json"
cp "$MODEL_RACE_DISPATCH" "$MODEL_RACE_CONFIG/crew-dispatch.json"
printf 'mutated\n' > "$MODEL_RACE_MARKER"
printf '%s\n' '{"models":[{"provider":"provider","id":"current","selector":"provider/current"}]}'
SH
chmod +x "$PUSH/jqbin/omp" "$PUSH/jqbin/inherit-ssh"
printf '%s\n' '{"version":1,"roles":{"later":{"omp":{"model":"provider/absent"}}},"retired":[]}' > "$PUSH/later-index.json"
printf '%s\n' '{"default":{"harness":"omp","role":"later"}}' > "$PUSH/later-dispatch.json"
for dispatch_presence in present absent; do
  printf '%s\n' '{"version":1,"roles":{"stable":{"omp":{"model":"provider/current"}}},"retired":[]}' > "$PUSH/home/config/model-index.json"
  cp "$PUSH/home/config/model-index.json" "$PUSH/staged-index.json"
  printf '%s\n' '{"default":{"harness":"omp","role":"stable"}}' > "$PUSH/staged-dispatch.json"
  if [ "$dispatch_presence" = present ]; then
    cp "$PUSH/staged-dispatch.json" "$PUSH/home/config/crew-dispatch.json"
  else
    rm -f "$PUSH/home/config/crew-dispatch.json"
  fi
  rm -f "$PUSH/race-marker"
  MODEL_RACE_CONFIG="$PUSH/home/config" MODEL_RACE_INDEX="$PUSH/later-index.json" \
    MODEL_RACE_DISPATCH="$PUSH/later-dispatch.json" MODEL_RACE_MARKER="$PUSH/race-marker" \
    FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" config_push ''
  [ -s "$PUSH/race-marker" ] || fail 'native catalog lookup did not mutate the original pair'
  cmp -s "$PUSH/later-index.json" "$PUSH/home/config/model-index.json" || fail 'original index did not change during lookup'
  cmp -s "$PUSH/later-dispatch.json" "$PUSH/home/config/crew-dispatch.json" || fail 'original dispatch did not change during lookup'
  assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' "staged pair was refused after original mutation: $(cat "$TMP_ROOT/push.out")"
  for destination in "$PUSH/sm" "$PUSH/remote"; do
    [ -f "$destination/config/model-index.json" ] || fail "index payload never reached $destination: $(cat "$TMP_ROOT/push.out")"
    cmp -s "$PUSH/staged-index.json" "$destination/config/model-index.json" || fail "source mutation reached $destination: $(cat "$TMP_ROOT/push.out")"
    [ "$(FM_HOME="$destination" "$TOOL" model omp role:stable)" = provider/current ] || fail "real consumer did not resolve staged index in $destination: $(cat "$TMP_ROOT/push.out")"
    if [ "$dispatch_presence" = present ]; then
      [ -f "$destination/config/crew-dispatch.json" ] || fail "dispatch payload never reached $destination: $(cat "$TMP_ROOT/push.out")"
      [ "$(FM_HOME="$destination" "$TOOL" profiles "$destination/config/crew-dispatch.json" | jq -r '.default.model')" = provider/current ] \
        || fail "real consumer did not resolve staged pair in $destination: $(cat "$TMP_ROOT/push.out")"
    else
      [ ! -e "$destination/config/crew-dispatch.json" ] || fail "late dispatch appearance reached $destination: $(cat "$TMP_ROOT/push.out")"
    fi
  done
done
rm "$PUSH/home/state/remote.meta" "$PUSH/jqbin/omp"
printf '%s\n' '{"default":{"harness":"codex","model":"current"}}' > "$PUSH/home/config/crew-dispatch.json"
pass 'real local and remote inheritance consume the frozen pair after native catalog mutation, including staged dispatch absence'

: > "$TMP_ROOT/empty-inheritance"
empty_hash=$(fm_inherit_sha256 "$TMP_ROOT/empty-inheritance")
remote_generation=1000
for guarded in model-index.json crew-dispatch.json; do
  for remote_guard in symlink hardlink directory; do
    for presence in both index-only dispatch-only absent; do
      remote_guard_home="$TMP_ROOT/remote-pair-$guarded-$remote_guard-$presence"
      mkdir -p "$remote_guard_home/config" "$remote_guard_home/state"
      cp "$TMP_ROOT/retained-index.json" "$remote_guard_home/config/model-index.json"
      cp "$TMP_ROOT/retained-dispatch.json" "$remote_guard_home/config/crew-dispatch.json"
      mv "$remote_guard_home/config/$guarded" "$remote_guard_home/guarded-payload"
      case "$remote_guard" in
        symlink) ln -s "$remote_guard_home/guarded-payload" "$remote_guard_home/config/$guarded" ;;
        hardlink) ln "$remote_guard_home/guarded-payload" "$remote_guard_home/config/$guarded" ;;
        directory)
          mkdir "$remote_guard_home/config/$guarded"
          printf 'retain\n' > "$remote_guard_home/config/$guarded/marker"
          ;;
      esac
      set_pair_source "$presence"
      for attempted in model-index.json crew-dispatch.json; do
        for command in put absent; do
          payload="$TMP_ROOT/incoming-index.json"
          [ "$attempted" != crew-dispatch.json ] || payload="$TMP_ROOT/incoming-dispatch.json"
          bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
          hash=$(fm_inherit_sha256 "$payload")
          if [ "$command" = absent ]; then
            payload="$TMP_ROOT/empty-inheritance"
            bytes=0
            hash=$empty_hash
          fi
          receiver_code=0
          FM_HOME="$remote_guard_home" FM_STATE_OVERRIDE="$remote_guard_home/state" \
            "$ROOT/bin/fm-remote-inherit.sh" "$command" "config/$attempted" "$bytes" "$hash" "$remote_generation" \
            < "$payload" > "$TMP_ROOT/receiver-guard.out" 2>&1 || receiver_code=$?
          [ "$receiver_code" -ne 0 ] || fail "direct receiver accepted $command $attempted with $guarded $remote_guard"
          assert_contains "$(cat "$TMP_ROOT/receiver-guard.out")" 'inherited destination' 'direct receiver refusal must name its destination guard'
        done
      done
      printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
        "$ROOT" "$remote_guard_home" > "$PUSH/home/data/secondmates.md"
      printf 'retain-trailers\n' > "$remote_guard_home/config/keep-ai-trailers"
      sender_code=0
      FM_HOME="$PUSH/home" FM_ROOT_OVERRIDE="$PUSH/root" FM_CONFIG_OVERRIDE="$PAIR_SOURCE" \
        FM_CONFIG_INHERIT_LIVE=1 FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" \
        "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation" \
        > "$TMP_ROOT/sender-guard.out" 2>&1 || sender_code=$?
      [ "$sender_code" -ne 0 ] || fail "sender accepted guarded remote pair: $guarded $remote_guard $presence"
      assert_contains "$(cat "$TMP_ROOT/sender-guard.out")" 'skipped: config/model-index.json and config/crew-dispatch.json' 'sender must report pair preflight refusal'
      cmp -s "$PAIR_SOURCE/dispatch-never-send" "$remote_guard_home/config/dispatch-never-send" || fail 'remote pair refusal blocked unrelated propagation'
      [ "$(cat "$remote_guard_home/config/keep-ai-trailers")" = retain-trailers ] || fail 'remote pair refusal changed an unchanged trailer setting'
      case "$remote_guard" in
        symlink)
          [ -L "$remote_guard_home/config/$guarded" ] || fail 'remote refusal replaced the guarded symlink'
          rm "$remote_guard_home/config/$guarded"
          ;;
        hardlink)
          cmp -s "$remote_guard_home/guarded-payload" "$remote_guard_home/config/$guarded" || fail 'remote refusal changed the guarded hardlink'
          [ "$(fm_inherit_file_link_count "$remote_guard_home/config/$guarded")" = 2 ] || fail 'remote refusal replaced the guarded hardlink'
          rm "$remote_guard_home/config/$guarded"
          ;;
        directory)
          [ "$(cat "$remote_guard_home/config/$guarded/marker")" = retain ] || fail 'remote refusal changed the guarded nonregular destination'
          rm "$remote_guard_home/config/$guarded/marker"
          rmdir "$remote_guard_home/config/$guarded"
          ;;
      esac
      cp "$remote_guard_home/guarded-payload" "$remote_guard_home/config/$guarded"
      assert_retained_pair "$remote_guard_home" "remote $guarded $remote_guard $presence"
      remote_generation=$((remote_generation + 1))
      FM_HOME="$PUSH/home" FM_ROOT_OVERRIDE="$PUSH/root" FM_CONFIG_OVERRIDE="$PAIR_SOURCE" \
        FM_CONFIG_INHERIT_LIVE=1 FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" \
        "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation" \
        > "$TMP_ROOT/sender-success.out" 2>&1 || fail "unguarded remote pair was refused: $(cat "$TMP_ROOT/sender-success.out")"
      for member in model-index.json crew-dispatch.json; do
        if [ -f "$PAIR_SOURCE/$member" ]; then
          cmp -s "$PAIR_SOURCE/$member" "$remote_guard_home/config/$member" || fail 'allowed remote pair payload did not converge'
        else
          [ ! -e "$remote_guard_home/config/$member" ] || fail 'allowed remote pair absence did not converge'
        fi
      done
      if [ "$presence" = both ] || [ "$presence" = dispatch-only ]; then
        [ "$(FM_HOME="$remote_guard_home" "$TOOL" profiles "$remote_guard_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail 'allowed remote pair did not reach the destination profiles consumer'
      fi
      remote_generation=$((remote_generation + 1))
    done
  done
done
pass 'remote sender and direct receiver guard both pair members for put and absent; refusal preserves unrelated propagation'

for boundary_mode in bootstrap launch; do
  for pair_selection in source staged; do
    for failure in removed-role missing-index; do
      coherence_home="$TMP_ROOT/remote-coherence-$boundary_mode-$pair_selection-$failure"
      seed_coherent_destination "$coherence_home"
      mkdir -p "$coherence_home/state"
      printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
        "$ROOT" "$coherence_home" > "$COHERENCE_SOURCE/data/secondmates.md"
      set_incoherent_source "$failure" "$pair_selection"
      boundary_code=0
      (
        unset FM_CONFIG_INHERIT_LIVE FM_CONFIG_INHERIT_PAIR_DIR
        [ "$boundary_mode" != bootstrap ] || { FM_CONFIG_INHERIT_LIVE=1; export FM_CONFIG_INHERIT_LIVE; }
        [ "$pair_selection" != staged ] || { FM_CONFIG_INHERIT_PAIR_DIR="$COHERENCE_STAGE"; export FM_CONFIG_INHERIT_PAIR_DIR; }
        FM_HOME="$COHERENCE_SOURCE" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$COHERENCE_SOURCE/config" \
          FM_MODEL_CATALOG_DIR="$COHERENCE_CATALOGS" FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" \
          "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation"
      ) > "$TMP_ROOT/coherence-remote.out" 2>&1 || boundary_code=$?
      [ "$boundary_code" = 1 ] || fail "remote $boundary_mode accepted $failure from $pair_selection"
      assert_retained_pair "$coherence_home" "remote $boundary_mode $pair_selection $failure"
      assert_unrelated_coherence_material "$coherence_home" "$boundary_mode"
      assert_contains "$(cat "$TMP_ROOT/coherence-remote.out")" 'skipped: config/model-index.json and config/crew-dispatch.json' \
        'remote boundary refusal must report both withheld routing members'
      assert_contains "$(cat "$TMP_ROOT/coherence-remote.out")" 'role or stand-in not configured: codex:retained' \
        'remote boundary refusal must explain the unresolved retained dispatch role'
      remote_generation=$((remote_generation + 1))
      selected_pair="$COHERENCE_SOURCE/config"
      if [ "$pair_selection" = staged ]; then
        selected_pair=$COHERENCE_STAGE
        printf '%s\n' '{"version":1,"roles":{},"retired":[]}' > "$COHERENCE_SOURCE/config/model-index.json"
        cp "$TMP_ROOT/retained-dispatch.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
      fi
      cp "$TMP_ROOT/incoming-index.json" "$selected_pair/model-index.json"
      cp "$TMP_ROOT/incoming-dispatch.json" "$selected_pair/crew-dispatch.json"
      (
        unset FM_CONFIG_INHERIT_LIVE FM_CONFIG_INHERIT_PAIR_DIR
        [ "$boundary_mode" != bootstrap ] || { FM_CONFIG_INHERIT_LIVE=1; export FM_CONFIG_INHERIT_LIVE; }
        [ "$pair_selection" != staged ] || { FM_CONFIG_INHERIT_PAIR_DIR="$COHERENCE_STAGE"; export FM_CONFIG_INHERIT_PAIR_DIR; }
        FM_HOME="$COHERENCE_SOURCE" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$COHERENCE_SOURCE/config" \
          FM_MODEL_CATALOG_DIR="$COHERENCE_CATALOGS" FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" \
          "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation"
      ) > "$TMP_ROOT/coherence-remote.out" 2>&1 \
        || fail "remote $boundary_mode refused a coherent offline pair: $(cat "$TMP_ROOT/coherence-remote.out")"
      for member in model-index.json crew-dispatch.json; do
        cmp -s "$selected_pair/$member" "$coherence_home/config/$member" || fail 'remote selected coherent pair did not converge'
      done
      [ "$(FM_HOME="$coherence_home" "$TOOL" profiles "$coherence_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
        || fail 'remote boundary coherent update did not reach the real profiles consumer'
      assert_not_contains "$(cat "$TMP_ROOT/coherence-remote.out")" 'skipped: config/model-index.json and config/crew-dispatch.json' \
        'remote boundary must not report coherent routing as refused'
      remote_generation=$((remote_generation + 1))
    done
  done
done
pass 'bootstrap and remote launch refuse incoherent source routing while real receiver convergence continues, and publish valid selected pairs without live catalog checks'

for source_member in model-index.json crew-dispatch.json; do
  for unsafe_source in symlink hardlink directory oversize; do
    source_guard_home="$TMP_ROOT/remote-source-$source_member-$unsafe_source"
    seed_coherent_destination "$source_guard_home"
    mkdir -p "$source_guard_home/state"
    set_pair_source both
    cp "$PAIR_SOURCE/model-index.json" "$COHERENCE_SOURCE/config/model-index.json"
    cp "$PAIR_SOURCE/crew-dispatch.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
    printf '%s\n' "$source_member-$unsafe_source" > "$COHERENCE_SOURCE/config/dispatch-never-send"
    source_payload="$TMP_ROOT/source-$source_member-$unsafe_source.json"
    cp "$COHERENCE_SOURCE/config/$source_member" "$source_payload"
    rm "$COHERENCE_SOURCE/config/$source_member"
    case "$unsafe_source" in
      symlink) ln -s "$source_payload" "$COHERENCE_SOURCE/config/$source_member" ;;
      hardlink) ln "$source_payload" "$COHERENCE_SOURCE/config/$source_member" ;;
      directory) mkdir "$COHERENCE_SOURCE/config/$source_member" ;;
      oversize)
        { cat "$source_payload"; printf '%1048577s\n' ''; } > "$COHERENCE_SOURCE/config/$source_member"
        [ "$(wc -c < "$COHERENCE_SOURCE/config/$source_member")" -gt 1048576 ] || fail 'automatic source fixture is not oversized'
        jq -e . "$COHERENCE_SOURCE/config/$source_member" >/dev/null || fail 'automatic oversized source is not valid JSON'
        ;;
    esac
    printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
      "$ROOT" "$source_guard_home" > "$COHERENCE_SOURCE/data/secondmates.md"
    : > "$TMP_ROOT/source-ssh.log"
    source_code=0
    FM_HOME="$COHERENCE_SOURCE" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$COHERENCE_SOURCE/config" \
      FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" PAIR_SSH_LOG="$TMP_ROOT/source-ssh.log" \
      "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation" \
      > "$TMP_ROOT/source-guard.out" 2>&1 || source_code=$?
    [ "$source_code" -ne 0 ] || fail "automatic remote sender accepted $source_member $unsafe_source"
    assert_retained_pair "$source_guard_home" "remote source $source_member $unsafe_source"
    assert_unrelated_coherence_material "$source_guard_home" launch
    for member in model-index.json crew-dispatch.json; do
      assert_not_contains "$(cat "$TMP_ROOT/source-ssh.log")" "put config/$member" 'unsafe source must withhold both routing transfers'
      assert_not_contains "$(cat "$TMP_ROOT/source-ssh.log")" "absent config/$member" 'unsafe source must withhold both routing removals'
    done
    if [ "$unsafe_source" = symlink ] || [ "$unsafe_source" = hardlink ]; then
      local_source_home="$TMP_ROOT/local-source-$source_member-$unsafe_source"
      seed_coherent_destination "$local_source_home"
      git -C "$local_source_home" init -q
      printf 'config/\n' > "$local_source_home/.gitignore"
      propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$local_source_home" \
        > "$TMP_ROOT/local-source.out" 2>&1 || fail "local automatic boundary refused source $source_member $unsafe_source"
      [ "$(FM_HOME="$local_source_home" "$TOOL" profiles "$local_source_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
        || fail "local source $source_member $unsafe_source did not reach the real consumer"
      cmp -s "$source_payload" "$local_source_home/config/$source_member" || fail 'local source link bytes changed'
    fi
    if [ "$unsafe_source" = directory ]; then
      rmdir "$COHERENCE_SOURCE/config/$source_member"
    else
      rm "$COHERENCE_SOURCE/config/$source_member"
    fi
    remote_generation=$((remote_generation + 1))
  done
done
pass 'automatic remote source guards withhold both members before transfer for either unsafe source while local source links remain consumable'

RACE_BIN="$TMP_ROOT/pair-race-bin"
RACE_LATER="$TMP_ROOT/pair-race-later"
mkdir -p "$RACE_BIN" "$RACE_LATER"
cp "$TMP_ROOT/retained-index.json" "$RACE_LATER/model-index.json"
cp "$TMP_ROOT/retained-dispatch.json" "$RACE_LATER/crew-dispatch.json"
REAL_GIT=$(command -v git)
cat > "$RACE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  if [ "$arg" = check-ignore ]; then
    count=0
    [ ! -f "$PAIR_RACE_COUNT" ] || read -r count < "$PAIR_RACE_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" > "$PAIR_RACE_COUNT"
    if [ "$count" = 3 ]; then
      for member in model-index.json crew-dispatch.json; do
        if [ "$PAIR_RACE_ACTION" = remove ] && [ -e "$PAIR_RACE_SOURCE/$member" ]; then
          rm "$PAIR_RACE_SOURCE/$member"
        else
          cp "$PAIR_RACE_LATER/$member" "$PAIR_RACE_SOURCE/$member"
        fi
      done
      printf 'mutated\n' > "$PAIR_RACE_MARKER"
    fi
    break
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$RACE_BIN/git"
for race_boundary in local remote; do
  for presence in both index-only dispatch-only absent; do
    for race_action in replace remove; do
      race_home="$TMP_ROOT/pair-race-$race_boundary-$presence-$race_action"
      race_expected="$race_home/expected"
      race_mutated="$race_home/mutated"
      seed_coherent_destination "$race_home"
      mkdir -p "$race_home/state" "$race_expected" "$race_mutated"
      git -C "$race_home" init -q
      printf 'config/\n' > "$race_home/.gitignore"
      set_pair_source "$presence"
      rm -f "$COHERENCE_SOURCE/config/model-index.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
      for member in model-index.json crew-dispatch.json; do
        if [ -f "$PAIR_SOURCE/$member" ]; then
          cp "$PAIR_SOURCE/$member" "$COHERENCE_SOURCE/config/$member"
          cp "$PAIR_SOURCE/$member" "$race_expected/$member"
        fi
        if [ "$race_action" != remove ] || [ ! -f "$PAIR_SOURCE/$member" ]; then
          cp "$RACE_LATER/$member" "$race_mutated/$member"
        fi
      done
      printf '%s\n' "$race_boundary-$presence-$race_action" > "$COHERENCE_SOURCE/config/dispatch-never-send"
      if [ "$race_boundary" = local ]; then
        PATH="$RACE_BIN:$PATH" REAL_GIT="$REAL_GIT" PAIR_RACE_COUNT="$race_home/check-count" \
          PAIR_RACE_SOURCE="$COHERENCE_SOURCE/config" PAIR_RACE_LATER="$RACE_LATER" \
          PAIR_RACE_ACTION="$race_action" PAIR_RACE_MARKER="$race_home/marker" \
          propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$race_home" \
          > "$TMP_ROOT/pair-race.out" 2>&1 || fail "local frozen $presence $race_action refused: $(cat "$TMP_ROOT/pair-race.out")"
      else
        printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
          "$ROOT" "$race_home" > "$COHERENCE_SOURCE/data/secondmates.md"
        FM_HOME="$COHERENCE_SOURCE" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$COHERENCE_SOURCE/config" \
          FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" PAIR_RACE_SOURCE="$COHERENCE_SOURCE/config" \
          PAIR_RACE_LATER="$RACE_LATER" PAIR_RACE_ACTION="$race_action" PAIR_RACE_MARKER="$race_home/marker" \
          "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation" \
          > "$TMP_ROOT/pair-race.out" 2>&1 || fail "remote frozen $presence $race_action refused: $(cat "$TMP_ROOT/pair-race.out")"
        remote_generation=$((remote_generation + 1))
      fi
      [ "$(cat "$race_home/marker")" = mutated ] || fail "$race_boundary post-validation mutation hook did not run"
      for member in model-index.json crew-dispatch.json; do
        if [ -f "$race_mutated/$member" ]; then
          cmp -s "$race_mutated/$member" "$COHERENCE_SOURCE/config/$member" || fail "$race_boundary original $member did not mutate"
        else
          [ ! -e "$COHERENCE_SOURCE/config/$member" ] || fail "$race_boundary original $member was not removed"
        fi
        if [ -f "$race_expected/$member" ]; then
          cmp -s "$race_expected/$member" "$race_home/config/$member" || fail "$race_boundary published unfrozen $member for $presence $race_action"
        else
          [ ! -e "$race_home/config/$member" ] || fail "$race_boundary published late $member for $presence $race_action"
        fi
      done
      if [ -f "$race_expected/crew-dispatch.json" ]; then
        [ "$(FM_HOME="$race_home" "$TOOL" profiles "$race_home/config/crew-dispatch.json" | jq -r '.default.model')" = current ] \
          || fail "$race_boundary frozen $presence pair failed the real consumer"
      fi
      assert_unrelated_coherence_material "$race_home" launch
    done
  done
done
pass 'automatic local and remote boundaries publish validated bytes and absences after source replacement, removal, and late appearance of either member'

NOJQ="$TMP_ROOT/no-jq"
mkdir -p "$NOJQ/bin" "$NOJQ/home/config" "$NOJQ/home/data" "$NOJQ/home/state"
for executable in bash sh dirname perl git mkdir mktemp cp mv rm cmp uname stat sed chmod date awk \
  wc tr basename head cat ln readlink rmdir sleep base64 grep tail cut sort ps od touch; do
  resolved=$(command -v "$executable") || fail "missing no-jq fixture dependency: $executable"
  ln -s "$resolved" "$NOJQ/bin/$executable"
done
if resolved=$(command -v shasum); then
  ln -s "$resolved" "$NOJQ/bin/shasum"
else
  ln -s "$(command -v sha256sum)" "$NOJQ/bin/sha256sum"
fi
PATH="$NOJQ/bin" bash -c '! command -v jq >/dev/null 2>&1' || fail 'restricted fixture PATH still exposes jq'
for nojq_boundary in local remote; do
  for presence in absent index-only dispatch-only; do
    nojq_home="$NOJQ/$nojq_boundary-$presence"
    seed_coherent_destination "$nojq_home"
    mkdir -p "$nojq_home/state"
    git -C "$nojq_home" init -q
    printf 'config/\n' > "$nojq_home/.gitignore"
    set_pair_source "$presence"
    rm -f "$COHERENCE_SOURCE/config/model-index.json" "$COHERENCE_SOURCE/config/crew-dispatch.json"
    for member in model-index.json crew-dispatch.json; do
      [ ! -f "$PAIR_SOURCE/$member" ] || cp "$PAIR_SOURCE/$member" "$COHERENCE_SOURCE/config/$member"
    done
    printf '%s\n' "$nojq_boundary-$presence" > "$COHERENCE_SOURCE/config/dispatch-never-send"
    nojq_code=0
    if [ "$nojq_boundary" = local ]; then
      (
        export PATH="$NOJQ/bin"
        ! command -v jq >/dev/null 2>&1 || exit 98
        propagate_secondmate_inheritance "$COHERENCE_SOURCE" "$nojq_home"
      ) > "$TMP_ROOT/no-jq.out" 2>&1 || nojq_code=$?
    else
      printf -- '- remote - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-06)\n' \
        "$ROOT" "$nojq_home" > "$COHERENCE_SOURCE/data/secondmates.md"
      PATH="$NOJQ/bin" FM_HOME="$COHERENCE_SOURCE" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$COHERENCE_SOURCE/config" \
        FM_SSH_BIN="$PUSH/jqbin/inherit-ssh" "$ROOT/bin/fm-remote-inherit-push.sh" remote "$remote_generation" \
        > "$TMP_ROOT/no-jq.out" 2>&1 || nojq_code=$?
      remote_generation=$((remote_generation + 1))
    fi
    if [ "$presence" = absent ]; then
      [ "$nojq_code" = 0 ] || fail "$nojq_boundary absent pair required jq: $(cat "$TMP_ROOT/no-jq.out")"
      [ ! -e "$nojq_home/config/model-index.json" ] && [ ! -e "$nojq_home/config/crew-dispatch.json" ] \
        || fail "$nojq_boundary no-jq pair absence did not remove both destination members"
    else
      [ "$nojq_code" -ne 0 ] || fail "$nojq_boundary accepted $presence without mandatory jq validation"
      assert_retained_pair "$nojq_home" "$nojq_boundary no-jq $presence"
      assert_contains "$(cat "$TMP_ROOT/no-jq.out")" jq 'present pair refusal must explain missing validation dependency'
    fi
    assert_unrelated_coherence_material "$nojq_home" launch
  done
done

git -C "$PUSH/root" worktree add -q --detach "$NOJQ/sm" HEAD
printf 'no-jq\n' > "$NOJQ/sm/.fm-secondmate-home"
mkdir -p "$NOJQ/sm/config" "$NOJQ/sm/state" "$NOJQ/sm/data"
printf 'window=firstmate:fm-no-jq\nkind=secondmate\nhome=%s\n' "$NOJQ/sm" > "$NOJQ/home/state/no-jq.meta"
printf 'codex\n' > "$NOJQ/home/config/crew-harness"
cp "$NOJQ/home/config/crew-harness" "$NOJQ/sm/config/crew-harness"
touch "$NOJQ/home/state/.last-watcher-beat"
mkdir -p "$NOJQ/code"
cp -R "$ROOT/bin" "$NOJQ/code/bin"
cat > "$NOJQ/code/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$#" = 2 ] && [ "$1" = fm-no-jq ] || exit 90
case "$2" in
  "CONFIG_REREAD: $NOJQ_SEND_HOME/state/"*) instruction=${2#CONFIG_REREAD: } ;;
  *) exit 91 ;;
esac
[ -f "$instruction" ] || exit 92
printf '%s\t%s\n' "$1" "$2" >> "$NOJQ_SEND_LOG"
SH
chmod +x "$NOJQ/code/bin/fm-send.sh"
for presence in absent index-only dispatch-only; do
  seed_coherent_destination "$NOJQ/sm"
  rm "$NOJQ/sm/config/dispatch-never-send"
  set_pair_source "$presence"
  rm -f "$NOJQ/home/config/model-index.json" "$NOJQ/home/config/crew-dispatch.json"
  for member in model-index.json crew-dispatch.json; do
    [ ! -f "$PAIR_SOURCE/$member" ] || cp "$PAIR_SOURCE/$member" "$NOJQ/home/config/$member"
  done
  printf 'main-authoritative; read-only in secondmate homes; must not be edited there; edit in the main firstmate; document pointer\nno-jq %s\n' \
    "$presence" > "$NOJQ/home/data/captain-shared.md"
  nojq_code=0
  rm -f "$NOJQ/send.log"
  PATH="$NOJQ/bin" FM_HOME="$NOJQ/home" FM_ROOT_OVERRIDE="$PUSH/root" FM_MODEL_CATALOG_DIR="$CATALOGS" \
    NOJQ_SEND_HOME="$NOJQ/sm" NOJQ_SEND_LOG="$NOJQ/send.log" \
    "$NOJQ/code/bin/fm-config-push.sh" > "$TMP_ROOT/no-jq-push.out" 2>&1 || nojq_code=$?
  if [ "$presence" = absent ]; then
    [ "$nojq_code" = 0 ] || fail "config-push absent pair required jq: $(cat "$TMP_ROOT/no-jq-push.out")"
    [ ! -e "$NOJQ/sm/config/model-index.json" ] && [ ! -e "$NOJQ/sm/config/crew-dispatch.json" ] \
      || fail 'config-push no-jq absence did not remove both destination members'
    assert_contains "$(cat "$NOJQ/send.log")" "fm-no-jq"$'\t'"CONFIG_REREAD: $NOJQ/sm/state/" \
      'no-jq config-push pair removal must deliver the real reread instruction through the fixture transport'
  else
    [ "$nojq_code" -ne 0 ] || fail "config-push accepted $presence without jq"
    assert_retained_pair "$NOJQ/sm" "config-push no-jq $presence"
    assert_contains "$(cat "$TMP_ROOT/no-jq-push.out")" 'model-index.json and crew-dispatch.json not pushed' 'config-push must withhold unvalidated pair'
    [ ! -e "$NOJQ/send.log" ] || fail 'withheld no-jq routing unexpectedly sent a reread instruction'
  fi
  cmp -s "$NOJQ/home/data/captain-shared.md" "$NOJQ/sm/data/captain-shared.md" || fail 'no-jq config-push blocked shared preferences'
  cmp -s "$NOJQ/home/config/crew-harness" "$NOJQ/sm/config/crew-harness" || fail 'no-jq config-push changed unrelated config'
done
pass 'both-source absence removes routing without jq at local, remote, and config-push boundaries while either present member still requires validation'
cat > "$PUSH/jqbin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 0
printf 'provider  model  context  max-out  thinking  images\n'
cat "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/listed" 2>/dev/null
[ -z "${ANTHROPIC_API_KEY:-}" ] || printf 'anthropic  claude-sonnet-5-5  200K  64K  yes  yes\n'
SH
chmod +x "$PUSH/jqbin/pi"
mkdir -p "$PUSH/pinned-pi" "$PUSH/ambient-pi"
printf 'openai-codex  gpt-pinned  272K  32K  yes  no\n' > "$PUSH/pinned-pi/listed"
printf 'openai-codex  gpt-ambient  272K  32K  yes  no\n' > "$PUSH/ambient-pi/listed"
printf '%s\nopenai-codex\n' "$PUSH/pinned-pi" > "$PUSH/home/config/pi-account"
printf '%s\n' '{"version":1,"roles":{"routine":{"pi":{"model":"openai-codex/gpt-pinned"}}},"retired":[]}' > "$PUSH/home/config/model-index.json"
PI_CODING_AGENT_DIR="$PUSH/ambient-pi" config_push ''
assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' "an id only the pinned Pi root lists must push: $(cat "$TMP_ROOT/push.out")"
cmp -s "$PUSH/home/config/model-index.json" "$PUSH/sm/config/model-index.json" || fail 'the pinned-account index was not pushed'
cp "$PUSH/sm/config/model-index.json" "$PUSH/prior-index.json"
printf '%s\n' '{"version":1,"roles":{"routine":{"pi":{"model":"openai-codex/gpt-ambient"}}},"retired":[]}' > "$PUSH/home/config/model-index.json"
PI_CODING_AGENT_DIR="$PUSH/ambient-pi" config_push ''
assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' 'an id only the ambient Pi root lists must be withheld under the pin'
cmp -s "$PUSH/prior-index.json" "$PUSH/sm/config/model-index.json" || fail 'an index absent from the pinned catalog reached the secondmate home'
rm "$PUSH/home/config/pi-account"
# A Claude pin sheds Claude credentials for the Claude catalog only; Pi keeps
# the environment key its anthropic provider lists models with.
mkdir -p "$PUSH/pinned-claude"
printf '%s\n' "$PUSH/pinned-claude" > "$PUSH/home/config/claude-account"
printf '%s\n' '{"version":1,"roles":{"sonnet-grade":{"pi":{"model":"anthropic/claude-sonnet-5-5"},"claude":{"model":"sonnet"}}},"retired":[]}' > "$PUSH/home/config/model-index.json"
ANTHROPIC_API_KEY=pi-provider-key PI_CODING_AGENT_DIR="$PUSH/ambient-pi" config_push ''
assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' "a Claude pin must not shed the key Pi's catalog uses: $(cat "$TMP_ROOT/push.out")"
cmp -s "$PUSH/home/config/model-index.json" "$PUSH/sm/config/model-index.json" || fail 'an env-keyed Pi entry beside a Claude pin was not pushed'
rm "$PUSH/home/config/claude-account"
pass 'fm-config-push withholds an index with an absent id together with its dispatch profiles, pushes with a notice when catalogs are unreadable, pushes a valid pair, and reads each catalog under only its own worker account pin'
printf '# all fm-model-index tests passed\n'
