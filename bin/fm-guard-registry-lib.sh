#!/usr/bin/env bash
# fm-guard-registry-lib.sh - the single owner of how a guard registry entry's
# `test` field is read. Sourced by bin/fm-guard-lint.sh (rule R7) and
# bin/fm-guard-refcheck.sh (registry wiring), so both judge the same paths.
#
# The field is a comma-separated list. Each item loses only its leading and
# trailing spaces and tabs; inner spaces stay literal, so an item is checked
# exactly as written. Empty items are dropped, and a field left with no item
# names no test. A field that is not a string is read as its JSON text, which
# names no existing file.
#
# fm_guard_registry_test_items <guard-json>
#   Prints one line per item: "path<TAB><item>" for an item to check exactly as
#   written, or "invalid<TAB><item as JSON>" for an item holding a line break,
#   which no single file check can match exactly. Prints nothing when the field
#   names no item. Returns nonzero when the entry cannot be read; a caller must
#   then refuse the entry rather than treat it as having no test.

fm_guard_registry_test_items() {  # <guard-json>
  printf '%s' "$1" | jq -r '
    (.test // "") | (if type == "string" then . else tojson end)
    | split(",")
    | map(sub("^[ \t]+"; "") | sub("[ \t]+$"; ""))
    | map(select(length > 0))
    | .[]
    | if test("[\n\r]") then "invalid\t" + tojson else "path\t" + . end'
}
