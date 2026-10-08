#!/usr/bin/env bash
# Behavior tests for home-local config/keep-ai-trailers choices.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=${TMP_ROOT:-$(fm_test_tmproot fm-keep-trailers-local)}

fm_git_identity fmtest fmtest@example.invalid

FLAG=keep-ai-trailers

make_fake_toolchain() {
  local dir=$1 mode=${2:-live} fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir" codex)
  if [ "$mode" = live ]; then
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*)
    for meta in "${FM_HOME:?}"/state/*.meta; do
      [ -f "$meta" ] || continue
      while IFS= read -r line; do
        case "$line" in window=*) printf '%s\n' "${line#*:}" ;; esac
      done < "$meta"
    done
    ;;
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1' ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0 ;;
  *capture-pane*) printf '❯\n' ;;
esac
exit 0
SH
    chmod +x "$fakebin/tmux"
  else
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  new-window) printf 'fixture backend refused after inheritance\n' >&2; exit 1 ;;
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
    chmod +x "$fakebin/tmux"
  fi
  add_bootstrap_compatible_tools "$fakebin"
  printf '%s\n' "$fakebin"
}

add_bootstrap_compatible_tools() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.77
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
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
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/no-mistakes" "$fakebin/tasks-axi" "$fakebin/quota-axi"
}

new_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fm_test_spawn_home "$home" codex
  mkdir -p "$w/user-home"
  git init -q -b main "$root"
  printf '%s\n' '.fm-secondmate-home' 'data/' 'state/' 'config/' 'projects/' > "$root/.gitignore"
  printf '%s\n' instructions > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' 'echo spawn' > "$root/bin/fm-spawn.sh"
  printf '%s\n' skill > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' charter > "$w/sm/data/charter.md"
  printf 'pi\n' > "$w/sm/config/crew-harness"
  printf 'lane choice\n' > "$w/lane-flag.expected"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

write_live_meta() {
  local home=$1 sm=$2
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
    printf 'harness=codex\n'
  } > "$home/state/sm.meta"
}

assert_flag_kept() {
  [ -f "$1/config/$FLAG" ] || fail "$3: the lane's config/$FLAG was removed"
  cmp -s "$2" "$1/config/$FLAG" || fail "$3: the lane's config/$FLAG bytes changed"
}

assert_flag_absent() {
  [ ! -e "$1/config/$FLAG" ] && [ ! -L "$1/config/$FLAG" ] \
    || fail "$2: the primary created a home-local flag in the lane"
}

assert_no_reread_mentions_flag() {
  local state=$1 label=$2 f
  for f in "$state"/.fm-inherited-config-reread* "$state"/.fm-inherited-config-reread-retry/*/.fm-inherited-config-reread*; do
    [ -f "$f" ] || continue
    ! grep -q "config/$FLAG" "$f" || fail "$label: a config-reread record names config/$FLAG ($f)"
  done
}

assert_harness_reread_exists() {
  local state=$1 label=$2 f found=0
  for f in "$state"/.fm-inherited-config-reread.*; do
    case "$f" in *.pending) continue ;; esac
    [ -f "$f" ] || continue
    assert_contains "$(cat "$f")" $'-----BEGIN config/crew-harness-----\ncodex\n-----END config/crew-harness-----' \
      "$label: reread did not record the unrelated config change"
    found=1
  done
  [ "$found" -eq 1 ] || fail "$label: unrelated config convergence produced no reread instruction"
}

run_spawn() {
  local w=$1 root=$2 home=$3 sm=$4 fakebin
  fakebin=$(make_fake_toolchain "$w" spawn)
  PATH="$fakebin:$BASE_PATH" TMUX='fake,1,0' HOME="$w/user-home" CLAUDE_CONFIG_DIR='' \
    FM_FAKE_PANE_PATH="$root" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" codex --secondmate
}

run_bootstrap() {
  local w=$1 root=$2 home=$3 sm=$4 fakebin
  write_live_meta "$home" "$sm"
  printf -- '- sm - fixture secondmate (home: %s; scope: fixture; projects: sample; added 2026-07-16)\n' "$sm" \
    > "$home/data/secondmates.md"
  fakebin=$(make_fake_toolchain "$w")
  PATH="$fakebin:$BASE_PATH" HOME="$w/user-home" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_NETWORK=only FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-bootstrap.sh"
}

run_config_push() {
  local w=$1 root=$2 home=$3 sm=$4 fakebin
  write_live_meta "$home" "$sm"
  fakebin=$(make_fake_toolchain "$w")
  PATH="$fakebin:$BASE_PATH" HOME="$w/user-home" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-config-push.sh"
}

check_point() {
  local point=$1 primary=$2 lane=$3 rec w root home sm status label
  label="$point primary-$primary lane-$lane"
  rec=$(new_world "$point-$primary-$lane")
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  if [ "$primary" = present ]; then
    printf 'primary choice\n' > "$home/config/$FLAG"
  fi
  if [ "$lane" = present ]; then
    cp "$w/lane-flag.expected" "$sm/config/$FLAG"
  fi
  "run_$point" "$w" "$root" "$home" "$sm" > "$w/point.out" 2> "$w/point.err"
  status=$?
  if [ "$point" = spawn ]; then
    expect_code 1 "$status" "$label did not stop at the isolated backend boundary: $(cat "$w/point.out") $(cat "$w/point.err")"
    assert_contains "$(cat "$w/point.err")" 'fixture backend refused after inheritance' \
      "$label failed before reaching the isolated backend boundary"
  else
    expect_code 0 "$status" "$label failed: $(cat "$w/point.out") $(cat "$w/point.err")"
  fi
  cmp -s "$home/config/crew-harness" "$sm/config/crew-harness" \
    || fail "$label: unrelated crew-harness did not converge"
  if [ "$lane" = present ]; then
    assert_flag_kept "$sm" "$w/lane-flag.expected" "$label"
  else
    assert_flag_absent "$sm" "$label"
  fi
  assert_no_reread_mentions_flag "$sm/state" "$label"
  assert_no_reread_mentions_flag "$home/state" "$label"
  if [ "$point" != spawn ]; then
    assert_harness_reread_exists "$sm/state" "$label"
    assert_contains "$(cat "$w/point.out")" '  config-reread: sent' \
      "$label: successful reread enqueue was not reported"
  fi
  pass "$label preserves the lane's home-local choice while unrelated config converges"
}

remote_apply() {
  local home=$1 command=$2 rel=$3 payload=$4 generation=$5 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload")
  bytes=${bytes//[[:space:]]/}
  hash=$(fm_inherit_sha256 "$payload") || fail 'cannot hash remote payload'
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    "$command" "$rel" "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

test_remote_receiver_refuses_home_local_flag() {
  local base home payload empty expected out items command lane status generation=1
  base="$TMP_ROOT/remote"
  home="$base/home"
  payload="$base/payload"
  empty="$base/empty"
  expected="$base/lane-flag.expected"
  mkdir -p "$home/config" "$home/data"
  printf 'primary value\n' > "$payload"
  printf 'lane choice\n' > "$expected"
  : > "$empty"
  items=$(fm_config_inherit_items)
  assert_not_contains "$items" "config/$FLAG" 'remote inherited-material set includes a home-local flag'
  assert_contains "$items" 'config/crew-harness' 'remote inherited-material set lost unrelated config'
  for lane in present absent; do
    if [ "$lane" = present ]; then cp "$expected" "$home/config/$FLAG"; else rm -f "$home/config/$FLAG"; fi
    for command in put absent; do
      if [ "$command" = put ]; then
        out=$(remote_apply "$home" "$command" "config/$FLAG" "$payload" "$generation"); status=$?
      else
        out=$(remote_apply "$home" "$command" "config/$FLAG" "$empty" "$generation"); status=$?
      fi
      [ "$status" -ne 0 ] || fail "remote $command accepted the home-local flag ($lane)"
      assert_contains "$out" "path is not inherited material: config/$FLAG" \
        "remote $command failed for the wrong reason ($lane)"
      if [ "$lane" = present ]; then
        assert_flag_kept "$home" "$expected" "remote $command"
      else
        assert_flag_absent "$home" "remote $command"
      fi
      generation=$((generation + 1))
    done
  done
  out=$(remote_apply "$home" put config/crew-harness "$payload" "$generation") \
    || fail "remote unrelated put failed: $out"
  cmp -s "$payload" "$home/config/crew-harness" || fail 'remote unrelated put did not converge'
  generation=$((generation + 1))
  out=$(remote_apply "$home" absent config/crew-harness "$empty" "$generation") \
    || fail "remote unrelated absent failed: $out"
  [ ! -e "$home/config/crew-harness" ] || fail 'remote unrelated absence did not converge'
  pass 'remote item enumeration and receiver refuse both flag operations while preserving each local choice'
}

make_retry_boundary() {
  local base=$1 bin
  bin="$base/bin"
  mkdir -p "$bin" "$base/delivery"
  cp "$ROOT/bin/fm-config-inherit-lib.sh" "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$bin/"
  cat > "$bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = fm-sm ]
case "$2" in 'CONFIG_REREAD: '*) instruction=${2#'CONFIG_REREAD: '} ;; *) exit 2 ;; esac
[ -f "$instruction" ] && [ ! -L "$instruction" ]
count=0
if [ -f "$FM_DELIVERY_DIR/count" ]; then read -r count < "$FM_DELIVERY_DIR/count"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$FM_DELIVERY_DIR/count"
printf '%s\n' "$instruction" >> "$FM_DELIVERY_DIR/pointers"
cat "$instruction" > "$FM_DELIVERY_DIR/attempt.$count"
[ "${FM_DELIVERY_FAIL:-0}" = 0 ]
SH
  chmod +x "$bin/fm-send.sh"
  printf '%s\n' "$bin"
}

write_recorded_block() {
  local path=$1 payload=$2
  printf '\n%s\n-----BEGIN %s-----\n' "$path" "$path"
  cat "$payload"
  printf '%s\n' "-----END $path-----"
}

assert_retry_retired() {
  local home=$1 source=$2 label=$3 path
  ! fm_config_reread_has_pending "$home" || fail "$label: pending delivery remains"
  ! fm_config_reread_has_staged "$source" sm || fail "$label: staged retry remains"
  for path in "$home/state"/.fm-inherited-config-reread.*.pending \
    "$source/state/.fm-inherited-config-reread-retry/sm"/.fm-inherited-config-reread.*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$label: retained retry artifact remains ($path)"
  done
}

test_retained_retry_case() (
  local representation=$1 contents=$2 base source home bin retry_dir retained report expected recorded absent flag_record out status attempt
  base="$TMP_ROOT/retry-$representation-$contents"
  source="$base/source"
  home="$base/lane"
  mkdir -p "$source/state" "$source/config" "$home/state" "$home/config"
  printf 'lane choice\n' > "$base/lane-flag.expected"
  cp "$base/lane-flag.expected" "$home/config/$FLAG"
  printf 'newer primary choice\n' > "$source/config/$FLAG"
  recorded="$base/recorded"
  absent="$base/absent"
  flag_record="$base/flag-record"
  expected="$base/expected"
  printf '{\r\n  "default": {"harness": "recorded"},\r\n  "literal": "config/keep-ai-trailers",\r\n  "spacing": "keep  two spaces  "\r\n}\r\n\n' > "$recorded"
  if [ "$representation" = exact-temp ]; then
    printf '{"default":{"harness":"recorded"},"spacing":"keep  two spaces  "}  ' > "$recorded"
  fi
  printf 'ABSENT\n' > "$absent"
  printf '{"default":{"harness":"newer-destination"}}\n' > "$home/config/crew-dispatch.json"
  printf 'even-newer-source\n' > "$source/config/crew-dispatch.json"
  bin=$(make_retry_boundary "$base")
  . "$bin/fm-config-inherit-lib.sh"
  export PATH="$BASE_PATH" FM_HOME="$source" FM_STATE_OVERRIDE="$source/state" FM_ROOT_OVERRIDE="$base"
  export FM_DELIVERY_DIR="$base/delivery" FM_DELIVERY_FAIL=1
  retry_dir=$(fm_config_reread_retry_dir "$source" sm) || fail 'cannot derive retry directory'
  mkdir -p "$retry_dir"
  report="$base/unchanged.report"
  : > "$report"
  {
    printf '%s\n' "$FM_CONFIG_REREAD_FRAMING"
    write_recorded_block "config/$FLAG" "$absent"
  } > "$flag_record"
  if [ "$contents" = mixed ]; then
    if [ "$representation" = legacy-report ]; then
      cp "$recorded" "$home/config/crew-dispatch.json"
    fi
    {
      printf '%s\n' "$FM_CONFIG_REREAD_FRAMING"
      write_recorded_block config/crew-dispatch.json "$recorded"
    } > "$expected"
  fi
  case "$representation" in
    pending) retained="$home/state/.fm-inherited-config-reread.retained" ;;
    staged|staged-pending) retained="$retry_dir/.fm-inherited-config-reread.retained" ;;
    exact-temp) retained="$retry_dir/.fm-inherited-config-reread.retained.tmp.exact" ;;
    legacy-report) retained="$retry_dir/.fm-inherited-config-reread.retained.report" ;;
    *) fail "unknown retry representation: $representation" ;;
  esac
  if [ "$representation" = legacy-report ]; then
    printf '%s\tpushed\tmirrored primary absence\n' "$FLAG" > "$retained"
    printf 'data/captain-shared.md\tpushed\t\n' >> "$retained"
    if [ "$contents" = mixed ]; then printf 'crew-dispatch.json\tpushed\t\n' >> "$retained"; fi
  elif [ "$contents" = mixed ]; then
    {
      printf '%s\n' "$FM_CONFIG_REREAD_FRAMING"
      if [ "$representation" = exact-temp ]; then
        write_recorded_block "config/$FLAG" "$absent"
        write_recorded_block config/crew-dispatch.json "$recorded"
      else
        write_recorded_block config/crew-dispatch.json "$recorded"
        write_recorded_block "config/$FLAG" "$absent"
      fi
    } > "$retained"
  else
    cp "$flag_record" "$retained"
  fi
  if [ "$representation" = staged ]; then
    printf '%s\tpushed\tmirrored primary absence\n' "$FLAG" > "$retained.report"
    printf 'data/captain-shared.md\tpushed\t\n' >> "$retained.report"
    if [ "$contents" = mixed ]; then printf 'crew-dispatch.json\tpushed\t\n' >> "$retained.report"; fi
  fi
  case "$representation" in
    pending)
      fm_config_reread_mark_pending "$retained" "$retained.pending" || fail 'cannot seed pending retry'
      ;;
    staged-pending)
      cp "$retained" "$home/state/${retained##*/}"
      fm_config_reread_mark_pending "$home/state/${retained##*/}" "$home/state/${retained##*/}.pending" \
        || fail 'cannot seed published staged retry'
      ;;
  esac
  out=$(fm_config_send_reread_nudge sm "$home" "$report" 2>&1); status=$?
  if [ "$contents" = mixed ]; then
    expect_code 1 "$status" "$representation: rejected transport should leave a retry: $out"
    ! grep -q 'config-reread: sent' <<< "$out" \
      || fail "$representation: rejected transport was reported as sent"
    [ "$(cat "$FM_DELIVERY_DIR/count" 2>/dev/null)" = 1 ] \
      || fail "$representation: real retry did not reach the transport exactly once"
    cmp -s "$expected" "$FM_DELIVERY_DIR/attempt.1" \
      || fail "$representation: delivered ABSENT flag instructions or changed unrelated recorded bytes"
    printf '{"default":{"harness":"changed-after-rejection"}}\n' > "$home/config/crew-dispatch.json"
    export FM_DELIVERY_FAIL=0
    out=$(fm_config_reread_retry_pending sm "$home" 2>&1); status=$?
    expect_code 0 "$status" "$representation: retained delivery failed to converge: $out"
    assert_contains "$out" '  config-reread: sent' \
      "$representation: successful retained enqueue was not reported"
    [ "$(cat "$FM_DELIVERY_DIR/count")" = 2 ] || fail "$representation: retained delivery was not retried once"
    cmp -s "$expected" "$FM_DELIVERY_DIR/attempt.2" \
      || fail "$representation: retry reread newer config instead of retaining unrelated recorded bytes"
    while IFS= read -r attempt; do
      cmp -s "$expected" "$attempt" || fail "$representation: persisted delivered instruction changed"
    done < "$FM_DELIVERY_DIR/pointers"
  else
    expect_code 0 "$status" "$representation: flag-only retry did not retire successfully: $out"
    ! grep -q 'config-reread: sent' <<< "$out" \
      || fail "$representation: flag-only retirement was reported as sent"
    [ ! -e "$FM_DELIVERY_DIR/count" ] || fail "$representation: flag-only retry reached transport"
    out=$(fm_config_reread_retry_pending sm "$home" 2>&1); status=$?
    expect_code 0 "$status" "$representation: flag-only retirement left a stuck retry: $out"
    ! grep -q 'config-reread: sent' <<< "$out" \
      || fail "$representation: no-op retry was reported as sent"
    [ ! -e "$FM_DELIVERY_DIR/count" ] || fail "$representation: retired flag-only retry reached transport"
    assert_no_reread_mentions_flag "$home/state" "$representation flag-only"
    assert_no_reread_mentions_flag "$source/state" "$representation flag-only"
  fi
  assert_retry_retired "$home" "$source" "$representation $contents"
  assert_flag_kept "$home" "$base/lane-flag.expected" "$representation $contents retry"
  pass "$representation $contents retry removes retained home-local ABSENT instructions and converges"
)

test_excluded_report_retry_case() (
  local representation=$1 contents=$2 base source home bin retry_dir stage retained report original_allowlist
  local expected out status interface item
  base="$TMP_ROOT/excluded-report-$representation-$contents"
  source="$base/source"
  home="$base/lane"
  mkdir -p "$source/state" "$source/config" "$home/state" "$home/config" "$base/tmp"
  printf 'lane choice\n' > "$base/lane-flag.expected"
  cp "$base/lane-flag.expected" "$home/config/$FLAG"
  printf 'primary choice\n' > "$source/config/$FLAG"
  printf '{\r\n  "models": ["destination"],\r\n  "spacing": "keep  two spaces"\r\n}\r\n\n' > "$home/config/model-index.json"
  printf '{"default":{"harness":"destination"}}  \n\n' > "$home/config/crew-dispatch.json"
  printf 'destination-harness\n' > "$home/config/crew-harness"
  for item in model-index.json crew-dispatch.json crew-harness; do
    printf 'different source bytes\n' > "$source/config/$item"
  done
  bin=$(make_retry_boundary "$base")
  . "$bin/fm-config-inherit-lib.sh"
  original_allowlist=$FM_INHERITABLE_CONFIG
  export PATH="$BASE_PATH" FM_HOME="$source" FM_STATE_OVERRIDE="$source/state" FM_ROOT_OVERRIDE="$base"
  export TMPDIR="$base/tmp" FM_DELIVERY_DIR="$base/delivery" FM_DELIVERY_FAIL=0
  retry_dir=$(fm_config_reread_retry_dir "$source" sm) || fail 'cannot derive excluded-report retry directory'
  mkdir -p "$retry_dir"
  stage="$retry_dir/.fm-inherited-config-reread.retained"
  retained="$stage.report"
  {
    printf 'model-index.json\tpushed\t\n'
    printf 'crew-dispatch.json\tpushed\t\n'
    printf 'data/captain-shared.md\tpushed\t\n'
    if [ "$contents" = mixed ]; then
      printf 'crew-harness\tpushed\t\n'
      printf '%s\tpushed\tmirrored primary absence\n' "$FLAG"
    fi
  } > "$retained"
  cp "$retained" "$base/report.expected"
  if [ "$representation" = empty-stage ]; then
    : > "$stage"
    cp "$stage" "$base/stage.expected"
  fi
  report="$base/unchanged.report"
  : > "$report"
  export FM_INHERITABLE_CONFIG=crew-harness
  for interface in convergence queue-drain; do
    if [ "$interface" = convergence ]; then
      out=$(fm_config_send_reread_nudge sm "$home" "$report" 2>&1); status=$?
    else
      out=$(fm_config_reread_retry_pending sm "$home" 2>&1); status=$?
    fi
    expect_code 0 "$status" "$representation $contents $interface: deferred recovery failed: $out"
    cmp -s "$base/report.expected" "$retained" \
      || fail "$representation $contents $interface: excluded routing report changed or disappeared"
    if [ "$representation" = empty-stage ]; then
      cmp -s "$base/stage.expected" "$stage" \
        || fail "$representation $contents $interface: empty stage changed or disappeared"
    else
      [ ! -e "$stage" ] || fail "$representation $contents $interface: report-only recovery created a stage"
    fi
    [ ! -e "$FM_DELIVERY_DIR/count" ] \
      || fail "$representation $contents $interface: deferred report delivered an excluded or partial payload"
    ! grep -q 'config-reread: sent' <<< "$out" \
      || fail "$representation $contents $interface: deferred recovery was reported as sent"
    assert_flag_kept "$home" "$base/lane-flag.expected" "$representation $contents $interface"
  done
  expected="$base/delivery.expected"
  {
    printf '%s\n' "$FM_CONFIG_REREAD_FRAMING"
    write_recorded_block config/model-index.json "$home/config/model-index.json"
    write_recorded_block config/crew-dispatch.json "$home/config/crew-dispatch.json"
    if [ "$contents" = mixed ]; then
      write_recorded_block config/crew-harness "$home/config/crew-harness"
    fi
  } > "$expected"
  export FM_INHERITABLE_CONFIG="$original_allowlist"
  out=$(fm_config_reread_retry_pending sm "$home" 2>&1); status=$?
  expect_code 0 "$status" "$representation $contents: restored allowlist retry failed: $out"
  assert_contains "$out" '  config-reread: sent' "$representation $contents: restored retry was not reported as sent"
  [ "$(cat "$FM_DELIVERY_DIR/count" 2>/dev/null)" = 1 ] \
    || fail "$representation $contents: restored retry did not deliver exactly once"
  cmp -s "$expected" "$FM_DELIVERY_DIR/attempt.1" \
    || fail "$representation $contents: restored transport did not preserve exact destination routing/harness bytes"
  assert_no_reread_mentions_flag "$home/state" "$representation $contents restored"
  assert_retry_retired "$home" "$source" "$representation $contents restored"
  assert_flag_kept "$home" "$base/lane-flag.expected" "$representation $contents restored"
  pass "$representation $contents report recovery waits for the complete allowlist before delivering destination bytes"
)

test_retired_only_command() (
  local point=$1 rec w root home sm retained absent out status path
  rec=$(new_world "$point-retired-only")
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  cp "$w/lane-flag.expected" "$sm/config/$FLAG"
  propagate_secondmate_inheritance "$home" "$sm" > "$w/converge.out" 2> "$w/converge.err"
  status=$?
  expect_code 0 "$status" "$point: initial convergence failed: $(cat "$w/converge.out") $(cat "$w/converge.err")"
  retained="$sm/state/.fm-inherited-config-reread.retained"
  absent="$w/absent"
  printf 'ABSENT\n' > "$absent"
  {
    printf '%s\n' "$FM_CONFIG_REREAD_FRAMING"
    write_recorded_block "config/$FLAG" "$absent"
  } > "$retained"
  fm_config_reread_mark_pending "$retained" "$retained.pending" || fail "$point: cannot seed retained-only pending retry"
  "run_$point" "$w" "$root" "$home" "$sm" > "$w/point.out" 2> "$w/point.err"
  status=$?
  out=$(cat "$w/point.out")
  expect_code 0 "$status" "$point: retained-only retirement failed: $out $(cat "$w/point.err")"
  ! grep -q 'config-reread: sent' <<< "$out" \
    || fail "$point: retained-only retirement was reported as sent"
  assert_retry_retired "$sm" "$home" "$point retired-only"
  [ ! -e "$retained" ] && [ ! -L "$retained" ] \
    || fail "$point: retired-only instruction remains"
  assert_flag_kept "$sm" "$w/lane-flag.expected" "$point retired-only"
  for path in "$sm/state"/.fm-inherited-config-reread.*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] \
      || fail "$point: otherwise converged config delivered a new reread instruction ($path)"
  done
  pass "$point silently retires retained-only instructions without enqueueing a reread"
)

test_remote_receiver_refuses_home_local_flag
for point in spawn bootstrap config_push; do
  for primary in absent present; do
    for lane in present absent; do
      check_point "$point" "$primary" "$lane"
    done
  done
done
for point in config_push bootstrap; do
  test_retired_only_command "$point"
done
for representation in pending staged staged-pending exact-temp legacy-report; do
  for contents in mixed flag-only; do
    test_retained_retry_case "$representation" "$contents"
  done
done
for representation in report-only empty-stage; do
  for contents in routing-only mixed; do
    test_excluded_report_retry_case "$representation" "$contents"
  done
done

echo '# all fm-keep-ai-trailers-home-local tests passed'
