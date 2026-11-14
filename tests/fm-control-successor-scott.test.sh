#!/usr/bin/env bash
# fm-control.sh successor, end to end on the Scott task fixture: the real
# admission, the real relaunch against the fake backend, and the custody
# relationships (assumption A4: custody survives a relaunch).
#
# The fixture (tests/fixtures/fm-scott-task-shape.sh, a byte copy of the
# supervisor's make-scott-fixture.sh) is a synthetic copy of the SHAPE of the real
# task: its record, its copy on the OLD branch, the diverged branches S (old
# branch), B (pushed PR head), P (pipeline head, which the successor equals) and
# DF (the unpublished fix commit, held only by the gate), its archive branches and
# a bare repository standing for the daemon's gate repo with the run refs.
#
# What each stand-in is and what it can and cannot show:
#   - gate.git stands for the no-mistakes daemon's gate repository and holds the
#     refs and the unpublished DF object the runs own. A relaunch that reached
#     into it, or into the unpublished commit, would change its fingerprint. It
#     shows the operation and the relaunch do not read or write run-owned refs; it
#     cannot show a live daemon run survives.
#   - The no-mistakes shim records every call and answers none. It stands for the
#     custody path (axi sync --recover and every run verb); the tests assert it was
#     never called by the operation or the relaunch. It cannot show how the real
#     daemon reacts to the next recovery.
#   - The fake tmux backend stands for the live herdr backend. The fixture's
#     record says backend=herdr; the record is adapted to the fake tmux endpoint
#     (window label, and the herdr-only keys removed). Every branch, worktree and
#     project field is untouched. It cannot show herdr's launch-proof handling.
#   - The task id is renamed from the live task's (see TASK below).
#   - The fixture's brief has only the Ship branch line; a # Task heading with two sections (Captain's
#     intent, Firstmate spec) is appended so a relaunch accepts it. No existing
#     line changes.
set -u

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"
# shellcheck source=tests/fm-control-successor-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-successor-helpers.sh"

# The fixture maker names its task after the live task it models. A live task owns
# /tmp/fm-<id> and its launch siblings, which a relaunch would stage into, so the
# maker is run through a copy whose TASK line alone is renamed; every other line,
# every relation and every ref shape is unchanged.
TASK=fm-scott-fixture-task
OLD=fm/$TASK
SUCC=fm/$TASK-v2
RUN_NEW=01FIXTURENEWRUN0000000000B
SCOTT_MAKER=${FM_SCOTT_FIXTURE_MAKER:-$ROOT/tests/fixtures/fm-scott-task-shape.sh}

scott_cleanup() {
  successor_stop_sentinels
  successor_remove_task_tmp fm-scott-fixture-task
  relaunch_cleanup
}
trap scott_cleanup EXIT


# new_scott_case <name>: the fixture built by the maker, its record and instructions
# installed as this case's home, the fake backend pointed at the copy, a no-mistakes
# shim that records calls, and a live process standing in for the worker.
new_scott_case() {  # <name>
  local dir fx
  dir=$(new_case "$1" "$TASK")
  fx=$dir/fx
  mkdir "$fx"
  [ "$(grep -c '^TASK=fm-slack-second-person-scott$' "$SCOTT_MAKER")" = 1 ] || fail "the fixture maker no longer has the one TASK line this suite renames"
  sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$TASK/" "$SCOTT_MAKER" > "$dir/maker.sh"
  bash "$dir/maker.sh" "$fx" > "$dir/maker.out" 2>&1 || fail "the Scott fixture maker failed: $(cat "$dir/maker.out")"
  mv "$fx/home/state/$TASK.meta" "$fx/home/state/$TASK.status" "$dir/home/state/"
  mv "$fx/home/state/$TASK.inbox" "$dir/home/state/"
  mv "$fx/home/data/$TASK" "$dir/home/data/"
  # Adapt only the endpoint keys to the fake tmux backend, and say so.
  sed -i.bak -e "s#^window=.*#window=fmses:fm-$TASK#" \
    -e '/^backend=/d' -e '/^herdr_/d' -e '/^launch_proof=/d' "$dir/home/state/$TASK.meta"
  rm -f "$dir/home/state/$TASK.meta.bak"
  # The fixture's brief carries only the Ship branch line, which a relaunch refuses
  # before spawn (it needs a Captain's intent and a Firstmate spec). Append the two
  # sections, leaving every existing line, including Ship branch, untouched.
  printf '%s\n' "" "# Task" "## Captain's intent" "Fixture task for the successor-branch proof." "" "## Firstmate spec" "Keep the task while its agent is replaced." >> "$dir/home/data/$TASK/brief.md"
  printf '%s\n' "fm-$TASK" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  printf '%s' "$fx/slots/22/project" > "$dir/fake/cwd"
  mkdir -p "$fx/tmp"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/nm-calls"
exit 0
SH
  chmod +x "$dir/fakebin/no-mistakes"
  : > "$dir/fake/nm-calls"
  make_continuation_owner_fixture "$dir"
  successor_ps_fallback "$dir"
  successor_start_sentinel "$dir"
  printf '%s\n' "$dir"
}

sc() {  # <case-dir> <args...>: the verb as the lock-owning main session
  local dir=$1
  shift
  run_continuation_control "$dir" "$TASK" successor "$@"
}

# The custody relationships, as one comparable text: every ref of the project and
# of the gate, whether the unpublished commit exists in each, the copy's attached
# branch, and the run-binding file.
custody() {  # <case-dir>
  local fx=$1/fx df
  df=$(git -C "$fx/gate.git" rev-parse "refs/no-mistakes/recover/$RUN_NEW")
  printf 'project refs:\n'
  git -C "$fx/project" for-each-ref --format='%(refname) %(objectname)'
  printf 'gate refs:\n'
  git -C "$fx/gate.git" for-each-ref --format='%(refname) %(objectname)'
  printf 'DF in gate: %s\n' "$(git -C "$fx/gate.git" cat-file -e "$df" 2>/dev/null && echo present || echo absent)"
  printf 'refs reaching DF in project: %s\n' "$(git -C "$fx/project" for-each-ref --contains "$df" | wc -l | tr -d ' ')"
  printf 'copy attached: %s\n' "$(git -C "$fx/slots/22/project" symbolic-ref HEAD)"
  printf 'copy head: %s\n' "$(git -C "$fx/slots/22/project" rev-parse HEAD)"
  printf 'run binding: %s\n' "$(shasum -a 256 < "$fx/run-binding.txt")"
}

snap_scott() {  # <case-dir> <tag>
  local dir=$1 tag=$2 fx=$1/fx
  mkdir -p "$dir/snap/$tag"
  custody "$dir" > "$dir/snap/$tag/custody"
  fp "$fx/gate.git" > "$dir/snap/$tag/gate"
  fp "$fx/slots/22/project" > "$dir/snap/$tag/copy"
  fp "$fx/project/.git" > "$dir/snap/$tag/project-git"
  cp "$fx/run-binding.txt" "$dir/snap/$tag/binding"
  fp "$dir/home/state" > "$dir/snap/$tag/state"
  fp "$dir/home/data" > "$dir/snap/$tag/data"
  fp "$dir/fake" > "$dir/snap/$tag/fake"
  kill -0 "$(cat "$dir/sentinel-pid")" 2>/dev/null || fail "the stand-in worker process is no longer alive"
}

same() {  # <case-dir> <before> <after> <what> <part>...
  local dir=$1 before=$2 after=$3 what=$4 part
  shift 4
  for part in "$@"; do
    cmp -s "$dir/snap/$before/$part" "$dir/snap/$after/$part" \
      || { diff "$dir/snap/$before/$part" "$dir/snap/$after/$part" | head -20 >&2; fail "$what changed $part"; }
  done
}

no_custody_calls() {  # <case-dir> <what>: the operation calls nothing; a relaunch may only read run status
  case "$2" in
    "the operation") assert_equals "" "$(cat "$1/fake/nm-calls")" "$2 called no-mistakes" ;;
    *) successor_assert_read_only_run_calls "$1" "$2" ;;
  esac
}

test_scott_fixture_has_the_shape_the_amendment_names() {
  local dir fx
  dir=$(new_scott_case shape)
  fx=$dir/fx
  assert_equals "branch=$OLD" "$(grep '^branch=' "$dir/home/state/$TASK.meta")" "the fixture record must name the old branch"
  assert_equals 0 "$(grep -c '^pr=' "$dir/home/state/$TASK.meta")" "the fixture record must have no pr= line"
  assert_equals "refs/heads/$OLD" "$(git -C "$fx/slots/22/project" symbolic-ref HEAD)" "the copy must be on the old branch"
  # S, B and P are mutually diverged: no tip contains another.
  S=$(git -C "$fx/project" rev-parse "refs/heads/$OLD")
  P=$(git -C "$fx/project" rev-parse "refs/heads/$SUCC")
  B=$(git -C "$fx/project" rev-parse "refs/remotes/origin/$OLD")
  git -C "$fx/project" merge-base --is-ancestor "$S" "$P" && fail "S must not be an ancestor of P in the fixture"
  git -C "$fx/project" merge-base --is-ancestor "$B" "$P" && fail "B must not be an ancestor of P in the fixture"
  DF=$(git -C "$fx/gate.git" rev-parse "refs/no-mistakes/recover/$RUN_NEW")
  # DF is held by the gate's recover ref; no ref of the project reaches it.
  assert_equals "" "$(git -C "$fx/project" for-each-ref --contains "$DF" 2>/dev/null)" "no project ref may reach the unpublished commit"
  pass "the Scott fixture: copy on the old branch, S, B and P mutually diverged, the unpublished commit reachable only from the gate, no pr= line"
}

test_scott_admission_proves_the_successor_by_the_task_own_archive_branch() {
  local dir out rc
  dir=$(new_scott_case admission)
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --check) || rc=$?
  expect_code 0 "$rc" "the successor of the Scott shape must be admitted by --check"$'\n'"$out"
  assert_contains "$out" "successor-check $TASK" "--check names its outcome"
  # The same fixture refuses a branch with no proof tying it to the task.
  git -C "$dir/fx/project" branch fm/scott-unproved "$(git -C "$dir/fx/project" rev-parse main)"
  rc=0
  out=$(sc "$dir" --branch fm/scott-unproved --check) || rc=$?
  expect_code 1 "$rc" "an unproved branch must refuse on the Scott shape"$'\n'"$out"
  assert_contains "$out" "is not proved to be this task's successor" "the refusal must name the missing proof"
  # The old branch's own archive tip does not make a different branch the successor.
  git -C "$dir/fx/project" branch fm/scott-s-copy "refs/heads/$OLD"
  rc=0
  out=$(sc "$dir" --branch fm/scott-s-copy --check) || rc=$?
  expect_code 0 "$rc" "a branch at the tip of the task's own submitted archive is proved by route 2"$'\n'"$out"
  pass "the Scott shape: the successor is admitted by the task's own archive branch, and a branch with no proof is refused"
}

test_scott_operation_then_relaunch_keeps_every_custody_relationship() {
  local dir out rc fx diff_copy changed pid
  dir=$(new_scott_case custody)
  fx=$dir/fx
  pid=$(cat "$dir/sentinel-pid")
  snap_scott "$dir" before
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --note "Main's custody step needs the successor in this copy") || rc=$?
  expect_code 0 "$rc" "recording the Scott successor should succeed"$'\n'"$out"
  snap_scott "$dir" op
  # The operation writes the record and the brief and nothing else.
  same "$dir" before op "the operation" custody gate copy project-git binding fake
  no_custody_calls "$dir" "the operation"
  [ "$(diff "$dir/snap/before/state" "$dir/snap/op/state" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | tr '\n' ' ')" = "$TASK.meta " ] \
    || fail "the operation changed state beyond the task record: $(diff "$dir/snap/before/state" "$dir/snap/op/state")"
  [ "$(diff "$dir/snap/before/data" "$dir/snap/op/data" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | tr '\n' ' ')" = "$TASK/brief.md " ] \
    || fail "the operation changed data beyond the task brief: $(diff "$dir/snap/before/data" "$dir/snap/op/data")"
  assert_equals "successor_branch=$SUCC" "$(grep '^successor_branch=' "$dir/home/state/$TASK.meta")" "the record must carry the successor"
  assert_equals "branch=$OLD" "$(grep '^branch=' "$dir/home/state/$TASK.meta")" "the record must keep the old branch"
  assert_equals "Ship branch: $OLD" "$(grep '^Ship branch:' "$dir/home/data/$TASK/brief.md")" "the brief's Ship branch line must stay equal to branch="
  # The real relaunch against the fake backend.
  rc=0
  out=$(run_control "$dir" "$TASK" relaunch --note "apply the recorded successor branch") || rc=$?
  expect_code 0 "$rc" "the relaunch after the operation should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched $TASK" "the relaunch did not run"
  snap_scott "$dir" relaunch
  # Custody: the gate, the unpublished commit, every ref, the run binding and the project's Git directory.
  same "$dir" op relaunch "the relaunch" custody gate binding
  successor_relaunch_git_changes "$dir/snap/op/project-git" "$dir/snap/relaunch/project-git" "the relaunch"
  no_custody_calls "$dir" "the relaunch"
  # The copy: only the worker wiring files a relaunch always rewrites may differ.
  diff_copy=$(diff "$dir/snap/op/copy" "$dir/snap/relaunch/copy" || true)
  changed=$(printf '%s\n' "$diff_copy" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | grep -v -e '^\.claude/settings\.local\.json$' -e '^\.fm-busy-stop$' -e '^\.claude$' || true)
  [ -z "$changed" ] || fail "the relaunch changed task files beyond its worker wiring: $changed"
  printf 'note: relaunch rewrote only the worker wiring in the copy: %s\n' "$(printf '%s\n' "$diff_copy" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u | tr '\n' ' ')"
  assert_equals "successor_branch=$SUCC" "$(grep '^successor_branch=' "$dir/home/state/$TASK.meta")" "the relaunch lost the recorded successor"
  assert_equals "branch=$OLD" "$(grep '^branch=' "$dir/home/state/$TASK.meta")" "the relaunch changed the old branch"
  assert_equals "refs/heads/$OLD" "$(git -C "$fx/slots/22/project" symbolic-ref HEAD)" "the copy must stay on the old branch until Main's custody step"
  kill -0 "$pid" 2>/dev/null || fail "the unrelated stand-in worker process was signalled"
  if [ "$(uname -s)" = Darwin ]; then
    local sb=$dir/home/state/$TASK.write-confinement.sb common
    common=$(cd "$(git -C "$fx/project" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
    [ -f "$sb" ] || fail "the relaunch wrote no write profile"
    for path in "refs/heads/$OLD" "logs/refs/heads/$OLD" "refs/heads/$SUCC" "logs/refs/heads/$SUCC"; do
      grep -qxF "(allow file-write* (literal \"$common/$path\"))" "$sb" || fail "the profile lacks the literal allow for $path"
      grep -qxF "(allow file-write* (literal \"$common/$path.lock\"))" "$sb" || fail "the profile lacks the literal allow for $path.lock"
    done
    assert_equals 0 "$(grep -c "refs/heads/fm/\*\|refs/heads/fm\"" "$sb")" "the profile must not allow the fm folder"
  else
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
  fi
  pass "Scott shape: the operation writes only the record and brief, and the real relaunch keeps the gate refs, the unpublished commit, the old and successor refs, the copy and the run binding"
}

test_scott_record_revocation_restores_the_launch_profile() {
  local dir out rc fx common sb
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case revoke)
  fx=$dir/fx
  sb=$dir/home/state/$TASK.write-confinement.sb
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --note "needed") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  rc=0
  out=$(run_control "$dir" "$TASK" relaunch --note "apply") || rc=$?
  expect_code 0 "$rc" "relaunch with the successor should succeed"$'\n'"$out"
  common=$(cd "$(git -C "$fx/project" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
  grep -qF "$common/refs/heads/$SUCC\"" "$sb" || fail "the profile must carry the successor"
  # Removing the record's line (Main's own record edit) and relaunching drops the grant.
  sed -i.bak '/^successor_branch=/d' "$dir/home/state/$TASK.meta" && rm -f "$dir/home/state/$TASK.meta.bak"
  rc=0
  out=$(run_control "$dir" "$TASK" relaunch --note "revoked") || rc=$?
  expect_code 0 "$rc" "relaunch without the successor should succeed"$'\n'"$out"
  grep -qF "$common/refs/heads/$SUCC" "$sb" && fail "the revoked successor is still in the profile"
  grep -qxF "(allow file-write* (literal \"$common/refs/heads/$OLD\"))" "$sb" || fail "the old branch literal must remain"
  pass "Scott shape: removing the record's successor line and relaunching drops the grant from the profile"
}

test_scott_hand_edited_record_cannot_widen_a_launch() {
  local dir out rc fx common sb bad
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case handedit)
  fx=$dir/fx
  sb=$dir/home/state/$TASK.write-confinement.sb
  common=$(cd "$(git -C "$fx/project" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
  for bad in 'fm/*' 'fm/x y' main "archive/$TASK-submitted-0123abcd" "$OLD"; do
    sed -i.bak '/^successor_branch=/d' "$dir/home/state/$TASK.meta" && rm -f "$dir/home/state/$TASK.meta.bak"
    printf 'successor_branch=%s\n' "$bad" >> "$dir/home/state/$TASK.meta"
    rm -f "$sb"
    rc=0
    out=$(run_control "$dir" "$TASK" relaunch --note "hand edited") || rc=$?
    [ "$rc" != 0 ] || [ ! -f "$sb" ] || ! grep -qF -e "$bad\"" -e "$bad.lock\"" "$sb" \
      || fail "a hand-edited successor '$bad' reached the launch profile"
    [ "$rc" != 0 ] || fail "a hand-edited successor '$bad' must refuse the launch"
    assert_contains "$out" "not admissible" "the refusal of '$bad' must name the rule"
  done
  pass "Scott shape: a hand-edited successor record that the operation would refuse never reaches a launch profile"
}

control_relaunch_test_cases=(
test_scott_fixture_has_the_shape_the_amendment_names
test_scott_admission_proves_the_successor_by_the_task_own_archive_branch
test_scott_operation_then_relaunch_keeps_every_custody_relationship
test_scott_record_revocation_restores_the_launch_profile
test_scott_hand_edited_record_cannot_widen_a_launch
)

control_relaunch_run "$@"
