#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

CAPS_STYLED=$'styled=1\ncursor=0\nidentity=0\nrows=20'
CAPS_CURSOR=$'styled=1\ncursor=1\nidentity=0\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'

# omp v18.6.1's captured borderless empty row: the shortcut is bright,
# while only its explanation is muted and disappears during ghost stripping.
hint=$'\033[38;2;0;180;255m⇧⇥\033[0m \033[3m\033[38;2;107;114;128mto change thinking effort\033[0m'
screen=$'❯                                                                '"$hint"$'\n π · no-model · path · ◫ 14K/? ⟲'
for locale in '' C; do
  if [ -n "$locale" ]; then export LC_ALL=$locale; fi
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "native empty hint cursorless: expected empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_CURSOR" "$screen" 0)
  [ "$out" = empty ] || fail "native empty hint root cursor: expected empty, got '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen") \
    || fail 'native empty hint extraction refused'
  [ -z "$out" ] || fail "native empty hint or status extracted as draft: '$out'"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] || fail "unstyled hint cannot prove emptiness: got '$out'"

  # Typing either the shortcut or the entire hint is real draft content.
  for draft in '⇧⇥' '⇧⇥ to change thinking effort'; do
    screen_typed=$'❯ '"$draft"$'\n π · no-model · path · ◫ 14K/? ⟲'
    out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen_typed")
    [ "$out" = pending ] || fail "typed '$draft' cursorless: got '$out'"
    out=$(fm_composer_classify_screen "$CAPS_CURSOR" "$screen_typed" 0)
    [ "$out" = pending ] || fail "typed '$draft' root cursor: got '$out'"
    out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen_typed") \
      || fail "typed '$draft' extraction refused"
    [ "$out" = "$draft" ] || fail "typed hint lost: expected '$draft', got '$out'"
  done
  # The hint filter must not discard text preceding a hint-shaped suffix.
  screen_typed=$'❯ keep '"$hint"$'\n π · no-model · path · ◫ 14K/? ⟲'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen_typed")
  [ "$out" = pending ] || fail "hint-shaped suffix discarded real draft: '$out'"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen_typed")
  [ "$out" = 'keep ⇧⇥' ] || fail "hint-shaped suffix truncated draft: '$out'"
done
pass 'native empty hint is furniture only with styled empty-row proof'
