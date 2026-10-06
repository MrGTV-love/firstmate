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
