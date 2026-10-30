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
mkdir -p "$DIR/fm-gh-rest.JJJJJJ/sub"; : > "$DIR/fm-gh-rest.JJJJJJ/sub/page.1"
old "$DIR/fm-gh-rest.JJJJJJ/sub/page.1" "$DIR/fm-gh-rest.JJJJJJ/sub" "$DIR/fm-gh-rest.JJJJJJ"
(exec 3< "$DIR/fm-gh-rest.JJJJJJ/sub/page.1" && exec sleep 120) &     # a file open inside a subdirectory
holder_pid=$!
mkdir -p "$DIR/fm-contributions.KKKKKK/sub"; old "$DIR/fm-contributions.KKKKKK/sub" "$DIR/fm-contributions.KKKKKK"
(cd "$DIR/fm-contributions.KKKKKK/sub" && exec sleep 120) &           # a working directory inside a subdirectory
cwd_pid=$!
tries=0
until lsof -a -p "$holder_pid" -F n 2>/dev/null | grep -qx "n$DIR/fm-gh-rest.JJJJJJ/sub/page.1" &&
  lsof -a -p "$cwd_pid" -d cwd -F n 2>/dev/null | grep -qx "n$DIR/fm-contributions.KKKKKK/sub"; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || fail "the holder processes never opened their paths"
  sleep 0.05
done

out=$(bash "$REAPER" --tmpdir "$DIR")
assert_contains "$out" "would remove $DIR/fm-gh-rest.AAAAAA: legacy scratch entry of this user, nothing under it changed for 2 days, open in no process" \
  "dry run did not list an old directory with its reason"
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
assert_present "$DIR/fm-gh-rest.JJJJJJ/sub/page.1" "an entry with a file open in its subdirectory was removed"
assert_present "$DIR/fm-contributions.KKKKKK/sub" "an entry holding a process's working directory was removed"
exec 7<&-
kill -KILL "$holder_pid" "$cwd_pid" 2>/dev/null || true
wait "$holder_pid" "$cwd_pid" 2>/dev/null || true
out=$(bash "$REAPER" --tmpdir "$DIR" --apply)
assert_contains "$out" "removed $DIR/fm-session-start-stage.IIIIII" "the entry was not removed once nothing held it"
assert_contains "$out" "removed $DIR/fm-gh-rest.JJJJJJ" "the subdirectory-open entry was not removed once nothing held it"
assert_contains "$out" "removed $DIR/fm-contributions.KKKKKK" "the subdirectory-cwd entry was not removed once nothing held it"
pass "the legacy reaper removes only old, unowned, unused entries of the known prefixes"

if bash "$REAPER" --tmpdir "$DIR" --min-age-days nope >/dev/null 2>&1; then
  fail "a nonnumeric age floor was accepted"
fi
pass "the legacy reaper refuses a nonnumeric age floor"

: > "$DIR/fm-gh-rest.LLLLLL"; old "$DIR/fm-gh-rest.LLLLLL"
status=0
out=$(cd "$DIR" && TMPDIR="$DIR" bash "$REAPER" --apply 2>&1) || status=$?
assert_equals 2 "$status" "the legacy reaper ran without --tmpdir"
assert_contains "$out" "--tmpdir DIR is required" "the legacy reaper did not name the missing --tmpdir"
assert_present "$DIR/fm-gh-rest.LLLLLL" "the legacy reaper removed an entry of TMPDIR without --tmpdir"
pass "the legacy reaper refuses to run without an explicit --tmpdir, even with --apply"

# A failed age inspection proves nothing about age: the entry stays. Two ways
# the probe fails: `find` exits nonzero with no output at all, and `find` meets a
# directory it cannot read inside an old entry (it lists nothing for it).
FRESH="$TMP_ROOT/fresh"
mkdir -p "$FRESH" "$TMP_ROOT/failing-find-bin"
mkdir "$FRESH/fm-gh-rest.JJJJJJ"; : > "$FRESH/fm-gh-rest.JJJJJJ/fresh-payload"       # young contents
mkdir "$FRESH/fm-gh-rest.KKKKKK"; : > "$FRESH/fm-gh-rest.KKKKKK/payload"; old "$FRESH/fm-gh-rest.KKKKKK/payload" "$FRESH/fm-gh-rest.KKKKKK"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/failing-find-bin/find"
chmod +x "$TMP_ROOT/failing-find-bin/find"
out=$(PATH="$TMP_ROOT/failing-find-bin:$PATH" bash "$REAPER" --tmpdir "$FRESH" --apply 2>&1)
status=$?
case "$out" in *removed*|*"would remove"*) fail "an age probe that failed let an entry be listed for removal: $out" ;; esac
assert_present "$FRESH/fm-gh-rest.JJJJJJ/fresh-payload" "an age probe that exited nonzero with no output deleted fresh contents"
assert_present "$FRESH/fm-gh-rest.KKKKKK/payload" "an age probe that exited nonzero with no output deleted an old entry it could not inspect"
[ "$status" -eq 0 ] || fail "a failed age probe made the reaper exit $status instead of keeping the entries: $out"
pass "the legacy reaper keeps every entry whose age it could not inspect, even with fresh contents"

mkdir -p "$FRESH/unreadable"
mkdir "$FRESH/unreadable/fm-gh-rest.LLLLLL" "$FRESH/unreadable/fm-gh-rest.LLLLLL/locked"
: > "$FRESH/unreadable/fm-gh-rest.LLLLLL/locked/fresh-payload"
old "$FRESH/unreadable/fm-gh-rest.LLLLLL"
chmod 000 "$FRESH/unreadable/fm-gh-rest.LLLLLL/locked"
out=$(bash "$REAPER" --tmpdir "$FRESH/unreadable" --apply 2>&1)
chmod 755 "$FRESH/unreadable/fm-gh-rest.LLLLLL/locked"
case "$out" in *removed*) fail "an entry with an unreadable directory was removed: $out" ;; esac
assert_present "$FRESH/unreadable/fm-gh-rest.LLLLLL/locked/fresh-payload" "fresh contents behind an unreadable directory were deleted"
pass "the legacy reaper keeps an entry whose traversal was incomplete"
