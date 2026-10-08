#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*)
          count=0
          [ ! -f "${FM_FAKE_CAPTURE_COUNT:-/dev/null}" ] || count=$(cat "$FM_FAKE_CAPTURE_COUNT")
          if [ "${FM_FAKE_WATCHER_TURN:-0}" = 1 ] \
            && [ "$count" -ge "${FM_FAKE_WATCHER_AFTER:-2}" ]; then
            printf 'transcript\n\n  ⎋ Waiting independent watcher turn\n╭── ⠦ 13s > model ──╮\n╰─ %s ─╯\n' \
              "$(cat "$COMPOSER.payload")" > "$COMPOSER"
          fi
          printf '1\n'; exit 0 ;;
        *pane_current_command*)
          [ "${FM_FAKE_MISSING_IDENTITY:-0}" != 1 ] || exit 1
          printf '%s\n' "${FM_FAKE_HARNESS:-codex}"; exit 0 ;;
        *pane_tty*)
          [ "${FM_FAKE_MISSING_IDENTITY:-0}" != 1 ] || exit 1 ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_CAPTURE_COUNT:-}" ]; then
      count=0
      [ ! -f "$FM_FAKE_CAPTURE_COUNT" ] || count=$(cat "$FM_FAKE_CAPTURE_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_CAPTURE_COUNT"
      if [ "${FM_FAKE_FAIL_FIRST_CAPTURE:-0}" = 1 ] && [ "$count" -eq 1 ]; then
        exit 1
      fi
    fi
    cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l)
          if [ "${FM_FAKE_WATCHER_TURN:-0}" = 1 ]; then
            printf 'literal\n' >> "$COMPOSER.types"
            printf '%s' "$2" > "$COMPOSER.payload"
            printf '╭── π > model ──╮\n╰─ %s ─╯\n' "$2" > "$COMPOSER"
          fi
          ;;
        Enter) is_enter=1 ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      [ -z "${FM_FAKE_SENT:-}" ] || printf 'Enter\n' >> "$FM_FAKE_SENT"
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
        [ "${FM_FAKE_APPEND_BUSY:-0}" != 1 ] || printf '✻ Working…\n' >> "$COMPOSER"
      else
        printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_empty() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 FM_FAKE_HARNESS=opencode \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "proven pending should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
}

test_busy_omp_payload_stays_pending() {
  local dir fakebin composer sent out
  dir="$TMP_ROOT/omp-held"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent"
  printf '%s\n' '╭── π > model ──╮' '╰─ hello captain ─╯' > "$composer"
  touch "$dir/.swallow"; : > "$sent"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 FM_FAKE_HARNESS=omp \
    fm_tmux_submit_enter_core win 2 0)
  [ "$out" = pending ] || fail "busy omp held payload must remain pending, got '$out'"
  [ "$(grep -c '^Enter$' "$sent")" -eq 2 ] || fail "omp must consume exactly two attempts"
  pass "tmux busy omp held payload stays pending"
}
test_busy_omp_payload_stays_pending

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_wrapped_continuation_retries_swallowed_enter() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/wrapped-continuation-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '❯ wrapped typed input\ncontinues on the next terminal row\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "wrapped input must remain pending after swallowed Enter, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "wrapped input should consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: wrapped input retains swallowed-Enter retries"
}

test_placeholder_like_bare_input_retries_swallowed_enter() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/placeholder-like-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf 'transcript\n❯ Type a message...\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "placeholder-like bare input must remain pending after swallowed Enter, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "placeholder-like bare input should consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: placeholder-like bare input retains swallowed-Enter retries"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

test_busy_pane_unknown_stays_unknown() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/busy-unknown"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a busy pane must not convert an unsafe composer to empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy conversion is limited to proven pending input"
}

test_failed_baseline_capture_keeps_busy_unknown_unconfirmed() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/failed-baseline"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    FM_FAKE_CAPTURE_COUNT="$dir/captures" FM_FAKE_FAIL_FIRST_CAPTURE=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_APPEND_BUSY=1 \
    fm_tmux_submit_core "win" "fix" 3 0.05 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a failed idle-baseline capture must not let a later busy footer confirm delivery, got '$(cat "$vfile")'"
  grep -q 'Working' "$composer" \
    || fail "failed-baseline regression did not render the post-Enter busy footer"
  pass "fm_tmux_submit_core: failed baseline capture disables busy unknown conversion"
}

test_omp_explicit_idle_baseline_does_not_confirm_unknown() (
  local dir="$TMP_ROOT/omp-explicit-idle-baseline" fakebin composer sent out
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent"
  printf '│ > unbounded\nWorking…\n' > "$composer"
  touch "$dir/.swallow"; : > "$sent"
  fm_pane_is_busy() { [ "$(fm_pane_busy_state "$1" omp)" = busy ]; }
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_pane_is_busy win \
    || fail "omp explicit-baseline regression must render a canonical busy signature"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_HARNESS=omp \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core win 3 0 1)
  [ "$out" = pending ] || fail "omp unknown with an explicit idle baseline must stay pending, got '$out'"
  [ "$(grep -c '^Enter$' "$sent")" -eq 1 ] || fail "omp explicit baseline must not cause another Enter"
  pass "tmux omp unknown remains pending despite explicit idle baseline and canonical busy footer"
)
test_omp_explicit_idle_baseline_does_not_confirm_unknown

test_dropped_enter_independent_omp_turn_redraw_stays_pending() {
  local dir fakebin composer sent out after expected_enters
  for after in 0 1 2; do
    dir="$TMP_ROOT/omp-watcher-redraw-$after"
    fakebin=$(make_submit_mock "$dir")
    composer="$dir/composer"; sent="$dir/sent"
    printf '╭── π > model ──╮\n╰─ ─╯\n' > "$composer"
    touch "$dir/.swallow"; : > "$sent"
    out=$(
      # shellcheck disable=SC2329
      fm_pane_is_busy() { [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]; }
      PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
        FM_FAKE_HARNESS=omp FM_FAKE_CAPTURE_COUNT="$dir/captures" \
        FM_FAKE_WATCHER_TURN=1 FM_FAKE_WATCHER_AFTER="$after" \
        FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
        fm_tmux_submit_core win 'unsubmitted watcher wake' 3 0 0
    )
    [ "$out" = pending ] || fail "independent omp turn with redraw must keep held input pending, got '$out'"
    expected_enters=1
    [ "$after" -ne 2 ] || expected_enters=2
    [ "$(grep -c '^Enter$' "$sent")" -eq "$expected_enters" ] \
      || fail "omp must stop sending Enter at the unreadable redraw"
    [ "$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$(cat "$composer")" 1)" = unknown ] \
      || fail "redraw must leave the saved cursor outside the omp box"
    [ "$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$(cat "$composer")" 4)" = pending ] \
      || fail "repositioned omp box must still contain pending input"
    [ "$(fm_composer_extract_selected_content "$(fm_tmux_composer_caps)" "$(cat "$composer")")" = 'unsubmitted watcher wake' ] \
      || fail "independent watcher turn must leave the typed payload unconsumed"
    printf '%s\n' "$(cat "$composer")" | fm_busy_lines_match omp \
      || fail "independent watcher turn must supply the misleading busy signal"
  done
  pass "tmux omp initial, refreshed, and postretry redraws retain independent-watcher payloads"
}
test_dropped_enter_independent_omp_turn_redraw_stays_pending

test_busy_pane_ambiguous_pending_retries_without_conversion() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-ambiguous-pending"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  : > "$sent"
  printf '╭────────────╮\n│ > fix  │\n╰────────────╯\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "ambiguous composer text should be pending-unproven, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "a busy pane must not convert pending-unproven to empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "pending-unproven should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: pending-unproven retries without busy conversion"
}

test_unknown_draft_unconfirmed_sends_one_enter() {
  local mode dir fakebin composer sent vfile expected_busy
  for mode in no-baseline-idle no-baseline-busy idle-baseline; do
    dir="$TMP_ROOT/unknown-draft-$mode"
    fakebin=$(make_submit_mock "$dir")
    composer="$dir/composer"
    sent="$dir/sent.log"
    vfile="$dir/verdict"
    printf '❯ preface\n ❯ nested draft\n' > "$composer"
    : > "$sent"
    expected_busy=idle
    if [ "$mode" = no-baseline-busy ]; then
      printf '✻ Working…\n' >> "$composer"
      expected_busy=busy
    fi
    touch "$dir/.swallow"
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
    [ "$(cat "$vfile")" = unknown-draft ] \
      || fail "$mode pre-check: ambiguous captured draft should read unknown-draft, got '$(cat "$vfile")'"
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_pane_busy_state "win" > "$vfile" 2>/dev/null
    [ "$(cat "$vfile")" = "$expected_busy" ] \
      || fail "$mode pre-check: captured busy state should read $expected_busy, got '$(cat "$vfile")'"
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
      FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
      bash -c '. "$0/bin/fm-tmux-lib.sh"
        if [ "$1" = idle-baseline ]; then
          fm_tmux_submit_core "win" "fix" 3 0.01 0
        else
          fm_tmux_submit_enter_core "win" 3 0.01
        fi' "$ROOT" "$mode" > "$vfile" 2>/dev/null
    [ "$(cat "$vfile")" = unknown-draft ] \
      || fail "$mode must preserve unconfirmed draft risk, got '$(cat "$vfile")'"
    [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 1 ] \
      || fail "$mode must stop after one Enter for unknown-draft"
  done
  pass "fm_tmux_submit_enter_core: unconfirmed draft risk retains its token and stops Enter retries, even when already busy"
}

test_unknown_draft_idle_to_busy_confirms() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/unknown-draft-idle-to-busy"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '❯ preface\n ❯ nested draft\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown-draft ] \
    || fail "idle-to-busy pre-check: ambiguous captured draft should read unknown-draft, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_pane_busy_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = idle ] \
    || fail "idle-to-busy pre-check: captured pane must be idle, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_APPEND_BUSY=1 \
    bash -c '. "$0/bin/fm-tmux-lib.sh"; fm_tmux_submit_core "win" "fix" 3 0.01 0' \
    "$ROOT" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "a captured idle-to-busy transition must still confirm unknown-draft, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "an idle-to-busy draft-risk confirmation must not repeat Enter"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown-draft ] \
    || fail "the captured composer must remain unknown-draft after confirmation, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_core: idle-to-busy proof still confirms a conservative unknown-draft after one Enter"
}

test_unrecognized_state_skips_busy_conversion() {
  local dir fakebin composer busy_called vfile
  dir="$TMP_ROOT/unrecognized-state"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  busy_called="$dir/busy-called"
  vfile="$dir/verdict"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    # shellcheck disable=SC2329
    fm_pane_is_busy() { touch "$busy_called"; return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  ) || fail "unrecognized-state submit check failed"
  [ "$(cat "$vfile")" = future-state ] \
    || fail "unrecognized state should be preserved, got '$(cat "$vfile")'"
  [ ! -e "$busy_called" ] \
    || fail "unrecognized state must not trigger busy conversion"
  pass "fm_tmux_submit_enter_core: unrecognized states skip busy conversion"
}

test_claude_busy_signature_uses_real_capture_shapes() {
  local dir fakebin composer
  dir="$TMP_ROOT/claude-signature"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  pane_busy() {
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" "$3"' \
      _ "$ROOT" "$1" "${2:-}"
  }

  # Live Claude 2.1.220 capture 1: spinner glyph and word from one turn.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 1 should be busy"

  # Live Claude 2.1.220 capture 2: a later turn with a changed glyph and word.
  printf '✽ Proofing… (5s · thinking with high effort)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 2 should be busy"

  # Real idle Claude capture shape from the verified pane sample.
  printf '✻ Worked for 31s\n' > "$composer"
  pane_busy idle claude && fail "Claude Worked-for capture must be idle"

  # The new signature is Claude-scoped and must not widen the shared default.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens)\n' > "$composer"
  pane_busy live && fail "Claude signature must not match without the Claude harness"

  # Each verified harness must use only its own signature.
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore OpenCode's interrupt footer"
  printf 'Working...\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore Pi's Working footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross opencode && fail "OpenCode must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross pi && fail "Pi must ignore OpenCode's interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy cross grok && fail "Grok must ignore Claude's legacy interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy own codex || fail "Codex's escape footer should be busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy own opencode || fail "OpenCode's interrupt footer should be busy"

  # No harness keeps the historical combined-pattern compatibility fallback.
  printf 'Working...\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Pi's shared signature"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Grok's shared signature"

  # A supplied harness must never use another harness's signature. This is
  # particularly important for Kimi: its idle key-tip rotation can include the
  # same cancel token Grok uses to mean busy.
  printf 'Working...\n' > "$composer"
  pane_busy unknown kimi && fail "Kimi must ignore Pi's Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy unknown kimi && fail "idle Kimi must ignore Grok's cancel footer"

  # Older Claude Code and the existing Pi and Grok signatures remain unchanged.
  printf 'esc to interrupt\n' > "$composer"
  pane_busy old-claude claude || fail "older Claude escape footer should be busy"
  printf 'Working...\n' > "$composer"
  pane_busy pi pi || fail "Pi Working footer should be busy"
  pane_busy pi-signed pi-signed || fail "pi-signed should share Pi's exact Working footer"
  # omp (Oh My Pi) renders its TUI line with U+2026; Pi's three-dot footer is
  # not omp's signature, and neither Pi nor Codex may borrow the ellipsis form.
  # The status-row spinner cell is its second, independent signal, and an idle
  # status row (identity glyph, no elapsed time) is not busy.
  pane_busy omp-three-dots omp && fail "omp must not read Pi's three-dot Working... footer as busy"
  printf ' \xf3\xb1\x8a\xb7 Working\xe2\x80\xa6\n' > "$composer"
  pane_busy omp omp || fail "omp TUI Working… footer should be busy"
  pane_busy omp-ellipsis-pi pi && fail "Pi must not borrow omp's Working… footer"
  pane_busy omp-ellipsis-codex codex && fail "Codex must not borrow omp's Working… footer"
  printf ' \xe2\xa0\xa7 11s  \xc2\xb7 gpt-6-astra\n' > "$composer"
  pane_busy omp-spinner omp || fail "omp braille spinner plus elapsed cell should be busy"
  printf ' \xf3\xb0\xb5\x97  \xc2\xb7 gpt-6-astra \xc2\xb7 36.7%%/41K\n' > "$composer"
  pane_busy omp-idle omp && fail "omp idle status row must not read busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy omp-cross omp && fail "omp must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy grok grok || fail "Grok cancel footer should be busy"
  pass "fm_pane_is_busy: Claude spinner is scoped, multi-frame, and backward-compatible"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_wrapped_continuation_retries_swallowed_enter
test_placeholder_like_bare_input_retries_swallowed_enter
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_busy_pane_unknown_stays_unknown
test_failed_baseline_capture_keeps_busy_unknown_unconfirmed
test_busy_pane_ambiguous_pending_retries_without_conversion
test_unknown_draft_unconfirmed_sends_one_enter
test_unknown_draft_idle_to_busy_confirms
test_unrecognized_state_skips_busy_conversion
test_claude_busy_signature_uses_real_capture_shapes

test_omp_pending_frame_refreshes_before_retry() (
  local dir="$TMP_ROOT/omp-stale-pending" out initial final expected
  mkdir -p "$dir"
  for initial in pending pending-unproven; do
    for final in empty unknown; do
      : > "$dir/enters"; printf '0' > "$dir/reads"
      # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
      tmux() {
        case "$1" in
          display-message) printf 'omp\n' ;;
          send-keys) printf 'Enter\n' >> "$dir/enters" ;;
        esac
      }
      # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
      fm_tmux_composer_state() {
        local n
        n=$(cat "$dir/reads"); n=$((n + 1)); printf '%s' "$n" > "$dir/reads"
        if [ "$n" -eq 1 ]; then printf '%s' "$initial"; else printf '%s' "$final"; fi
      }
      out=$(fm_tmux_submit_enter_core win 3 0)
      expected=$final
      [ "$final" != unknown ] || expected=pending
      [ "$out" = "$expected" ] || fail "omp $initial then $final must return $expected, got '$out'"
      [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 1 ] || fail "omp must not Enter after fresh $final"
    done
  done
  pass "tmux omp refreshes pending frames and requires empty proof before confirming"
)
test_omp_pending_frame_refreshes_before_retry

test_omp_dropped_first_enter_retries_successfully() {
  local dir fakebin composer sent out
  dir="$TMP_ROOT/omp-first-enter-dropped"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent"
  printf '╭── π > model ──╮\n╰─ ─╯\n' > "$composer"
  touch "$dir/.swallow"; : > "$sent"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_HARNESS=omp FM_FAKE_SWALLOW="$dir/.swallow" \
    FM_FAKE_WATCHER_TURN=1 FM_FAKE_WATCHER_AFTER=100 FM_FAKE_CAPTURE_COUNT="$dir/captures" \
    fm_tmux_submit_core win 'retry me' 3 0 0)
  [ "$out" = empty ] || fail "omp must confirm the successful second Enter, got '$out'"
  [ "$(grep -c '^Enter$' "$sent")" -eq 2 ] || fail "omp dropped first Enter must retry exactly once"
  [ "$(grep -c '^literal$' "$composer.types")" -eq 1 ] || fail "omp Enter retry must never retype the payload"
  [ "$(cat "$composer.payload")" = 'retry me' ] || fail "omp retry must type the intended payload"
  pass "tmux omp retries dropped first Enter and confirms a cleared composer"
}
test_omp_dropped_first_enter_retries_successfully

test_nonomp_unknown_and_retry_keep_main_behavior() (
  local dir="$TMP_ROOT/legacy-main" pane_command out
  mkdir -p "$dir"
  for pane_command in pi-launcher kimi; do
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    tmux() {
      case "$1" in
        display-message)
          case "$*" in *pane_current_command*) printf '%s\n' "$pane_command" ;; esac
          ;;
        send-keys) printf 'Enter\n' >> "$dir/enters" ;;
      esac
    }
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    fm_pane_is_busy() { return 0; }
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    fm_tmux_composer_state() { printf 'unknown'; }
    : > "$dir/enters"
    out=$(fm_tmux_submit_enter_core win 3 0 1)
    [ "$out" = empty ] || fail "$pane_command legacy idle-to-busy unknown must confirm, got '$out'"
    [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 1 ] || fail "$pane_command unknown must not repeat Enter"
    out=$(fm_tmux_submit_enter_core win 3 0)
    [ "$out" = unknown ] || fail "$pane_command unknown without baseline must remain unknown, got '$out'"
    : > "$dir/enters"; printf '0' > "$dir/reads"
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    fm_tmux_composer_state() {
      local n enters
      n=$(cat "$dir/reads"); n=$((n + 1)); printf '%s' "$n" > "$dir/reads"
      enters=$(wc -l < "$dir/enters" | tr -d ' ')
      [ "$enters" -eq "$n" ] || fail "$pane_command must not refresh before retry Enter"
      if [ "$n" -lt 3 ]; then printf 'pending'; else printf 'empty'; fi
    }
    out=$(fm_tmux_submit_enter_core win 3 0)
    [ "$out" = empty ] || fail "$pane_command legacy third Enter must clear the composer, got '$out'"
    [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 3 ] || fail "$pane_command must retain all three legacy Enter attempts"
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    fm_tmux_composer_state() { printf 'pending'; }
    : > "$dir/enters"
    out=$(fm_tmux_submit_enter_core win 3 0)
    [ "$out" = empty ] || fail "$pane_command legacy busy pending must remain queued, got '$out'"
    [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 3 ] || fail "$pane_command queued pending must exhaust legacy retries"
  done
  pass "tmux pi-launcher and kimi retain main unknown confirmation, repeated Enter, and busy queue handling"
)
test_nonomp_unknown_and_retry_keep_main_behavior

test_omp_identity_snapshot_survives_missing_later_identity() (
  local dir="$TMP_ROOT/omp-identity-snapshot" out
  mkdir -p "$dir"
  : > "$dir/enters"; printf '0' > "$dir/identities"
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  tmux() {
    local n
    case "$1" in
      display-message)
        n=$(cat "$dir/identities"); n=$((n + 1)); printf '%s' "$n" > "$dir/identities"
        [ "$n" -ne 1 ] || printf 'omp\n'
        ;;
      send-keys)
        case " $* " in *' Enter '*) printf 'Enter\n' >> "$dir/enters" ;; esac
        ;;
    esac
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  fm_tmux_composer_state() {
    tmux display-message -p -t win '#{pane_current_command}' >/dev/null
    printf 'unknown'
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  fm_pane_busy_state() { printf 'idle'; }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  fm_pane_is_busy() { return 0; }
  out=$(fm_tmux_submit_core win retained 3 0 0)
  [ "$out" = pending ] || fail "missing later identity must not discard a proven omp snapshot, got '$out'"
  [ "$(cat "$dir/identities")" -ge 2 ] || fail "identity snapshot scenario must reach a missing subsequent identity"
  [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 1 ] || fail "omp unknown after identity loss must not retry"
  pass "tmux proven omp identity survives a missing subsequent pane identity"
)
test_omp_identity_snapshot_survives_missing_later_identity

test_omp_foreground_identity_controls_submit_scope() (
  local dir="$TMP_ROOT/omp-foreground-identity" scenario title processes expected out
  mkdir -p "$dir"
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  tmux() {
    case "$1" in
      display-message)
        case "$*" in
          *pane_current_command*) printf '%s\n' "$title" ;;
          *pane_tty*) printf '/dev/ttys777\n' ;;
        esac
        ;;
      send-keys) printf 'Enter\n' >> "$dir/enters" ;;
    esac
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  ps() {
    printf '%s\n' "$processes"
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  fm_tmux_composer_state() { printf 'unknown'; }
  # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
  fm_pane_is_busy() { return 0; }
  for scenario in absent-title rewritten-title background-omp; do
    case "$scenario" in
      absent-title)
        title=''
        processes='101 20 20 /opt/bin/omp'
        expected=pending
        ;;
      rewritten-title)
        title=node
        processes='101 20 20 /opt/bin/omp'
        expected=pending
        ;;
      background-omp)
        title=kimi
        processes=$'101 10 20 /opt/bin/omp\n102 20 20 /opt/bin/kimi'
        expected=empty
        ;;
    esac
    : > "$dir/enters"
    out=$(fm_tmux_submit_enter_core win 3 0 1)
    [ "$out" = "$expected" ] || fail "$scenario must return $expected, got '$out'"
    [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 1 ] || fail "$scenario unknown must stop after one Enter"
  done
  pass "tmux foreground omp proof survives title loss while background omp cannot change legacy submit scope"
)
test_omp_foreground_identity_controls_submit_scope

test_missing_initial_identity_never_confirms_busy_input() (
  local dir="$TMP_ROOT/missing-initial-identity" fakebin composer sent out path fixture_state
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent"
  . "$ROOT/bin/fm-tmux-lib.sh"
  for path in typed direct explicit-empty; do
    for fixture_state in unknown pending postretry; do
      printf '0' > "$dir/reads"; : > "$sent"
      printf '│ > retained wake\n' > "$composer"
      touch "$dir/.swallow"
      # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
      fm_tmux_composer_state() {
        local n
        n=$(cat "$dir/reads"); n=$((n + 1)); printf '%s' "$n" > "$dir/reads"
        case "$fixture_state" in
          postretry) if [ "$n" -eq 1 ]; then printf 'pending'; else printf 'unknown'; fi ;;
          *) printf '%s' "$fixture_state" ;;
        esac
      }
      out=$(
        export FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent"
        export FM_FAKE_MISSING_IDENTITY=1 FM_FAKE_APPEND_BUSY=1
        export FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1
        [ "$(PATH="$fakebin:$PATH" fm_tmux_submit_harness win)" = unavailable ] || fail "both missing probes must establish unavailable identity"
        if [ "$path" = typed ]; then
          PATH="$fakebin:$PATH" fm_tmux_submit_core win 'retained wake' 3 0 0
        elif [ "$path" = explicit-empty ]; then
          PATH="$fakebin:$PATH" fm_tmux_submit_enter_core win 3 0 1 ''
        else
          PATH="$fakebin:$PATH" fm_tmux_submit_enter_core win 3 0 1
        fi
      )
      [ "$out" = pending ] || fail "$path $fixture_state with unavailable initial identity must stay pending, got '$out'"
      PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_pane_is_busy win legacy-tmux \
        || fail "unavailable identity regression must render a later legacy busy signal"
      grep -q 'retained wake' "$composer" || fail "unavailable identity must not consume the payload"
    done
  done
  pass "tmux unavailable initial identity fails closed on initial, postretry, and exhausted pending paths"
)
test_missing_initial_identity_never_confirms_busy_input

test_nonomp_uses_unchanged_legacy_busy_predicate() (
  local dir="$TMP_ROOT/legacy-busy-predicate" fakebin composer out command signal fixture_state
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  . "$ROOT/bin/fm-tmux-lib.sh"
  for command in pi pi-signed pi-launcher claude kimi; do
    for signal in '⠧ 11s' '╭── ⠦ 13s > model ──╮' '⎋ Waiting' \
      '✢ Pollinating… (16s · ↓ 1.1k tokens)' '🌕 · Thinking'; do
      printf '%s\n' "$signal" > "$composer"
      touch "$dir/.swallow"
      PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_pane_is_busy win legacy-tmux \
        && fail "$command legacy matcher must not newly accept '$signal'"
      for fixture_state in unknown pending; do
        # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
        fm_tmux_composer_state() { printf '%s' "$fixture_state"; }
        out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_HARNESS="$command" \
          FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
          fm_tmux_submit_core win payload 2 0 0)
        [ "$out" = "$fixture_state" ] || fail "$command unchanged busy signal must retain $fixture_state, got '$out'"
      done
    done
    printf 'idle\n' > "$composer"
    # shellcheck disable=SC2329 # Invoked indirectly by the submit helper under test.
    fm_tmux_composer_state() { printf 'unknown'; }
    out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_HARNESS="$command" \
      FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_APPEND_BUSY=1 \
      fm_tmux_submit_core win payload 2 0 0)
    [ "$out" = empty ] || fail "$command legacy idle-to-Working transition must confirm, got '$out'"
  done
  pass "tmux non-omp confirmation preserves main's predicate and Pi launcher eligibility"
)
test_nonomp_uses_unchanged_legacy_busy_predicate
