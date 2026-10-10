#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. tests/fm-worker-account-live-e2e.test.sh proves those answers
# against the real runners.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY FM_MODEL_CATALOG_DIR

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 0
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
if [ "\${1:-}" = -p ] && [ "\${2:-}" = --input-format ]; then
  printf 'CLAUDE_CONFIG_DIR=%s ANTHROPIC_API_KEY=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${ANTHROPIC_API_KEY-unset}" >> '$dir/claude-catalogs'
  jq -Rsc '{type:"control_response",response:{subtype:"success",request_id:"model-index",
    response:{models:[split("\n")[] | select(length > 0) | {value:., resolvedModel:.}]}}}' \
    "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/catalog" 2>/dev/null
  exit 0
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
if { [ "\${1:-}" = auth ] && [ -f '$dir/mutate-auth' ]; } ||
  { [ "\${1:-}" = --list-models ] && [ -f '$dir/mutate-check' ]; }; then
  cp '$dir/later-index.json' '$dir/home/config/model-index.json'
  cp '$dir/later-dispatch.json' '$dir/home/config/crew-dispatch.json'
  touch '$dir/mutated'
fi
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf '%s\n' "\$root" >> '$dir/pi-catalogs'
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
cat "\$root/listed" > '$dir/pi-worker-catalog' 2>/dev/null || :
SH
  chmod +x "$fakebin/claude" "$fakebin/pi"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    CODEX_HOME="$CASE/pane-codex" \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  # spawn_ship's ambient invoker key reaches an unpinned Claude worker, so the
  # Claude API key guard refuses the spawn unless it opts in to API billing.
  out=$(spawn_ship "$id" --allow-api-key); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --allow-api-key \
    --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

test_model_index_catalog_follows_the_pinned_account() {
  local out rc id=acct-catalog
  new_case index-catalog claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  printf 'pinned-only\n' > "$CASE/work/catalog"
  mkdir -p "$CASE/ambient-claude"
  printf 'ambient-only\n' > "$CASE/ambient-claude/catalog"
  printf '%s\n' '{"version":1,"roles":{"pinned":{"claude":{"model":"pinned-only"}},"ambient":{"claude":{"model":"ambient-only"}}},"retired":[]}' \
    > "$HOME_DIR/config/model-index.json"
  out=$(spawn_ship "$id-pinned" --model role:pinned); rc=$?
  expect_code 0 "$rc" "a role listed only by the pinned account's catalog should launch: $out"
  assert_grep "model=pinned-only" "$HOME_DIR/state/$id-pinned.meta" "the pinned spawn should record the resolved id"
  [ "$(cat "$CASE/claude-catalogs")" = "CLAUDE_CONFIG_DIR=$CASE/work ANTHROPIC_API_KEY=unset" ] \
    || fail "the catalog must be read from the pinned root with outranking credentials shed: $(cat "$CASE/claude-catalogs")"
  out=$(spawn_ship "$id-ambient" --model role:ambient); rc=$?
  expect_code 1 "$rc" "a role listed only by the ambient account's catalog must refuse under the pin"
  assert_refused_before_launch "$id-ambient" "$out" "id 'ambient-only' absent or retired in claude catalog"

  new_case index-catalog-pi pi
  mkdir -p "$CASE/pi-work" "$CASE/ambient-pi"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  printf 'openai-codex  gpt-pinned  272K  32K  yes  no\n' > "$CASE/pi-work/listed"
  printf 'openai-codex  gpt-ambient  272K  32K  yes  no\n' > "$CASE/ambient-pi/listed"
  printf '%s\n' '{"version":1,"roles":{"pinned":{"pi":{"model":"openai-codex/gpt-pinned"}},"ambient":{"pi":{"model":"openai-codex/gpt-ambient"}}},"retired":[]}' \
    > "$HOME_DIR/config/model-index.json"
  out=$(PI_CODING_AGENT_DIR="$CASE/ambient-pi" spawn_ship "$id-pi-pinned" --model role:pinned); rc=$?
  expect_code 0 "$rc" "a Pi role listed only by the pinned root's catalog should launch: $out"
  assert_contains "$(cat "$CASE/launch.log")" "--model 'openai-codex/gpt-pinned'" "the pinned Pi spawn should launch the resolved id"
  out=$(PI_CODING_AGENT_DIR="$CASE/ambient-pi" spawn_ship "$id-pi-ambient" --model role:ambient); rc=$?
  expect_code 1 "$rc" "a Pi role listed only by the ambient root's catalog must refuse under the pin"
  assert_refused_before_launch "$id-pi-ambient" "$out" "id 'openai-codex/gpt-ambient' absent or retired in pi catalog"
  pass "a pinned worker's model-index verdict comes from its pinned account's catalog, not the ambient one"
}

test_unpinned_model_index_never_uses_the_supervisor_catalog() {
  local harness filter model out rc id pane_root
  for harness in codex pi pi-signed; do
    for filter in absent empty; do
      for model in pane-only supervisor-only; do
        id="acct-context-$harness-$filter-$model"
        new_case "$id" "$harness"
        [ "$harness" != pi-signed ] || cp "$FAKEBIN/pi" "$FAKEBIN/pi-signed"
        mkdir -p "$CASE/supervisor" "$CASE/ambient-pi" "$HOME_DIR/user-home/.pi/agent" "$CASE/pane-codex" "$HOME_DIR/user-home/.codex"
        printf '%s\n' '{"models":[{"slug":"supervisor-only"}]}' > "$CASE/supervisor/models_cache.json"
        printf 'openai  supervisor-only  272K  32K  yes  no\n' > "$CASE/supervisor/listed"
        printf '%s\n' '{"models":[{"slug":"pane-only"}]}' > "$CASE/pane-codex/models_cache.json"
        cp "$CASE/pane-codex/models_cache.json" "$HOME_DIR/user-home/.codex/models_cache.json"
        printf 'openai  pane-only  272K  32K  yes  no\n' > "$CASE/ambient-pi/listed"
        cp "$CASE/ambient-pi/listed" "$HOME_DIR/user-home/.pi/agent/listed"
        cat > "$FAKEBIN/codex" <<SH
#!/usr/bin/env bash
printf 'CODEX_HOME=%s\n' "\${CODEX_HOME-unset}" > '$CASE/codex-worker'
cat "\${CODEX_HOME:-\$HOME/.codex}/models_cache.json" > '$CASE/codex-worker-catalog'
SH
        chmod +x "$FAKEBIN/codex"
        [ "$filter" != empty ] || : > "$HOME_DIR/config/launch-env-allowlist"
        if [ "$harness" != codex ]; then
          printf '{"version":1,"roles":{"chosen":{"%s":{"model":"openai/%s"}}},"retired":[]}\n' "$harness" "$model" > "$HOME_DIR/config/model-index.json"
        else
          printf '{"version":1,"roles":{"chosen":{"codex":{"model":"%s"}}},"retired":[]}\n' "$model" > "$HOME_DIR/config/model-index.json"
        fi
        out=$(CODEX_HOME="$CASE/supervisor" PI_CODING_AGENT_DIR="$CASE/supervisor" \
          spawn_ship "$id" --model role:chosen); rc=$?
        expect_code 0 "$rc" "an unknown worker context must not use supervisor catalog evidence: $out"
        assert_contains "$out" "effective worker account context is not established" "unknown context must be disclosed even when the supervisor lists the id"
        assert_contains "$out" "not validated" "unknown context must never claim catalog validation"
        assert_absent "$CASE/pi-catalogs" "an unpinned selected check must never query the supervisor Pi catalog"
        run_pane
        if [ "$harness" != codex ]; then
          pane_root=$CASE/ambient-pi
          [ "$filter" != empty ] || pane_root=$HOME_DIR/user-home/.pi/agent
          assert_grep "pane-only" "$CASE/pi-worker-catalog" "the actual Pi worker must see the pane catalog, not the supervisor catalog"
          if [ "$filter" = empty ]; then
            assert_grep "PI_CODING_AGENT_DIR=unset" "$CASE/pi-worker" "an empty allowlist must not forward the supervisor or pane Pi root"
          else
            assert_grep "PI_CODING_AGENT_DIR=$pane_root" "$CASE/pi-worker" "an unpinned Pi worker must retain the pane root"
          fi
        else
          assert_grep "pane-only" "$CASE/codex-worker-catalog" "the actual Codex worker must see the pane catalog, not the supervisor catalog"
          if [ "$filter" = empty ]; then
            assert_grep "CODEX_HOME=unset" "$CASE/codex-worker" "an empty allowlist must not forward the supervisor or pane Codex root"
          else
            assert_grep "CODEX_HOME=$CASE/pane-codex" "$CASE/codex-worker" "an unpinned Codex worker must retain the pane root"
          fi
        fi
      done
    done
  done
  pass "unpinned Codex, Pi, and Pi-signed selected checks disclose unknown context and never use supervisor catalogs"
}

test_ordinary_claude_catalog_context_is_unavailable() {
  local out rc id=acct-ordinary-index
  new_case ordinary-index claude
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  signed_in_claude_root "$CASE/pane-home/.claude"
  printf 'supervisor-only\n' > "$HOME_DIR/user-home/.claude/catalog"
  printf 'pane-only\n' > "$CASE/pane-home/.claude/catalog"
  printf '%s\n' '{"version":1,"roles":{"chosen":{"claude":{"model":"pane-only"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
  out=$(spawn_ship "$id" --model role:chosen); rc=$?
  expect_code 0 "$rc" "an ordinary pin must not refuse using the supervisor HOME catalog: $out"
  assert_contains "$out" "effective worker account context is not established" "ordinary root unset does not establish the destination HOME"
  assert_absent "$CASE/claude-catalogs" "an ordinary pin must not query the supervisor default account catalog"
  env -i HOME="$CASE/pane-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    bash -c "$(cat "$CASE/launch.log")" || fail "ordinary pinned launch must still execute"
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "ordinary launch must still unset the pane root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "ordinary launch must retain credential shedding"
  printf '%s\n' '{"version":1,"roles":{"chosen":{"claude":{"model":"pane-only"}}},"retired":["pane-only"]}' > "$HOME_DIR/config/model-index.json"
  out=$(spawn_ship "$id-retired" --model role:chosen); rc=$?
  expect_code 1 "$rc" "unknown ordinary context must still refuse offline retirement"
  assert_refused_before_launch "$id-retired" "$out" "retired model"
  printf '%s\n' '{"version":1,"roles":[],"retired":[]}' > "$HOME_DIR/config/model-index.json"
  out=$(spawn_ship "$id-malformed" --model role:chosen); rc=$?
  expect_code 1 "$rc" "unknown ordinary context must still refuse malformed schema"
  assert_refused_before_launch "$id-malformed" "$out" "malformed index"
  pass "ordinary Claude pins retain launch semantics without treating supervisor HOME as catalog proof"
}

test_indexed_native_catalog_guards_use_the_shared_boundary() {
  local harness executable model selected out rc id
  for harness in cursor omp; do
    for selected in role:chosen stand-in:chosen primary-literal stand-in-literal; do
      id="acct-native-$harness-${selected//:/-}"
      new_case "$id" "$harness"
      executable=$harness
      [ "$harness" != cursor ] || executable=cursor-agent
      model="pane-only"
      [ "$harness" != omp ] || model=openai/pane-only
      cat > "$FAKEBIN/$executable" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --list-models|models)
    printf '%s\n' "\$*" >> '$CASE/native-catalogs'
    case '$harness' in
      omp) printf '%s\n' '{"models":[{"provider":"openai","selector":"openai/supervisor-only"}]}' ;;
      cursor) printf 'supervisor-only - Supervisor model\n' ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
      chmod +x "$FAKEBIN/$executable"
      jq -n --arg h "$harness" --arg m "$model" \
        '{version:1,roles:{chosen:{($h):{model:$m,stand_in:($m+"-stand-in")}}},retired:[]}' > "$HOME_DIR/config/model-index.json"
      case "$selected" in
        primary-literal) selected=$model ;;
        stand-in-literal) selected=$model-stand-in ;;
      esac
      out=$(spawn_ship "$id" --model "$selected"); rc=$?
      expect_code 0 "$rc" "an indexed $harness selection must not refuse through a native supervisor catalog guard: $out"
      assert_contains "$out" "effective worker account context is not established" "the shared indexed boundary must disclose unknown $harness context"
      assert_absent "$CASE/native-catalogs" "the legacy $harness precheck must not query a supervisor catalog for an indexed selection"
    done
  done
  pass "Cursor and omp primary and stand-in entries delegate their native guards through the shared boundary"
}

test_nonentry_literals_keep_the_native_catalog_guards() {
  local harness executable model out rc id
  for harness in cursor omp; do
    id="acct-nonentry-$harness"
    new_case "$id" "$harness"
    executable=$harness
    [ "$harness" != cursor ] || executable=cursor-agent
    model=unsupported
    [ "$harness" != omp ] || model=openai/unsupported
    cat > "$FAKEBIN/$executable" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --list-models|models)
    printf '%s\n' "\$*" >> '$CASE/native-catalogs'
    case '$harness' in
      omp) printf '%s\n' '{"models":[{"provider":"openai","selector":"openai/supported"}]}' ;;
      cursor) printf 'supported - Supported model\n' ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$FAKEBIN/$executable"
    jq -n --arg h "$harness" --arg m "$model" \
      '{version:1,roles:{unrelated:{($h):{model:"unrelated"}},other_harness:{claude:{model:$m}}},retired:[]}' \
      > "$HOME_DIR/config/model-index.json"
    out=$(spawn_ship "$id" --model "$model"); rc=$?
    expect_code 1 "$rc" "an unrelated index must not disable the $harness literal guard: $out"
    assert_refused_before_launch "$id" "$out" "$model"
    assert_present "$CASE/native-catalogs" "a non-entry literal must query the native catalog"
    assert_contains "$out" "is not" "the native guard must give concrete unsupported evidence"
    model=supported
    [ "$harness" != omp ] || model=openai/supported
    out=$(spawn_ship "$id-supported" --model "$model"); rc=$?
    expect_code 0 "$rc" "a listed non-entry $harness literal should still launch: $out"
    assert_contains "$out" "not an index entry" "non-entry literals retain the index warning"
    assert_not_contains "$out" "effective worker account context is not established" "a non-entry literal must not claim delegated catalog validation"
    assert_grep "model=$model" "$HOME_DIR/state/$id-supported.meta" "a supported literal must retain its concrete model"
  done
  pass "an unrelated or other-harness index entry leaves Cursor and omp non-entry native guards active"
}

test_configured_secondmate_inherits_frozen_routing_pair() {
  local boundary out rc id sm root member
  for boundary in auth check; do
    id="acct-configured-freeze-$boundary"
    new_case "$id" pi
    root="$CASE/pinned"
    mkdir -p "$root"
    printf 'openai\n' > "$root/signed-in"
    printf 'openai current 128K 32K yes no\n' > "$root/listed"
    printf '%s\nopenai\n' "$root" > "$HOME_DIR/config/pi-account"
    printf 'pi role:chosen\n' > "$HOME_DIR/config/secondmate-harness"
    printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/current"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
    printf '%s\n' '{"default":{"harness":"pi","role":"chosen"}}' > "$HOME_DIR/config/crew-dispatch.json"
    for member in model-index.json crew-dispatch.json; do
      cp "$HOME_DIR/config/$member" "$CASE/original-$member"
    done
    printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later"}}},"retired":["openai/current"]}' > "$CASE/later-index.json"
    printf '%s\n' '{"default":{"harness":"pi","model":"openai/later"}}' > "$CASE/later-dispatch.json"
    touch "$CASE/mutate-$boundary"
    sm="$CASE/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    git init -q -b main "$sm"
    printf '%s\n' 'config/' 'state/' 'data/' > "$sm/.gitignore"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
    out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
      fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
    expect_code 0 "$rc" "$boundary configured secondmate frozen launch failed: $out"
    assert_not_contains "$out" "catalog unavailable" "configured selection must have readable pinned catalog evidence"
    assert_present "$CASE/mutated" "configured model did not exercise mutation"
    assert_grep 'model=openai/current' "$HOME_DIR/state/$id.meta" "configured model lost its frozen selection"
    assert_contains "$(cat "$CASE/launch.log")" "--model 'openai/current'" "configured launch used later routing"
    for member in model-index.json crew-dispatch.json; do
      cmp -s "$CASE/original-$member" "$sm/config/$member" \
        || fail "local secondmate inherited later $member at $boundary"
    done
  done
  pass "configured local secondmates inherit the exact pair selected before auth and catalog mutation"
}

test_configured_secondmate_inherits_frozen_routing_pair
test_spawn_routing_pair_survives_account_boundaries() {
  local boundary selector id root model out rc
  for boundary in auth check; do
    for selector in role:chosen stand-in:chosen openai/current; do
      id="acct-freeze-$boundary-${selector//[:\/]/-}"
      new_case "$id" pi
      root="$CASE/pinned"
      mkdir -p "$root"
      printf 'openai\n' > "$root/signed-in"
      printf 'openai current 128K 32K yes no\nopenai standby 128K 32K yes no\n' > "$root/listed"
      printf '%s\nopenai\n' "$root" > "$HOME_DIR/config/pi-account"
      printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/current","stand_in":"openai/standby"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
      printf '%s\n' '{"default":{"harness":"pi","role":"chosen"}}' > "$HOME_DIR/config/crew-dispatch.json"
      printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later"}}},"retired":["openai/current","openai/standby"]}' > "$CASE/later-index.json"
      printf '%s\n' '{"default":{"harness":"pi","model":"openai/later"}}' > "$CASE/later-dispatch.json"
      touch "$CASE/mutate-$boundary"
      out=$(spawn_ship "$id" --harness pi --model "$selector"); rc=$?
      expect_code 0 "$rc" "$boundary/$selector must retain its initial entry: $out"
      assert_not_contains "$out" "catalog unavailable" "selected entry must have readable pinned catalog evidence"
      assert_present "$CASE/mutated" "the account mutation boundary was not exercised"
      model=openai/current
      [ "$selector" != stand-in:chosen ] || model=openai/standby
      assert_grep "model=$model" "$HOME_DIR/state/$id.meta" "spawn changed its frozen selection"
      assert_contains "$(cat "$CASE/launch.log")" "--model '$model'" "spawn launched a later model generation"
      assert_grep "$root" "$CASE/pi-catalogs" "frozen selection bypassed the pinned native catalog"
      printf 'openai unrelated 128K 32K yes no\n' > "$root/listed"
      printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/current","stand_in":"openai/standby"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
      out=$(spawn_ship "$id-refuse" --harness pi --model "$selector"); rc=$?
      [ "$rc" -ne 0 ] || fail "mutation bypassed initial-entry catalog refusal: $out"
      assert_absent "$HOME_DIR/state/$id-refuse.meta" "unsupported frozen entry published metadata"
      assert_contains "$out" "absent or retired in pi catalog" "initial-entry refusal lost native catalog evidence"
    done
  done
  pass "local auth and catalog mutations preserve initial roles, stand-ins, and indexed literals without bypassing account checks"
}

test_spawn_routing_pair_survives_account_boundaries
test_nonentry_literals_keep_the_native_catalog_guards
test_indexed_native_catalog_guards_use_the_shared_boundary
test_ordinary_claude_catalog_context_is_unavailable
test_unpinned_model_index_never_uses_the_supervisor_catalog
test_model_index_catalog_follows_the_pinned_account
test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin

echo "# all fm-worker-account tests passed"
