#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-composer-lib.sh"

CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'

assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_native_prompt_continuations_own_literal_frames() {
  local continuation frame screen expected caps cursor last out frame_expected
  for continuation in '> quote' '# heading' '$ command' '% command' '❯ nested draft' '› nested draft' '⟩ nested draft' '→ nested draft'; do
    for frame in $'  ╭── π > model > path ─╮\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  ╰─  ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'; do
      screen=$'❯ preface\n  '"$continuation"$'\n'"$frame"
      case "$frame" in
        *'│ │'*) last=4; frame_expected='╭── π > model > path ─╮ │ │ ╰─ ─╯' ;;
        *) last=3; frame_expected='╭── π > model > path ─╮ ╰─ ─╯' ;;
      esac
      expected="preface $continuation $frame_expected"
      for caps in "$CAPS_STYLED" "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        if [ "$caps" = "$CAPS_PLAIN" ]; then
          assert_screen "plain native '$continuation' with literal frame" unknown "$caps" "$screen"
        else
          assert_screen "native '$continuation' with literal frame cursorless" pending "$caps" "$screen"
        fi
        out=$(fm_composer_extract_selected_content "$caps" "$screen")
        [ "$out" = "$expected" ] || fail "native '$continuation' extraction: expected '$expected', got '$out'"
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
        [ "$out" = "$expected" ] || fail "native '$continuation' extraction under LC_ALL=C: expected '$expected', got '$out'"
      done
      cursor=0
      while [ "$cursor" -le "$last" ]; do
        assert_screen "native '$continuation' literal frame cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
        cursor=$((cursor + 1))
      done
    done
  done

  screen=$'  ❯ preface\n      > quote\n    # heading\n    $ command\n    % command\n    ❯ nested draft\n    › nested draft\n    ⟩ nested draft\n    → nested draft\n    ╭── π > model > path ─╮\n    │ │\n    ╰─  ─╯'
  expected='preface > quote # heading $ command % command ❯ nested draft › nested draft ⟩ nested draft → nested draft ╭── π > model > path ─╮ │ │ ╰─ ─╯'
  assert_screen "indented native gutter with consecutive prompt literals" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "plain indented native gutter with consecutive prompt literals" unknown "$CAPS_PLAIN" "$screen"
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "consecutive native literal extraction: expected '$expected', got '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "consecutive native literal extraction under LC_ALL=C: expected '$expected', got '$out'"
  done
  for cursor in 0 1 2 3 4 5 6 7 8 9 10 11; do
    assert_screen "indented consecutive native literal cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
  done

  local glyph prefix shell_row status
  for glyph in '>' '#' '$' '%'; do
    for prefix in $'❯ preface\n ' $'  ❯ preface\n   ' $'❯ preface\n\n  ' $'❯ preface\n > independent shell\n  '; do
      screen="${prefix}${glyph} command"
      case "$prefix" in
        *$'\n\n'*|*'independent shell'*) shell_row=2 ;;
        *) shell_row=1 ;;
      esac
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "genuine '$glyph' shell after insufficient gutter or continuity boundary" unknown "$caps" "$screen"
        status=0
        out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
        [ "$status" -ne 0 ] && [ -z "$out" ] || fail "genuine '$glyph' shell must refuse extraction, got status $status and '$out'"
        status=0
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") || status=$?
        [ "$status" -ne 0 ] && [ -z "$out" ] || fail "genuine '$glyph' shell under LC_ALL=C must refuse extraction, got status $status and '$out'"
      done
      assert_screen "genuine '$glyph' shell cursor is not native input" unknown "$CAPS_TMUX" "$screen" "$shell_row"
      screen="$screen"$'\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'
      assert_screen "genuine '$glyph' shell boundary leaves frame independent" empty "$CAPS_STYLED_NOID" "$screen"
      assert_screen "genuine '$glyph' shell boundary leaves frame floor independent" empty "$CAPS_TMUX" "$screen" "$((shell_row + 3))"
      out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
      [ -z "$out" ] || fail "independent frame after genuine '$glyph' shell inherited native draft: '$out'"
      out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
      [ -z "$out" ] || fail "independent frame after genuine '$glyph' shell under LC_ALL=C inherited native draft: '$out'"
    done
  done
  pass "native gutter-backed prompt literals retain complete frames without claiming genuine shell boundaries"
}

test_native_prompt_continuations_own_literal_frames
