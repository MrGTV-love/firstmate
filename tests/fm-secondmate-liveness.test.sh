#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified.
#   - The tmux classifier returns missing only after a readable session
#     inventory omits the exact window, regardless of display-message fallback.
#   - The Herdr classifier preserves the proven husk mapping while separating a
#     missing pane from an existing agent-less pane.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep recovers only dead or
#     missing endpoints, keeps successful recovery and already-live results
#     silent by default, and reports ambiguous and unreadable targets distinctly.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)
FIXTURE_ROOT="$TMP_ROOT/firstmate-code"
mkdir -p "$FIXTURE_ROOT"
ln -s "$ROOT/bin" "$FIXTURE_ROOT/bin"
ln -s "$ROOT/.omp" "$FIXTURE_ROOT/.omp"

# --- unit level: fm_backend_tmux_agent_state --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_failed_probe_tmux <dir> <inventory>: missing and present fail the pane
# read, while unreadable returns a misleading fallback node process but fails
# the inventory that must be authoritative.
make_failed_probe_tmux() {
  local dir=$1 inventory=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    [ '$inventory' = unreadable ] && { printf '%s\n' node; exit 0; }
    exit 1
    ;;
  list-windows)
    case '$inventory' in
      missing) printf '%s\n' main ; exit 0 ;;
      missing-session) printf '%s\n' "can't find session: sess" >&2; exit 1 ;;
      missing-server) printf '%s\n' "no server running on /tmp/tmux-test/default" >&2; exit 1 ;;
      missing-socket) printf '%s\n' "error connecting to /tmp/tmux-test/default (No such file or directory)" >&2; exit 1 ;;
      present) printf '%s\n' fm-sm1 ; exit 0 ;;
      *) printf '%s\n' "permission denied" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_classifies() {
  local fb out

  for harness in claude codex opencode grok kimi pi pi-signed pi-launcher Pi; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-$harness" "$harness")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $harness foreground process should classify as alive, got '$out'"
  done

  for shell in zsh bash -zsh; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-${shell#-}" "$shell")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = dead ] || fail "a bare $shell foreground process should classify as dead, got '$out'"
  done

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-missing" missing)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
  [ "$out" = missing ] || fail "a readable inventory omitting the target should classify as missing, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:fm-sm1' "$ROOT")" = dead ] \
    || fail "the compatibility view should treat an authoritatively missing target as dead"

  for inventory in present unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = unreadable ] || fail "a $inventory inventory case should stay unreadable, got '$out'"
  done

  for inventory in missing-session missing-server missing-socket; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = missing ] || fail "a confirmed $inventory inventory failure should classify as missing, got '$out'"
  done

  pass "fm_backend_tmux_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_tmux_agent_state_rejects_malformed_targets_before_probe() {
  local fakebin marker target out
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux-malformed")
  marker="$TMP_ROOT/tmux-malformed-called"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_TMUX_MARKER"
printf 'bash\n'
SH
  chmod +x "$fakebin/tmux"

  for target in sess sess: :win sess:win:extra; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_TEST_TMUX_MARKER="$marker" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1"' "$ROOT" "$target")
    [ "$out" = unreadable ] || fail "malformed tmux target '$target' should classify as unreadable, got '$out'"
    [ ! -e "$marker" ] || fail "malformed tmux target '$target' invoked tmux"
  done

  pass "fm_backend_tmux_agent_state: rejects malformed targets before probing tmux"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  # Pin the session server as running so an installed herdr on the host
  # cannot turn the unknown row into a stopped-server `missing`.
  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_server_running_state() { printf running; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
    [ "$out" = "$expected" ] || fail "Herdr pane state $pane_state should map to $expected, got '$out'"
  done

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "no-colon-target"' "$ROOT")
  [ "$out" = unreadable ] || fail "an unparseable Herdr target should classify as unreadable, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "the Herdr compatibility view should keep a no-agent husk dead, got '$out'"

  pass "fm_backend_herdr_agent_state: preserves missing/no-agent/live/unknown husk behavior"
}

# --- unit level: the generic dispatchers ------------------------------------

test_agent_state_dispatcher_and_compatibility() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route tmux, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_state herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route Herdr, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state zellij sess:7' "$ROOT")
  [ "$out" = unverified ] || fail "Zellij should remain unverified, got '$out'"
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:7' "$ROOT")
  [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified to unknown, got '$out'"

  pass "fm_backend_agent_state: routes tmux/Herdr and keeps Zellij unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin real_jq
  fakebin=$(fm_fakebin "$dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for secondmate liveness tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.77
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail).
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  list-windows)
    case "$mode" in
      missing) printf '%s\n' main; exit 0 ;;
      unreadable) exit 1 ;;
      *) [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1; exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && [ "${1:-}" = new-window ] && exit 1
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. The operational homes are siblings
# of FIXTURE_ROOT; its bin/ uses the checkout's production scripts. The pinned
# harness keeps replacement selection independent of ambient harness detection.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a seeded secondmate home with an independent
# git repository and no origin.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$FIXTURE_ROOT" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed" \
    "legacy recovery failed before allocating its replacement"

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" \
    "the shared library did not leave the durable per-mate relaunch record"
  [ ! -e "$w/sm1/config/session-launch-policy" ] || fail "absent policy unexpectedly changed child policy"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_skips_mate_whose_liveness_lock_is_held() {
  local w fb tmuxfb log out holder i=0
  w=$(new_world sweep-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # A concurrent liveness episode (the watcher's tick) owns the per-mate lock;
  # the sweep must skip rather than probe or relaunch a moving target.
  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$w/home/state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  while [ ! -d "$w/home/state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$w/home/state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: another liveness check is already in progress" \
    "a mate under an active liveness lock should be skipped, not probed"
  [ ! -s "$log" ] || fail "a locked mate must never be killed or respawned: $(cat "$log")"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "sweep: a mate mid-episode under the shared liveness lock is skipped entirely"
}

test_sweep_refuses_relaunch_on_ledger_errors() {
  local w fb tmuxfb log out mode ledger word
  if [ "$(id -u)" -eq 0 ]; then
    pass "sweep: ledger permission errors skipped (root ignores file modes)"
    return 0
  fi
  for mode in 200 444; do
    case "$mode" in 200) word=unreadable ;; *) word=unwritable ;; esac
    w=$(new_world "sweep-ledger-$mode")
    add_sm_home "$w" sm1 firstmate:fm-sm1
    fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
    log="$w/calls.log"; : > "$log"
    ledger="$w/home/state/.secondmate-relaunch-sm1"
    : > "$ledger"
    chmod "$mode" "$ledger"

    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
    chmod 644 "$ledger"

    assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: relaunch ledger $ledger is $word" \
      "a mode-$mode relaunch ledger should skip the relaunch with its reason"
    [ ! -s "$log" ] || fail "a mode-$mode relaunch ledger still killed or spawned: $(cat "$log")"
    [ ! -s "$ledger" ] || fail "a mode-$mode ledger gained rows: $(cat "$ledger")"
  done
  pass "sweep: an unreadable or unwritable relaunch ledger refuses to kill or spawn"
}

test_sweep_launch_policy_preserves_endpoint_and_records() {
  local w fb tmuxfb log out mode pin ledger config
  for mode in zsh missing; do
    for pin in codex fallback malformed override; do
      w=$(new_world "sweep-policy-$mode-$pin")
      add_sm_home "$w" sm1 firstmate:fm-sm1 omp
      printf 'omp-or-tc\n' > "$w/home/config/session-launch-policy"
      config="$w/home/config"
      case "$pin" in
        codex) printf 'codex explicit-model high\n' > "$w/home/config/secondmate-harness" ;;
        fallback) printf 'default\n' > "$w/home/config/secondmate-harness" ;;
        malformed) printf 'invalid\n' > "$w/home/config/session-launch-policy" ;;
        override)
          printf 'omp\n' > "$w/home/config/secondmate-harness"
          config="$w/override-config"
          mkdir -p "$config"
          printf 'omp-or-tc\n' > "$config/session-launch-policy"
          printf 'codex explicit-model high\n' > "$config/secondmate-harness" ;;
      esac
      ledger="$w/home/state/.secondmate-relaunch-sm1"
      printf '1\tattempt\n1\tfailed\n' > "$ledger"
      cp "$ledger" "$w/ledger-before"
      cp "$w/home/state/sm1.meta" "$w/meta-before"
      cp "$w/sm1/data/charter.md" "$w/charter-before"
      printf 'unpublished work\n' > "$w/sm1/unpublished"
      fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
      log="$w/calls.log"; : > "$log"

      out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" "$mode" "$log" FM_CONFIG_OVERRIDE="$config")

      assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: error: config/session-launch-policy" \
        "restricted $mode recovery did not report the policy refusal"
      [ ! -s "$log" ] || fail "restricted recovery killed or spawned: $(cat "$log")"
      cmp -s "$w/meta-before" "$w/home/state/sm1.meta" || fail "policy refusal rewrote endpoint metadata"
      cmp -s "$w/ledger-before" "$ledger" || fail "policy refusal consumed a recovery attempt"
      cmp -s "$w/charter-before" "$w/sm1/data/charter.md" || fail "policy refusal rewrote instructions"
      [ "$(cat "$w/sm1/unpublished")" = 'unpublished work' ] || fail "policy refusal lost unpublished work"
    done
  done
  pass "sweep: policy checks the configured replacement before kill, spawn, or attempt records"
}

test_sweep_launch_policy_allows_configured_omp_replacement() {
  local w fb tmuxfb log out
  w=$(new_world sweep-policy-allowed)
  add_sm_home "$w" sm1 firstmate:fm-sm1 codex
  printf 'omp-or-tc\n' > "$w/home/config/session-launch-policy"
  printf 'omp openai-codex/gpt-6.1-sol high\n' > "$w/home/config/secondmate-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  fm_fake_exit0 "$fb" omp
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed" \
    "allowed recovery failed before allocating its replacement"

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "allowed replacement failed recovery"
  assert_contains "$(cat "$log")" "kill-window" "allowed replacement did not remove the dead endpoint"
  assert_contains "$(cat "$log")" "new-window" "allowed replacement did not allocate its endpoint"
  assert_grep 'harness=omp' "$w/home/state/sm1.meta" "recovery ignored the configured replacement harness"
  assert_grep 'model=openai-codex/gpt-6.1-sol' "$w/home/state/sm1.meta" "recovery lost the configured model"
  assert_grep 'effort=high' "$w/home/state/sm1.meta" "recovery lost the configured effort"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" "allowed replacement outcome was not ledgered"
  assert_equals 'omp-or-tc' "$(cat "$w/sm1/config/session-launch-policy")" \
    "allowed replacement did not converge its child policy"
  pass "sweep: policy accepts the configured omp profile rather than the previous harness"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=tmux)" \
    "verbose diagnostics should identify the already-live outcome"
  [ ! -s "$log" ] || fail "verbose reporting must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

test_sweep_respawns_authoritatively_missing_pi_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "a successful missing-window recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window" "an authoritatively missing Pi secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" "an absent window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing Pi secondmate window is relaunched"
}

test_sweep_respawns_authoritatively_missing_pi_signed_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi-signed)
  printf '%s\n' pi-signed > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi-signed
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded pi-signed secondmate should be verified for recovery"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing pi-signed secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent pi-signed window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing pi-signed secondmate window is relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb tmuxfb log out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing Pi-shaped node process should be reported as ambiguous"
  [ ! -s "$log" ] || fail "an ambiguous existing process must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an existing ambiguous Pi process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" unreadable "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_missing_endpoint_relaunch_failure() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after recorded endpoint confidently missing" \
    "a failed missing-endpoint relaunch should retain its authorizing cause"
  pass "sweep: failed relaunch diagnostics distinguish a confidently missing endpoint"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should not let a dead endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an unverified harness blocks recovery with a concrete diagnostic"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

# --- library level: the watcher's poll-mode remote probe ---------------------
# bin/fm-secondmate-liveness-lib.sh's `poll` mode is the read-only probe the
# watcher tick runs per cadence: exactly one remote `state` call, `dead` and
# `missing` alone authorize relaunch, and transport failure (ssh exit 255) is
# never evidence of death. Full-mode remote readiness repair and route
# revalidation remain the startup sweep's own behavior, covered by the sweep
# tests above and tests/fm-remote-secondmate-lifecycle-e2e.test.sh.

# make_remote_probe_world <name>: a parent home carrying one remote-route
# secondmate meta plus a fake ssh that logs every call and answers with
# FM_FAKE_REMOTE_REPLY on FM_FAKE_REMOTE_RC.
make_remote_probe_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

# probe_remote <w> <mode> [env...] -> "<status>|<state>|<kill>|<cause>|<where>|<reason>"
probe_remote() {
  local w=$1 mode=$2; shift 2
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/home/config" FM_STATE_OVERRIDE="$w/home/state" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" "$@" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 "$2"
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" \
        "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_WHERE" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta" "$mode"
}

test_remote_poll_probe_maps_states() {
  local w out
  w=$(make_remote_probe_world probe-states)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=dead)
  [ "$out" = 'relaunchable|dead|0|remote endpoint dead on its configured host|host=lab-host|' ] \
    || fail "a dead remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=missing)
  [ "$out" = 'relaunchable|missing|0|remote endpoint missing on its configured host|host=lab-host|' ] \
    || fail "a missing remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=alive)
  [ "$out" = 'alive|alive|0|||' ] || fail "an alive remote reply should be a quiet no-op, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=ambiguous)
  [ "$out" = 'skipped|ambiguous|0|||remote endpoint state is ambiguous on lab-host' ] \
    || fail "an ambiguous remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=unverified)
  [ "$out" = 'skipped|unverified|0|||remote endpoint state is unverified on lab-host' ] \
    || fail "an unverified remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=bogus)
  [ "$out" = 'skipped|bogus|0|||remote endpoint returned an invalid state' ] \
    || fail "an invalid remote reply must preserve the endpoint, got: $out"

  [ "$(wc -l < "$w/ssh.log" | tr -d ' ')" -eq 6 ] \
    || fail "each poll-mode probe should spend exactly one remote state call: $(cat "$w/ssh.log")"
  pass "poll probe: remote states map to the same contract as local, one call each"
}

test_remote_poll_probe_unreachable_preserves_route() {
  local w out
  w=$(make_remote_probe_world probe-unreachable)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "ssh exit 255 must never read as a dead endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=1)
  [ "$out" = 'skipped|unknown|0|||remote endpoint probe unreadable on lab-host' ] \
    || fail "a non-transport remote probe failure must stay inconclusive, got: $out"
  pass "poll probe: unreachable or inconclusive remote reads preserve the route"
}

make_remote_readiness_world() {
  local w
  w=$(make_remote_probe_world "$1")
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf 'alive\n' > "$w/endpoint"
  printf 'spawn_gen=remote-generation\n' >> "$w/home/state/rsm1.meta"
  cat > "$w/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -u
argv=${!#}
encoded() { printf '%s\0' "$@" | base64 | tr -d '\n'; }
if [ "$argv" = "$(encoded fm-remote-doctor.sh)" ]; then
  printf 'doctor\n' >> "$FM_FAKE_SSH_LOG"
  [ -e "$FM_FAKE_SSH_LOG.repaired" ] && exit 0
  printf 'check herdr=fixable: foreign server\n'
  exit 1
elif [ "$argv" = "$(encoded fm-remote-doctor.sh --fix)" ]; then
  printf 'doctor --fix\n' >> "$FM_FAKE_SSH_LOG"
  : > "$FM_FAKE_SSH_LOG.repaired"
  printf 'dead\n' > "$FM_FAKE_REMOTE_ENDPOINT"
elif [ "$argv" = "$(encoded fm-remote-secondmate-control.sh state rsm1)" ]; then
  printf 'state\n' >> "$FM_FAKE_SSH_LOG"
  cat "$FM_FAKE_REMOTE_ENDPOINT"
elif [ "$argv" = "$(encoded fm-remote-secondmate-control.sh route rsm1)" ]; then
  printf 'route\n' >> "$FM_FAKE_SSH_LOG"
  printf 'backend=herdr\n'
else
  printf 'unexpected remote command\n' >&2
  exit 1
fi
SH
  printf '%s\n' "$w"
}

recover_remote() {
  local w=$1 mode=$2; shift 2
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/home/config" FM_STATE_OVERRIDE="$w/home/state" \
    FM_WAKE_QUEUE="$w/home/state/.wake-queue" FM_WAKE_QUEUE_LOCK="$w/home/state/.wake-queue.lock" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" \
    FM_FAKE_REMOTE_ENDPOINT="$w/endpoint" "$@" bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_lock rsm1 || exit 1
      fm_secondmate_liveness_probe "$1" rsm1 "$2"
      rc=0
      if [ "$FM_SM_LIVE_STATUS" = relaunchable ]; then
        fm_secondmate_liveness_relaunch "$1" rsm1 || rc=$?
      fi
      printf "%s|%s|%s|%s\n%s\n%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" \
        "${FM_SM_LIVE_POLICY_REFUSED:-0}" "$rc" "$FM_SM_LIVE_REASON" "${FM_SM_LIVE_WAKE:-}"
      fm_secondmate_liveness_unlock rsm1
    ' "$ROOT" "$w/home/state/rsm1.meta" "$mode"
}

test_remote_full_probe_policy_precedes_readiness_repair() {
  local w pin state config out expected
  for pin in codex fallback malformed override; do
    for state in alive dead missing ambiguous unreadable; do
      w=$(make_remote_readiness_world "full-policy-$pin-$state")
      config="$w/home/config"
      printf 'omp-or-tc\n' > "$config/session-launch-policy"
      case "$pin" in
        codex) printf 'codex explicit-model high\n' > "$config/secondmate-harness" ;;
        fallback) printf 'default\n' > "$config/secondmate-harness" ;;
        malformed)
          printf 'invalid\n' > "$config/session-launch-policy"
          printf 'omp explicit-model high\n' > "$config/secondmate-harness" ;;
        override)
          printf 'omp\n' > "$config/secondmate-harness"
          config="$w/override-config"
          mkdir -p "$config"
          printf 'omp-or-tc\n' > "$config/session-launch-policy"
          printf 'codex explicit-model high\n' > "$config/secondmate-harness" ;;
      esac
      printf '%s\n' "$state" > "$w/endpoint"
      cp "$w/home/state/rsm1.meta" "$w/meta-before"
      out=$(probe_remote "$w" full FM_CONFIG_OVERRIDE="$config" FM_FAKE_REMOTE_ENDPOINT="$w/endpoint")
      case "$state" in
        alive) expected='alive|alive|0|||' ;;
        dead|missing) expected="relaunchable|$state|0|remote endpoint $state on its configured host|host=lab-host|" ;;
        *) expected="skipped|$state|0|||remote endpoint state is $state on lab-host" ;;
      esac
      [ "$out" = "$expected" ] || fail "$pin policy stopped read-only classification of $state: $out"
      assert_not_contains "$(cat "$w/ssh.log")" doctor "$pin probe ran readiness before replacement admission"
      assert_contains "$(cat "$w/ssh.log")" state "$pin probe did not classify the remote endpoint"
      [ ! -e "$w/ssh.log.repaired" ] || fail "$pin probe repaired a denied endpoint"
      [ "$(cat "$w/endpoint")" = "$state" ] || fail "$pin probe changed endpoint state"
      cmp -s "$w/meta-before" "$w/home/state/rsm1.meta" || fail "$pin probe changed route metadata"
      [ ! -e "$w/home/state/.secondmate-relaunch-rsm1" ] || fail "$pin probe recorded a relaunch attempt"
      [ ! -e "$w/home/state/.session-launch-refused-rsm1" ] || fail "$pin read-only probe recorded a refusal"
    done
  done
  pass "full probe: denied and malformed replacement policies preserve remote endpoints while classifying them"
}

test_remote_full_probe_admitted_readiness_still_repairs() {
  local w policy out
  for policy in allowed absent; do
    w=$(make_remote_readiness_world "full-policy-$policy")
    if [ "$policy" = allowed ]; then
      printf 'omp-or-tc\n' > "$w/home/config/session-launch-policy"
      printf 'omp explicit-model high\n' > "$w/home/config/secondmate-harness"
    fi
    out=$(probe_remote "$w" full FM_FAKE_REMOTE_ENDPOINT="$w/endpoint")
    [ "$out" = 'relaunchable|dead|0|remote endpoint dead on its configured host|host=lab-host|' ] \
      || fail "$policy full probe did not preserve readiness behavior: $out"
    [ "$(cat "$w/ssh.log")" = "$(printf 'doctor\ndoctor --fix\ndoctor\nstate')" ] \
      || fail "$policy full probe changed the readiness repair sequence: $(cat "$w/ssh.log")"
    [ -e "$w/ssh.log.repaired" ] || fail "$policy full probe did not run the doctor repair sentinel"
    [ "$(cat "$w/endpoint")" = dead ] || fail "$policy repair sentinel did not exercise endpoint mutation"
  done
  pass "full probe: allowed omp and absent policy retain the readiness repair sequence"
}

test_remote_policy_refusal_survives_relaunch_boundary() {
  local w mode policy state out
  for mode in full poll; do
    for policy in denied malformed; do
      for state in dead missing; do
        w=$(make_remote_readiness_world "remote-recovery-$mode-$policy-$state")
        case "$policy" in
          denied) printf 'omp-or-tc\n' > "$w/home/config/session-launch-policy" ;;
          malformed) printf 'invalid\n' > "$w/home/config/session-launch-policy" ;;
        esac
        printf '%s\n' "$state" > "$w/endpoint"
        cp "$w/home/state/rsm1.meta" "$w/meta-before"
        out=$(recover_remote "$w" "$mode")
        assert_contains "$out" "skipped|$state|1|1" "$mode $policy recovery lost its policy refusal"
        assert_contains "$out" 'config/session-launch-policy' "$mode recovery lost the admission diagnostic"
        assert_contains "$out" 'auto-relaunch refused' "$mode recovery did not retain the refusal wake"
        assert_equals 'remote-generation' "$(sed -n '1p' "$w/home/state/.session-launch-refused-rsm1")" \
          "$mode recovery did not retain the generation-scoped refusal receipt"
        assert_not_contains "$(cat "$w/ssh.log")" doctor "$mode refused recovery invoked readiness repair"
        [ "$(cat "$w/endpoint")" = "$state" ] || fail "$mode refused recovery changed endpoint state"
        cmp -s "$w/meta-before" "$w/home/state/rsm1.meta" || fail "$mode refused recovery changed metadata"
        [ ! -e "$w/home/state/.secondmate-relaunch-rsm1" ] || fail "$mode refused recovery consumed an attempt"
      done
    done
  done
  pass "remote recovery: full and poll retain policy diagnostics and receipts without repair or attempts"
}

test_remote_relaunch_rechecks_probe_admission() {
  local w out
  w=$(make_remote_readiness_world remote-policy-recheck)
  printf 'omp-or-tc\n' > "$w/home/config/session-launch-policy"
  printf 'omp explicit-model high\n' > "$w/home/config/secondmate-harness"
  out=$(env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$w/home/config" FM_STATE_OVERRIDE="$w/home/state" \
    FM_WAKE_QUEUE="$w/home/state/.wake-queue" FM_WAKE_QUEUE_LOCK="$w/home/state/.wake-queue.lock" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" FM_FAKE_REMOTE_ENDPOINT="$w/endpoint" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_lock rsm1 || exit 1
      fm_secondmate_liveness_probe "$1" rsm1 full
      printf "probe=%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"
      cp "$FM_FAKE_SSH_LOG" "$FM_FAKE_SSH_LOG.before-relaunch"
      printf "codex explicit-model high\n" > "$FM_CONFIG_OVERRIDE/secondmate-harness"
      rc=0
      fm_secondmate_liveness_relaunch "$1" rsm1 || rc=$?
      printf "%s|%s|%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_POLICY_REFUSED" "$rc"
      fm_secondmate_liveness_unlock rsm1
    ' "$ROOT" "$w/home/state/rsm1.meta")
  assert_contains "$out" 'probe=relaunchable|dead' "allowed probe did not reach a recovery verdict"
  assert_contains "$out" 'skipped|dead|1|1' "relaunch reused stale probe admission"
  assert_equals 'remote-generation' "$(sed -n '1p' "$w/home/state/.session-launch-refused-rsm1")" \
    "changed replacement profile did not create a refusal receipt"
  cmp -s "$w/ssh.log.before-relaunch" "$w/ssh.log" || fail "relaunch performed a remote mutation after policy changed"
  [ ! -e "$w/home/state/.secondmate-relaunch-rsm1" ] || fail "changed replacement policy consumed an attempt"
  pass "remote recovery: relaunch rechecks the current replacement profile after probe admission"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_respawns_authoritatively_missing_pi_secondmate
test_sweep_respawns_authoritatively_missing_pi_signed_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_missing_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta
test_sweep_skips_mate_whose_liveness_lock_is_held
test_sweep_refuses_relaunch_on_ledger_errors
test_sweep_launch_policy_preserves_endpoint_and_records
test_sweep_launch_policy_allows_configured_omp_replacement
test_remote_poll_probe_maps_states
test_remote_poll_probe_unreachable_preserves_route
test_remote_full_probe_policy_precedes_readiness_repair
test_remote_full_probe_admitted_readiness_still_repairs
test_remote_policy_refusal_survives_relaunch_boundary
test_remote_relaunch_rechecks_probe_admission

echo "# all fm-secondmate-liveness tests passed"
