#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions-read-saved)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/hidden" "$HOME_DIR/state"
trap 'chmod 755 "$HOME_DIR/data/hidden"; fm_test_cleanup' EXIT
printf '{"backlog":{"present":true,"records":[]},"tasks":[]}\n' > "$HOME_DIR/input.json"

contributions() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="${DATA_ROOT:-$HOME_DIR/data}" \
    FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z \
    "$ROOT/bin/fm-contributions.sh" "$@"
}

write_record() {
  local task=$1 bytes=$2
  mkdir -p "$HOME_DIR/data/$task"
  jq -njr --arg task "$task" --argjson bytes "$bytes" '
    {schema:"fm-contributions.v1",task:$task,records:[]} | tojson
    | . + (" " * ($bytes - length))' > "$HOME_DIR/data/$task/contributions.json"
}

assert_clear() {
  contributions pending > "$HOME_DIR/pending.json" || fail 'valid records were refused'
  [ "$(cat "$HOME_DIR/pending.json")" = '[]' ] || fail 'empty valid records produced pending signals'
  contributions snapshot "$HOME_DIR/input.json" > "$HOME_DIR/snapshot.json" || fail 'snapshot failed'
  cmp -s "$HOME_DIR/clear.json" "$HOME_DIR/snapshot.json" \
    || fail 'valid empty records changed the published snapshot bytes'
}

assert_refused() {
  if contributions pending > "$HOME_DIR/pending.json" 2> "$HOME_DIR/pending.err"; then
    fail 'unsafe record coverage was reported as an empty pending inbox'
  fi
  [ ! -s "$HOME_DIR/pending.json" ] || fail 'refused pending read emitted a verified inbox'
  contributions snapshot "$HOME_DIR/input.json" > "$HOME_DIR/snapshot.json" || fail 'snapshot failed'
  jq -e '.unreadable_records == 1 and .complete == false and .proven_clear == false' \
    "$HOME_DIR/snapshot.json" >/dev/null || fail 'unsafe records falsely proved complete coverage'
}

contributions snapshot "$HOME_DIR/input.json" > "$HOME_DIR/clear.json"
jq -e '.unreadable_records == 0 and .complete == true and .proven_clear == true' \
  "$HOME_DIR/clear.json" >/dev/null || fail 'empty-home coverage was not clear'
write_record visible 1048576
assert_clear
pass 'records at the 1 MiB cap preserve normal output bytes'

write_record hidden 1048577
assert_refused
pass 'bulk size enumeration refuses records above the cap'

chmod 111 "$HOME_DIR/data/hidden"
if find "$HOME_DIR/data" -mindepth 2 -maxdepth 2 -name contributions.json \
    -size +1048576c -print > "$HOME_DIR/scan.out" 2> "$HOME_DIR/scan.err"; then
  fail 'permission fixture did not cause incomplete size enumeration; run without root privileges'
fi
assert_refused
pass 'incomplete enumeration refuses oversized records in searchable unreadable directories'

chmod 755 "$HOME_DIR/data/hidden"
write_record hidden 1048576
chmod 111 "$HOME_DIR/data/hidden"
assert_clear
pass 'fallback accepts capped records and preserves readable sibling output'

chmod 000 "$HOME_DIR/data/hidden/contributions.json"
assert_refused
pass 'failed fallback size reads cannot prove clear coverage'
chmod 644 "$HOME_DIR/data/hidden/contributions.json"
chmod 755 "$HOME_DIR/data/hidden"

ln -s "$HOME_DIR/data" "$HOME_DIR/data-link"
for suffix in '' / ////; do
  DATA_ROOT="$HOME_DIR/data-link$suffix"
  assert_refused
done
unset DATA_ROOT
pass 'symlink data roots are refused with or without trailing slashes'

DATA_ROOT="$HOME_DIR/data////"
assert_clear
pass 'ordinary data roots retain byte-identical output with trailing slashes'
