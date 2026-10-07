#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-policy-inherit)
OWNERS='fm-session-launch-policy-lib.sh fm-config-inherit-lib.sh fm-spawn.sh fm-control.sh fm-secondmate-liveness-lib.sh fm-session-end-relaunch-lib.sh fm-remote-secondmate-relaunch.sh fm-remote-secondmate-control.sh'
FM_INHERITABLE_CONFIG='session-launch-policy crew-harness'

new_home() {
  local owner
  CASE="$TMP_ROOT/$1"
  CHILD="$CASE/child"
  PRIMARY="$CASE/primary"
  mkdir -p "$CHILD/bin" "$CHILD/config" "$CHILD/data" "$CHILD/state" "$PRIMARY/config" "$PRIMARY/data"
  for owner in $OWNERS; do cp "$ROOT/bin/$owner" "$CHILD/bin/$owner"; done
  git -C "$CHILD" init -q
  printf '/config/\n/data/\n/state/\n' > "$CHILD/.gitignore"
  printf 'committed project\n' > "$CHILD/project"
  git -C "$CHILD" add .
  git -C "$CHILD" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial
  printf 'unpublished project edits\n' >> "$CHILD/project"
  printf 'untracked work\n' > "$CHILD/untracked"
  printf 'window=firstmate:fm-running\nharness=omp\n' > "$CHILD/state/running.meta"
  printf 'validation custody\n' > "$CHILD/state/running.validation"
  printf 'persistent charter\n' > "$CHILD/data/charter.md"
  printf 'omp-or-tc\n' > "$PRIMARY/config/session-launch-policy"
  printf 'omp\n' > "$PRIMARY/config/crew-harness"
}

snapshot() {
  git -C "$CHILD" rev-parse HEAD > "$CASE/head"
  git -C "$CHILD" diff --binary > "$CASE/diff"
  cp "$CHILD/project" "$CASE/project"
  cp "$CHILD/untracked" "$CASE/untracked"
  cp "$CHILD/state/running.meta" "$CASE/meta"
  cp "$CHILD/state/running.validation" "$CASE/validation"
  cp "$CHILD/data/charter.md" "$CASE/charter"
}

assert_preserved() {
  [ "$(git -C "$CHILD" rev-parse HEAD)" = "$(cat "$CASE/head")" ] || fail 'inheritance moved HEAD'
  git -C "$CHILD" diff --binary > "$CASE/diff-after"
  cmp -s "$CASE/diff" "$CASE/diff-after" || fail 'inheritance rewrote tracked work or owners'
  cmp -s "$CASE/project" "$CHILD/project" || fail 'inheritance changed project edits'
  cmp -s "$CASE/untracked" "$CHILD/untracked" || fail 'inheritance changed untracked work'
  cmp -s "$CASE/meta" "$CHILD/state/running.meta" || fail 'inheritance changed running endpoint'
  cmp -s "$CASE/validation" "$CHILD/state/running.validation" || fail 'inheritance changed validation custody'
  cmp -s "$CASE/charter" "$CHILD/data/charter.md" || fail 'inheritance changed charter'
}

run_local() {
  : > "$CASE/report"
  rc=0
  FM_CONFIG_INHERIT_REPORT="$CASE/report" FM_CONFIG_INHERIT_LIVE=1 \
    propagate_secondmate_inheritance "$PRIMARY" "$CHILD" > "$CASE/out" 2> "$CASE/err" || rc=$?
}

assert_local_error() {
  [ "$rc" -ne 0 ] || fail 'incapable local home reported convergence'
  grep -F "$CHILD/bin/$owner" "$CASE/err" >/dev/null || fail 'local diagnostic omitted owner'
  grep -F "$(printf 'session-launch-policy\terror\t')" "$CASE/report" >/dev/null || fail 'local policy omitted error result'
  if grep -E '^session-launch-policy[[:space:]]+(pushed|unchanged)' "$CASE/report" >/dev/null; then
    fail 'local policy error was also reported successful'
  fi
  [ "$(cat "$CHILD/config/crew-harness")" = omp ] || fail 'policy error prevented unrelated inheritance'
  changed=$(fm_config_reread_changed_items "$CASE/report")
  case "$changed" in *session-launch-policy*) fail 'failed policy selected for successful reread' ;; esac
  assert_preserved
}

run_remote() {
  local generation=$1
  rc=0
  FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-remote-inherit.sh" \
    put config/session-launch-policy "$bytes" "$hash" "$generation" \
    < "$PRIMARY/config/session-launch-policy" > "$CASE/out" 2> "$CASE/err" || rc=$?
}

assert_remote_error() {
  [ "$rc" -ne 0 ] || fail 'incapable remote home reported convergence'
  grep -F "$CHILD/bin/$owner" "$CASE/err" >/dev/null || fail 'remote diagnostic omitted destination owner'
  [ ! -s "$CASE/out" ] || fail 'remote receiver emitted successful policy stdout'
  assert_preserved
}

for owner in $OWNERS; do
  for state in missing outdated; do
    for policy in copied equal; do
      new_home "local-$owner-$state-$policy"
      if [ "$state" = missing ]; then rm "$CHILD/bin/$owner"; else printf 'obsolete owner\n' > "$CHILD/bin/$owner"; fi
      [ "$policy" != equal ] || cp "$PRIMARY/config/session-launch-policy" "$CHILD/config/session-launch-policy"
      snapshot
      run_local
      assert_local_error
      cmp -s "$PRIMARY/config/session-launch-policy" "$CHILD/config/session-launch-policy" || fail 'local policy publication missing'
      pass "local live $policy policy refuses $state $owner and preserves home"

      new_home "remote-$owner-$state-$policy"
      if [ "$state" = missing ]; then rm "$CHILD/bin/$owner"; else printf 'obsolete owner\n' > "$CHILD/bin/$owner"; fi
      [ "$policy" != equal ] || cp "$PRIMARY/config/session-launch-policy" "$CHILD/config/session-launch-policy"
      snapshot
      bytes=$(LC_ALL=C wc -c < "$PRIMARY/config/session-launch-policy" | tr -d ' ')
      hash=$(fm_inherit_sha256 "$PRIMARY/config/session-launch-policy")
      run_remote 1
      assert_remote_error
      cmp -s "$PRIMARY/config/session-launch-policy" "$CHILD/config/session-launch-policy" || fail 'remote policy publication missing'
      run_remote 1
      assert_remote_error
      pass "remote $policy policy and identical-generation retry refuse $state $owner and preserve home"
    done
  done
done

new_home capable-local
snapshot
run_local
[ "$rc" = 0 ] || fail "capable dirty local home refused: $(cat "$CASE/err")"
grep -F "$(printf 'session-launch-policy\tpushed\t')" "$CASE/report" >/dev/null || fail 'capable copied policy not reported pushed'
assert_preserved
run_local
[ "$rc" = 0 ] || fail 'capable equal local policy refused'
grep -F "$(printf 'session-launch-policy\tunchanged\t')" "$CASE/report" >/dev/null || fail 'capable equal policy not reported unchanged'
assert_preserved
pass 'capable dirty local home supports copied and equal live policy'

new_home capable-remote
snapshot
bytes=$(LC_ALL=C wc -c < "$PRIMARY/config/session-launch-policy" | tr -d ' ')
hash=$(fm_inherit_sha256 "$PRIMARY/config/session-launch-policy")
run_remote 1
[ "$rc" = 0 ] || fail "capable dirty remote home refused: $(cat "$CASE/err")"
grep -Fx 'pushed: config/session-launch-policy' "$CASE/out" >/dev/null || fail 'remote copied policy not reported pushed'
assert_preserved
run_remote 1
[ "$rc" = 0 ] || fail 'capable equal remote policy refused'
grep -Fx 'unchanged: config/session-launch-policy' "$CASE/out" >/dev/null || fail 'remote equal policy not reported unchanged'
assert_preserved
pass 'separate authoritative root and capable dirty remote home support policy convergence'

new_home legacy-local
rm -rf "$CHILD/bin"
rm "$PRIMARY/config/session-launch-policy"
printf 'omp-or-tc\n' > "$CHILD/config/session-launch-policy"
snapshot
run_local
[ "$rc" = 0 ] && [ ! -e "$CHILD/config/session-launch-policy" ] || fail 'local absence required capable tooling'
assert_preserved
run_local
[ "$rc" = 0 ] || fail 'absent policy changed legacy compatibility'
pass 'local primary absence clears policy without capable owners'

new_home legacy-remote
rm -rf "$CHILD/bin"
printf 'omp-or-tc\n' > "$CHILD/config/session-launch-policy"
snapshot
: > "$CASE/empty"
hash=$(fm_inherit_sha256 "$CASE/empty")
FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-remote-inherit.sh" \
  absent config/session-launch-policy 0 "$hash" 1 < "$CASE/empty" > "$CASE/out" 2> "$CASE/err" || fail 'remote absence required capable owners'
[ ! -e "$CHILD/config/session-launch-policy" ] || fail 'remote absence did not clear policy'
assert_preserved
FM_HOME="$CHILD" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-remote-inherit.sh" \
  absent config/session-launch-policy 0 "$hash" 1 < "$CASE/empty" > "$CASE/out" 2> "$CASE/err" || fail 'remote absent retry required capable owners'
pass 'remote primary absence and absent retry preserve legacy compatibility'
