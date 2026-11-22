#!/usr/bin/env bash
# Regression tests for bin/fm-home-write.sh, the home-state-write guard.
#
# Every case runs the real entry point against a disposable git home and
# observes the filesystem by content hash and existence, never only by the
# script's exit status.
# The sensitivity case swaps in an unguarded engine and shows the same
# observations do detect a harmful write, so the refusal assertions can fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-write)
BIN="$ROOT/bin"
WRITE="$BIN/fm-home-write.sh"

sha() { if [ -e "$1" ] || [ -L "$1" ]; then shasum -a 256 < "$1" | cut -d' ' -f1; else echo absent; fi; }

make_home() {  # <name> [gitignore-body]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects/p"
  printf '%s\n' "${2:-data/
state/
config/
projects/
.env}" > "$home/.gitignore"
  printf 'echo tracked\n' > "$home/bin/x.sh"
  printf 'forced record\n' > "$home/data/forced.md"
  printf 'existing record\n' > "$home/data/existing.md"
  printf 'SECRET=1\n' > "$home/.env"
  printf 'acct\n' > "$home/config/claude-account"
  git -C "$home" init -q
  git -C "$home" add .gitignore bin/x.sh
  git -C "$home" add -f data/forced.md
  git -C "$home" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
  printf '%s\n' "$home"
}

run_write() {  # <home> <content> <args...>
  local home=$1 content=$2
  shift 2
  printf '%s' "$content" | FM_HOME="$home" FM_GUARD_EVENT_LOG="$home.events" "$WRITE" "$@" >/dev/null 2>&1
}

expect_refused() {  # <label> <home> <path-to-observe> <args...>
  local label=$1 home=$2 observe=$3 before rc
  shift 3
  before=$(sha "$observe")
  run_write "$home" "harmful bytes" "$@"
  rc=$?
  [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ] || fail "$label: expected refusal, exit $rc"
  [ "$(sha "$observe")" = "$before" ] || fail "$label: $observe changed despite refusal"
}

event_count() {  # <home> <decision>
  grep -c "\"guard\":\"home-state-write\".*\"decision\":\"$2\"" "$1.events" 2>/dev/null || true
}

H=$(make_home main)

test_new_data_record() {
  local content="new record body
" target="$H/data/new-dir/sub/rec.md"
  run_write "$H" "$content" data/new-dir/sub/rec.md || fail "C1: create refused"
  [ "$(sha "$target")" = "$(printf '%s' "$content" | shasum -a 256 | cut -d' ' -f1)" ] || fail "C1: bytes did not land"
  run_write "$H" "abs" "$H/data/abs.md" || fail "C1: absolute path refused"
  [ "$(cat "$H/data/abs.md")" = abs ] || fail "C1: absolute bytes did not land"
  pass "C1-new-data-record"
}

test_tracked_source() {
  expect_refused C2 "$H" "$H/bin/x.sh" --replace bin/x.sh
  expect_refused C2 "$H" "$H/bin/x.sh" --replace "$H/bin/x.sh"
  pass "C2-tracked-source"
}

test_force_added_data() {
  expect_refused C3 "$H" "$H/data/forced.md" --replace data/forced.md
  pass "C3-force-added-data"
}

test_projects_path() {
  expect_refused C4 "$H" "$H/projects/p/file.py" projects/p/file.py
  [ ! -e "$H/projects/p/file.py" ] || fail "C4: projects file created"
  pass "C4-projects-path"
}

test_other_ignored_roots() {
  expect_refused C5 "$H" "$H/.env" --replace .env
  expect_refused C5 "$H" "$H/config/claude-account" --replace config/claude-account
  expect_refused C5 "$H" "$H/state/t.status" state/t.status
  pass "C5-other-ignored-roots"
}

test_symlink_escape() {
  local listing
  ln -s ../bin "$H/data/linkdir"
  ln -s ../bin/x.sh "$H/data/linkfile"
  listing=$(ls "$H/bin")
  expect_refused C6 "$H" "$H/bin/x.sh" --replace data/linkdir/x.sh
  expect_refused C6 "$H" "$H/bin/new.sh" data/linkdir/new.sh
  expect_refused C6 "$H" "$H/bin/x.sh" --replace data/linkfile
  [ "$(ls "$H/bin")" = "$listing" ] || fail "C6: bin/ gained a file"
  [ -L "$H/data/linkfile" ] || fail "C6: final symlink was replaced"
  for target in data/linkdir/x.sh data/linkfile; do
    run_write "$H" "x" --replace "$target"
    [ $? -eq 3 ] || fail "C6: $target was not refused as a symbolic link"
  done
  pass "C6-symlink-escape"
}

test_dot_segments() {
  expect_refused C7 "$H" "$H/bin/x.sh" --replace data/../bin/x.sh
  expect_refused C7 "$H" "$H/bin/x.sh" --replace "$H/data/./../bin/x.sh"
  pass "C7-dot-segments"
}

test_existing_needs_replace() {
  expect_refused C8 "$H" "$H/data/existing.md" data/existing.md
  chmod 600 "$H/data/existing.md"
  run_write "$H" "replaced" --replace data/existing.md || fail "C8: --replace refused"
  [ "$(cat "$H/data/existing.md")" = replaced ] || fail "C8: replace bytes did not land"
  [ "$(stat -f %Lp "$H/data/existing.md" 2>/dev/null || stat -c %a "$H/data/existing.md")" = 600 ] || fail "C8: mode not kept"
  pass "C8-existing-needs-replace"
}

test_outside_home() {
  local outside="$TMP_ROOT/outside.md"
  expect_refused C9 "$H" "$outside" "$outside"
  [ ! -e "$outside" ] || fail "C9: outside file created"
  pass "C9-outside-home"
}

test_unignored_data() {
  local n
  n=$(make_home negation "data/*
!data/keep.md
state/
config/
projects/
.env")
  expect_refused C10 "$n" "$n/data/keep.md" data/keep.md
  run_write "$n" "fine" data/other.md || fail "C10: an ignored sibling was refused"
  pass "C10-unignored-data"
}

test_missing_evidence() {
  local plain="$TMP_ROOT/not-git" rc
  mkdir -p "$plain/data"
  printf 'x' | env -u FM_HOME FM_GUARD_EVENT_LOG="$TMP_ROOT/unset.events" "$WRITE" "$plain/data/a.md" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 4 ] || fail "C11: unset FM_HOME exit $rc"
  expect_refused C11 "$plain" "$plain/data/a.md" data/a.md
  [ ! -e "$plain/data/a.md" ] || fail "C11: non-git home written"
  pass "C11-missing-evidence"
}

test_case_variant() {
  expect_refused case "$H" "$H/data/forced.md" --replace data/FORCED.md
  expect_refused case "$H" "$H/data/forced.md" --replace DATA/forced.md
  pass "case-variant-refused"
}

test_telemetry() {
  local t
  t=$(make_home telemetry)
  : > "$t.events"
  run_write "$t" "a" data/one.md || fail "C12: allow case refused"
  run_write "$t" "b" --replace bin/x.sh
  run_write "$t" "c" data/existing.md
  [ "$(event_count "$t" allow)" = 1 ] || fail "C12: expected one allow event"
  [ "$(event_count "$t" deny)" = 2 ] || fail "C12: expected two deny events"
  [ "$(wc -l < "$t.events" | tr -d ' ')" = 3 ] || fail "C12: expected exactly three events"
  pass "C12-telemetry"
}

test_sensitivity_unguarded_engine_is_detected() {
  local s fake="$TMP_ROOT/unguarded-bin" before
  s=$(make_home sensitivity)
  ln -s ../bin "$s/data/linkdir"
  mkdir -p "$fake"
  cp "$BIN/fm-home-write.sh" "$BIN/fm-guard-event.sh" "$fake/"
  cat > "$fake/fm-home-write.py" <<'PY'
import sys
target = sys.argv[-1]
home = sys.argv[sys.argv.index("--home") + 1]
if not target.startswith("/"):
    target = home + "/" + target
with open(target, "wb") as handle:
    handle.write(sys.stdin.buffer.read())
PY
  for target in bin/x.sh data/forced.md data/linkdir/x.sh; do
    case "$target" in data/forced.md) observe="$s/data/forced.md" ;; *) observe="$s/bin/x.sh" ;; esac
    before=$(sha "$observe")
    printf 'harmful %s' "$target" | FM_HOME="$s" FM_GUARD_EVENT_LOG="$s.events" "$fake/fm-home-write.sh" --replace "$target" >/dev/null 2>&1
    [ "$(sha "$observe")" != "$before" ] || fail "S1: unguarded write to $target was not observed, so the oracle cannot fail"
  done
  pass "S1-sensitivity"
}

test_new_data_record
test_tracked_source
test_force_added_data
test_projects_path
test_other_ignored_roots
test_symlink_escape
test_dot_segments
test_existing_needs_replace
test_outside_home
test_unignored_data
test_missing_evidence
test_case_variant
test_telemetry
test_sensitivity_unguarded_engine_is_detected
