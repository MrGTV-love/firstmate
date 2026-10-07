#!/usr/bin/env bash
# Shared public composer APIs for native omp's default band, including saved
# omp 18.6.3 captures. Run: bash tests/fm-composer-native-band.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=0\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'
HEADER='π > ⬢ Apple AFM 3 Core Advanced > 📁 /work > ⑂ main ▶────86%┃──8.2K─'
BAND=$' '"$HEADER"$'\n╰─'

assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

assert_content() {
  local label=$1 want=$2 caps=$3 screen=$4 out
  out=$(fm_composer_extract_selected_content "$caps" "$screen") \
    || fail "$label: extraction refused"
  [ "$out" = "$want" ] || fail "$label: expected '$want', got '$out'"
  out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") \
    || fail "$label under LC_ALL=C: extraction refused"
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected '$want', got '$out'"
}

assert_refused() {
  local label=$1 screen=$2 caps out status
  for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
    assert_screen "$label" unknown "$caps" "$screen"
    status=0
    out=$(fm_composer_extract_selected_content "$caps" "$screen") || status=$?
    [ "$status" -ne 0 ] && [ -z "$out" ] || fail "$label: extraction must refuse, got $status '$out'"
    status=0
    out=$(LC_ALL=C fm_composer_extract_selected_content "$caps" "$screen") || status=$?
    [ "$status" -ne 0 ] && [ -z "$out" ] || fail "$label under LC_ALL=C: extraction must refuse"
  done
}

# These are the saved default-renderer surfaces, not the older compact box.
for state in empty pending; do
  screen=$(cat "$ROOT/tests/fixtures/omp-native-band-$state.ansi")
  floor=$(printf '%s\n' "$screen" | fm_composer_strip_ansi | awk '/^╰─/ {print NR - 1}')
  [ -n "$floor" ] || fail "captured $state surface has no input floor"
  expected=''
  [ "$state" != pending ] || expected='!git diff'
  for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
    assert_screen "saved native $state band" "$state" "$caps" "$screen"
    assert_content "saved native $state band" "$expected" "$caps" "$screen"
  done
  assert_screen "saved native $state band cursor" "$state" "$CAPS_TMUX" "$screen" "$floor"
done
pass "saved omp 18.6.3 native empty and command draft bands agree across public APIs and locales"

for draft in '!git diff' '!!git diff' '!python print(1)' '#' '>' '$' '%' '❯' '|draft|' '⇧⇥ to change thinking effort'; do
  screen="$BAND $draft"
  for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
    assert_screen "literal band draft '$draft'" pending "$caps" "$screen"
    assert_content "literal band draft '$draft'" "$draft" "$caps" "$screen"
  done
  assert_screen "literal band draft '$draft' cursor" pending "$CAPS_TMUX" "$screen" 1
done

for continuation in 'second line' '> quote' '❯ nested draft' '|draft|' '│ literal │' '╰─' "$HEADER" 'π · model · 15.4%/272K'; do
  screen="$BAND !git diff"$'\n   '"$continuation"
  expected="!git diff $continuation"
  for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
    assert_screen "band literal continuation '$continuation'" pending "$caps" "$screen"
    assert_content "band literal continuation '$continuation'" "$expected" "$caps" "$screen"
  done
  for cursor in 1 2; do
    assert_screen "band continuation cursor $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
  done
done
screen="$BAND"$'\n   '"$HEADER"$'\n   ╰─\n   │ literal │'
expected="$HEADER ╰─ │ literal │"
assert_screen "empty band floor retains pasted band and literal borders" pending "$CAPS_STYLED" "$screen"
assert_content "empty band floor retains pasted band and literal borders" "$expected" "$CAPS_STYLED" "$screen"
for cursor in 1 2 3 4; do
  assert_screen "pasted band within native band cursor $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
done
pass "native band floor and three-space continuations retain command drafts and literal border-looking bytes"

# A native-looking band pasted into an existing bare/Pi draft cannot replace it.
frame=$'   '"$HEADER"$'\n  ╰─\n     second line'
expected="preface $HEADER ╰─ second line"
screen=$'❯ preface\n'"$frame"
assert_screen "bare draft owns pasted native band" pending "$CAPS_STYLED" "$screen"
for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
  assert_content "bare draft owns pasted native band" "$expected" "$caps" "$screen"
done
for cursor in 0 1 2 3; do
  assert_screen "bare-owned native band cursor $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
done
screen=$'────────\n'"$BAND"$'\n────────'
expected="$HEADER ╰─"
assert_screen "Pi owns pasted native band" pending "$CAPS_TMUX" "$screen" 2 $'pi\tidle'
assert_screen "Pi owns pasted native band cursorless" pending $'styled=1\ncursor=0\nidentity=1' "$screen" '' $'pi\tidle'
assert_content "Pi owns pasted native band" "$expected" "$CAPS_PLAIN" "$screen"
pass "bare and Pi enclosing drafts retain ownership of pasted native bands"

for blocker in '' 'π · model' '│ │' '⠂⠁'; do
  screen=$'❯ preface\n  '"$blocker"$'\n'"$frame"
  assert_refused "bare ambiguous '$blocker' before pasted band" "$screen"
  for cursor in 0 2 3; do
    assert_screen "bare ambiguous '$blocker' band cursor $cursor" unknown "$CAPS_TMUX" "$screen" "$cursor"
  done
done
for suffix in $'\n\n   second line' $'\n  second line'; do
  screen="$BAND$suffix"
  assert_refused "unproven native band continuation" "$screen"
  assert_screen "unproven native band floor cursor" unknown "$CAPS_TMUX" "$screen" 1
done
assert_refused "band header alone" " $HEADER"
assert_refused "band missing usage meter" $' π > model > 📁 /work > ⑂ main\n╰─'
assert_refused "band misaligned floor" $'  '"$HEADER"$'\n╰─'
assert_refused "band stale above shell" "$BAND"$'\n$ command'
assert_refused "band stale above stray border" "$BAND"$'\n│ │'
assert_screen "band header cannot claim cursor" unknown "$CAPS_TMUX" "$BAND" 0
assert_screen "standalone compact omp box stays supported" empty "$CAPS_STYLED" $'╭── π > model > path ─╮\n╰─  ─╯'
assert_screen "standalone band after independent shell stays supported" empty "$CAPS_STYLED" $'$ command\n'"$BAND"
pass "native band admission remains narrow and ambiguous continuations refuse classification and extraction"

test_cursor_ambiguity_survives_later_band_continuations() {
  local prefix screen suffix cursor
  prefix=$'❯ preface\n\n ╭── π > model > path ─╮\n │ │\n ╰─ ─╯'
  screen="$prefix"$'\n π > model > 📁 /work > ⑂ main ▶86%┃8.2K─\n ╰─\n\n second line'
  assert_screen "reported compact floor ambiguity with later band" unknown "$CAPS_TMUX" "$screen" 4
  for suffix in $'\n\n   second line' $'\n second line' $'\n  second line'; do
    screen="$prefix"$'\n '"$HEADER"$'\n╰─'"$suffix"
    for cursor in 0 2 3 4; do
      assert_screen "cursor-owned compact ambiguity survives later band '$suffix', cursor $cursor" \
        unknown "$CAPS_TMUX" "$screen" "$cursor"
    done
    assert_refused "cursorless compact ambiguity and later band '$suffix'" "$screen"
  done
  pass "later band gaps and short gutters cannot replace cursor-owned compact ambiguity"
}

test_owned_band_blank_and_braille_continuations() {
  local root frame screen expected continuation caps cursor prefix
  for prefix in '' '  '; do
    root="${prefix}❯ preface"
    for continuation in '     ' '     ⠂⠁'; do
      frame="${prefix}   $HEADER"$'\n'"${prefix}  ╰─"$'\n'"${prefix}${continuation}"$'\n'"${prefix}     keep tail"
      screen="$root"$'\n'"$frame"
      expected="preface $HEADER ╰─"
      case "$continuation" in *'⠂⠁'*) expected="$expected ⠂⠁" ;; esac
      expected="$expected keep tail"
      assert_screen "owned band gutter '$continuation', root '$prefix'" pending "$CAPS_STYLED" "$screen"
      assert_screen "plain owned band gutter '$continuation', root '$prefix'" unknown "$CAPS_PLAIN" "$screen"
      for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
        assert_content "owned band gutter '$continuation', root '$prefix'" "$expected" "$caps" "$screen"
      done
      for cursor in 0 1 2 3 4; do
        assert_screen "owned band gutter '$continuation', root '$prefix', cursor $cursor" \
          pending "$CAPS_TMUX" "$screen" "$cursor"
      done
    done
  done
  screen=$'❯ preface\n π > model > 📁 /work > ⑂ main ▶86%┃8.2K─\n ╰─\n ⠂⠁\n keep tail'
  assert_refused "reported band and braille capture with unproven gutter" "$screen"
  for continuation in '   ' '   ⠂⠁'; do
    screen="$BAND"$'\n'"$continuation"$'\n   keep tail'
    expected='keep tail'
    case "$continuation" in *'⠂⠁'*) expected="⠂⠁ $expected" ;; esac
    for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
      assert_screen "standalone band gutter '$continuation'" pending "$caps" "$screen"
      assert_content "standalone band gutter '$continuation'" "$expected" "$caps" "$screen"
    done
    for cursor in 1 2 3; do
      assert_screen "standalone band gutter '$continuation', cursor $cursor" pending "$CAPS_TMUX" "$screen" "$cursor"
    done
  done
  pass "owned band blank and braille gutters retain every content row while unproven gutters refuse extraction"
}

test_stale_ambiguous_band_does_not_veto_newer_composer() {
  local stale shape draft candidate screen caps candidate_caps want cursor
  stale=$'π > model > 📁 /work > ⑂ main ▶86%┃8.2K─\n╰─'
  assert_refused "reported ambiguous band without a newer composer" "$stale"
  for shape in bare ompbox leftbar pi; do
    for draft in '' 'newer draft'; do
      case "$shape" in
        bare) candidate="❯ $draft"; cursor=3 ;;
        ompbox) candidate=$'╭── 󰵗 > model > path ─╮\n╰─ '"$draft"' ─╯'; cursor=4 ;;
        leftbar) candidate=$'┃\n┃  '"$draft"$'\n┃'; cursor=4 ;;
        pi) candidate=$'────────\n'"$draft"$'\n────────'; cursor=4 ;;
      esac
      screen="$stale"$'\n\n'"$candidate"
      for caps in "$CAPS_STYLED" "$CAPS_PLAIN"; do
        candidate_caps=$caps
        [ "$shape" != pi ] || candidate_caps="$caps"$'\nidentity=1'
        want=empty
        if [ -n "$draft" ]; then
          want=pending
          if [ "$caps" = "$CAPS_PLAIN" ] && { [ "$shape" = bare ] || [ "$shape" = leftbar ]; }; then
            want=unknown
          fi
        fi
        assert_screen "stale ambiguous band below newer $shape '$draft'" "$want" \
          "$candidate_caps" "$screen" '' $'pi\tidle'
        assert_content "stale ambiguous band extracts only newer $shape '$draft'" "$draft" \
          "$candidate_caps" "$screen"
      done
      want=empty
      [ -z "$draft" ] || want=pending
      assert_screen "newer $shape cursor ignores stale ambiguous band" "$want" \
        "$CAPS_TMUX" "$screen" "$cursor" $'pi\tidle'
      assert_screen "cursor in old ambiguous band still refuses below newer $shape" unknown \
        "$CAPS_TMUX" "$screen" 1 $'pi\tidle'
    done
  done
  pass "newer bare, compact omp, left-bar and Pi composers outrank stale band ambiguity without weakening cursor refusal"
}

test_cursor_ambiguity_survives_later_band_continuations
test_owned_band_blank_and_braille_continuations
test_stale_ambiguous_band_does_not_veto_newer_composer
