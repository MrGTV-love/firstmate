#!/usr/bin/env bash
# Behavior tests for the home-owned config/keep-ai-trailers exception.
#
# The primary home deliberately has no config/keep-ai-trailers, yet a secondmate
# home (a Vernant lane) keeps its flag permanently. A destination-local marker,
# config/keep-ai-trailers.home-owned, makes every convergence point leave that
# home's flag untouched and out of the config-reread record. Without the marker
# the primary-authoritative mirror of absence is unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-keep-trailers-owned)

fm_git_identity fmtest fmtest@example.invalid

FLAG=keep-ai-trailers
MARKER=keep-ai-trailers.home-owned

make_fake_spawn_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# Version-aware stubs so bootstrap's tool floors stay quiet in fixture PATH.
add_bootstrap_compatible_tools() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh treehouse
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.77
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/no-mistakes" "$fakebin/tasks-axi" "$fakebin/quota-axi"
}

# A primary home with NO config/keep-ai-trailers and one secondmate home that
# keeps its own flag. Prints "<world>|<root>|<home>|<secondmate-home>".
new_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'data/'
    printf '%s\n' 'state/'
    printf '%s\n' 'config/'
    printf '%s\n' 'projects/'
  } > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' "echo spawn" > "$root/bin/fm-spawn.sh"
  printf '%s\n' "skill" > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' "charter" > "$w/sm/data/charter.md"
  printf '%s\n' "lane choice" > "$w/sm/config/$FLAG"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

set_marker() {
  : > "$1/config/$MARKER"
}

write_live_meta() {
  local home=$1 sm=$2
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
}

assert_flag_kept() {
  [ -f "$1/config/$FLAG" ] || fail "$2: the lane's config/$FLAG was removed"
  [ "$(cat "$1/config/$FLAG")" = "lane choice" ] || fail "$2: the lane's config/$FLAG bytes changed"
}

assert_flag_removed() {
  [ ! -e "$1/config/$FLAG" ] || fail "$2: config/$FLAG should have mirrored the primary's absence"
}

assert_no_reread_mentions_flag() {
  local state=$1 label=$2 f
  for f in "$state"/.fm-inherited-config-reread* "$state"/.fm-inherited-config-reread-retry/*/.fm-inherited-config-reread*; do
    [ -f "$f" ] || continue
    ! grep -q "config/$FLAG" "$f" || fail "$label: a config-reread record names config/$FLAG ($f)"
  done
}

run_spawn() {
  local w=$1 root=$2 home=$3 sm=$4 fakebin
  fakebin=$(make_fake_spawn_toolchain "$w")
  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" codex --secondmate >/dev/null 2>&1 || true
}

run_bootstrap() {
  local w=$1 root=$2 home=$3 sm=$4 fakebin
  write_live_meta "$home" "$sm"
  printf -- '- sm - fixture secondmate (home: %s; scope: fixture; projects: sample; added 2026-07-16)\n' "$sm" \
    > "$home/data/secondmates.md"
  fakebin=$(make_fake_spawn_toolchain "$w")
  add_bootstrap_compatible_tools "$fakebin"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

run_config_push() {
  local root=$2 home=$3 sm=$4
  write_live_meta "$home" "$sm"
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-config-push.sh" 2>/dev/null
}

# Each local convergence point runs against a world whose primary has no flag.
# Without the marker the lane's flag follows the primary's absence (unchanged
# behavior); with the marker it survives and never reaches a reread record.
check_point() {
  local point=$1 with_marker=$2 rec w root home sm out label
  label="$point ${with_marker:+with}${with_marker:-without} marker"
  rec=$(new_world "$point-${with_marker:-plain}")
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  [ -z "$with_marker" ] || set_marker "$sm"
  out=$("run_$point" "$w" "$root" "$home" "$sm")
  if [ -n "$with_marker" ]; then
    assert_flag_kept "$sm" "$label"
    assert_no_reread_mentions_flag "$sm/state" "$label"
    [ -f "$sm/config/$MARKER" ] || fail "$label: the marker itself was removed"
  else
    assert_flag_removed "$sm" "$label"
  fi
  printf '%s' "$out" > "$w/point.out"
  if [ "$point" = config_push ] && [ -n "$with_marker" ]; then
    assert_contains "$out" "$FLAG" "$label: report should list the item"
    assert_not_contains "$out" "$FLAG: pushed" "$label: report must not mark the flag pushed"
  fi
}

test_spawn_without_marker_mirrors_absence() {
  check_point spawn ''
  pass "spawn without the marker still mirrors the primary's absence"
}

test_spawn_with_marker_keeps_flag() {
  check_point spawn yes
  pass "spawn with the marker leaves the lane's flag untouched"
}

test_bootstrap_without_marker_mirrors_absence() {
  check_point bootstrap ''
  pass "bootstrap sweep without the marker still mirrors the primary's absence"
}

test_bootstrap_with_marker_keeps_flag() {
  check_point bootstrap yes
  pass "bootstrap sweep with the marker leaves the lane's flag untouched"
}

test_config_push_without_marker_mirrors_absence() {
  check_point config_push ''
  pass "focused push without the marker still mirrors the primary's absence"
}

test_config_push_with_marker_keeps_flag() {
  check_point config_push yes
  pass "focused push with the marker leaves the lane's flag untouched and out of the reread record"
}

test_config_push_without_marker_records_absent() {
  local rec w root home sm instruction
  rec=$(new_world push-absent-record)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  run_config_push "$w" "$root" "$home" "$sm" >/dev/null
  instruction=$(cat "$sm"/state/.fm-inherited-config-reread* "$sm"/state/.fm-inherited-config-reread-retry/*/.fm-inherited-config-reread* 2>/dev/null || true)
  assert_contains "$instruction" "config/$FLAG" "without the marker the reread record names the flag"
  assert_contains "$instruction" "ABSENT" "without the marker the reread record states the removal"
  pass "without the marker the removal still reaches the reread record"
}

# Direct library check: the mirror of a present primary value and a pre-existing
# lane flag, plus the marker's narrow scope.
test_library_pins_present_and_absent_lane_values() {
  local base src dest report
  base="$TMP_ROOT/library"
  src="$base/src"
  dest="$base/dest"
  report="$base/report"
  mkdir -p "$src" "$dest"
  : > "$report"

  # Primary has the flag, lane has none but owns its choice: stays absent.
  : > "$src/$FLAG"
  : > "$dest/$MARKER"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$src" "$dest" 2>/dev/null \
    || fail "propagation failed with a home-owned flag"
  [ ! -e "$dest/$FLAG" ] || fail "primary flag was copied over a home-owned absence"
  assert_contains "$(grep "^$FLAG	" "$report")" "unchanged	home-owned" \
    "a home-owned item should be reported unchanged with its reason"

  # Marker gone: the primary's value converges again.
  rm -f "$dest/$MARKER"
  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$src" "$dest" 2>/dev/null \
    || fail "propagation failed without the marker"
  [ -f "$dest/$FLAG" ] || fail "without the marker the primary flag should converge"
  assert_contains "$(grep "^$FLAG	" "$report")" "pushed" "unowned flag should be pushed"

  # The marker covers only keep-ai-trailers: a stray marker for another item pins nothing.
  rm -f "$src/$FLAG" "$dest/$FLAG"
  printf 'codex\n' > "$src/crew-harness"
  : > "$dest/crew-harness.home-owned"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$src" "$dest" 2>/dev/null \
    || fail "propagation failed with a stray marker"
  [ "$(cat "$dest/crew-harness" 2>/dev/null)" = codex ] \
    || fail "a marker for another item must not pin that item"
  pass "the library honors the marker for keep-ai-trailers only, and drops it when the marker goes"
}

remote_apply() {
  local home=$1 command=$2 payload=$3 generation=$4 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash remote payload"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    "$command" "config/$FLAG" "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

test_remote_receiver_honors_marker_and_item_set_is_unchanged() {
  local base home payload empty out items
  base="$TMP_ROOT/remote"
  home="$base/home"
  payload="$base/payload"
  empty="$base/empty"
  mkdir -p "$home/config" "$home/data"
  printf 'primary value\n' > "$payload"
  : > "$empty"
  printf 'lane choice\n' > "$home/config/$FLAG"

  # The item set is the same declaration as before; the marker is not an item.
  items=$(fm_config_inherit_items)
  assert_contains "$items" "config/$FLAG" "keep-ai-trailers must stay in the declared item set"
  assert_not_contains "$items" "$MARKER" "the marker must never be an inherited item"

  set_marker "$home"
  out=$(remote_apply "$home" absent "$empty" 1) || fail "remote absent was refused: $out"
  assert_contains "$out" "unchanged: config/$FLAG" "owned item should report unchanged on absent"
  [ "$(cat "$home/config/$FLAG")" = "lane choice" ] || fail "remote absent removed the lane's flag"
  out=$(remote_apply "$home" put "$payload" 2) || fail "remote put was refused: $out"
  assert_contains "$out" "unchanged: config/$FLAG" "owned item should report unchanged on put"
  [ "$(cat "$home/config/$FLAG")" = "lane choice" ] || fail "remote put replaced the lane's flag"

  rm -f "$home/config/$FLAG"
  out=$(remote_apply "$home" put "$payload" 3) || fail "remote put over owned absence failed: $out"
  [ ! -e "$home/config/$FLAG" ] || fail "remote put created a flag in a home that owns its absence"

  # Without the marker the receiver behaves as before.
  rm -f "$home/config/$MARKER"
  out=$(remote_apply "$home" put "$payload" 4) || fail "remote put without marker failed: $out"
  assert_contains "$out" "pushed: config/$FLAG" "without the marker the put should apply"
  out=$(remote_apply "$home" absent "$empty" 5) || fail "remote absent without marker failed: $out"
  assert_contains "$out" "removed: config/$FLAG" "without the marker the absence should apply"
  [ ! -e "$home/config/$FLAG" ] || fail "without the marker the lane flag should have been removed"
  pass "remote receiver leaves an owned flag alone, applies it otherwise, and the item set is unchanged"
}

test_library_pins_present_and_absent_lane_values
test_remote_receiver_honors_marker_and_item_set_is_unchanged
test_spawn_without_marker_mirrors_absence
test_spawn_with_marker_keeps_flag
test_bootstrap_without_marker_mirrors_absence
test_bootstrap_with_marker_keeps_flag
test_config_push_without_marker_mirrors_absence
test_config_push_with_marker_keeps_flag
test_config_push_without_marker_records_absent

echo "# all fm-keep-ai-trailers-home-owned tests passed"
