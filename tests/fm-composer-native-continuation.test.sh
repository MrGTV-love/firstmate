#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
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

test_owned_frame_status_substrings_remain_input() {
  local frame screen expected caps want cursor last out enclosed
  for frame in $'  ╭── π > model > path · 15.4%/272K ─╮\n  ╰─ ─╯' \
               $'  ╭── π > model > path ─╮\n  │ text · 15.4%/272K │\n  ╰─ ─╯' \
               $'  ╭── π > model > path ─╮\n  ╰─ text · 15.4%/272K ─╯'; do
    expected=${frame//$'\n'/ }
    expected=${expected//  /}
    case "$frame" in *'│'*) last=3 ;; *) last=2 ;; esac
    for enclosed in 0 1; do
      screen=$'❯ \n'"$frame"
      cursor=0
      if [ "$enclosed" = 1 ]; then
        screen=$'────────────────────\n'"$screen"$'\n────────────────────'
        cursor=1
      fi
      screen="$screen"$'\n π · model · 15.4%/272K'
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        want=pending
        [ "$caps" != "$CAPS_PLAIN" ] || want=unknown-draft
        assert_screen "owned frame status substring, enclosure=$enclosed" "$want" "$caps" "$screen"
        out=$(fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "owned frame status substring extraction refused"
        [ "$out" = "$expected" ] || fail "owned frame status substring extraction: expected '$expected', got '$out'"
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "owned frame status substring extraction under LC_ALL=C refused"
        [ "$out" = "$expected" ] || fail "owned frame status substring extraction under LC_ALL=C: expected '$expected', got '$out'"
      done
      while [ "$cursor" -le "$((last + enclosed))" ]; do
        assert_screen "owned frame status substring cursor row $cursor, enclosure=$enclosed" \
          pending "$CAPS_TMUX" "$screen" "$cursor" $'omp\tidle'
        cursor=$((cursor + 1))
      done
    done
  done
  screen=$'❯ \n π · model · 15.4%/272K'
  assert_screen "unowned status still bounds empty native root" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "unowned status still bounds empty root cursor" empty "$CAPS_TMUX" "$screen" 0
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
    || fail "empty root with unowned status extraction refused"
  [ -z "$out" ] || fail "unowned status was extracted as draft: '$out'"
  pass "owned frame header, body and floor status substrings preserve the entire draft"
}

test_owned_frame_status_substrings_remain_input

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
          assert_screen "plain native '$continuation' with literal frame" unknown-draft "$caps" "$screen"
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
      screen=$'❯ \n  '"$continuation"$'\n'"$frame"
      for cursor in 0 1; do
        assert_screen "empty native root with '$continuation' literal frame cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
      done
      assert_screen "plain empty native root with '$continuation' literal frame" unknown-draft \
        $'styled=0\ncursor=1\nidentity=0\nrows=20' "$screen" 0
    done
  done
  screen=$'❯ '
  assert_screen "native root after removing the multiline draft" empty "$CAPS_TMUX" "$screen" 0
  screen=$'  ❯ \n    → nested draft\n    ╭── π > model > path ─╮\n    │ │\n    ╰─ ─╯'
  assert_screen "indented empty native root retains its owned draft" pending "$CAPS_TMUX" "$screen" 0
  for continuation in '❯ nested draft' '› nested draft' '⟩ nested draft' '→ nested draft'; do
    screen=$'❯ \n '"$continuation"$'\n╭── π > model > path ─╮\n│ │\n╰─  ─╯'
    assert_screen "insufficient native gutter before '$continuation' does not claim the cursor" unknown-draft "$CAPS_TMUX" "$screen" 0
    assert_screen "insufficient native gutter before '$continuation' leaves standalone frame empty" empty "$CAPS_TMUX" "$screen" 4
  done

  screen=$'  ❯ preface\n      > quote\n    # heading\n    $ command\n    % command\n    ❯ nested draft\n    › nested draft\n    ⟩ nested draft\n    → nested draft\n    ╭── π > model > path ─╮\n    │ │\n    ╰─  ─╯'
  expected='preface > quote # heading $ command % command ❯ nested draft › nested draft ⟩ nested draft → nested draft ╭── π > model > path ─╮ │ │ ╰─ ─╯'
  assert_screen "indented native gutter with consecutive prompt literals" pending "$CAPS_STYLED_NOID" "$screen"
  assert_screen "plain indented native gutter with consecutive prompt literals" unknown-draft "$CAPS_PLAIN" "$screen"
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    out=$(fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "consecutive native literal extraction: expected '$expected', got '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen")
    [ "$out" = "$expected" ] || fail "consecutive native literal extraction under LC_ALL=C: expected '$expected', got '$out'"
  done
  for cursor in 0 1 2 3 4 5 6 7 8 9 10 11; do
    assert_screen "indented consecutive native literal cursor row $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
  done

  local glyph prefix shell_row status want
  for glyph in '>' '#' '$' '%'; do
    for prefix in $'❯ preface\n ' $'  ❯ preface\n   ' $'❯ preface\n\n  ' $'❯ preface\n > independent shell\n  '; do
      screen="${prefix}${glyph} command"
      case "$prefix" in
        *$'\n\n'*) shell_row=2; want=unknown-draft ;;
        *'independent shell'*) shell_row=2; want=unknown ;;
        *) shell_row=1; want=unknown ;;
      esac
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        assert_screen "'$glyph' shell after insufficient gutter or uncertain continuity" "$want" "$caps" "$screen"
        status=0
        out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
        [ "$status" -ne 0 ] && [ -z "$out" ] || fail "genuine '$glyph' shell must refuse extraction, got status $status and '$out'"
        status=0
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") || status=$?
        [ "$status" -ne 0 ] && [ -z "$out" ] || fail "genuine '$glyph' shell under LC_ALL=C must refuse extraction, got status $status and '$out'"
      done
      assert_screen "genuine '$glyph' shell cursor is not native input" "$want" "$CAPS_TMUX" "$screen" "$shell_row"
      screen="$screen"$'\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'
      case "$prefix" in
        *$'\n\n'*)
          assert_screen "blank-separated native '$glyph' cannot prove an independent frame" unknown-draft "$CAPS_STYLED_NOID" "$screen"
          assert_screen "blank-separated native '$glyph' frame floor stays ambiguous" unknown-draft "$CAPS_TMUX" "$screen" "$((shell_row + 3))"
          for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
            status=0
            out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
            [ "$status" -ne 0 ] && [ -z "$out" ] || fail "blank-separated native '$glyph' must refuse incomplete extraction"
          done
          ;;
        *)
          assert_screen "genuine '$glyph' shell boundary leaves frame independent" empty "$CAPS_STYLED_NOID" "$screen"
          assert_screen "genuine '$glyph' shell boundary leaves frame floor independent" empty "$CAPS_TMUX" "$screen" "$((shell_row + 3))"
          out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
          [ -z "$out" ] || fail "independent frame after genuine '$glyph' shell inherited native draft: '$out'"
          out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
          [ -z "$out" ] || fail "independent frame after genuine '$glyph' shell under LC_ALL=C inherited native draft: '$out'"
          ;;
      esac
    done
  done
  pass "native gutter-backed prompt literals retain complete frames without claiming genuine shell boundaries"
}

test_native_prompt_continuations_own_literal_frames

test_separator_enclosed_native_prompt_continuations() {
  local continuation frame screen expected frame_expected last cursor caps out identity
  local bright=$'\033[1;38;2;255;255;255m' reset=$'\033[0m'
  for continuation in '❯ nested draft' '› nested draft' '⟩ nested draft' '→ nested draft' '❭ nested draft'; do
    for frame in '' \
                 $'  ╭── π > model > path ─╮\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  ╰─  ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'; do
      screen=$'────────\n❯ \n  '"$continuation"
      expected="$continuation"
      case "$frame" in
        '') last=2 ;;
        *'│ │'*)
          last=5
          frame_expected='╭── π > model > path ─╮ │ │ ╰─ ─╯'
          ;;
        *)
          last=4
          frame_expected='╭── π > model > path ─╮ ╰─ ─╯'
          ;;
      esac
      if [ -n "$frame" ]; then
        screen="$screen"$'\n'"$frame"
        expected="$expected $frame_expected"
      fi
      screen="$screen"$'\n────────'
      assert_screen "separator native '$continuation' complete styled draft" pending "$CAPS_STYLED_NOID" "$screen"
      assert_screen "separator native '$continuation' plain draft stays unproven" unknown-draft "$CAPS_PLAIN" "$screen"
      assert_screen "separator native '$continuation' lazily requests identity" need-identity "$CAPS_STYLED" "$screen"
      for identity in probe-absent $'zsh\t' $'claude\tidle' $'pi\tidle' $'pi\tworking'; do
        assert_screen "separator native '$continuation' identity '$identity' keeps complete draft" pending \
          "$CAPS_STYLED" "$screen" '' "$identity"
      done
      assert_screen "plain separator native '$continuation' Pi owns literal content" pending \
        $'styled=0\ncursor=0\nidentity=1\nrows=20' "$screen" '' $'pi\tidle'
      assert_screen "plain separator native '$continuation' non-Pi stays unproven" unknown-draft \
        $'styled=0\ncursor=0\nidentity=1\nrows=20' "$screen" '' $'zsh\t'
      for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
        out=$(fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "separator native '$continuation' complete extraction refused"
        [ "$out" = "$expected" ] || fail "separator native '$continuation' extraction: expected '$expected', got '$out'"
        out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") \
          || fail "separator native '$continuation' complete extraction under LC_ALL=C refused"
        [ "$out" = "$expected" ] || fail "separator native '$continuation' extraction under LC_ALL=C: expected '$expected', got '$out'"
      done
      cursor=1
      while [ "$cursor" -le "$last" ]; do
        assert_screen "separator native '$continuation' cursor row $cursor absent identity" pending \
          "$CAPS_TMUX" "$screen" "$cursor" probe-absent
        cursor=$((cursor + 1))
      done
      assert_screen "separator native '$continuation' empty root requests identity" need-identity "$CAPS_TMUX" "$screen" 1
      assert_screen "separator native '$continuation' empty root non-Pi identity" pending "$CAPS_TMUX" "$screen" 1 $'zsh\t'
      assert_screen "separator native '$continuation' empty root Pi identity" pending "$CAPS_TMUX" "$screen" 1 $'pi\tidle'
      assert_screen "separator native '$continuation' final content row Pi identity" pending "$CAPS_TMUX" "$screen" "$last" $'pi\tidle'
      assert_screen "plain separator native '$continuation' empty root stays unproven" unknown-draft \
        $'styled=0\ncursor=1\nidentity=0\nrows=20' "$screen" 1
    done
    screen=$'────────\n'"${bright}❯ ${reset}"$'\n  '"${bright}${continuation}${reset}"$'\n  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯\n────────'
    expected="$continuation ╭── π > model > path ─╮ │ │ ╰─ ─╯"
    assert_screen "bright separator native '$continuation' root cursor" pending "$CAPS_TMUX" "$screen" 1 probe-absent
    assert_screen "bright separator native '$continuation' cursorless" pending "$CAPS_STYLED_NOID" "$screen"
    out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
      || fail "bright separator native '$continuation' extraction refused"
    [ "$out" = "$expected" ] || fail "bright separator native '$continuation' extraction changed literal content: '$out'"
    out=$(LC_ALL=C fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen") \
      || fail "bright separator native '$continuation' extraction under LC_ALL=C refused"
    [ "$out" = "$expected" ] || fail "bright separator native '$continuation' extraction under LC_ALL=C changed literal content: '$out'"
  done
  pass "separator-enclosed native prompt continuations retain every draft row and literal frame"
}

test_separator_enclosed_native_prompt_continuations

test_blank_boundary_prompt_transitions() {
  local glyph frame transition screen last cursor caps out status
  for glyph in '>' '$' '%' '#' '❯' '›' '⟩' '→' '❭'; do
    for frame in $'  ╭── π > model > path ─╮\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  ╰─  ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─ ─╯' \
                 $'  ╭── π > model > path ─╮\n  │ │\n  ╰─  ─╯'; do
      case "$frame" in *'│ │'*) last=5 ;; *) last=4 ;; esac
      for transition in before after; do
        screen=$'❯ preface\n  \n'
        if [ "$transition" = before ]; then
          screen="$screen  $glyph quote"$'\n'"$frame"
        else
          screen="$screen$frame"$'\n'"  $glyph "
        fi
        for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
          assert_screen "blank-boundary '$glyph' $transition frame remains ambiguous" unknown-draft "$caps" "$screen"
          status=0
          out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
          [ "$status" -ne 0 ] && [ -z "$out" ] || fail "blank-boundary '$glyph' $transition frame must refuse extraction, got $status '$out'"
          status=0
          out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") || status=$?
          [ "$status" -ne 0 ] && [ -z "$out" ] || fail "blank-boundary '$glyph' $transition frame under LC_ALL=C must refuse extraction"
        done
        for cursor in 0 2 "$((last - 1))" "$last"; do
          assert_screen "blank-boundary '$glyph' $transition frame cursor row $cursor" unknown-draft "$CAPS_TMUX" "$screen" "$cursor" probe-absent
        done
      done
    done
  done
  pass "blank-boundary prompt glyphs cannot reset native roots or escape frame ambiguity"
}

test_blank_boundary_prompt_transitions

test_reported_one_space_nested_draft() {
  local screen=$'❯ preface\n ❯ nested draft' caps cursor identity
  for caps in "$CAPS_STYLED_NOID" "$CAPS_PLAIN"; do
    assert_screen "reported one-space nested draft preserves risk" unknown-draft "$caps" "$screen"
  done
  for caps in "$CAPS_TMUX" $'styled=0\ncursor=1\nidentity=1\nrows=20'; do
    for cursor in 0 1; do
      assert_screen "reported one-space nested draft cursor $cursor" unknown-draft "$caps" "$screen" "$cursor"
    done
  done
  screen=$'────────\n❯ preface\n ❯ nested draft\n────────'
  assert_screen "enclosed one-space draft lazily probes identity" need-identity "$CAPS_STYLED" "$screen"
  assert_screen "enclosed one-space draft without identity" unknown-draft "$CAPS_STYLED_NOID" "$screen"
  for identity in probe-absent $'claude\tidle' $'zsh\t'; do
    assert_screen "enclosed one-space draft denied identity '$identity'" unknown-draft "$CAPS_STYLED" "$screen" '' "$identity"
  done
  assert_screen "enclosed one-space draft proven Pi" pending "$CAPS_STYLED" "$screen" '' $'pi\tidle'
  screen="$screen"$'\n❯ '
  assert_screen "independent newer empty prompt ignores enclosed ambiguity" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "plain independent newer empty prompt ignores enclosed ambiguity" empty "$CAPS_PLAIN" "$screen"
}

test_reported_one_space_nested_draft
