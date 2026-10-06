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
for source_route in local remote; do
  if [ "$source_route" = remote ]; then
    printf 'window=firstmate:fm-remote\nkind=secondmate\nhome=%s\nremote_host=inherit-host\n' "$PUSH/remote" > "$PUSH/home/state/remote.meta"
  fi
  for unsafe_source in symlink hardlink directory; do
  cp "$PUSH/sm/config/model-index.json" "$PUSH/before-stage-index.json"
  cp "$PUSH/sm/config/crew-dispatch.json" "$PUSH/before-stage-dispatch.json"
  rm "$PUSH/home/config/model-index.json"
  case "$unsafe_source" in
    symlink) ln -s "$PUSH/safe-index.json" "$PUSH/home/config/model-index.json" ;;
    hardlink) ln "$PUSH/safe-index.json" "$PUSH/home/config/model-index.json" ;;
    directory) mkdir "$PUSH/home/config/model-index.json" ;;
  esac
  printf '%s\n' "$unsafe_source" > "$PUSH/home/config/dispatch-never-send"
  config_push "$CATALOGS"
  if [ "$source_route" = local ] && [ "$unsafe_source" != directory ]; then
    assert_not_contains "$(cat "$TMP_ROOT/push.out")" 'not pushed' "local $unsafe_source regular target must still stage"
    [ "$(FM_HOME="$PUSH/sm" "$TOOL" model codex role:stable)" = current ] || fail "local $unsafe_source target did not reach real consumer"
  else
    assert_contains "$(cat "$TMP_ROOT/push.out")" 'model-index.json and crew-dispatch.json not pushed' "unsafe $source_route $unsafe_source staging must withhold the pair"
    cmp -s "$PUSH/before-stage-index.json" "$PUSH/sm/config/model-index.json" || fail "unsafe $unsafe_source staging changed destination index"
    cmp -s "$PUSH/before-stage-dispatch.json" "$PUSH/sm/config/crew-dispatch.json" || fail "unsafe $unsafe_source staging changed destination dispatch"
  fi
  cmp -s "$PUSH/home/config/dispatch-never-send" "$PUSH/sm/config/dispatch-never-send" || fail "unsafe $unsafe_source staging blocked unrelated config"
  if [ "$unsafe_source" = directory ]; then
    rmdir "$PUSH/home/config/model-index.json"
  else
    rm "$PUSH/home/config/model-index.json"
  fi
  cp "$PUSH/safe-index.json" "$PUSH/home/config/model-index.json"
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
