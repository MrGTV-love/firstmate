#!/usr/bin/env bash
# Behavior tests for bin/fm-scratch-legacy-reap.sh, the one-time removal of the
# unowned `<prefix>.XXXXXX` entries commands made before bin/fm-scratch-lib.sh.
# The proof rule: a known prefix with a six-character suffix, owned by this user,
# not a symlink, untouched for the age floor, and held open by nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; exit 0; }

REAPER="$ROOT/bin/fm-scratch-legacy-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-scratch-legacy-reap)
DIR="$TMP_ROOT/shared"
mkdir -p "$DIR"

old() { touch -t 202001010000 "$@"; }

# Candidates that must go.
mkdir "$DIR/fm-gh-rest.AAAAAA"; : > "$DIR/fm-gh-rest.AAAAAA/page.1"; old "$DIR/fm-gh-rest.AAAAAA/page.1" "$DIR/fm-gh-rest.AAAAAA"
: > "$DIR/fm-timeout-status.BBBBBB"; old "$DIR/fm-timeout-status.BBBBBB"
: > "$DIR/fm-lavish-poll.CCCCCC"; old "$DIR/fm-lavish-poll.CCCCCC"
# Entries that must stay.
: > "$DIR/fm-timeout-status.young1"                                   # too young
mkdir "$DIR/fm-gh-rest.DDDDDD"; : > "$DIR/fm-gh-rest.DDDDDD/page.1"; old "$DIR/fm-gh-rest.DDDDDD"  # a young file inside
: > "$DIR/fm-other-tool.EEEEEE"; old "$DIR/fm-other-tool.EEEEEE"      # not a known prefix
mkdir "$DIR/fm-fleet-tasks.123-Mon_Oct_1.FFFFFF"; old "$DIR/fm-fleet-tasks.123-Mon_Oct_1.FFFFFF"  # owner token
: > "$DIR/fm-gh-rest.GGGGGGG"; old "$DIR/fm-gh-rest.GGGGGGG"          # not a six-character suffix
mkdir "$TMP_ROOT/elsewhere"; : > "$TMP_ROOT/elsewhere/data"
ln -s "$TMP_ROOT/elsewhere" "$DIR/fm-gh-rest.HHHHHH"                  # a symlink
: > "$DIR/fm-session-start-stage.IIIIII"; old "$DIR/fm-session-start-stage.IIIIII"
exec 7< "$DIR/fm-session-start-stage.IIIIII"                          # held open by this shell

out=$(bash "$REAPER" --tmpdir "$DIR")
assert_contains "$out" "would remove $DIR/fm-gh-rest.AAAAAA" "dry run did not list an old directory"
assert_absent "$DIR/none" "sanity"
[ -d "$DIR/fm-gh-rest.AAAAAA" ] || fail "a dry run removed an entry"

out=$(bash "$REAPER" --tmpdir "$DIR" --apply)
assert_contains "$out" "removed $DIR/fm-gh-rest.AAAAAA" "apply did not remove the old directory"
assert_absent "$DIR/fm-gh-rest.AAAAAA" "an old unowned directory survived"
assert_absent "$DIR/fm-timeout-status.BBBBBB" "an old unowned file survived"
assert_absent "$DIR/fm-lavish-poll.CCCCCC" "an old unowned lavish file survived"
assert_present "$DIR/fm-timeout-status.young1" "a young entry was removed"
assert_present "$DIR/fm-gh-rest.DDDDDD" "a directory holding a young file was removed"
assert_present "$DIR/fm-other-tool.EEEEEE" "an entry of another prefix was removed"
assert_present "$DIR/fm-fleet-tasks.123-Mon_Oct_1.FFFFFF" "an owner-tokened fleet directory was removed"
assert_present "$DIR/fm-gh-rest.GGGGGGG" "an entry with a seven-character suffix was removed"
assert_present "$DIR/fm-gh-rest.HHHHHH" "a symlink was removed"
assert_present "$TMP_ROOT/elsewhere/data" "the target of a symlink was removed"
assert_present "$DIR/fm-session-start-stage.IIIIII" "an entry that a process holds open was removed"
exec 7<&-
out=$(bash "$REAPER" --tmpdir "$DIR" --apply)
assert_contains "$out" "removed $DIR/fm-session-start-stage.IIIIII" "the entry was not removed once nothing held it"
pass "the legacy reaper removes only old, unowned, unused entries of the known prefixes"

if bash "$REAPER" --tmpdir "$DIR" --min-age-days nope >/dev/null 2>&1; then
  fail "a nonnumeric age floor was accepted"
fi
pass "the legacy reaper refuses a nonnumeric age floor"
