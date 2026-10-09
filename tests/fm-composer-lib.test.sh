#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩` (muse), and `→`
#      (cursor) are a genuine empty agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# rule_n <columns> -> a solid `─` rule of that many columns. A titled rule proves
# its composer only at the closing rule's width, so fixtures size the closers.
rule_n() { local n=$1 out='' i; for ((i = 0; i < n; i++)); do out+='─'; done; printf '%s' "$out"; }

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'Type a message...' "$idle" sensitive 'Type a message...' 1 1)
  [ "$out" = pending ] || fail "placeholder-like text surviving a styled box capture should read pending, got '$out'"
  out=$(classify 1 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 1 0)
  [ "$out" = empty ] || fail "a glyph-bearing plain box placeholder should read empty, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 1)
  [ "$out" = pending ] || fail "placeholder text on a styled bare input row must be pending, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 0)
  [ "$out" = unknown ] || fail "placeholder text on a plain bare input row must be unknown, got '$out'"
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: idle matching is limited to proven placeholder positions"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle" sensitive 'type a message...' 1 0)
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive 'type a message...' 1 0)
  [ "$out" = empty ] || fail "an explicitly insensitive plain placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# =============================================================================
# fm_composer_classify_screen: the adapter-facing screen classifier and the
# correctness matrix (audit data/fm-composer-consolidation-audit-s1, task
# fm-composer-thin-adapter-refactor-r1).
#
# Fixtures are the audit's byte-level captures of six REAL idle harnesses:
# claude 2.1.226 (bare `❯` + U+00A0 NO-BREAK SPACE), codex 0.146.0 (bold `›`
# + SGR-2 dim hint), codex 0.154.0 (the same `›` amid a braille starfield over
# a status footer, captured through Herdr on 2026-09-15), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
# between solid `─` rules), opencode 1.14.46 (left-bar `┃` rows), and grok
# 1.0.0 (bordered box with a TITLED bottom border), plus claude captured
# inside zellij through `dump-screen --ansi` (`ESC[m` `❯` U+00A0).
#
# Capability profiles mirror the real adapters' descriptors: tmux
# (styled+cursor+identity), herdr/zellij (styled), cmux/orca (plain). Every
# emptiness verdict is asserted under the ambient UTF-8 locale AND LC_ALL=C,
# pinning the locale-safe Unicode-space normalization (issue #1988).
# =============================================================================

ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  # Real idle claude: `❯` + U+00A0, borderless, between horizontal rules.
  # The audit's headline defect: this row read `pending` under LC_ALL=C
  # (issue #1988), deferring every away-mode escalation in daemon contexts.
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  assert_screen "claude typed on plain backends" pending "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row reads empty on every profile in both locales (#1988)"
}

test_matrix_claude_arrow_statusline_footer() {
  # Real claude 2.x on herdr (captured live 2026-09-20, herdr 0.8.0): the
  # composer is a bare `❯`+U+00A0 row between two solid rules, and the harness
  # draws a user statusLine plus its permission-mode hint directly BELOW the
  # closing rule. That statusLine opened with `→`, which is Cursor's own agent
  # prompt glyph, so the bottom-most-candidate rule selected the statusLine as
  # a bare composer, swallowed the hint row beneath it as wrapped input, and
  # every steer to a claude worker was refused with a `pending` verdict on a
  # visibly empty composer. A pair that closed over a bare agent-glyph row is
  # a proven composer container, so its contiguous non-blank footer rows are
  # furniture and cannot outrank the composer they sit under.
  local pair footer screen typed residue claude_idle
  claude_idle=$(printf 'claude\tidle')
  pair=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────'
  footer=$'\n  → repo git:(fm/branch)× | Opus 5 | ctx 15%\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  screen="$pair$footer"
  assert_screen "claude idle under an arrow statusline on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "claude idle under an arrow statusline on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle under an arrow statusline on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # The protection this must NOT remove: real unsubmitted text in that same
  # composer, under that same statusline, still refuses.
  typed=$'transcript line\n────────────────────────\n❯ fix the login bug\n────────────────────────'"$footer"
  assert_screen "claude typed under an arrow statusline" pending "$CAPS_STYLED" "$typed" '' "$claude_idle"
  # The live second defect: a stray SGR mouse report left in the composer by
  # a click in the pane is real pending content, not furniture.
  residue=$'transcript line\n────────────────────────\n❯ <65;77;27M\n────────────────────────'"$footer"
  assert_screen "stray mouse report in the composer" pending "$CAPS_STYLED" "$residue" '' "$claude_idle"
  pass "matrix: claude's arrow statusline is footer furniture, not a composer holding text"
}

test_matrix_claude_titled_top_border() {
  # Real claude 2.x draws the session title (a --name, a /rename, a hook-supplied
  # or generated title) INSIDE the composer's top rule: `──── <title> ─`. That row
  # is no longer a solid rule, so the cursorless profiles lost the pair, saw the
  # lower plain rule as an unproven separator, and refused `unknown` on a visibly
  # empty composer - every steer to the worker was undeliverable and its
  # relaunch refused (task fm-claude-titled-composer-unknown, captured live
  # 2026-10-06 on herdr).
  local titled plain_rule empty typed claude_idle pi_idle screen
  claude_idle=$(printf 'claude\tidle'); pi_idle=$(printf 'pi\tidle')
  # Claude draws the titled top rule and the closing rule at one width; the
  # title is ASCII, so its character count is the same in every locale.
  local title_text=' Firstmate operational input waiting read Users ' dashes i
  titled="────────────────────────${title_text}─"
  dashes=$((24 + ${#title_text} + 1)); plain_rule=''
  for ((i = 0; i < dashes; i++)); do plain_rule+='─'; done
  empty=$'transcript line\n'"$titled"$'\n❯'"$NBSP"$'\n'"$plain_rule"$'\n  Sonnet 5.5 ░░░░░░░░░░ 9%\n  ⏵⏵ bypass permissions on'
  assert_screen "claude titled idle on tmux" empty "$CAPS_TMUX" "$empty" 2 probe-absent
  assert_screen "claude titled idle on herdr" empty "$CAPS_STYLED" "$empty" '' "$claude_idle"
  assert_screen "claude titled idle on zellij" empty "$CAPS_STYLED_NOID" "$empty"
  assert_screen "claude titled idle on cmux/orca" empty "$CAPS_PLAIN" "$empty"
  typed=$'transcript line\n'"$titled"$'\n❯ fix the login bug\n'"$plain_rule"$'\n  Sonnet 5.5 ░░░░░░░░░░ 9%'
  assert_screen "claude titled typed on tmux" pending "$CAPS_TMUX" "$typed" 2 probe-absent
  assert_screen "claude titled typed on herdr" pending "$CAPS_STYLED" "$typed" '' "$claude_idle"
  assert_screen "claude titled typed on zellij" pending "$CAPS_STYLED_NOID" "$typed"
  assert_screen "claude titled typed on plain backends" pending "$CAPS_PLAIN" "$typed"
  # The same plain-border shapes keep their verdicts beside the titled ones.
  screen=$'transcript line\n'"$plain_rule"$'\n❯'"$NBSP"$'\n'"$plain_rule"
  assert_screen "claude plain idle on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  pass "matrix: claude's titled top border reads empty when idle and pending when typed on every profile"
}

assert_selected_content() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_extract_selected_content "$@") \
    || fail "$label: selected content extraction failed"
  [ "$out" = "$want" ] || fail "$label: expected '$want', got '$out'"
  out=$(LC_ALL=C fm_composer_extract_selected_content "$@") \
    || fail "$label under LC_ALL=C: selected content extraction failed"
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected '$want', got '$out'"
}

assert_multiline_rule_pair() {
  local label=$1 screen=$2 want=$3 first=$4 last=$5 claude_idle cursor
  claude_idle=$(printf 'claude\tidle')
  assert_screen "$label on idle Herdr Claude" pending "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_selected_content "$label on styled capture" "$want" "$CAPS_STYLED" "$screen"
  assert_screen "$label requests lazy Herdr identity" need-identity "$CAPS_STYLED" "$screen"
  assert_screen "$label after absent Herdr identity probe" pending "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "$label on Zellij without identity" pending "$CAPS_STYLED_NOID" "$screen"
  assert_selected_content "$label on Zellij without identity" "$want" "$CAPS_STYLED_NOID" "$screen"
  assert_screen "$label on plain capture" pending "$CAPS_PLAIN" "$screen"
  assert_selected_content "$label on plain capture" "$want" "$CAPS_PLAIN" "$screen"
  assert_selected_content "$label on tmux capture" "$want" "$CAPS_TMUX" "$screen"
  cursor=$first
  while [ "$cursor" -le "$last" ]; do
    assert_screen "$label on tmux row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor" probe-absent
    cursor=$((cursor + 1))
  done
}

test_rule_pair_equal_indentation() {
  local top bottom screen caps draft want verdict claude_idle
  # Same width as the titled opener '──────── Session ─' (18 columns): a titled
  # rule proves its composer only when it spans the closing rule's columns.
  bottom='──────────────────'
  claude_idle=$(printf 'claude\tidle')
  for top in '──────── Session ─' "$bottom"; do
    for draft in '' 'keep this unsent text'; do
      want=$draft
      verdict=empty
      [ -z "$draft" ] || verdict=pending
      screen=$'transcript line\n  '"$top"$'\n  ❯ '"$draft"$'\n  '"$bottom"
      assert_screen "$top equally indented $verdict on cursor" "$verdict" "$CAPS_TMUX" "$screen" 2 probe-absent
      for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "$top equally indented $verdict cursorless" "$verdict" "$caps" "$screen" '' "$claude_idle"
        assert_selected_content "$top equally indented $verdict extraction" "$want" "$caps" "$screen"
      done
      assert_selected_content "$top equally indented $verdict tmux extraction" "$want" "$CAPS_TMUX" "$screen"
    done
    # A less-indented closing rule is also a mismatch, not a proven pair.
    screen=$'transcript line\n  '"$top"$'\n  ❯ keep this unsent text\n'"$bottom"
    assert_screen "$top outdented closer on cursor" unknown-draft "$CAPS_TMUX" "$screen" 2 probe-absent
    assert_screen "$top outdented closer cursorless" unknown-draft "$CAPS_STYLED_NOID" "$screen"
    if fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"; then
      fail "$top outdented closer must refuse extraction"
    fi
  done
  pass "equally indented plain and titled rule pairs classify and extract while mismatched closers refuse"
}

test_rule_pair_ambiguity_is_candidate_scoped() {
  local history top bottom draft screen caps cursor verdict want r22 r23
  # Each closing rule spans its titled opener's columns: a titled rule proves
  # its composer only when it does.
  r22=$(rule_n 22); r23=$(rule_n 23)
  bottom=$r23
  for history in \
    ' ──────── Old example ─'$'\n ❯ old example\n'"$r22" \
    '──────── Old example ─'$'\n❯ old example\n '"$r22" \
    '──────── Old example ─'$'\n❯ old example\n'"$r22"$'\n❯ old continuation\n'"$r22" \
    '──────── Old example ─'$'\n❯ old example\n ──────── pasted title ─\n ❯\n'"$r23" \
    $'╭───╮\n│ ❯ │\n╰────╯'; do
    cursor=$(printf '%s\n' "$history" | wc -l)
    cursor=$((cursor + 2))
    for top in '──────── Live session ─' "$bottom"; do
      for draft in '' 'live draft'; do
        verdict=empty
        [ -z "$draft" ] || verdict=pending
        want=$draft
        screen="$history"$'\n\n'"$top"$'\n❯ '"$draft"$'\n'"$bottom"
        assert_screen "historical ambiguity before $top $verdict on cursor" "$verdict" "$CAPS_TMUX" "$screen" "$cursor" probe-absent
        for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
          assert_screen "historical ambiguity before $top $verdict cursorless" "$verdict" "$caps" "$screen" '' probe-absent
          assert_selected_content "historical ambiguity before $top $verdict extraction" "$want" "$caps" "$screen"
        done
        assert_selected_content "historical ambiguity before $top $verdict tmux extraction" "$want" "$CAPS_TMUX" "$screen"
      done
    done
    screen="$history"$'\n\n❯ live draft'
    assert_screen "historical ambiguity before live bare composer" pending "$CAPS_STYLED_NOID" "$screen"
    assert_screen "historical ambiguity before live bare composer on cursor" pending "$CAPS_TMUX" "$screen" "$((cursor - 1))" probe-absent
    assert_selected_content "historical ambiguity before live bare composer extraction" 'live draft' "$CAPS_STYLED_NOID" "$screen"
    screen="$history"$'\n\n╭──────────────────╮\n│ ❯ live draft     │\n╰──────────────────╯'
    assert_screen "historical ambiguity before live boxed composer" pending "$CAPS_STYLED_NOID" "$screen"
    assert_screen "historical ambiguity before live boxed composer on cursor" pending "$CAPS_TMUX" "$screen" "$cursor" probe-absent
    assert_selected_content "historical ambiguity before live boxed composer extraction" 'live draft' "$CAPS_STYLED_NOID" "$screen"
  done
  for top in '──────── Live session ─' "$bottom"; do
    screen="$top"$'\n❯ keep this unsent text\n '"$bottom"
    assert_screen "selected $top indented closer on cursor" unknown-draft "$CAPS_TMUX" "$screen" 1 probe-absent
    for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
      assert_screen "selected $top indented closer cursorless" unknown-draft "$caps" "$screen" '' probe-absent
      if fm_composer_extract_selected_content "$caps" "$screen"; then
        fail "selected $top indented closer must refuse extraction"
      fi
    done
  done
  pass "historical ambiguity does not poison live rule pairs and selected ambiguity still refuses"
}

test_titled_rule_pair_ignores_outside_glyph_after_recorded_closer() {
  local history outside prefix draft screen cursor verdict caps r22 r23
  r22=$(rule_n 22); r23=$(rule_n 23)
  for history in ' ──────── Old example ─'$'\n ❯ old example\n'"$r22" ''; do
    for outside in \
      $'  ❯ /exit                       Exit the CLI\n    /context                    Visualize current context usage as a colored grid' \
      $'────────────────\n❯ old example\n────────────────\n\n❯ outside example'; do
      prefix=$outside
      [ -z "$history" ] || prefix="$history"$'\n\n'"$outside"
      cursor=$(printf '%s\n' "$prefix" | wc -l)
      cursor=$((cursor + 1))
      for draft in '/exit' ''; do
        verdict=empty
        [ -z "$draft" ] || verdict=pending
        screen="$prefix"$'\n──────── Live session ─\n❯'"$NBSP $draft"$'\n'"$r23"$'\n  ⏵⏵ bypass permissions on'
        assert_screen "outside glyph before titled $verdict on cursor" "$verdict" "$CAPS_TMUX" "$screen" "$cursor" probe-absent
        assert_selected_content "outside glyph before titled $verdict tmux extraction" "$draft" "$CAPS_TMUX" "$screen"
        for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
          assert_screen "outside glyph before titled $verdict cursorless" "$verdict" "$caps" "$screen" '' probe-absent
          assert_selected_content "outside glyph before titled $verdict extraction" "$draft" "$caps" "$screen"
        done
      done
    done
  done
  pass "glyphs outside a closed pair do not poison a live titled composer or its extracted draft"
}

test_multiline_rule_pair_retains_all_interior_rows() {
  local top bottom screen earlier later
  # Same width as the titled opener '──────── Session ─' (18 columns): a titled
  # rule proves its composer only when it spans the closing rule's columns.
  bottom='──────────────────'
  for top in '──────── Session ─' "$bottom"; do
    screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n ❯\n'"$bottom"
    assert_multiline_rule_pair "$top concrete multiline draft" "$screen" 'keep this unsent text ❯' 2 3
    screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n\n ordinary continuation\n ❯\n\n final continuation\n'"$bottom"
    assert_multiline_rule_pair "$top blank and ordinary continuations" "$screen" 'keep this unsent text ordinary continuation ❯ final continuation' 2 7
    screen=$'transcript line\n'"$top"$'\n❯\n\n ❯\n'"$bottom"
    assert_multiline_rule_pair "$top empty proof with a later glyph" "$screen" '❯' 2 4
    screen=$'transcript line\n'"$top"$'\n\n❯ keep this unsent text\n\n ❯\n'"$bottom"
    assert_multiline_rule_pair "$top leading blank before proof" "$screen" 'keep this unsent text ❯' 2 5
    earlier=$'────────────────\n❯ old draft\n────────────────\n\n'"$screen"
    assert_screen "$top real earlier composer does not replace multiline draft" pending "$CAPS_STYLED_NOID" "$earlier"
    assert_selected_content "$top real earlier composer does not replace multiline draft" 'keep this unsent text ❯' "$CAPS_STYLED_NOID" "$earlier"
    later="$screen"$'\n\n────────────────\n❯\n────────────────'
    assert_screen "$top later real empty composer wins" empty "$CAPS_STYLED_NOID" "$later"
    assert_selected_content "$top later real empty composer wins" '' "$CAPS_STYLED_NOID" "$later"
    later="$screen"$'\n\n────────────────\n❯ newer draft\n────────────────'
    assert_screen "$top later real pending composer wins" pending "$CAPS_STYLED_NOID" "$later"
    assert_selected_content "$top later real pending composer wins" 'newer draft' "$CAPS_STYLED_NOID" "$later"
  done
  pass "multiline rule pairs retain every interior row and strip only the proving prompt glyph"
}

test_rule_pair_continuations_never_prove_empty() {
  local top bottom pasted screen caps cursor literal want pi_idle
  # Same width as the titled opener '──────── Session ─' (18 columns): a titled
  # rule proves its composer only when it spans the closing rule's columns.
  bottom='──────────────────'
  pi_idle=$(printf 'pi\tidle')
  for top in '──────── Session ─' "$bottom"; do
    for pasted in ' ──────── pasted title ─' '──────── pasted title ─' ' ──────── Pasted! ─' ' ────────────────' '──────── Pasted! ─' "$bottom"; do
      screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n'"$pasted"$'\n ❯\n'"$bottom"
      for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "$top ambiguous pasted rule $pasted" unknown-draft "$caps" "$screen" '' probe-absent
        if fm_composer_extract_selected_content "$caps" "$screen"; then
          fail "$top ambiguous pasted rule must refuse extraction"
        fi
        if LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen"; then
          fail "$top ambiguous pasted rule must refuse extraction under LC_ALL=C"
        fi
      done
      for cursor in 2 3 4; do
        assert_screen "$top ambiguous pasted rule on cursor row $cursor" unknown-draft "$CAPS_TMUX" "$screen" "$cursor" probe-absent
      done
    done
    for literal in '││' '┃┃' '║║' '||' '│draft│' '┃draft┃' '║draft║' '|draft|' '│' '┃' '║' '|'; do
      screen=$'transcript line\n'"$top"$'\n❯\n '"$literal"$'\n'"$bottom"
      assert_multiline_rule_pair "$top literal continuation $literal" "$screen" "$literal" 2 3
      screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n '"$literal"$'\n ❯\n'"$bottom"
      want="keep this unsent text $literal ❯"
      assert_multiline_rule_pair "$top literal continuation and later glyph $literal" "$screen" "$want" 2 4
    done
  done
  for literal in '││' '┃┃' '║║' '||' '│draft│' '┃draft┃' '║draft║' '|draft|'; do
    screen="$bottom"$'\n '"$literal"$'\n'"$bottom"
    assert_screen "Pi literal rule-pair content $literal" pending "$CAPS_STYLED" "$screen" '' "$pi_idle"
    assert_screen "Pi literal rule-pair content $literal on cursor" pending "$CAPS_TMUX" "$screen" 1 "$pi_idle"
    assert_selected_content "Pi literal rule-pair extraction $literal" "$literal" "$CAPS_STYLED" "$screen"
  done
  pass "rule-like continuations refuse proof and literal side characters remain draft content"
}

test_rejected_titled_rule_pair_retains_refusal() {
  local top bottom screen caps cursor later
  for top in '──────── pasted title ─' '──────── Café ─'; do
    bottom=$(rule_n 18)
    [ "$top" != '──────── Café ─' ] || bottom=$(rule_n 15)
    screen="$top"$'\n❯\n keep this unsent text\n ❯\n'"$bottom"
    for caps in "$CAPS_TMUX" "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
      assert_screen "$top rejected pair cursorless" unknown "$caps" "$screen" '' probe-absent
      if fm_composer_extract_selected_content "$caps" "$screen"; then
        fail "$top rejected pair must refuse extraction"
      fi
      if LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen"; then
        fail "$top rejected pair must refuse extraction under LC_ALL=C"
      fi
    done
    for cursor in 1 2 3; do
      assert_screen "$top rejected pair on cursor row $cursor" unknown "$CAPS_TMUX" "$screen" "$cursor" probe-absent
    done
    for later in '' 'newer draft'; do
      screen="$top"$'\n❯\n keep this unsent text\n ❯\n'"$bottom"$'\n\n──────── Live session ─\n❯ '"$later"$'\n'"$(rule_n 23)"
      if [ -z "$later" ]; then
        assert_screen "$top before newer empty composer" empty "$CAPS_TMUX" "$screen" 7 probe-absent
        assert_screen "$top before newer empty composer cursorless" empty "$CAPS_STYLED_NOID" "$screen"
      else
        assert_screen "$top before newer draft" pending "$CAPS_TMUX" "$screen" 7 probe-absent
        assert_screen "$top before newer draft cursorless" pending "$CAPS_STYLED_NOID" "$screen"
      fi
      assert_selected_content "$top before newer composer extraction" "$later" "$CAPS_STYLED_NOID" "$screen"
    done
  done
  pass "rejected titled rule pairs refuse fallback without poisoning newer composers"
}

test_rule_pair_pasted_containers_remain_literal() {
  local top bottom pasted screen want later cursor caps
  # Same width as the titled opener '──────── Session ─' (18 columns): a titled
  # rule proves its composer only when it spans the closing rule's columns.
  bottom='──────────────────'
  for top in '──────── Session ─' "$bottom"; do
    screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n ╭───╮\n │ │\n ╰───╯\n'"$bottom"
    assert_multiline_rule_pair "$top indented pasted rounded box" "$screen" 'keep this unsent text ╭───╮ │ │ ╰───╯' 2 5
    for pasted in \
      $'╭────────╮\n│ ❯     │\n╰────────╯' \
      $'┌────────┐\n│ ❯     │\n└────────┘' \
      $'┏━━━━━━━━┓\n┃ ❯     ┃\n┗━━━━━━━━┛' \
      $'╔════════╗\n║ ❯     ║\n╚════════╝' \
      $'+--------+\n| >      |\n+--------+'; do
      case "$pasted" in
        ╭*) want='╭────────╮ │ ❯ │ ╰────────╯' ;;
        ┌*) want='┌────────┐ │ ❯ │ └────────┘' ;;
        ┏*) want='┏━━━━━━━━┓ ┃ ❯ ┃ ┗━━━━━━━━┛' ;;
        ╔*) want='╔════════╗ ║ ❯ ║ ╚════════╝' ;;
        +*) want='+--------+ | > | +--------+' ;;
      esac
      screen=$'transcript line\n'"$top"$'\n❯\n'"$pasted"$'\n'"$bottom"
      assert_multiline_rule_pair "$top pasted box $pasted" "$screen" "$want" 2 5
      screen=$'transcript line\n'"$top"$'\n❯ keep this unsent text\n'"$pasted"$'\n ❯\n'"$bottom"
      assert_multiline_rule_pair "$top pasted box with later glyph $pasted" "$screen" "keep this unsent text $want ❯" 2 6
      later="$screen"$'\n\n────────────────\n❯\n────────────────'
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "$top newer empty pair below pasted box" empty "$caps" "$later"
        assert_selected_content "$top newer empty pair below pasted box" '' "$caps" "$later"
      done
      for cursor in 2 3 4 5 6; do
        assert_screen "$top cursor stays in earlier pasted-box pair on row $cursor" pending "$CAPS_TMUX" "$later" "$cursor" probe-absent
      done
    done
    pasted="$(omp_box_top)"$'\n╰─ nested draft ─╯'
    want="$(omp_box_top) ╰─ nested draft ─╯"
    screen=$'transcript line\n'"$top"$'\n❯\n'"$pasted"$'\n'"$bottom"
    assert_multiline_rule_pair "$top nested omp folded box" "$screen" "$want" 2 4
    pasted="$(omp_box_top)"$'\n│ nested draft │\n'"$(omp_box_last '')"
    want="$(omp_box_top) │ nested draft │ ╰─ ─╯"
    screen=$'transcript line\n'"$top"$'\n❯\n'"$pasted"$'\n'"$bottom"
    assert_multiline_rule_pair "$top nested omp multiline box" "$screen" "$want" 2 5
    pasted=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀'
    want='┃ ┃ Ask anything... ┃ ┃ Build · GPT-5.5 Fast OpenAI · high ╹▀▀▀▀▀▀▀▀'
    screen=$'transcript line\n'"$top"$'\n❯\n'"$pasted"$'\n'"$bottom"
    assert_multiline_rule_pair "$top nested opencode leftbar" "$screen" "$want" 2 7
    for later in \
      "$bottom"$'\n❯ newer draft\n'"$bottom" \
      $'╭────────────────────────╮\n│ ❯ newer draft          │\n╰────────────────────────╯'; do
      later="$screen"$'\n\n'"$later"
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "$top lower genuine candidate wins" pending "$caps" "$later"
        assert_selected_content "$top lower genuine candidate wins" 'newer draft' "$caps" "$later"
      done
      assert_screen "$top newer genuine candidate on prompt row" pending "$CAPS_TMUX" "$later" 11 probe-absent
      case "$later" in
        *"$bottom")
          assert_screen "$top cursor on newer pair closing border" unknown "$CAPS_TMUX" "$later" 12 probe-absent
          ;;
        *)
          assert_screen "$top cursor on newer box folded border" pending "$CAPS_TMUX" "$later" 12 probe-absent
          ;;
      esac
    done
  done
  pass "rule pairs retain pasted boxes and leftbars while newer genuine candidates win"
}

test_rule_pair_braille_is_literal_content() {
  local top bottom literal screen caps
  # Same width as the titled opener '──────── Session ─' (18 columns): a titled
  # rule proves its composer only when it spans the closing rule's columns.
  bottom='──────────────────'
  for top in '──────── Session ─' "$bottom"; do
    for literal in '⠋' '⠧' '⠀' '⣿⠿'; do
      screen=$'transcript line\n'"$top"$'\n❯ '"$literal"$'\n'"$bottom"
      assert_multiline_rule_pair "$top Braille-only singleton $literal" "$screen" "$literal" 2 2
      screen=$'transcript line\n'"$top"$'\n❯ '"$literal"$'\n\n'"$bottom"
      assert_multiline_rule_pair "$top Braille-only prompt followed by blank $literal" "$screen" "$literal" 2 3
      screen=$'transcript line\n'"$top"$'\n❯ '"$literal"$'\n\n ordinary continuation\n'"$bottom"
      assert_multiline_rule_pair "$top Braille-only prompt with continuation $literal" "$screen" "$literal ordinary continuation" 2 4
      screen=$'transcript line\n'"$top"$'\n❯\n '"$literal"$'\n'"$bottom"
      assert_multiline_rule_pair "$top Braille-only continuation $literal" "$screen" "$literal" 2 3
    done
    screen=$'transcript line\n'"$top"$'\n❯\n'"$bottom"
    for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
      assert_screen "$top empty singleton" empty "$caps" "$screen"
      assert_selected_content "$top empty singleton" '' "$caps" "$screen"
    done
    assert_screen "$top empty singleton on cursor" empty "$CAPS_TMUX" "$screen" 2 probe-absent
    assert_selected_content "$top empty singleton on tmux capture" '' "$CAPS_TMUX" "$screen"
  done
  pass "rule pairs preserve Braille prompt content and empty singletons stay empty"
}

test_claude_titled_top_border_needs_glyph_proof_and_exact_shape() {
  # A titled rule only OPENS a composer pair, and the pair needs the agent glyph
  # row inside it. Anything short of that exact shape keeps the refusal.
  local titled plain_rule screen claude_idle pi_idle
  claude_idle=$(printf 'claude\tidle'); pi_idle=$(printf 'pi\tidle')
  titled='──────────────────────── Some session title ─'
  plain_rule='────────────────────────────────────────────────────────────────────────'
  # No glyph row between the titled rule and the closing rule: not a composer,
  # whatever the agent identity claims.
  screen=$'transcript line\n'"$titled"$'\n\n'"$plain_rule"
  assert_screen "titled rule around a blank row (no identity)" unknown "$CAPS_STYLED_NOID" "$screen"
  assert_screen "titled rule around a blank row (idle pi identity)" unknown "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "titled rule around a blank row (idle claude identity)" unknown "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "titled rule around a blank row on tmux" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  # Shapes that are not a titled rule stay ordinary rows: a short opening run,
  # no closing rule glyph, a title without surrounding spaces, an edge glyph
  # inside the title, and a heading rule carrying only spaces.
  for titled in \
    '─────── Some session title ─' \
    '──────────────────────── Some session title' \
    '────────────────────────Some session title─' \
    '──────────────────────── Some │ title ─' \
    '──────────────────────── ─'; do
    screen=$'transcript line\n'"$titled"$'\n❯'"$NBSP"$'\n'"$plain_rule"
    assert_screen "not a titled rule: $titled" unknown "$CAPS_STYLED_NOID" "$screen"
  done
  pass "matrix: a titled rule opens a composer pair only with an exact shape and an agent glyph row inside"
}

test_composer_footer_demotion_needs_a_proven_pair() {
  # The demotion is bounded in three directions, and each bound is a case
  # where a lower glyph row IS the live composer.
  local screen out claude_idle pi_idle
  claude_idle=$(printf 'claude\tidle'); pi_idle=$(printf 'pi\tidle')
  # 1. Contiguity: a blank row ends the footer zone, so a composer redrawn
  #    below an old rule pair still wins.
  screen=$'────────────────────────\n❯ old draft\n────────────────────────\n  → repo git:(main)\n\n→'
  assert_screen "blank row reopens lower candidates" empty "$CAPS_STYLED_NOID" "$screen"
  # 2. Proof: a pair that closed over NO agent-glyph row proves no composer,
  #    so nothing below it is demoted. pi's own blank pair is exactly that.
  screen=$'────────────────────────\n\n────────────────────────\n→'
  assert_screen "an unproven pair demotes nothing" empty "$CAPS_STYLED_NOID" "$screen"
  # 3. No pair at all: Cursor draws its `→` composer between half-block rules,
  #    which are not separator rules, so its footer rows change nothing.
  screen=$' ▄▄▄▄▄▄▄▄\n  →\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  assert_screen "cursor keeps its own bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  # A later pair WITHOUT a glyph row must reopen candidates the earlier proven
  # pair had closed, so the zone cannot leak down a screen.
  screen=$'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  → repo git:(main)\n────────────────────────\n────────────────────────\n→'
  assert_screen "a later unproven pair reopens candidates" empty "$CAPS_STYLED_NOID" "$screen"
  # And the strict posture is untouched: a footer row alone proves nothing.
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" $'transcript\n  → repo git:(main) | Opus 5')
  [ "$out" != empty ] \
    || fail "an unanchored statusline row must never prove an empty composer, got '$out'"
  pass "fm_composer_classify_screen: footer demotion needs a contiguous, glyph-proven pair"
}

test_composer_footer_zone_is_shape_independent() {
  # The same captain-facing failure on the BORDERED composer: claude 2.x
  # renders its composer inside a rounded box on a wide pane, and this home's
  # statusLine (opening with `→`, Cursor's prompt glyph) plus the permission
  # hint still land on the two contiguous rows below the closing border. The
  # footer-zone invariant is a property of an envelope proven by a glyph row
  # inside it, not of the pi separator pair, so it must hold here too.
  local box footer screen out claude_idle
  claude_idle=$(printf 'claude\tidle')
  box=$'transcript line\n╭───────────────────────────╮\n│ ❯'"$NBSP"$'                        │\n╰───────────────────────────╯'
  footer=$'\n → repo git:(fm/branch)× | Opus 5 | ctx 15%\n ⏵⏵ bypass permissions on'
  screen="$box$footer"
  assert_screen "boxed claude idle under an arrow statusline on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "boxed claude idle under an arrow statusline on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "boxed claude idle under an arrow statusline on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen")
  case "$out" in
    *'repo git:'*|*'bypass permissions'*)
      fail "the statusline footer must never be extracted as composer content, got '$out'" ;;
  esac
  # The protection this must NOT remove: real unsubmitted text inside that same
  # bordered composer, under that same footer, still refuses.
  screen=$'transcript line\n╭───────────────────────────╮\n│ ❯ half-typed draft        │\n╰───────────────────────────╯'"$footer"
  assert_screen "boxed claude typed under an arrow statusline" pending "$CAPS_STYLED" "$screen" '' "$claude_idle"
  # The deliberate counterexample, pinned as such: codex's startup banner has
  # no glyph row inside it, so it proves no composer, opens no footer zone, and
  # the live bare row contiguously below it keeps winning.
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "unproven banner still yields to the bare row below it" empty "$CAPS_PLAIN" "$screen"
  pass "fm_composer_classify_screen: the footer zone holds for boxes, not only separator pairs"
}

test_composer_footer_zone_refuses_rather_than_allows() {
  # The footer-zone demotion is ASYMMETRIC: `empty` is the only verdict that
  # authorizes fm-send to type into the pane, so the rule may move a verdict
  # toward refusing but never toward `empty`. Every screen below classified
  # `pending` before the footer zone existed and must never read `empty`.
  local screen out
  # 1. Draft loss. A row leading with the SAME glyph the envelope was proven by
  #    is a live composer, not furniture, and must keep winning - otherwise the
  #    doorbell types over a draft the worker can see.
  screen=$'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n❯ my typed draft'
  assert_screen "separated: a live draft below the pair keeps winning" pending "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'my typed draft' ] \
    || fail "the live draft must be the extracted composer content, got '$out'"
  screen=$'╭────────────────────────╮\n│ ❯'"$NBSP"$'                     │\n╰────────────────────────╯\n❯ my typed draft'
  assert_screen "boxed: a live draft below the box keeps winning" pending "$CAPS_STYLED_NOID" "$screen"
  # 2. Working agent. Unclaimed activity below a proven envelope is not
  #    furniture in EITHER row order, even when one of the rows leads with a
  #    foreign agent glyph, so the envelope above it stays stale.
  for screen in \
    $'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...\n→ ran npm test (3 failures)' \
    $'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\n→ ran npm test (3 failures)\nWorking on request...' \
    $'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\nWorking on request...\n→ ran npm test (3 failures)' \
    $'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n→ ran npm test (3 failures)\nWorking on request...'
  do
    out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$screen")
    [ "$out" != empty ] \
      || fail "a working agent below a proven envelope must never read empty, got '$out'"
    out=$(LC_ALL=C fm_composer_classify_screen "$CAPS_STYLED_NOID" "$screen")
    [ "$out" != empty ] \
      || fail "a working agent below a proven envelope must never read empty under LC_ALL=C, got '$out'"
  done
  # 3. The other direction, which the demotion must not invert either: a pair
  #    holding a QUOTED prompt in the transcript above a live, visibly empty
  #    composer row reads empty, and the quoted text is never composer content.
  screen=$'────────────────────────\ntranscript one\ntranscript two\n❯ some quoted prompt in the transcript\n────────────────────────\n❯'"$NBSP"
  assert_screen "a quoted prompt above a live empty row stays empty" empty "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  case "$out" in
    *'some quoted prompt'*) fail "a quoted transcript prompt must never be composer content, got '$out'" ;;
  esac
  pass "fm_composer_classify_screen: the footer zone only ever refuses, never allows"
}

test_matrix_codex_dim_hint_row() {
  # Real idle codex: bold `›`, reset, then an SGR-2 dim hint. Styled captures
  # strip the ghost and prove empty; plain captures must defer as unknown -
  # NEVER the old false `pending` that read the hint as unsent text.
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty when styling proves it, unknown (never pending) when it cannot"
}

test_matrix_muse_truecolor_glyph_survives_signal_loss() {
  # Real idle muse: truecolor `⟩` (38;2;90;160;255, luminance ~149.9) under a
  # TITLED rule. Two independent signals prove emptiness: the glyph surviving
  # the ghost strip, and the UNSTRIPPED plain row carrying an agent glyph.
  # Drive them apart: with the luma threshold raised past the glyph's
  # luminance, the ghost strip erases it, and the verdict must survive on the
  # plain-row signal alone.
  local screen plain out
  screen=$'── Voice input (⌥ + v to start) ─────\n'"${ESC}[0m${ESC}[38;2;90;160;255m⟩${ESC}[0m"
  plain=$'── Voice input (⌥ + v to start) ─────\n⟩'
  assert_screen "muse idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "muse idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "muse idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "muse idle on cmux/orca" empty "$CAPS_PLAIN" "$plain"
  out=$(FM_COMPOSER_GHOST_LUMA_MAX=200 fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "muse must stay empty when the ghost strip eats its glyph (plain-row signal), got '$out'"
  pass "matrix: muse's ⟩ reads empty everywhere and survives losing the styled-glyph signal"
}

test_matrix_cursor_reverse_video_placeholder_remnant() {
  # Real idle cursor-agent (2026.08.11-e8db854), captured byte-for-byte from a
  # live pane: the `→ ` glyph and the placeholder tail are dim (SGR 2), but the
  # cell under the terminal cursor is REVERSE VIDEO (SGR 0;7). Reverse video is
  # neither dim nor a dark foreground, so the ghost stripper keeps that one
  # character and an idle composer reduces to a lone `P`.
  local row screen plain out stripped
  row="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mP"
  row="${row}${ESC}[0;2m${ESC}[48;2;21;21;21mlan, search, build anything${ESC}[0m"
  screen=$'transcript\n\n'"$row"
  plain=$'transcript\n\n  → Plan, search, build anything'

  # NON-VACUOUSNESS: prove the remnant really survives stripping. If the ghost
  # stripper ever learned SGR 7, `stripped` would be empty and the verdict below
  # would come from the empty-content path instead, silently retiring the
  # plain-row branch this case exists to cover.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = P ] \
    || fail "cursor's reverse-video remnant must survive ghost stripping as 'P', got '$stripped'"

  assert_screen "cursor idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "cursor idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  # An UNSTYLED capture carries no ghost-strip proof, so a bare row matching a
  # placeholder is indistinguishable from typed text and must stay unknown -
  # the same degradation every other bare-row placeholder already takes.
  assert_screen "cursor idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"

  # The dangerous direction: text a user actually TYPED is uniformly bright, so
  # stripping leaves it EQUAL to the plain row. Even when that text is exactly
  # the placeholder, it must stay pending - never a false empty.
  local typed typed_plain
  typed="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0m${ESC}[38;2;224;222;244mAdd a follow-up${ESC}[0m"
  typed_plain=$'transcript\n\n  → Add a follow-up'
  assert_screen "cursor typed placeholder text stays pending" pending \
    "$CAPS_STYLED" $'transcript\n\n'"$typed"
  # Without styling there is no proof either way, so it must not read empty.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$typed_plain")
  [ "$out" != empty ] \
    || fail "an unstyled cursor row matching the placeholder must not read empty, got '$out'"
  pass "matrix: cursor's reverse-video placeholder remnant reads empty; real typed text stays pending"
}

test_matrix_herdr_halfblock_rule_bounds_bare_wrap() {
  # Herdr draws a composer's rules with half-block glyphs (▄ above, ▀ below)
  # rather than the box-drawing family. Without treating those as edges, a bare
  # composer's WRAP region walks through its own closing rule and swallows the
  # footer, whose real content turns an idle pane into a false `pending`.
  # Captured live from a herdr cursor pane.
  local screen plain out
  plain=$'transcript\n ▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  # The closing rule must bound the region, so the footer below is not input.
  fm_composer_row_has_edge ' ▀▀▀' \
    || fail "a half-block rule row must count as a structural edge"
  fm_composer_row_has_edge ' ▄▄▄' \
    || fail "the upper half-block rule must count as a structural edge"
  # Non-vacuousness: the footer rows really are non-blank content that would be
  # swallowed if the rule did not bound the region.
  case "$plain" in *"Run Everything"*) : ;; *) fail "fixture lost its footer content" ;; esac
  ESC_LOCAL=$(printf '\033')
  screen=$'transcript\n ▄▄▄▄▄▄▄▄\n'"  ${ESC_LOCAL}[2m→ ${ESC_LOCAL}[0;7mA${ESC_LOCAL}[0;2mdd a follow-up${ESC_LOCAL}[0m"$'\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] \
    || fail "an idle cursor composer inside herdr half-block rules must read empty, got '$out'"
  pass "matrix: herdr half-block rules bound a bare composer's wrap region"
}

test_matrix_omp_status_row_bounds_bare_composer() {
  # omp (Oh My Pi) draws its status line directly BELOW the borderless `❯`
  # composer. Captured live through Herdr on omp 18.1.11 under the captain's
  # unicode preset (idle), plus the nerd-preset idle row and the busy spinner
  # row from the 18.1.2 investigation. Without the status-row rule the bare
  # wrap region swallows that row and an idle omp pane reads `pending`, which
  # skipped the doorbell on the first live omp worker.
  local idle_unicode idle_nerd busy typed wrapped
  idle_unicode=$'transcript line

❯
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  idle_nerd=$'transcript line

❯
 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K'
  busy=$'transcript line

  ⎋ Working…

❯
 ⠧ 11s  · ◔ GPT-6-Astra · ◫ 15.4%/272K'
  typed=$'transcript line

❯ fix the flaky test
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  # Non-vacuousness: each status row is real non-blank content that the wrap
  # region would otherwise take as typed input.
  _fm_composer_row_is_omp_status ' π  · ◔ GPT-6-Astra · 🌳 …-workspace' \
    || fail "the unicode-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K' \
    || fail "the nerd-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' ⠧ 11s  · ◔ GPT-6-Astra' \
    || fail "the busy omp spinner row must be recognized as furniture"
  _fm_composer_row_is_omp_status 'fix the flaky test' \
    && fail "ordinary typed text must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status 'please rerun the suite and report' \
    && fail "ordinary prose must not be mistaken for omp status furniture"
  # Only omp's identity cell opens the row: a wrapped typed row that happens
  # to begin with a short word and a spaced middle dot is composer input.
  _fm_composer_row_is_omp_status 'fix · tests before pushing' \
    && fail "wrapped typed text with a middle dot must not be mistaken for omp status furniture"
  # The ascii preset's identity cell is `pi`, but that preset separates its
  # cells with ` - `, so a row opening `pi ·` is never omp furniture.
  _fm_composer_row_is_omp_status 'pi · e · phi as the three constants' \
    && fail "typed text opening 'pi ·' must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status ' ⣾ 3s  · ◔ GPT-6-Astra' \
    || fail "the status-set omp spinner row must be recognized as furniture"
  assert_screen "idle omp (unicode preset)" empty "$CAPS_STYLED" "$idle_unicode"
  assert_screen "idle omp (nerd preset)" empty "$CAPS_STYLED" "$idle_nerd"
  assert_screen "busy omp keeps an empty composer" empty "$CAPS_STYLED" "$busy"
  assert_screen "typed omp text is pending" pending "$CAPS_STYLED" "$typed"
  assert_screen "idle omp on a plain capture" empty "$CAPS_PLAIN" "$idle_unicode"
  # The boundary must not cut a bare composer's own wrapped input: with the
  # cursor on a continuation row that opens `fix · tests`, the composer is a
  # proven wrap region and reads pending, exactly as it did before the rule.
  wrapped=$'transcript line\n\n❯ please run the suite and then\nfix · tests before pushing'
  assert_screen "wrapped typed text with a middle dot stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  wrapped=$'transcript line\n\n❯ document the constants in the order\npi · e · phi with one example each'
  assert_screen "wrapped typed text opening 'pi ·' stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  pass "matrix: omp's status row bounds the bare composer's wrap region"
}

test_matrix_omp_effort_hint_remnant() {
  # omp 18.4.10 draws cyan shortcut keys and a muted explanation on the
  # otherwise empty row. The keys survive the shared ghost extractor.
  local hint row screen typed plain out draft
  hint="${ESC}[38;2;0;180;255m⇧⇥${ESC}[38;2;229;229;231m ${ESC}[38;2;107;114;128mto change thinking effort"
  row="❯ ${ESC}[38;2;229;229;231m                                                   $hint"
  screen=$'transcript\n\n'"$row"$'\n π · ◔ GPT-6.1-Sol · ◫ 7.5%/272K'
  assert_screen "omp styled effort hint on tmux" empty "$CAPS_TMUX" "$screen" 2
  assert_screen "omp styled effort hint cursorless" empty "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] || fail "styled effort hint must extract no draft, got '$out'"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  assert_screen "omp unstyled hint has no emptiness proof" unknown "$CAPS_PLAIN" "$plain"
  out=$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$plain")
  [ "$out" = '⇧⇥ to change thinking effort' ] || fail "unstyled effort hint must remain extracted content, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" \
    $'╭────────────────────────╮\n│ ❯ '"$hint"$'\033[0m │\n╰────────────────────────╯')
  [ "$out" = '⇧⇥' ] || fail "boxed effort-like content must not gain bare-hint stripping, got '$out'"
  [ "$(classify 1 '❯ ⇧⇥ to change thinking effort' "$FM_COMPOSER_IDLE_RE_DEFAULT" \
    sensitive '❯ ⇧⇥ to change thinking effort' 1 0)" = pending ] \
    || fail "the effort hint must never become a plain boxed placeholder"
  typed="❯ ${ESC}[38;2;229;229;231m⇧⇥ to change thinking effort${ESC}[39m"
  assert_screen "typed complete hint stays pending" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "typed shortcut-only stays pending" pending "$CAPS_TMUX" '❯ ⇧⇥' 0
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$typed")
  [ "$out" = '⇧⇥ to change thinking effort' ] || fail "human full hint must survive extraction, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" '❯ ⇧⇥')
  [ "$out" = '⇧⇥' ] || fail "human shortcut keys must survive extraction, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" '❯ shift+tab to change thinking effort')
  [ "$out" = 'shift+tab to change thinking effort' ] || fail "generic shortcut text must survive extraction, got '$out'"
  draft="❯ ${ESC}[38;2;229;229;231mdo not discard this draft      $hint"
  assert_screen "draft before rendered hint cursorless" pending "$CAPS_STYLED_NOID" "$draft"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$draft")
  [ "$out" = 'do not discard this draft' ] || fail "only effort furniture must be removed beside a draft, got '$out'"
  draft="$draft"$'\n'"${ESC}[38;2;229;229;231mkeep this second line"
  assert_screen "wrapped draft with hint cursorless" pending "$CAPS_STYLED_NOID" "$draft"
  assert_screen "wrapped draft with hint cursor anchored" pending "$CAPS_TMUX" "$draft" 1
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$draft")
  [ "$out" = 'do not discard this draft keep this second line' ] || fail "wrapped draft extraction must omit only the effort hint, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" '❯ do not discard this draft')
  [ "$out" = 'do not discard this draft' ] || fail "hint disappearance must not change the extracted draft, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" '❯')
  [ -z "$out" ] || fail "hint disappearance must preserve empty extraction, got '$out'"
  draft="❯ ${ESC}[2mghost${ESC}[0m ⇧⇥ to change thinking effort"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$draft")
  [ "$out" = '⇧⇥ to change thinking effort' ] || fail "unrelated ghost text must not prove a bright human hint is furniture, got '$out'"
  assert_screen "draft before rendered hint stays pending" pending "$CAPS_TMUX" \
    "❯ ${ESC}[38;2;229;229;231mdo not discard this draft      $hint" 0
  assert_screen "multiline draft before hint stays pending" pending "$CAPS_TMUX" \
    "$row"$'\nkeep this second line' 1
  assert_screen "queued text resembling the hint stays pending" pending "$CAPS_STYLED_NOID" \
    $'Working…\n❯ ⇧⇥ to change thinking effort\n ⠧ 11s · ◔ GPT-6.1-Sol'
  assert_screen "busy activity below hint is not erased" pending "$CAPS_STYLED_NOID" \
    "$row"$'\nWorking on request...'
  assert_screen "slash popup remains unreadable" unknown "$CAPS_TMUX" \
    $'❯ /\n❯ ✦  skill:            37 skills\n  ❯ exit              Exit the application │' 0
  pass "omp effort hint needs styling proof; drafts, activity, and popups keep refusing"
}

# codex_cell <grey> <glyph>: one codex 0.154 starfield cell exactly as the
# harness draws it - a truecolor grey foreground, the composer's grey
# background, the braille glyph, then a reset.
codex_cell() {
  printf '%s[38;2;%s;%s;%sm%s[48;2;57;57;57m%s%s[0m' "$ESC" "$1" "$1" "$1" "$ESC" "$2" "$ESC"
}

# omp's `box` composer shape: the status line rides the TOP border and the
# editor's last row is folded into the bottom border (`╰─ text ─╯`). This is the
# screen 11 idle omp workers drew after live-reloading an overlay file that no
# longer pinned `borderless` (task fm-omp-composer-unknown-blocks-control);
# every verdict read `unknown`, which stopped fm-control exit and relaunch.
# The captured screen is the task's own capture; the rest are real omp 18.6.3
# captures through Herdr (typed text, wrapped rows, the empty-row hint).
omp_box_top() {
  printf '%s' '╭── π > ◒ GPT-6.1-Sol 🙈 > 🌳 firstmate/firstmate > ⑂ fm/fm-model-index > S1.95 + 👁 1.11 ▶─────────────38%─────────╎──┃────272K─◀ ⚙ 1 < Implement fleet model index < 🆔 01a111e1 ──╮'
}

omp_box_last() {  # <editor text>
  printf '╰─ %-176s ─╯' "$1"
}

test_matrix_omp_box_composer() {
  local top captured typed multi hint styled_hint styled_typed multi_hint
  top=$(omp_box_top)
  captured=$'⚠ Operation aborted

 TODO
  ├─ II. Validate · 0/1
  │  └─ ☐ Drive no-mistakes through every gate to CI readiness
  ├─ III. Deliver · 0/1
  └─────

  F5 to retry

'"$top"$'
╰─                                                                                                                                                                                 ─╯'
  # The captured idle worker: an empty editor reads empty on every profile.
  assert_screen "omp box idle on herdr" empty "$CAPS_STYLED" "$captured" '' probe-absent
  assert_screen "omp box idle on zellij" empty "$CAPS_STYLED_NOID" "$captured"
  assert_screen "omp box idle on cmux/orca" empty "$CAPS_PLAIN" "$captured"
  # Typed text is pending (the plain profile cannot be fooled either: a bordered
  # row reads pending without ghost proof).
  typed=$'transcript\n\n'"$top"$'\n'"$(omp_box_last 'hello world typed text')"
  assert_screen "omp box typed on herdr" pending "$CAPS_STYLED" "$typed" '' probe-absent
  assert_screen "omp box typed on plain backends" pending "$CAPS_PLAIN" "$typed"
  multi=$'transcript\n\n'"$top"$'\n│  first line'"$(printf '%*s' 160 '')"$'│\n'"$(omp_box_last '')"
  assert_screen "omp box draft in an upper row" pending "$CAPS_STYLED" "$multi" '' probe-absent
  # omp's box draws no prompt glyph, so a typed glyph is text, never an empty
  # composer (the shared bordered rule would have read `>` as empty).
  assert_screen "omp box typed >" pending "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n'"$(omp_box_last '>')" '' probe-absent
  assert_screen "omp box typed ❯" pending "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n'"$(omp_box_last '❯')" '' probe-absent
  assert_screen "omp box typed dash" pending "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n'"$(omp_box_last '─')" '' probe-absent
  hint=$'transcript\n\n'"$top"$'\n╰─'"$(printf '%*s' 60 '')"$'⇧⇥ to change thinking effort ─╯'
  assert_screen "omp box unstyled hint stays ambiguous" unknown "$CAPS_PLAIN" "$hint"
  assert_screen "omp box unstyled hint with cursor" unknown \
    $'styled=0\ncursor=1\nidentity=1' "$hint" 3 probe-absent
  styled_hint=$'transcript\n\n'"$top"$'\n'"${ESC}[0m${ESC}[38;2;0;180;255m╰─ ${ESC}[0m${ESC}[38;2;229;229;231m$(printf '%*s' 60 '')${ESC}[0m${ESC}[38;2;0;180;255m⇧⇥${ESC}[0m${ESC}[38;2;229;229;231m ${ESC}[0m${ESC}[3m${ESC}[38;2;107;114;128mto change thinking effort${ESC}[0m${ESC}[38;2;0;180;255m ─╯"
  assert_screen "omp box styled hint" empty "$CAPS_STYLED" "$styled_hint" '' probe-absent
  styled_typed=$'transcript\n\n'"$top"$'\n'"${ESC}[0m${ESC}[38;2;0;180;255m╰─ ${ESC}[0m${ESC}[38;2;229;229;231m⇧⇥ to change thinking effort${ESC}[0m${ESC}[38;2;0;180;255m ─╯"
  assert_screen "omp box whole hint typed bright" pending "$CAPS_STYLED" "$styled_typed" '' probe-absent
  assert_screen "omp box hint loses proof without styling" unknown "$CAPS_PLAIN" "$styled_hint"
  assert_screen "omp box styled hint with cursor" empty "$CAPS_TMUX" "$styled_hint" 3 probe-absent
  [ "$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$hint")" = '⇧⇥ to change thinking effort' ] \
    || fail "omp box plain extraction must preserve ambiguous hint-like text"
  [ "$(fm_composer_extract_selected_content "$CAPS_STYLED" "$styled_typed")" = '⇧⇥ to change thinking effort' ] \
    || fail "omp box styled extraction must preserve a bright typed hint"
  multi_hint=$'transcript\n\n'"$top"$'\n│ first line │\n'"$(omp_box_last '⇧⇥ to change thinking effort')"
  assert_screen "omp box draft precedes ambiguous last row" pending "$CAPS_PLAIN" "$multi_hint"
  [ "$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$multi_hint")" = 'first line ⇧⇥ to change thinking effort' ] \
    || fail "omp box extraction must preserve both the upper draft and ambiguous last row"
  [ "$(fm_composer_extract_selected_content "$CAPS_STYLED" "$styled_hint")" = '' ] \
    || fail "omp box extraction must drop the empty-row hint"
  [ "$(fm_composer_extract_selected_content "$CAPS_STYLED" "$typed")" = 'hello world typed text' ] \
    || fail "omp box extraction must return the typed text without its borders"
  # Cursor mode (tmux): the cursor sits on the folded last row.
  assert_screen "omp box idle on tmux" empty "$CAPS_TMUX" "$captured" 11 probe-absent
  assert_screen "omp box typed on tmux" pending "$CAPS_TMUX" "$typed" 3 probe-absent
  pass "matrix: omp's box composer (status in the top border, folded last row) reads empty, pending, and never a typed glyph as empty"
}

# While a turn runs, omp's box top border carries a spinner frame and the elapsed
# time where the idle border carries its identity glyph. These are real omp
# 18.6.3 captures through Herdr of a worker running `sleep 60`: the empty
# composer, a draft typed while the turn ran, and the same draft wrapped onto a
# second row. Reading the border as unknown hid a typed line that never
# submitted from every busy caller.
omp_box_busy_top() {  # <spinner> <elapsed>
  printf '╭── %s %s > ◔ GPT-6-Astra 👁 > 🗑 …lab.m13m2O/project > ⑂ fm/fm-omp-lane-wake-unsubmitted *7 > S0.27 + 👁 0.05 ▶─7%%─┃272K───╮' "$1" "$2"
}

test_omp_box_busy_status_border_reads_the_composer() {
  local busy empty_last typed wrapped frame elapsed
  busy=$'transcript\n\n  ⎋ Waiting requested sixty seconds\n\n'
  empty_last=$(omp_box_last '')
  assert_screen "omp busy box empty on herdr" empty "$CAPS_STYLED" \
    "$busy$(omp_box_busy_top ⠦ 13s)"$'\n'"$empty_last" '' probe-absent
  assert_screen "omp busy box empty on plain backends" empty "$CAPS_PLAIN" \
    "$busy$(omp_box_busy_top ⠦ 13s)"$'\n'"$empty_last"
  typed=$busy$(omp_box_busy_top ⠦ 13s)$'\n'$(omp_box_last 'half typed draft while busy')
  assert_screen "omp busy box typed on herdr" pending "$CAPS_STYLED" "$typed" '' probe-absent
  assert_screen "omp busy box typed on plain backends" pending "$CAPS_PLAIN" "$typed"
  [ "$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$typed")" = 'half typed draft while busy' ] \
    || fail "omp busy box extraction must return the typed draft"
  wrapped=$busy$(omp_box_busy_top ⠹ 16s)$'\n│  half typed draft while busy and a long wrapped continuation that goes on and on and on and on  │\n'$(omp_box_last 'on and on and on and on')
  assert_screen "omp busy box wrapped draft" pending "$CAPS_STYLED" "$wrapped" '' probe-absent
  # Every spinner frame and a minutes-long elapsed cell keep the identity.
  for frame in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷; do
    assert_screen "omp busy box frame $frame" empty "$CAPS_STYLED" \
      "$busy$(omp_box_busy_top "$frame" 5s)"$'\n'"$empty_last" '' probe-absent
  done
  for elapsed in 59s 1m3s 2h5m; do
    assert_screen "omp busy box elapsed $elapsed" empty "$CAPS_STYLED" \
      "$busy$(omp_box_busy_top ⠧ "$elapsed")"$'\n'"$empty_last" '' probe-absent
  done
  pass "matrix: omp's box composer is readable while a turn runs (spinner and elapsed time in the top border), so a typed line that never submitted reads pending"
}

test_omp_box_working_renders_match_delivery_busy() {
  local top empty typed wrapped screen frame elapsed separator harness invalid
  local waiting=$'  ⎋ Waiting requested sixty seconds'
  top=$(omp_box_busy_top ⠦ 13s)
  empty=$'transcript\n\n'"$waiting"$'\n\n'"$top"$'\n'"$(omp_box_last '')"
  typed=$'transcript\n\n'"$waiting"$'\n\n'"$top"$'\n'"$(omp_box_last 'half typed draft while busy')"
  wrapped=$'transcript\n\n'"$waiting"$'\n\n'"$(omp_box_busy_top ⠹ 16s)"$'\n│  half typed draft while busy and a long wrapped continuation that goes on and on and on and on  │\n'"$(omp_box_last 'on and on and on and on')"
  for screen in "$top" "$waiting" "$empty" "$typed" "$wrapped"; do
    for harness in omp ''; do
      printf '%s\n' "$screen" | fm_busy_lines_match "$harness" \
        || fail "omp working render must match delivery busy for harness '$harness': $screen"
    done
    for harness in claude devin codex opencode pi pi-signed grok agy kimi cursor unregistered; do
      if printf '%s\n' "$screen" | fm_busy_lines_match "$harness"; then
        fail "omp working render must not match another harness '$harness': $screen"
      fi
    done
  done
  for frame in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷; do
    for elapsed in 59s 1m3s 2h5m; do
      for separator in '>' '·'; do
        top=$(omp_box_busy_top "$frame" "$elapsed")
        top=${top/ > / $separator }
        for harness in omp ''; do
          printf '%s\n' "$top" | fm_busy_lines_match "$harness" \
            || fail "omp busy border $frame $elapsed $separator must match delivery busy for harness '$harness'"
        done
      done
    done
  done
  for invalid in \
    "$(omp_box_top)" \
    '╭── 13s > ◔ GPT-6-Astra ──╮' \
    '╭── ⠦ > ◔ GPT-6-Astra ──╮' \
    '╭── ⠦ 13s ◔ GPT-6-Astra ──╮' \
    '╭── x 13s > ◔ GPT-6-Astra ──╮'; do
    for harness in omp ''; do
      if printf '%s\n' "$invalid" | fm_busy_lines_match "$harness"; then
        fail "idle or incomplete omp border must not match delivery busy for harness '$harness': $invalid"
      fi
    done
  done
  pass "omp working borders and waiting rows are delivery busy independently of empty or pending composer contents"
}

test_omp_box_requires_omp_identity_and_complete_shape() {
  local top empty_last
  top=$(omp_box_top)
  empty_last=$(omp_box_last '')
  # Only omp's own status identity proves the container; an arbitrary titled
  # rounded border, a spinner with no elapsed cell, or the ascii preset's `pi`
  # stays an unprovable shape and reads unknown, never empty.
  assert_screen "titled non-omp border" unknown "$CAPS_STYLED" \
    $'transcript\n\n╭── some other title ──╮\n'"$empty_last" '' probe-absent
  assert_screen "spinner without an elapsed cell" unknown "$CAPS_STYLED" \
    $'transcript\n\n╭── ⠧ > ◒ GPT-6.1-Sol ──╮\n'"$empty_last" '' probe-absent
  assert_screen "elapsed cell without a spinner" unknown "$CAPS_STYLED" \
    $'transcript\n\n╭── 11s > ◒ GPT-6.1-Sol ──╮\n'"$empty_last" '' probe-absent
  assert_screen "omp ascii-preset status" unknown "$CAPS_STYLED" \
    $'transcript\n\n╭── pi - GPT-6.1-Sol ──╮\n'"$empty_last" '' probe-absent
  # A bare rule closing the box is not the folded last row.
  assert_screen "bare rule bottom" unknown "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n╰'"$(printf '─%.0s' $(seq 1 60))"$'╯' '' probe-absent
  # A broken interior (blank row, shifted indent) is not a proven box.
  assert_screen "blank row inside the box" unknown "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n\n'"$empty_last" '' probe-absent
  assert_screen "shifted side-border indent" unknown "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n │'"$(printf '%*s' 60 '')"$'│\n'"$empty_last" '' probe-absent
  # Anything live below the box makes it stale, and a newer shape outranks it.
  assert_screen "activity below the box" unknown "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n'"$empty_last"$'\nsome later activity' '' probe-absent
  assert_screen "dead shell below the box" unknown "$CAPS_STYLED" \
    $'transcript\n\n'"$top"$'\n'"$empty_last"$'\n$ ls -la' '' probe-absent
  assert_screen "cursor outside the box" unknown "$CAPS_TMUX" \
    $'transcript\n\n'"$top"$'\n'"$empty_last" 0 probe-absent
  pass "matrix: an omp box needs omp's status identity and a complete shape; every other variant reads unknown"
}

test_matrix_codex_idle_starfield_furniture() {
  # Real idle codex-cli 0.154.0 (gpt-6-astra, fast mode) captured byte-for-byte
  # through Herdr (`pane read --format ansi`) from the first codex second mate:
  # an animated braille "starfield" on the row above the bold `›`, on the `›`
  # row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on
  # the row below, then a bright model/path/title status footer. The cells are
  # truecolor greys on BOTH sides of the 128 ghost-luma ceiling, so the
  # brighter ones survive the ghost strip, and the rows below the glyph carry
  # no structural edge. The bare shape therefore extended its wrap region over
  # the two rows beneath the glyph and read the survivors as wrapped typed
  # input: `pending`, which deferred every steering doorbell for that pane.
  local bg="${ESC}[48;2;57;57;57m" above glyph glyph2 below footer
  local screen screen2 plain plain2 ascii_screen stripped out
  above="${ESC}[0m${bg}                         ${ESC}[0m$(codex_cell 82 ⢀)${bg}      ${ESC}[0m$(codex_cell 136 ⠂)${bg} ${ESC}[0m$(codex_cell 163 ⠄)${bg}     ${ESC}[0m$(codex_cell 118 ⠈)"
  glyph="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m${bg} ${ESC}[0m${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 117 ⡀)${bg}  ${ESC}[0m$(codex_cell 88 ⠈)${bg}       ${ESC}[0m$(codex_cell 156 ⠂)${bg}        ${ESC}[0m$(codex_cell 71 ⠁)$(codex_cell 161 ⠐)${bg} ${ESC}[0m$(codex_cell 165 ⠁)"
  # A second live sample of the same pane, minutes later: the animation had
  # placed a bright cell BETWEEN the glyph and the placeholder.
  glyph2="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m$(codex_cell 138 ⠁)${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 163 ⡀)${bg}  ${ESC}[0m$(codex_cell 132 ⠈)"
  below="${ESC}[0m${bg}        ${ESC}[0m$(codex_cell 101 ⠐)${bg}    ${ESC}[0m$(codex_cell 111 ⠄)${bg}   ${ESC}[0m$(codex_cell 165 ⠠)${bg}  ${ESC}[0m$(codex_cell 121 ⢀)$(codex_cell 122 ⠠)$(codex_cell 81 ⡀)$(codex_cell 150 ⠄⠂)"
  footer="  ${ESC}[0m${ESC}[38;2;246;226;183mgpt-6-astra high fast${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;171;223;167m~/Projects/purser${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;156;222;211mLaunch Purser desk brief${ESC}[0m"
  screen=$'transcript line\n\n'"$above"$'\n'"$glyph"$'\n'"$below"$'\n'"$footer"
  screen2=$'transcript line\n\n'"$above"$'\n'"$glyph2"$'\n'"$below"$'\n'"$footer"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  plain2=$(printf '%s\n' "$screen2" | fm_composer_strip_ansi)

  # NON-VACUOUSNESS: the ghost strip really leaves braille survivors behind the
  # placeholder and on the row below (cells above the luma ceiling), and the
  # footer really is non-blank, edge-free content the wrap region would take.
  stripped=$(printf '%s\n' "$glyph" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" != '›' ] \
    || fail "the glyph row's starfield cells must survive ghost stripping, or the furniture case is vacuous"
  stripped=$(printf '%s\n' "$stripped" | fm_composer_strip_braille)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = '›' ] \
    || fail "everything surviving ghost stripping behind the glyph must be braille, got '$stripped'"
  stripped=$(printf '%s\n' "$below" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ -n "$stripped" ] \
    || fail "the row below the glyph must keep starfield cells after ghost stripping"
  _fm_composer_row_is_braille_furniture "$stripped" \
    || fail "the row below the glyph must be recognized as braille furniture"
  fm_composer_row_has_edge '  gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief' \
    && fail "fixture drift: the footer must carry no structural edge, or the boundary rule is untested"

  # The verdicts: empty wherever styling can prove the placeholder ghost, on
  # both live samples, in both locales; unknown (never pending) on a plain
  # capture, exactly as the codex dim-hint row above.
  assert_screen "codex 0.154 idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "codex 0.154 idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "codex 0.154 idle on tmux (cursor on the glyph row)" empty "$CAPS_TMUX" "$screen" 3
  assert_screen "codex 0.154 idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"
  assert_screen "codex 0.154 idle (second sample) on herdr" empty "$CAPS_STYLED" "$screen2"
  assert_screen "codex 0.154 idle (second sample) on tmux" empty "$CAPS_TMUX" "$screen2" 3
  assert_screen "codex 0.154 idle (second sample) on cmux/orca" unknown "$CAPS_PLAIN" "$plain2"
  # A cursor parked on the starfield row below the glyph is not inside a wrap
  # region, so the strict blank-row posture keeps it unknown.
  assert_screen "codex 0.154 cursor on the starfield row" unknown "$CAPS_TMUX" "$screen" 4

  # DIVERGENCE: the same screen with every starfield cell replaced by a letter
  # is wrapped typed input and must stay pending, so the furniture verdict
  # above cannot come from anything but the braille rule.
  ascii_screen=$(printf '%s\n' "$screen" | LC_ALL=C sed 's/⢀/x/g; s/⠂/x/g; s/⠄/x/g; s/⠈/x/g; s/⡀/x/g; s/⠁/x/g; s/⠐/x/g; s/⠠/x/g')
  case "$ascii_screen" in *'⠂'*|*'⠁'*) fail "fixture drift: the divergence screen still carries braille" ;; esac
  assert_screen "starfield replaced by letters on herdr" pending "$CAPS_STYLED" "$ascii_screen"
  assert_screen "starfield replaced by letters on tmux" pending "$CAPS_TMUX" "$ascii_screen" 3

  # NEGATIVES that keep the rule from over-stripping:
  # (i) a real message wrapped below the `›` row, footer beneath, stays pending.
  out=$'transcript line\n\n› please run the suite and then\ncontinue with the docs\n'"$footer"
  assert_screen "wrapped typed input above the codex footer on herdr" pending "$CAPS_STYLED" "$out"
  assert_screen "wrapped typed input above the codex footer on tmux" pending "$CAPS_TMUX" "$out" 3
  # (ii) braille mixed with typed text is typed text, on the glyph row and on
  # a wrapped row alike.
  assert_screen "braille mixed into the glyph row" pending "$CAPS_STYLED" $'transcript line\n\n› fix ⠂ the tests'
  assert_screen "braille mixed into a wrapped row" pending "$CAPS_STYLED" $'transcript line\n\n› please\nfix ⠂ the tests'
  # (iii) a typed row carrying a spaced middle dot is composer input.
  assert_screen "wrapped typed row with a middle dot on herdr" pending "$CAPS_STYLED" $'transcript line\n\n› deploy\nfix · tests before pushing'
  assert_screen "wrapped typed row with a middle dot on tmux" pending "$CAPS_TMUX" $'transcript line\n\n› deploy\nfix · tests before pushing' 3
  # (iv) the footer or a starfield row alone, with no bare glyph above, gains
  # no new verdict: still no container proof.
  assert_screen "codex footer alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$footer"
  assert_screen "codex footer alone on tmux" unknown "$CAPS_TMUX" $'transcript line\n\n'"$footer" 2
  assert_screen "starfield row alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$below"
  pass "matrix: codex 0.154's starfield rows are furniture; typed, mixed, and unanchored rows keep their verdicts"
}

test_matrix_pi_separated_needs_identity() {
  # Real idle pi: a blank row between two solid rules. The blank row alone is
  # exactly what the strict rule refuses; only structure PLUS a live
  # idle/done pi identity proves the composer (herdr's rule, now
  # fleet-wide; tmux supplies identity from its foreground-process probe).
  local screen typed pi_idle pi_working pi_blocked none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  pi_blocked=$(printf 'pi\tblocked')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  # Identity-capable but unfetched: the adapter is asked to probe lazily.
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  # No identity capability (cmux/orca/zellij): the shape is unprovable.
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  # A working pi cannot authorize injection into the blank region.
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  # A pi parked on an interactive prompt reports `blocked`: it is waiting on a
  # human keystroke, so the blank region is a menu's, not a free composer's.
  # Typing there answers the prompt and the text is discarded (issue #2797).
  assert_screen "blocked pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_blocked"
  # The audit's live counterexample: a plain shell running sleep, cursor
  # parked on a blank line between two rules, NO pi process. The permissive
  # rule read this `empty`; identity+structure refuses it.
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: pi's separated composer needs identity + structure; the blank row alone never proves it"
}

test_pi_literal_omp_floor_with_blank_continuation() {
  local draft expected screen prefix caps styled cursor row out
  for prefix in '' $'╭── π > model > path ─╮\n╰─  ─╯\n'; do
    row=2
    [ -z "$prefix" ] || row=4
    for draft in '╰─ ─╯' '╰─  ─╯' '╰─ ⇧⇥ to change thinking effort ─╯'; do
      expected=${draft//'  '/' '}
      screen="${prefix}"$'────────\n'"$draft"$'\n\n────────'
      for styled in 0 1; do
        for cursor in 0 1; do
          caps=$(printf 'styled=%s\ncursor=%s\nidentity=1' "$styled" "$cursor")
          assert_screen "Pi literal omp floor, styled=$styled cursor=$cursor continuation=$row" \
            pending "$caps" "$screen" "$row" $'pi\tidle'
        done
        out=$(fm_composer_extract_selected_content "styled=$styled" "$screen")
        [ "$out" = "$expected" ] \
          || fail "Pi extraction must preserve normalized literal omp floor '$expected', got '$out'"
        out=$(LC_ALL=C fm_composer_extract_selected_content "styled=$styled" "$screen")
        [ "$out" = "$expected" ] \
          || fail "Pi extraction under LC_ALL=C must preserve normalized literal omp floor '$expected', got '$out'"
      done
    done
  done
  screen=$'────────\n╰─  ─╯\n\n────────\n╭────────────────────────╮\n│ clipped draft'
  assert_screen "incomplete box below Pi still refuses injection" unknown "$CAPS_STYLED" "$screen" '' $'pi\tidle'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen"); then
    fail "an incomplete box below Pi must refuse extraction, got '$out'"
  fi
  pass "Pi floor-looking drafts stay pending on blank continuation rows and survive extraction"
}

test_pi_nested_omp_box_preserves_enclosing_draft() {
  local frame screen expected prefix suffix caps styled cursor row last out
  for frame in $'╭── π > model > path ─╮\n╰─  ─╯' \
               $'╭── π > model > path ─╮\n╰─ ⇧⇥ to change thinking effort ─╯'; do
    for prefix in '' $'before the literal frame\n'; do
      suffix=''
      [ -z "$prefix" ] || suffix=$'\nafter the literal frame'
      screen=$'────────\n'"${prefix}${frame}${suffix}"$'\n\n────────'
      last=$(printf '%s\n' "$screen" | awk 'END {print NR - 1}')
      expected=$(printf '%s\n' "${prefix}${frame}${suffix}" | LC_ALL=C awk '{$1=$1; printf "%s%s", sep, $0; sep=" "}')
      for styled in 0 1; do
        for cursor in 0 1; do
          caps=$(printf 'styled=%s\ncursor=%s\nidentity=1' "$styled" "$cursor")
          row=1
          while [ "$row" -lt "$last" ]; do
            assert_screen "nested omp-looking Pi draft, styled=$styled cursor=$cursor row=$row" \
              pending "$caps" "$screen" "$row" $'pi\tidle'
            assert_screen "nested Pi draft requests identity, styled=$styled cursor=$cursor row=$row" \
              need-identity "$caps" "$screen" "$row"
            assert_screen "nested Pi draft without probe, styled=$styled cursor=$cursor row=$row" \
              unknown-draft "$caps" "$screen" "$row" probe-absent
            assert_screen "nested Pi draft with foreign identity, styled=$styled cursor=$cursor row=$row" \
              unknown-draft "$caps" "$screen" "$row" $'zsh\t'
            assert_screen "nested Pi draft without capability, styled=$styled cursor=$cursor row=$row" \
              unknown-draft "$(printf 'styled=%s\ncursor=%s\nidentity=0' "$styled" "$cursor")" "$screen" "$row"
            row=$((row + 1))
          done
          out=$(fm_composer_extract_selected_content "$caps" "$screen")
          [ "$out" = "$expected" ] \
            || fail "nested Pi extraction must preserve '$expected', got '$out'"
          out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
          [ "$out" = "$expected" ] \
            || fail "nested Pi extraction under LC_ALL=C must preserve '$expected', got '$out'"
        done
        caps=$(printf 'styled=%s\ncursor=0\nidentity=0' "$styled")
        assert_screen "nested omp-looking box without Pi identity capability" unknown-draft "$caps" "$screen"
      done
      assert_screen "real omp below a Pi draft still wins" empty "$CAPS_STYLED_NOID" \
        "$screen"$'\n╭── π > model > path ─╮\n╰─  ─╯'
      row=2
      [ -z "$prefix" ] || row=3
      # The cursor's own pair is the composer: its owned draft reads pending,
      # and a later empty pair can neither restore emptiness nor veto it.
      assert_screen "later Pi pair cannot restore an earlier nested omp proof" pending "$CAPS_TMUX" \
        "$screen"$'\n\n────────' "$row" $'pi\tidle'
      assert_screen "earlier cursor retains nested native risk with denied identity" unknown-draft "$CAPS_TMUX" \
        "$screen"$'\n\n────────' "$row" probe-absent
      assert_screen "later empty pair does not inherit native risk" unknown "$CAPS_STYLED_NOID" \
        "$screen"$'\n\n────────'
      assert_screen "later empty Pi pair remains the cursorless composer" empty "$CAPS_STYLED" \
        "$screen"$'\n\n────────' '' $'pi\tidle'
      out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen"$'\n\n────────')
      [ -z "$out" ] || fail "later empty Pi composer must not extract an earlier draft, got '$out'"
    done
  done
  screen=$'────────\n╭── π > model > path ─╮\n╰─ ─╯\n\n────────'
  assert_screen "one-space nested floor remains a cursorless Pi draft" pending \
    "$CAPS_STYLED" "$screen" '' $'pi\tidle'
  for caps in "$CAPS_TMUX" $'styled=0\ncursor=1\nidentity=1'; do
    out=$(fm_composer_classify_screen "$caps" "$screen" 2 $'pi\tidle')
    [ "$out" != empty ] || fail "cursor on an unproven nested floor must never authorize injection"
    out=$(LC_ALL=C fm_composer_classify_screen "$caps" "$screen" 2 $'pi\tidle')
    [ "$out" != empty ] || fail "cursor on an unproven nested floor must never authorize injection under LC_ALL=C"
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = '╭── π > model > path ─╮ ╰─ ─╯' ] \
      || fail "one-space nested floor extraction lost the enclosing Pi draft: '$out'"
  done
  pass "nested omp-looking boxes remain Pi drafts for cursor, cursorless and extraction consumers"
}

test_matrix_pi_dollar_status_footer_is_empty() {
  # Pi's status row `$0.000 (sub) 5.4%/272k (auto)` at column 0 used to read
  # as a dead-shell prompt, so an idle separated composer classified unknown.
  # A counters-first footer never took that path. A real `$` or `$ ls` prompt,
  # and the same cost string typed between the separators, still refuse.
  local dollar typed dead_shell dead_cmd spaced footer_only inside wrap dollar_status
  local pi_idle pi_working none out
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  dollar_status=$'$0.000 (sub) 5.4%/272k (auto)'
  dollar=$'transcript\n────────────────────────\n\n────────────────────────\n'"$dollar_status"

  assert_screen "pi dollar-first status on herdr" empty "$CAPS_STYLED" "$dollar" '' "$pi_idle"
  assert_screen "pi dollar-first status on tmux" empty "$CAPS_TMUX" "$dollar" 2 "$pi_idle"

  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$dollar")" = need-identity ] \
    || fail "a dollar-first Pi footer must still request the lazy identity probe"
  assert_screen "dollar-first status without identity capability" unknown "$CAPS_PLAIN" "$dollar"
  assert_screen "working pi with dollar-first status defers" unknown \
    "$CAPS_STYLED" "$dollar" '' "$pi_working"
  assert_screen "non-pi identity with dollar-first status defers" unknown \
    "$CAPS_STYLED" "$dollar" '' "$none"

  typed=$'────────────────────────\nfix the flaky test\n────────────────────────\n'"$dollar_status"
  assert_screen "pi typed text above dollar-first status" pending \
    "$CAPS_STYLED" "$typed" '' "$pi_idle"
  inside=$'────────────────────────\n'"$dollar_status"$'\n────────────────────────'
  assert_screen "dollar-first string typed into the pi composer" pending \
    "$CAPS_STYLED" "$inside" '' "$pi_idle"

  dead_shell=$'transcript\n────────────────────────\n\n────────────────────────\n$'
  dead_cmd=$'transcript\n────────────────────────\n\n────────────────────────\n$ ls -la'
  spaced=$'transcript\n────────────────────────\n\n────────────────────────\n$ 0.000 (sub)'
  assert_screen "real dead shell below a pi pair" unknown "$CAPS_STYLED" "$dead_shell" '' "$pi_idle"
  assert_screen "dead-shell command below a pi pair" unknown "$CAPS_STYLED" "$dead_cmd" '' "$pi_idle"
  assert_screen "spaced dollar below a pi pair" unknown "$CAPS_STYLED" "$spaced" '' "$pi_idle"

  footer_only=$'transcript\n'"$dollar_status"
  assert_screen "dollar-first status with no pi pair" unknown \
    "$CAPS_STYLED" "$footer_only" '' "$pi_idle"

  wrap=$'❯\n$ ls -la'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$wrap")
  [ "$out" = unknown ] \
    || fail "a real dead shell below a bare glyph must still invalidate cursorless selection, got '$out'"
  wrap=$'❯\n$ '
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$wrap")
  [ "$out" = unknown ] \
    || fail "a bare dollar prompt below a glyph must still invalidate cursorless selection, got '$out'"
  pass "matrix: a dollar-first pi status footer reads empty; dead shells still refuse"
}

test_matrix_opencode_leftbar_signals() {
  # Real idle opencode: `┃`-prefixed rows holding an "Ask anything" hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen captured_idle captured_pending out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # This sanitized live OpenCode 1.18.30 capture preserves its U+2026 hint and
  # RGB 128 styling. RGB 128 is deliberately outside the ghost threshold, so
  # the placeholder spelling is the independent empty signal. The completed-
  # turn row above the active composer also pins the incident's idle layout.
  captured_idle=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;128;128;128mAsk anything… \"Fix a TODO in the codebase\"${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn idle hint on tmux" empty "$CAPS_TMUX" "$captured_idle" 3
  captured_pending=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;255;255;255mReply with OK.${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn typed composer on tmux" pending "$CAPS_TMUX" "$captured_pending" 3
  # Signal separation: with the idle pattern overridden to something that
  # cannot match, a DIM-styled hint still proves empty through the ghost strip.
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via the ghost strip alone, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: opencode's left-bar composer reads empty everywhere and scans the full active run"
}

test_matrix_grok_titled_bottom_border() {
  # Grok 1.0.5 widened its titled BOTTOM border three columns past the top and
  # content rows. This is the idle capture from issue #3436; Herdr has no
  # cursor anchor, so the geometry mismatch used to make the proven box
  # ambiguous and the verdict unknown, stranding away-mode injection.
  local titled plain_border typed malformed placeholder_draft
  titled=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯\n\n  Shift+Tab:mode  │  Ctrl+x:shortcuts'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "issue #3436 idle grok 1.0.5 on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ Type a message...                                                      │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ deploy the fix                                                         │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "grok typed on herdr" pending "$CAPS_STYLED" "$typed"
  malformed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── unknown surface ─╯'
  assert_screen "oversized unknown title on herdr" unknown "$CAPS_STYLED" "$malformed"
  pass "matrix: grok's real oversized titled bottom is empty while typed and unproved panes stay safe"
}

test_matrix_claude_titled_top_rule() {
  # A named Claude Code session draws its title into the composer's TOP rule
  # (issues #5601 and #5558; observed on herdr as
  # `─── Firstmate operational input 1790546042 ─`). The strict separator
  # predicate rejects that row, so the pair never opened, the closing rule
  # read as a lower unmatched separator, and a visibly empty composer read
  # `unknown` on every cursorless backend, refusing steers, exit, and relaunch.
  local rule title top bottom footer screen ansi typed claude_idle
  local scrollback short nonascii flush blank
  claude_idle=$(printf 'claude\tidle')
  rule='────────────────────────────────────────────────────────────'
  title=' Firstmate operational input 1790546042 '
  top="${rule}───${title}─"
  bottom="${rule}────────────────────────────────────────────"
  footer='  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  screen="recap: earlier work"$'\n'"$top"$'\n❯'"$NBSP"$'\n'"$bottom"$'\n'"$footer"
  ansi="${ESC}[38;2;128;130;131mrecap: earlier work${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;121;129;134m${rule}─── ${ESC}[38;2;177;185;249m${title# }${ESC}[38;2;121;129;134m─${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;128;130;131m❯${NBSP}${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;121;129;134m${bottom}${ESC}[0m"$'\n'"$footer"
  assert_screen "titled claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "titled claude idle on herdr (ansi)" empty "$CAPS_STYLED" "$ansi" '' "$claude_idle"
  assert_screen "titled claude idle on zellij (ansi)" empty "$CAPS_STYLED_NOID" "$ansi"
  assert_screen "titled claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "titled claude idle on tmux" empty "$CAPS_TMUX" "$ansi" 2 probe-absent
  typed="$top"$'\n❯ fix the login bug\n'"$bottom"$'\n'"$footer"
  assert_screen "titled claude typed on herdr" pending "$CAPS_STYLED" "$typed" '' "$claude_idle"
  assert_screen "titled claude typed on zellij" pending "$CAPS_STYLED_NOID" "$typed"
  assert_screen "titled claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  assert_screen "titled claude typed on plain backends" pending "$CAPS_PLAIN" "$typed"
  # The staleness rule still holds: a titled sandwich stranded in scrollback,
  # with transcript rows between it and a lower unmatched rule, stays unknown.
  scrollback="$top"$'\n❯'"$NBSP"$'\n'"$bottom"$'\nlater transcript output\n'"$bottom"$'\nmore output'
  assert_screen "titled sandwich in scrollback" unknown "$CAPS_STYLED_NOID" "$scrollback"
  # Width is proven, not assumed: a titled rule narrower than its closing rule
  # is not that composer's top edge.
  short="${rule}${title}─"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "mismatched titled rule width" unknown "$CAPS_STYLED_NOID" "$short"
  # A non-ASCII title leaves residue and refuses rather than guessing width.
  nonascii="${rule}─── ✳ Firstmate operational input 179054604 ─"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "non-ASCII titled rule" unknown "$CAPS_STYLED_NOID" "$nonascii"
  # The rule must open with the strict separator's dash run.
  flush=" Firstmate operational input 1790546042 ${rule}────"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "title flush at the rule's start" unknown "$CAPS_STYLED_NOID" "$flush"
  # The strict blank-row posture is untouched: no glyph row, no proof.
  blank="$top"$'\n\n'"$bottom"
  assert_screen "titled rule over a blank row" unknown "$CAPS_STYLED_NOID" "$blank"
  # The untitled pair keeps its verdict alongside the new shape.
  assert_screen "untitled claude idle on herdr" empty "$CAPS_STYLED" \
    "$bottom"$'\n❯'"$NBSP"$'\n'"$bottom"$'\n'"$footer" '' "$claude_idle"
  pass "matrix: claude's titled top rule proves an idle composer empty and a draft pending (#5601, #5558)"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  # Kimi's bordered `│ > │` composer - the shape fm-spawn.sh's retired
  # spawn-local regex used to own. Now the shared owner proves it everywhere,
  # which is what kimi launch-readiness and delivery route through.
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: kimi's bordered shell-glyph box reads empty through the shared owner (spawn's fourth copy retired)"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  # Real claude captured through `zellij action dump-screen --ansi`
  # (capability established by the audit): `ESC[m` `❯` U+00A0.
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: the real claude-in-zellij --ansi dump reads empty in both locales"
}

test_strict_blank_row_divergence() {
  # THE STRICT POSTURE PIN (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank or otherwise unidentified input row with no positive
  # container proof is `unknown`. Each case below read `empty` (or `pending`)
  # under the replaced permissive rule; if any of them drifts back, the
  # permissive posture has silently returned and away-mode injection would
  # again type escalations into unproven panes.
  local out
  # Permissive read this blank cursor row as empty = safe to inject.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown (was permissive empty), got '$out'"
  # A dead shell's prompt row.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  # A bare busy-footer row is not a composer container.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown (was permissive empty), got '$out'"
  # An unidentified free-text cursor row carries no container proof either.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown under strict, got '$out'"
  # A blank screen with no cursor capability.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown, never injectable empty"
}

test_bare_wrap_region_classifies() {
  # Long typed input wraps below the glyph row; the cursor rides the wrapped
  # continuation. The region is IDENTIFIED (glyph row + contiguous non-blank,
  # non-structural rows), so a swallowed Enter still reads pending and earns
  # its retry; a wrapped GHOST suggestion still proves empty.
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  wrapped=$'❯ wrapped typed input\ncontinues without a terminal-inserted glyph'
  assert_screen "ordinary wrapped input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should still prove empty, got '$out'"
  # A structural row between the glyph and the cursor breaks the wrap claim.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule between glyph and cursor must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt below a glyph row must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: the bare composer's wrap region stays identified; structure breaks it"
}

test_contiguous_transcript_reanchors_on_live_prompt() {
  local screen
  screen=$'❯ hi\nHello!\n❯'
  assert_screen "contiguous transcript live prompt on cursorless styled backend" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "contiguous transcript live prompt on cursorless plain backend" empty "$CAPS_PLAIN" "$screen"
  assert_screen "contiguous transcript live prompt with cursor" empty "$CAPS_TMUX" "$screen" 2
  pass "fm_composer_classify_screen: a row-leading agent glyph reanchors the live composer"
}

test_lower_dead_shell_invalidates_cursorless_candidate() {
  local stale live out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$stale" 1)
  [ "$out" = empty ] \
    || fail "cursor mode must keep the cursor-anchored composer verdict, got '$out'"

  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer on herdr" empty "$CAPS_STYLED" "$live"
  assert_screen "shell transcript above live composer on zellij" empty "$CAPS_STYLED_NOID" "$live"
  assert_screen "shell transcript above live composer on cmux/orca" empty "$CAPS_PLAIN" "$live"
  pass "fm_composer_classify_screen: a lower dead shell invalidates only cursorless stale composers"
}

test_cursorless_bare_wrap_region_classifies() {
  local activity status bounded ghost out
  activity=$'❯\nWorking on request...'
  assert_screen "cursorless activity below bare row on herdr" pending "$CAPS_STYLED" "$activity"
  assert_screen "cursorless activity below bare row on zellij" pending "$CAPS_STYLED_NOID" "$activity"
  assert_screen "cursorless activity below bare row on cmux/orca" unknown "$CAPS_PLAIN" "$activity"

  status=$'›\n\ncodex status line'
  assert_screen "blank-separated codex status on herdr" empty "$CAPS_STYLED" "$status"
  assert_screen "blank-separated codex status on zellij" empty "$CAPS_STYLED_NOID" "$status"
  assert_screen "blank-separated codex status on cmux/orca" empty "$CAPS_PLAIN" "$status"

  bounded=$'────────────────────────\n❯\n────────────────────────\nClaude 4.1'
  assert_screen "rule-bounded claude footer on herdr" empty "$CAPS_STYLED" "$bounded" '' probe-absent
  assert_screen "rule-bounded claude footer on zellij" empty "$CAPS_STYLED_NOID" "$bounded"
  assert_screen "rule-bounded claude footer on cmux/orca" empty "$CAPS_PLAIN" "$bounded"

  ghost=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on herdr should be empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on zellij should be empty, got '$out'"
  pass "fm_composer_classify_screen: cursorless bare wrap regions participate in verdicts"
}

test_cursorless_container_rejects_contiguous_lower_activity() {
  local box leftbar grok kimi opencode
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity on herdr" unknown "$CAPS_STYLED" "$box"
  assert_screen "stale box above activity on zellij" unknown "$CAPS_STYLED_NOID" "$box"
  assert_screen "stale box above activity on cmux/orca" unknown "$CAPS_PLAIN" "$box"

  leftbar=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\nWorking on request...'
  assert_screen "stale left-bar above activity on herdr" unknown "$CAPS_STYLED" "$leftbar"
  assert_screen "stale left-bar above activity on zellij" unknown "$CAPS_STYLED_NOID" "$leftbar"
  assert_screen "stale left-bar above activity on cmux/orca" unknown "$CAPS_PLAIN" "$leftbar"

  grok=$'╭────────────────────────╮\n│ ❯                      │\n╰──────── Grok 4.5 ──────╯\n\nGrok status'
  kimi=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n\nKimi status'
  opencode=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\n\nOpenCode status'
  assert_screen "blank-separated grok footer" empty "$CAPS_STYLED_NOID" "$grok"
  assert_screen "blank-separated kimi footer" empty "$CAPS_PLAIN" "$kimi"
  assert_screen "left-bar floor and blank-separated footer" empty "$CAPS_STYLED_NOID" "$opencode"
  pass "fm_composer_classify_screen: cursorless containers reject only contiguous unclaimed activity"
}

test_bottom_most_candidate_wins() {
  # The one ranking rule: the live composer is bottom-anchored, so a stale
  # decorative box (codex's startup banner) can never outrank the real row
  # below it - the confidently-wrong orca case from the audit.
  local screen out
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live claude row" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n› Use /skills to list available skills')
  [ "$out" != pending ] || fail "a stale banner must never classify as pending composer text"
  screen=$'❯ old draft\n\n❯'
  assert_screen "blank-separated newer bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  pass "fm_composer_classify_screen: the bottom-most candidate wins; stale banners cannot"
}

test_incomplete_lower_box_invalidates_stale_candidate() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] \
    || fail "an incomplete lower box must invalidate an earlier empty box, got '$out'"
  pass "fm_composer_classify_screen: incomplete lower structure invalidates stale boxes"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] \
    || fail "a short titled bottom must not prove an empty box, got '$out'"
  pass "fm_composer_classify_screen: titled bottoms retain full box geometry"
}

test_cursor_on_proven_box_bottom_classifies_content() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] \
    || fail "a cursor on a proven box bottom must classify its content, got '$out'"
  pass "fm_composer_classify_screen: a proven box tolerates a bottom-border cursor"
}

test_selected_content_is_composer_scoped_and_wrap_normalized() {
  local screen out
  screen=$'hello captain in transcript\n╭────────────────────╮\n│ unrelated          │\n│ draft               │\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'unrelated draft' ] \
    || fail "box extraction should contain only normalized selected composer rows, got '$out'"
  screen=$'hello captain in transcript\n┃ hello\n┃ captain\n┃ Build · GPT-5.5 Fast OpenAI · high'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'hello captain' ] \
    || fail "left-bar extraction should join user rows without footer furniture, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost agent-prompt placeholders should be excluded from extracted user content, got '$out'"
  screen=$'╭────────────────────╮\n│ > '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost shell-prompt placeholders should be excluded from boxed user content, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ Type a message...│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'Type a message...' ] \
    || fail "surviving placeholder-like input should remain extracted user content, got '$out'"
  screen=$'❯ a legitimately long steer that\nwraps across the next bare row\n\ntranscript below the break'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'a legitimately long steer that wraps across the next bare row' ] \
    || fail "bare extraction should include only its contiguous wrap region, got '$out'"
  screen=$'❯ wrapped user content\ncontinuation preserves a mid-row ❯ glyph'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content continuation preserves a mid-row ❯ glyph' ] \
    || fail "bare extraction should preserve mid-row agent glyph bytes, got '$out'"
  screen=$'❯ stale composer\n$ live shell'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"); then
    fail "a lower live shell must invalidate composer extraction, got '$out'"
  fi
  screen=$'╭──────────────────────────────╮\n│ > wrapped user content       │\n│ ❯ preserves its leading glyph│\n╰──────────────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content ❯ preserves its leading glyph' ] \
    || fail "box extraction should strip only its actual prompt-row glyph, got '$out'"
  pass "fm_composer_extract_selected_content: scopes user content and excludes furniture"
}

# Captured from omp 18.6.0 in a named Herdr lab, not a simulated vendor frame.
# The title occupies the top border; actual input occupies the bottom border.
test_omp_bordered_captured_frames() {
  local empty pending plain out
  empty=$(cat "$ROOT/tests/fixtures/omp-bordered-empty.ansi")
  pending=$(cat "$ROOT/tests/fixtures/omp-bordered-pending.ansi")
  assert_screen "real compact omp empty" empty "$CAPS_STYLED_NOID" "$empty"
  assert_screen "real compact omp empty with cursor" empty "$CAPS_TMUX" "$empty" 16
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$empty")
  [ -z "$out" ] || fail "empty omp extraction must omit its styled hint: $out"
  assert_screen "real compact omp draft" pending "$CAPS_STYLED_NOID" "$pending"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$pending")
  [ "$out" = 'recovery draft must survive' ] || fail "omp extraction includes title or loses input: $out"
  plain=$(printf '%s\n' "$empty" | fm_composer_strip_ansi)
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$plain")
  [ "$out" != empty ] || fail "without styling the hint could be a typed draft"
  assert_screen "typed hint stays pending" pending "$CAPS_STYLED_NOID" \
    $'╭── π > model > path ─╮\n╰─ ⇧⇥ to change thinking effort ─╯'
  assert_screen "incomplete omp floor" unknown "$CAPS_STYLED_NOID" \
    $'╭── π > model > path ─╮\n╰─ unfinished draft'
  assert_screen "omp title alone" unknown "$CAPS_STYLED_NOID" \
    '╭── π > model > path ─╮'
  assert_screen "omp mismatched family" unknown "$CAPS_STYLED_NOID" \
    $'╭── π > model > path ─╮\n└─ ─┘'
  assert_screen "omp multiline draft" pending "$CAPS_STYLED_NOID" \
    $'╭── π > model > path ─╮\n│ first line          │\n╰─ second line ─╯'
  assert_screen "stale omp above shell" unknown "$CAPS_STYLED_NOID" "$empty"$'\n$'
  pass "omp captured bordered frames preserve drafts and require a complete container"
}
test_omp_bordered_captured_frames

test_omp_literal_input_rows() {
  local draft screen out position cursor
  for position in floor body; do
    for draft in '#' '||' '# heading' '|draft|' '>' '$' '%' '❯' '›' '⟩' '→'; do
      if [ "$position" = floor ]; then
        screen=$'╭── π > model > path ─╮\n╰─ '"$draft"' ─╯'
        cursor=1
      else
        screen=$'╭── π > model > path ─╮\n│ '"$draft"$' │\n╰─  ─╯'
        cursor=1
      fi
      assert_screen "omp literal $position '$draft' with cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
      assert_screen "omp literal $position '$draft' cursorless" pending "$CAPS_STYLED_NOID" "$screen"
      assert_screen "omp literal $position '$draft' plain cursorless" pending "$CAPS_PLAIN" "$screen"
      out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
      [ "$out" = "$draft" ] || fail "omp literal $position extraction lost '$draft': '$out'"
    done
  done
  screen=$'╭── π > model > path ─╮\n│ # heading │\n╰─ |draft| ─╯'
  assert_screen "omp literal multiline with cursor on floor" pending "$CAPS_TMUX" "$screen" 2
  assert_screen "omp literal multiline cursorless" pending "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = '# heading |draft|' ] || fail "omp multiline extraction changed literal input: '$out'"
  pass "omp prompt-free input stays literal on its floor and body rows"
}
test_omp_literal_input_rows

assert_extraction_refused() {
  local label=$1 caps=$2 screen=$3 out status=0
  out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
  [ "$status" -ne 0 ] && [ -z "$out" ] \
    || fail "$label: expected nonzero empty extraction, got status $status and '$out'"
  status=0
  out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") || status=$?
  [ "$status" -ne 0 ] && [ -z "$out" ] \
    || fail "$label under LC_ALL=C: expected nonzero empty extraction, got status $status and '$out'"
}

test_gutter_blockers_preserve_omp_literal_ambiguity() {
  local blocker frame screen caps cursor last out
  for blocker in '│ │' '╭── stray ─╮' 'π · model' '⠂⠁'; do
    for frame in $'  ╭── π > model > path ─╮\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  ╰─  ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'; do
      screen=$'❯ preface\n  '"$blocker"$'\n'"$frame"
      last=$(printf '%s\n' "$screen" | awk 'END {print NR - 1}')
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "gutter blocker '$blocker' before literal '$frame' refuses cursorless" unknown-draft "$caps" "$screen"
        assert_extraction_refused "gutter blocker '$blocker' before literal '$frame'" "$caps" "$screen"
      done
      for cursor in 0 1 2 "$last"; do
        assert_screen "gutter blocker '$blocker' literal cursor row $cursor refuses" unknown-draft "$CAPS_TMUX" "$screen" "$cursor"
      done
      screen="$screen"$'\n  ❯ '
      assert_screen "gutter prompt after '$blocker' and literal refuses" unknown-draft "$CAPS_STYLED_NOID" "$screen"
      assert_screen "gutter prompt cursor after '$blocker' and literal refuses" unknown-draft "$CAPS_TMUX" "$screen" "$((last + 1))"
      assert_extraction_refused "gutter prompt after '$blocker' and literal" "$CAPS_STYLED_NOID" "$screen"
    done
    screen=$'❯ preface\n  '"$blocker"$'\n  ❯ '
    assert_screen "gutter prompt directly after '$blocker' refuses" unknown-draft "$CAPS_STYLED_NOID" "$screen"
    assert_screen "gutter prompt cursor directly after '$blocker' refuses" unknown-draft "$CAPS_TMUX" "$screen" 2
    assert_extraction_refused "gutter prompt directly after '$blocker'" "$CAPS_STYLED_NOID" "$screen"
  done
  screen=$'❯ preface\n  │ │\n  π · model\n  ⠂⠁\n  ╭── π > model > path ─╮\n  ╰─  ─╯'
  frame=$'  ╭── π > model > path ─╮\n  ╰─  ─╯'
  for screen in "$screen"$'\n❯ ' "$screen"$'\n$ shell\n'"$frame"; do
    assert_screen "independent margin boundary ends blocker ambiguity" empty "$CAPS_STYLED_NOID" "$screen"
    out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
      || fail "independent margin boundary extraction refused"
    [ -z "$out" ] || fail "independent margin boundary inherited ambiguous input: '$out'"
  done
  pass "native-gutter edge, status and braille blockers cannot promote later literal frames or prompts"
}
test_gutter_blockers_preserve_omp_literal_ambiguity

test_captured_empty_native_roots_preserve_gutter_ambiguity() {
  local blocker frame screen last caps cursor out
  for blocker in '│ │' 'π · model' '⠂⠁'; do
    for frame in $'  ╭── π > model > path ─╮\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  ╰─  ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯' \
                 '  ❯'; do
      screen=$'❯\n  '"$blocker"$'\n'"$frame"
      last=$(printf '%s\n' "$screen" | awk 'END {print NR - 1}')
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "captured empty root with '$blocker' and '$frame'" unknown-draft "$caps" "$screen"
        assert_extraction_refused "captured empty root with '$blocker' and '$frame'" "$caps" "$screen"
      done
      for cursor in 0 1 "$last"; do
        assert_screen "captured empty root '$blocker' cursor $cursor" unknown-draft "$CAPS_TMUX" "$screen" "$cursor"
      done
      screen="$screen"$'\n  ❯\n  tail'
      assert_screen "captured empty root keeps later prompt and tail ambiguous" unknown-draft "$CAPS_STYLED_NOID" "$screen"
      assert_screen "captured empty root tail cursor stays ambiguous" unknown-draft "$CAPS_TMUX" "$screen" "$((last + 2))"
      assert_extraction_refused "captured empty root prompt and tail" "$CAPS_STYLED_NOID" "$screen"
    done
  done
  screen=$'❯\n  │ │\n  ╭── π > model > path ─╮\n  ╰─  ─╯'
  for screen in "$screen"$'\n❯' "$screen"$'\n$ shell\n  ╭── π > model > path ─╮\n  ╰─  ─╯'; do
    assert_screen "independent boundary ends captured-root ambiguity" empty "$CAPS_STYLED_NOID" "$screen"
    out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
      || fail "captured-root independent boundary extraction refused"
    [ -z "$out" ] || fail "captured-root independent boundary inherited draft: '$out'"
  done
  pass "capture-trimmed empty native roots retain gutter-backed draft ambiguity"
}
test_captured_empty_native_roots_preserve_gutter_ambiguity

test_bare_draft_owns_indented_compact_omp_literal() {
  local floor screen expected caps cursor out status
  status=' π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  for floor in '╰─ ─╯' '╰─  ─╯' '╰─ typed text ─╯'; do
    screen=$'❯ preface\n  ╭── π > model > path ─╮\n  '"$floor"
    expected="preface ╭── π > model > path ─╮ $floor"
    [ "$floor" != '╰─  ─╯' ] || expected='preface ╭── π > model > path ─╮ ╰─ ─╯'
    for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID"; do
      assert_screen "bare draft owns compact literal '$floor' cursorless" pending "$caps" "$screen"
      out=$(fm_composer_extract_selected_content "$caps" "$screen")
      [ "$out" = "$expected" ] || fail "compact literal extraction dropped bare draft: '$out'"
    done
    assert_screen "plain bare compact literal stays unproven" unknown-draft "$CAPS_PLAIN" "$screen"
    out=$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$screen")
    [ "$out" = "$expected" ] || fail "plain compact literal extraction dropped bare draft: '$out'"
    for cursor in 0 1 2; do
      assert_screen "bare compact literal cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
    done
    screen="$screen"$'\n'"$status"
    assert_screen "status bounds bare compact literal" pending "$CAPS_STYLED_NOID" "$screen"
    out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
    [ "$out" = "$expected" ] || fail "compact literal extraction included status: '$out'"
    assert_screen "status cursor is not draft input" unknown "$CAPS_TMUX" "$screen" 3
  done
  screen=$'❯ preface\n  continuation\n  ╭── π > model > path ─╮\n  ╰─  ─╯\n  ╭── π > model > path ─╮\n  ╰─  ─╯\n  tail'
  assert_screen "multiple compact literals remain bare draft" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "cursor after compact literals remains bare draft" pending "$CAPS_TMUX" "$screen" 6
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  expected='preface continuation ╭── π > model > path ─╮ ╰─ ─╯ ╭── π > model > path ─╮ ╰─ ─╯ tail'
  [ "$out" = "$expected" ] || fail "multiple compact literals lost content: '$out'"
  screen=$'────────\nold Pi draft\n────────\n\n❯ preface\n  ╭── π > model > path ─╮\n  ╰─  ─╯'
  expected='preface ╭── π > model > path ─╮ ╰─ ─╯'
  assert_screen "completed Pi transcript does not veto bare literal" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "completed Pi transcript preserves bare floor cursor" pending "$CAPS_TMUX" "$screen" 6
  assert_screen "completed Pi transcript preserves plain degradation" unknown-draft "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = "$expected" ] || fail "earlier Pi pair vetoed bare literal extraction: '$out'"
  screen=$'────────\n❯ preface\n  ╭── π > model > path ─╮\n  ╰─  ─╯\n────────'
  assert_screen "enclosing Pi retains bare overlap identity verdict" pending "$CAPS_STYLED" "$screen" '' $'pi\tidle'
  assert_screen "enclosing Pi retains plain identity verdict" pending \
    $'styled=0\ncursor=0\nidentity=1' "$screen" '' $'pi\tidle'
  assert_screen "enclosing Pi retains floor cursor verdict" pending "$CAPS_TMUX" "$screen" 3 $'pi\tidle'
  assert_screen "enclosing Pi floor still requests identity" need-identity "$CAPS_TMUX" "$screen" 3
  screen=$'❯ old draft\n\n  ╭── π > model > path ─╮\n  ╰─  ─╯'
  assert_screen "blank-separated compact omp stays ambiguous" unknown-draft "$CAPS_STYLED_NOID" "$screen"
  assert_screen "blank-separated compact floor cursor stays ambiguous" unknown-draft "$CAPS_TMUX" "$screen" 3
  assert_extraction_refused "blank-separated compact omp" "$CAPS_STYLED_NOID" "$screen"
  screen=$'❯ old draft\n╭── π > model > path ─╮\n╰─  ─╯'
  assert_screen "unindented compact omp remains standalone" empty "$CAPS_STYLED_NOID" "$screen"
  pass "bare drafts own indented compact omp literals without claiming standalone boxes or status"
}
test_bare_draft_owns_indented_compact_omp_literal

test_bare_draft_owns_indented_multirow_omp_literal() {
  local frame screen expected caps cursor last out status prefix
  status=' π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  screen=$'❯ preface\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'
  expected='preface ╭── π > model > path ─╮ │ │ ╰─ ─╯'
  assert_screen "minimal accepted-floor literal is not empty cursorless" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "minimal accepted-floor literal stays unproven on plain capture" unknown-draft "$CAPS_PLAIN" "$screen"
  for cursor in 2 3; do
    assert_screen "minimal accepted-floor literal cursor row $cursor is not empty" pending "$CAPS_TMUX" "$screen" "$cursor"
  done
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "minimal accepted-floor literal extraction lost side borders: '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "minimal accepted-floor literal extraction under LC_ALL=C lost side borders: '$out'"
  done
  for frame in $'  ╭── π > model > path ─╮\n  │ │\n  ╰─ ─╯' \
               $'  ╭── π > model > path ─╮\n  │ │\n  │ typed | > ❯ │\n  ╰─  ─╯' \
               $'  ╭── π > model > path ─╮\n  │ typed | > ❯ │\n  ╰─ typed text ─╯'; do
    screen=$'❯ preface\n'"$frame"$'\n  tail'
    expected=$(printf '%s\n' "${screen#❯ }" | LC_ALL=C awk '{$1=$1; printf "%s%s", sep, $0; sep=" "}')
    last=$(printf '%s\n' "$screen" | awk 'END {print NR - 1}')
    for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
      if [ "$caps" = "$CAPS_PLAIN" ]; then
        assert_screen "plain bare multirow literal stays unproven" unknown-draft "$caps" "$screen"
      else
        assert_screen "bare draft owns multirow literal cursorless" pending "$caps" "$screen"
      fi
      out=$(fm_composer_extract_selected_content "$caps" "$screen")
      [ "$out" = "$expected" ] \
        || fail "multirow literal extraction must retain side borders: expected '$expected', got '$out'"
      out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
      [ "$out" = "$expected" ] \
        || fail "multirow literal extraction under LC_ALL=C must retain side borders: expected '$expected', got '$out'"
    done
    cursor=0
    while [ "$cursor" -le "$last" ]; do
      assert_screen "bare multirow literal cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
      cursor=$((cursor + 1))
    done
  done

  frame=$'  ╭── π > model > path ─╮\n  │ │\n  │ typed | > ❯ │\n  ╰─  ─╯'
  screen=$'❯ preface\n'"$frame"$'\n  tail\n'"$status"
  expected='preface ╭── π > model > path ─╮ │ │ │ typed | > ❯ │ ╰─ ─╯ tail'
  assert_screen "status bounds bare multirow literal" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "multirow status cursor is not draft input" unknown "$CAPS_TMUX" "$screen" 6
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = "$expected" ] || fail "multirow literal extraction included status or lost body bytes: '$out'"
  out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = "$expected" ] || fail "multirow status-bound extraction under LC_ALL=C changed draft bytes: '$out'"

  prefix=$'────────\nold Pi draft\n────────\n\n'
  screen="${prefix}"$'❯ preface\n'"$frame"$'\n  ╭── π > model > path ─╮\n  │ second body │\n  ╰─ typed floor ─╯\n  tail'
  expected='preface ╭── π > model > path ─╮ │ │ │ typed | > ❯ │ ╰─ ─╯ ╭── π > model > path ─╮ │ second body │ ╰─ typed floor ─╯ tail'
  assert_screen "earlier Pi transcript does not claim multiple multirow literals" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "earlier Pi transcript preserves multirow plain degradation" unknown-draft "$CAPS_PLAIN" "$screen"
  assert_screen "cursor on first literal body after Pi transcript" pending "$CAPS_TMUX" "$screen" 7
  assert_screen "cursor on second literal floor after Pi transcript" pending "$CAPS_TMUX" "$screen" 11
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = "$expected" ] || fail "multiple multirow literal extraction lost draft bytes: '$out'"
  out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = "$expected" ] || fail "multiple multirow literal extraction under LC_ALL=C lost draft bytes: '$out'"
  pass "bare multirow omp literals stay pending or unproven and preserve all normalized draft bytes"
}
test_bare_draft_owns_indented_multirow_omp_literal

test_pi_and_standalone_multirow_omp_ownership() {
  local frame screen expected caps cursor out
  frame=$'  ╭── π > model > path ─╮\n  │ │\n  │ typed | > ❯ │\n  ╰─  ─╯'
  screen=$'────────\nbefore the literal frame\n'"$frame"$'\n  tail\n────────'
  expected='before the literal frame ╭── π > model > path ─╮ │ │ │ typed | > ❯ │ ╰─ ─╯ tail'
  for caps in "$CAPS_STYLED" $'styled=0\ncursor=0\nidentity=1'; do
    assert_screen "enclosing Pi owns multirow literal with idle identity" pending "$caps" "$screen" '' $'pi\tidle'
    assert_screen "enclosing Pi multirow literal requests identity" need-identity "$caps" "$screen"
    assert_screen "non-Pi identity cannot claim enclosing multirow literal" unknown-draft "$caps" "$screen" '' $'zsh\t'
    assert_screen "absent probe cannot claim enclosing multirow literal" unknown-draft "$caps" "$screen" '' probe-absent
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "enclosing Pi extraction lost literal body bytes or preface: '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "enclosing Pi extraction under LC_ALL=C lost literal body bytes or preface: '$out'"
  done
  for cursor in 1 2 3 4 5 6; do
    assert_screen "enclosing Pi multirow literal cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor" $'pi\tidle'
    assert_screen "enclosing Pi multirow row $cursor requests identity" need-identity "$CAPS_TMUX" "$screen" "$cursor"
    for caps in "$CAPS_TMUX" $'styled=0\ncursor=1\nidentity=1'; do
      assert_screen "multirow denied probe cursor row $cursor" unknown-draft "$caps" "$screen" "$cursor" probe-absent
      assert_screen "multirow foreign identity cursor row $cursor" unknown-draft "$caps" "$screen" "$cursor" $'claude\tidle'
    done
    for caps in $'styled=0\ncursor=1\nidentity=0' $'styled=1\ncursor=1\nidentity=0'; do
      assert_screen "multirow missing capability cursor row $cursor" unknown-draft "$caps" "$screen" "$cursor"
    done
  done
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    assert_screen "enclosing Pi literal without identity capability stays unproven" unknown-draft "$caps" "$screen"
  done

  screen=$'❯ old draft\n\n'"$frame"
  assert_screen "blank-separated multirow omp stays ambiguous" unknown-draft "$CAPS_STYLED_NOID" "$screen"
  assert_screen "blank-separated multirow omp plain capture stays ambiguous" unknown-draft "$CAPS_PLAIN" "$screen"
  assert_screen "blank-separated multirow floor cursor stays ambiguous" unknown-draft "$CAPS_TMUX" "$screen" 5
  assert_extraction_refused "blank-separated multirow omp" "$CAPS_PLAIN" "$screen"
  screen=$'❯ old draft\n╭── π > model > path ─╮\n│ │\n│ │\n╰─  ─╯'
  assert_screen "unindented empty multirow omp remains standalone" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "plain empty standalone multirow omp remains empty" empty "$CAPS_PLAIN" "$screen"
  assert_screen "empty standalone multirow floor cursor remains empty" empty "$CAPS_TMUX" "$screen" 4
  out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] || fail "empty standalone multirow extraction must not inherit old bare draft: '$out'"
  pass "multirow literal Pi ownership and real standalone box behavior remain distinct"
}
test_pi_and_standalone_multirow_omp_ownership

test_blank_separated_indented_omp_frames_are_ambiguous() {
  local root gutter gap frame screen last cursor caps identity out expected floor gap_index gap_offset=0 replacement
  for root in '❯ ' '❯ old draft'; do
    for gutter in ' ' '  '; do
      replacement=$'\n'"$gutter"
      gap_index=$gap_offset
      for frame in $'╭── π > model > path ─╮\n╰─ ─╯' \
                   $'╭── π > model > path ─╮\n╰─  ─╯' \
                   $'╭── π > model > path ─╮\n╰─ typed floor ─╯' \
                   $'╭── π > model > path ─╮\n│ │\n╰─ ─╯' \
                   $'╭── π > model > path ─╮\n│ │\n╰─  ─╯' \
                   $'╭── π > model > path ─╮\n│ typed body │\n╰─ ─╯' \
                   $'╭── π > model > path ─╮\n│ typed body │\n╰─  ─╯' \
                   $'╭── π > model > path ─╮\n│ typed body │\n╰─ typed floor ─╯'; do
        case $((gap_index % 4)) in
          0) gap='' ;;
          1) gap='  ' ;;
          2) gap=$'\t' ;;
          3) gap=$NBSP ;;
        esac
        gap_index=$((gap_index + 1))
        screen="$root"$'\n'"$gap"$'\n'"$gutter${frame//$'\n'/$replacement}"
        case "$frame" in
          *'│'*) last=4 ;;
          *) last=3 ;;
        esac
        for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
          assert_screen "blank-separated '$root' gutter '$gutter' frame '$frame' stays ambiguous" unknown-draft "$caps" "$screen"
          assert_extraction_refused "blank-separated '$root' gutter '$gutter' frame '$frame'" "$caps" "$screen"
        done
        for cursor in 0 1 "$last"; do
          assert_screen "blank-separated '$root' gutter '$gutter' cursor row $cursor stays ambiguous" unknown-draft \
            "$CAPS_TMUX" "$screen" "$cursor" probe-absent
        done
      done
      gap_offset=$((gap_offset + 1))
    done
  done

  screen=$'❯ \n\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'
  for identity in '' probe-absent $'zsh\t' $'pi\tidle'; do
    assert_screen "blank-separated ambiguity cannot be resolved by identity '$identity'" unknown-draft \
      "$CAPS_STYLED" "$screen" '' "$identity"
    assert_screen "blank-separated root ambiguity cannot be resolved by identity '$identity'" unknown-draft \
      "$CAPS_TMUX" "$screen" 0 "$identity"
    assert_screen "plain blank-separated floor ambiguity cannot be resolved by identity '$identity'" unknown-draft \
      $'styled=0\ncursor=1\nidentity=1\nrows=20' "$screen" 4 "$identity"
  done

  for floor in '╰─ ─╯' '╰─  ─╯'; do
    screen=$'────────\n❯ \n\n  ╭── π > model > path ─╮\n  │ │\n  '"$floor"$'\n────────'
    expected='❯ ╭── π > model > path ─╮ │ │ ╰─ ─╯'
    for caps in "$CAPS_STYLED" $'styled=0\ncursor=0\nidentity=1\nrows=20'; do
      assert_screen "genuine Pi containment of blank-separated literal requests identity" need-identity "$caps" "$screen"
      assert_screen "genuine Pi containment of blank-separated literal stays pending" pending "$caps" "$screen" '' $'pi\tidle'
      assert_screen "genuine Pi containment without Pi identity stays unproven" unknown-draft "$caps" "$screen" '' $'zsh\t'
      out=$(fm_composer_extract_selected_content "$caps" "$screen") \
        || fail "genuine Pi blank-separated literal extraction refused"
      [ "$out" = "$expected" ] || fail "genuine Pi blank-separated extraction lost literal frame: '$out'"
      out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") \
        || fail "genuine Pi blank-separated literal extraction under LC_ALL=C refused"
      [ "$out" = "$expected" ] || fail "genuine Pi blank-separated extraction under LC_ALL=C lost literal frame: '$out'"
    done
    for cursor in 1 2 3 4 5; do
      if [ "$floor" = '╰─ ─╯' ] && [ "$cursor" -ge 3 ]; then
        out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" "$cursor" $'pi\tidle')
        [ "$out" != empty ] || fail "genuine Pi unproven minimal frame cursor row $cursor must never authorize injection"
        out=$(LC_ALL=C fm_composer_classify_screen "$CAPS_TMUX" "$screen" "$cursor" $'pi\tidle')
        [ "$out" != empty ] || fail "genuine Pi unproven minimal frame cursor row $cursor under LC_ALL=C must never authorize injection"
      else
        assert_screen "genuine Pi blank-separated literal cursor row $cursor requests identity" need-identity "$CAPS_TMUX" "$screen" "$cursor"
        assert_screen "genuine Pi blank-separated literal cursor row $cursor stays pending" pending "$CAPS_TMUX" "$screen" "$cursor" $'pi\tidle'
      fi
    done

    if [ "$floor" = '╰─  ─╯' ]; then
      screen=$'unrelated transcript\n\n  ╭── π > model > path ─╮\n  │ │\n  '"$floor"
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "ordinary standalone indented omp after transcript stays empty" empty "$caps" "$screen"
        out=$(fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "ordinary standalone indented omp extraction refused"
        [ -z "$out" ] || fail "ordinary standalone indented omp inherited transcript: '$out'"
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "ordinary standalone indented omp extraction under LC_ALL=C refused"
        [ -z "$out" ] || fail "ordinary standalone indented omp under LC_ALL=C inherited transcript: '$out'"
      done
      assert_screen "ordinary standalone indented omp floor cursor stays empty" empty "$CAPS_TMUX" "$screen" 4
    fi
  done
  frame=$'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'
  screen=$'❯ \n\n'"$frame"$'\n'"$frame"
  assert_screen "second contiguous indented frame cannot outrank blank-separated ambiguity" unknown-draft "$CAPS_STYLED_NOID" "$screen"
  assert_screen "plain second contiguous indented frame cannot outrank ambiguity" unknown-draft "$CAPS_PLAIN" "$screen"
  assert_extraction_refused "multiple contiguous blank-separated indented frames" "$CAPS_STYLED_NOID" "$screen"
  for cursor in 0 1 2 3 4 5 6 7; do
    assert_screen "multiple ambiguous frames cursor row $cursor stays unproven" unknown-draft "$CAPS_TMUX" "$screen" "$cursor" probe-absent
  done
  screen="$screen"$'\n╭── π > model > path ─╮\n╰─  ─╯'
  assert_screen "later unindented standalone box ends blank-separated ambiguity" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "later unindented standalone floor proves its own empty input" empty "$CAPS_TMUX" "$screen" 9
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
    || fail "later unindented standalone box extraction refused"
  [ -z "$out" ] || fail "later unindented standalone box inherited earlier ambiguous frames: '$out'"
  out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
    || fail "later unindented standalone box extraction under LC_ALL=C refused"
  [ -z "$out" ] || fail "later unindented standalone box under LC_ALL=C inherited earlier ambiguous frames: '$out'"
  screen=$'❯ preface\n  \n  > quote\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯\n  ❯ '
  assert_screen "prompt transitions before and after a blank-separated frame stay ambiguous" unknown-draft "$CAPS_STYLED_NOID" "$screen"
  assert_extraction_refused "blank-separated frame with surrounding prompt transitions" "$CAPS_STYLED_NOID" "$screen"
  for cursor in 0 2 5 6; do
    assert_screen "blank-separated frame with surrounding prompt transitions cursor row $cursor" unknown-draft "$CAPS_TMUX" "$screen" "$cursor" probe-absent
  done
  screen="$screen"$'\n❯ '
  assert_screen "independent margin agent prompt ends native-gutter ambiguity" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "independent margin agent cursor keeps its own empty proof" empty "$CAPS_TMUX" "$screen" 7
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
    || fail "independent margin agent extraction refused"
  [ -z "$out" ] || fail "independent margin agent inherited ambiguous draft: '$out'"
  screen=$'❯ first draft\n\n'"$frame"$'\n❯ \n\n'"$frame"
  for caps in "$CAPS_TMUX" $'styled=0\ncursor=1\nidentity=1\nrows=20'; do
    for cursor in 0 4 9; do
      assert_screen "later blank-separated native root preserves ambiguity at cursor row $cursor" unknown-draft \
        "$caps" "$screen" "$cursor" probe-absent
    done
  done
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    assert_screen "latest separate native ambiguity remains unproven cursorless" unknown-draft "$caps" "$screen"
    assert_extraction_refused "latest separate native ambiguity" "$caps" "$screen"
  done
  screen=$'❯ first draft\n\n'"$frame"$'\n╭── π > model > path ─╮\n╰─  ─╯\n❯ \n\n'"$frame"
  for caps in "$CAPS_TMUX" $'styled=0\ncursor=1\nidentity=1\nrows=20'; do
    assert_screen "unindented standalone box between ambiguity intervals keeps its own cursor proof" empty \
      "$caps" "$screen" 6 probe-absent
    for cursor in 4 11; do
      assert_screen "separate ambiguity intervals retain cursor row $cursor without claiming intervening box" unknown-draft \
        "$caps" "$screen" "$cursor" probe-absent
    done
  done
  pass "blank-separated indented omp frames refuse ambiguous drafts without changing genuine Pi or standalone ownership"
}
test_blank_separated_indented_omp_frames_are_ambiguous
test_claude_selected_slash_menu_extracts_only_the_composer() {
  # Claude Code 2.1.291's captured /exit viewport, retaining its exact composer
  # and menu rows (only the launch transcript and warning above are omitted).
  local screen prefix out caps
  screen=$' ▐▛███▛█   Claude Code v2.1.291\n▝▜██████▀  Haiku 4.5 · Claude Max\n\n─────────────────────────────────────────────────────────────────────────────────────────────\n❯'"$NBSP"$'/exit\n─────────────────────────────────────────────────────────────────────────────────────────────\n  ❯ /exit                       Exit the CLI\n    /context                    Visualize current context usage as a colored grid\n    /usage-credits              Configure usage credits or request them from your admin\n                                when you hit a limit'
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = /exit ] || fail "selected /exit popup must extract exactly /exit, got '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = /exit ] || fail "selected /exit popup under LC_ALL=C must extract exactly /exit, got '$out'"
  done
  assert_screen "selected /exit popup on styled backends" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "selected /exit popup on plain backends" pending "$CAPS_PLAIN" "$screen"
  # A selected completion is not the typed command: preserve a nonempty prefix,
  # also when both the composer and popup are indented by the pane renderer.
  prefix=$'  ────────────────────────\n  ❯ /ex\n  ────────────────────────\n    ❯ /exit                       Exit the CLI\n      /extra                      Another matching command'
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    out=$(fm_composer_extract_selected_content "$caps" "$prefix")
    [ "$out" = /ex ] || fail "selected completion must preserve the typed /ex prefix, got '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$prefix")
    [ "$out" = /ex ] || fail "selected completion under LC_ALL=C must preserve /ex, got '$out'"
  done
  assert_screen "nonempty slash prefix on styled backends" pending "$CAPS_STYLED_NOID" "$prefix"
  assert_screen "nonempty slash prefix on plain backends" pending "$CAPS_PLAIN" "$prefix"
  pass "Claude selected slash-menu rows do not replace the actual command or prefix"
}

test_claude_slash_menu_demotion_preserves_lower_drafts_and_shells() {
  local pair menu screen want out caps scenario
  pair=$'────────────────────────\n❯ /exit\n────────────────────────'
  menu='  ❯ /exit                       Exit the CLI'
  for scenario in unindented same-indent draft unpadded mismatch empty slash-only unproven blank activity; do
    want='/exit Exit the CLI'
    case "$scenario" in
      unindented) screen="$pair"$'\n❯ /exit                       Exit the CLI' ;;
      same-indent) screen=$'  ────────────────────────\n  ❯ /exit\n  ────────────────────────\n'"$menu" ;;
      draft) screen="$pair"$'\n  ❯ my typed draft'; want='my typed draft' ;;
      unpadded) screen="$pair"$'\n  ❯ /exit my typed draft'; want='/exit my typed draft' ;;
      mismatch) screen=$'────────────────────────\n❯ /context\n────────────────────────\n'"$menu" ;;
      empty) screen=$'────────────────────────\n❯\n────────────────────────\n'"$menu" ;;
      slash-only) screen=$'────────────────────────\n❯ /\n────────────────────────\n'"$menu" ;;
      unproven) screen=$'❯ /exit\n────────────────────────\n'"$menu" ;;
      blank) screen="$pair"$'\n\n'"$menu" ;;
      activity) screen="$pair"$'\nWorking on request...\n'"$menu" ;;
    esac
    for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
      out=$(fm_composer_extract_selected_content "$caps" "$screen")
      [ "$out" = "$want" ] || fail "$scenario lower candidate must keep winning, expected '$want', got '$out'"
      out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
      [ "$out" = "$want" ] || fail "$scenario lower candidate under LC_ALL=C must keep winning, got '$out'"
    done
    assert_screen "$scenario lower candidate on styled backends" pending "$CAPS_STYLED_NOID" "$screen"
    assert_screen "$scenario lower candidate on plain backends" unknown "$CAPS_PLAIN" "$screen"
  done
  screen="$pair"$'\n'"$menu"$'\n$ live shell'
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    if out=$(fm_composer_extract_selected_content "$caps" "$screen"); then
      fail "a lower shell must still invalidate popup extraction, got '$out'"
    fi
    assert_screen "lower shell below slash menu" unknown "$caps" "$screen"
  done
  pass "slash-menu demotion cannot select an empty parent or replace a real lower draft or shell"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_matrix_claude_bare_nbsp_row
test_matrix_claude_arrow_statusline_footer
test_matrix_claude_titled_top_border
test_rule_pair_equal_indentation
test_rule_pair_ambiguity_is_candidate_scoped
test_titled_rule_pair_ignores_outside_glyph_after_recorded_closer
test_multiline_rule_pair_retains_all_interior_rows
test_rule_pair_continuations_never_prove_empty
test_rejected_titled_rule_pair_retains_refusal
test_rule_pair_pasted_containers_remain_literal
test_rule_pair_braille_is_literal_content
test_claude_titled_top_border_needs_glyph_proof_and_exact_shape
test_composer_footer_demotion_needs_a_proven_pair
test_composer_footer_zone_is_shape_independent
test_composer_footer_zone_refuses_rather_than_allows
test_matrix_codex_dim_hint_row
test_matrix_muse_truecolor_glyph_survives_signal_loss
test_matrix_cursor_reverse_video_placeholder_remnant
test_matrix_herdr_halfblock_rule_bounds_bare_wrap
test_matrix_omp_status_row_bounds_bare_composer
test_matrix_omp_effort_hint_remnant
test_matrix_omp_box_composer
test_omp_box_busy_status_border_reads_the_composer
test_omp_box_working_renders_match_delivery_busy
test_omp_box_requires_omp_identity_and_complete_shape
test_matrix_codex_idle_starfield_furniture
test_matrix_pi_separated_needs_identity
test_pi_literal_omp_floor_with_blank_continuation
test_pi_nested_omp_box_preserves_enclosing_draft
test_matrix_pi_dollar_status_footer_is_empty
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_claude_titled_top_rule
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_claude_inside_zellij_ansi_dump
test_strict_blank_row_divergence
test_bare_wrap_region_classifies
test_contiguous_transcript_reanchors_on_live_prompt
test_lower_dead_shell_invalidates_cursorless_candidate
test_cursorless_bare_wrap_region_classifies
test_cursorless_container_rejects_contiguous_lower_activity
test_bottom_most_candidate_wins
test_incomplete_lower_box_invalidates_stale_candidate
test_titled_bottom_requires_matching_width
test_cursor_on_proven_box_bottom_classifies_content
test_selected_content_is_composer_scoped_and_wrap_normalized
test_claude_selected_slash_menu_extracts_only_the_composer
test_claude_slash_menu_demotion_preserves_lower_drafts_and_shells

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy opencode)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle opencode)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown opencode)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown unknown-draft send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy opencode)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle opencode)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_queued_enter_requires_supported_harness() {
  local harness out
  for harness in omp claude codex unknown ''; do
    out=$(fm_composer_queued_enter_verdict pending busy "$harness")
    [ "$out" = pending ] || fail "unsupported '$harness' must retain pending, got '$out'"
  done
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = pending ] || fail "missing harness must not confirm delivery"
  pass "queued Enter requires positive OpenCode identity"
}
test_queued_enter_requires_supported_harness

test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states

# The selected row sits on cursor row 1 so a tmux read whose cursor is that
# row, and a cursorless read, both still see unsubmitted text.
exit_picker_screen() {
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel'
}

fm_test_picker_send() {
  printf 'Enter\n' >> "$FM_TEST_PICKER_ENTERS"
}

fm_test_picker_state() {
  fm_composer_classify_screen 'styled=1' "$FM_TEST_PICKER_SCREEN" 1
}

test_background_exit_picker_stays_pending_and_blocks_retry() {
  local screen out rc sink enters
  screen=$(exit_picker_screen)
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 0 ] || fail "the recorded picker should match"
  [ "$out" = 'Claude background-task exit picker' ] || fail "dialog name was '$out'"
  out=$(fm_composer_blocking_dialog 'Background work is running'); rc=$?
  [ "$rc" -eq 1 ] || fail "a heading alone must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' 'Background work is running' 'Exit and stop tasks')"); rc=$?
  [ "$rc" -eq 1 ] || fail "two of the three strings must not match"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' "$screen" '' '')"); rc=$?
  [ "$rc" -eq 0 ] || fail "blank rows below the footer should still match"
  sink=$(mktemp)
  FM_COMPOSER_DIALOG_SINK=$sink
  out=$(fm_composer_classify_screen 'styled=1' "$screen" 1)
  [ "$out" = pending ] || fail "cursor on the selected row should stay pending, got '$out'"
  [ "$(cat "$sink")" = 'Claude background-task exit picker' ] || fail "classify should note the dialog, got '$(cat "$sink")'"
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = pending ] || fail "a styled cursorless picker should stay pending, got '$out'"
  unset FM_COMPOSER_DIALOG_SINK
  rm -f "$sink"
  FM_TEST_PICKER_SCREEN=$screen
  FM_TEST_PICKER_ENTERS=$(mktemp)
  : > "$FM_TEST_PICKER_ENTERS"
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  sink=$FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_submit_retry_core fm_test_picker_send fm_test_picker_state win 3 0)
  fm_composer_dialog_sink_release
  [ ! -e "$sink" ] || fail "the release should remove a sink that prepare created"
  [ -z "${FM_COMPOSER_DIALOG_SINK:-}" ] || fail "the release should unset a sink that prepare created"
  enters=$(grep -c '^Enter$' "$FM_TEST_PICKER_ENTERS" || true)
  [ "$out" = unknown ] || fail "a picker must stop the retry as unknown, got '$out'"
  [ "$enters" -eq 1 ] || fail "a picker must receive one Enter, got $enters"
  rm -f "$FM_TEST_PICKER_ENTERS"
  unset FM_TEST_PICKER_SCREEN FM_TEST_PICKER_ENTERS
  pass "the Claude background-task exit picker stays pending and receives no confirming Enter"
}

# The picker's own text, shown the way a worker pane shows it when it prints
# this repository's diff, verification note, or a test fixture: quoted above a
# normal composer. No picker is open, so the next Enter confirms nothing.
quoted_exit_picker_screen() {
  printf '%s\n' \
    '● Here is the fixture the test uses:' \
    "+    'Background work is running' \\" \
    "+    '❯ 1. Exit and stop tasks' \\" \
    "+    'Enter to confirm · Esc to cancel'" \
    '  The selected row is "❯ 1. Exit and stop tasks" and the footer is "Enter to confirm · Esc to cancel".' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel' \
    '' \
    '╭──────────────╮' \
    '│ > next steer │' \
    '╰──────────────╯'
}

test_dialog_heading_and_footer_must_be_the_recorded_lines() {
  local screen out rc
  screen=$(printf '%s\n' \
    'The fixture mentions Background work is running in a sentence' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel')
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a heading buried in a sentence must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  screen=$(printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm the deployment')
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a last line that only starts with the confirm words must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  pass "a buried heading or a different last line is not the exit picker"
}

test_dialog_note_skips_the_match_when_no_sink_is_set() {
  local screen out rc before after
  screen=$(exit_picker_screen)
  unset FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_note_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a note without a sink should return 1, got $rc"
  [ -z "$out" ] || fail "a note without a sink should print nothing, got '$out'"
  [ -z "${FM_COMPOSER_DIALOG_SINK:-}" ] || fail "a note without a sink must not create one"
  out=$(fm_composer_classify_screen 'styled=1' "$screen" 1)
  [ "$out" = pending ] || fail "classify without a sink should stay pending, got '$out'"
  trap 'true' RETURN
  before=$(trap -p RETURN)
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  fm_composer_dialog_sink_release
  after=$(trap -p RETURN)
  trap - RETURN
  [ "$before" = "$after" ] || fail "release replaced the caller RETURN trap: $after"
  pass "a dialog note without a sink skips the match, and release leaves a caller RETURN trap"
}

test_quoted_exit_picker_text_is_not_a_dialog() {
  local screen out rc sink enters
  screen=$(quoted_exit_picker_screen)
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "picker text quoted above a normal composer must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' \
    'Background work is running' \
    "+    '❯ 1. Exit and stop tasks' \\" \
    'Enter to confirm · Esc to cancel')"); rc=$?
  [ "$rc" -eq 1 ] || fail "a selected row that is not alone on its row must not match"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' \
    '❯ 1. Exit and stop tasks' \
    'Background work is running' \
    'Enter to confirm · Esc to cancel')"); rc=$?
  [ "$rc" -eq 1 ] || fail "a selected row above the heading must not match"
  FM_TEST_PICKER_SCREEN=$screen
  FM_TEST_PICKER_ENTERS=$(mktemp)
  : > "$FM_TEST_PICKER_ENTERS"
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  sink=$FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_submit_retry_core fm_test_picker_send fm_test_picker_state win 3 0)
  [ ! -s "$sink" ] || fail "quoted picker text must not be noted as a dialog, got '$(cat "$sink")'"
  fm_composer_dialog_sink_release
  enters=$(grep -c '^Enter$' "$FM_TEST_PICKER_ENTERS" || true)
  [ "$out" = pending ] || fail "quoted picker text must keep the ordinary pending verdict, got '$out'"
  [ "$enters" -eq 3 ] || fail "quoted picker text must keep the ordinary Enter retries, got $enters"
  rm -f "$FM_TEST_PICKER_ENTERS"
  unset FM_TEST_PICKER_SCREEN FM_TEST_PICKER_ENTERS
  pass "picker text quoted above a normal composer is not read as a live picker"
}

test_background_exit_picker_stays_pending_and_blocks_retry
test_dialog_heading_and_footer_must_be_the_recorded_lines
test_dialog_note_skips_the_match_when_no_sink_is_set
test_quoted_exit_picker_text_is_not_a_dialog

test_cursorless_submit_refreshes_pending_before_retry() (
  local dir backend initial final out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-retry.XXXXXX")
  trap 'rm -rf "$dir"' EXIT
  for backend in cmux orca zellij; do
    # shellcheck source=/dev/null
    . "$ROOT/bin/backends/$backend.sh"
    eval "fm_backend_${backend}_send_literal() { printf 'literal\n' >> \"\$dir/literals\"; }"
    eval "fm_backend_${backend}_send_key() { printf '%s\n' \"\$2\" >> \"\$dir/enters\"; }"
    eval "fm_backend_${backend}_composer_state() { retry_test_state; }"
    # Called indirectly by the dynamically sourced backends.
    # shellcheck disable=SC2329
    fm_backend_cmux_parse_target() { return 0; }
    # shellcheck disable=SC2329
    fm_backend_orca_tool_check() { return 0; }
    # shellcheck disable=SC2329
    fm_backend_zellij_composer_content() { printf ''; }
    # shellcheck disable=SC2329
    fm_backend_zellij_composer_observed_append() { return 0; }
    for initial in pending pending-unproven; do
      for final in empty unknown pending; do
        : > "$dir/enters"; : > "$dir/literals"; printf '0' > "$dir/reads"
        # Called by the eval-defined composer-state function.
        # shellcheck disable=SC2329
        retry_test_state() {
          local n
          n=$(cat "$dir/reads"); n=$((n + 1)); printf '%s' "$n" > "$dir/reads"
          if [ "$n" -eq 1 ]; then printf '%s' "$initial"; else printf '%s' "$final"; fi
        }
        out=$("fm_backend_${backend}_send_text_submit" target payload 2 0 0 label)
        [ "$out" = "$final" ] || fail "$backend $initial then $final returned '$out'"
        [ "$(wc -l < "$dir/literals" | tr -d ' ')" -eq 1 ] || fail "$backend must type only once"
        if [ "$final" = pending ]; then
          [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 2 ] || fail "$backend must retry fresh pending"
        else
          [ "$(wc -l < "$dir/enters" | tr -d ' ')" -eq 1 ] || fail "$backend must not retry fresh $final"
        fi
      done
    done
  done
  pass "cmux orca and zellij submit refresh pending frames without retyping"
)
test_cursorless_submit_refreshes_pending_before_retry
