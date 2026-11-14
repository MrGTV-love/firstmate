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
  # The same fixture refuses a branch with no proof tying it to the task: in the
  # task's name family, but at no archive tip and checked out nowhere.
  git -C "$dir/fx/project" branch "$OLD-unproved" "$(git -C "$dir/fx/project" rev-parse main)"
  rc=0
  out=$(sc "$dir" --branch "$OLD-unproved" --check) || rc=$?
  expect_code 1 "$rc" "an unproved branch must refuse on the Scott shape"$'\n'"$out"
  assert_contains "$out" "is not proved to be this task's successor" "the refusal must name the missing proof"
  pass "the Scott shape: the successor is admitted by the task's own archive branch, and a branch with no proof is refused"
}

# C1: the archive-tip route proves a tip, not a name, so it admits only a name in
# the task's own family. Every name below sits at the tip of the task's own
# archive branch; only the one in the family is admitted.
test_scott_name_family_bounds_the_archive_route() {
  local dir out rc name tip
  dir=$(new_scott_case family)
  tip=$(git -C "$dir/fx/project" rev-parse "refs/heads/$OLD")
  git -C "$dir/fx/project" for-each-ref --format='%(objectname)' "refs/heads/archive/$TASK-*" | grep -qx "$tip" \
    || fail "the fixture must hold a task archive branch at the old branch's tip"
  for name in develop release/1.x fm/scott-s-copy; do
    git -C "$dir/fx/project" branch "$name" "$tip"
    rc=0
    out=$(sc "$dir" --branch "$name" --check) || rc=$?
    expect_code 1 "$rc" "$name at a task archive tip is outside the task's name family and must refuse"$'\n'"$out"
    assert_contains "$out" "outside the task's own name family" "the refusal for $name must name the bound"
  done
  git -C "$dir/fx/project" branch "$OLD-copy" "$tip"
  rc=0
  out=$(sc "$dir" --branch "$OLD-copy" --check) || rc=$?
  expect_code 0 "$rc" "a name in the family at the same archive tip is the matched control and must be admitted"$'\n'"$out"
  assert_contains "$out" "route=archive-tip" "the control is proved by the archive-tip route"
  pass "the Scott shape: develop, release/1.x and another lineage's name at a task archive tip are refused for the name family, and a name in the family there is admitted"
}

test_scott_operation_then_relaunch_keeps_every_custody_relationship() {
  local dir out rc fx pid
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
  # What the relaunch changes in the copy is compared, without a filter list, by
  # test_scott_relaunch_changes_the_copy_only_as_a_relaunch_without_the_successor_does.
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

# C3: the receipt carries a structured route token, and the guard writes one event
# when the record is made and one at the launch that applies the grant, each naming
# the route and the successor. The Scott shape is proved by the archive-tip route.
test_scott_receipt_and_events_name_the_archive_tip_route() {
  local dir out rc row archive
  dir=$(new_scott_case route)
  : > "$FM_GUARD_EVENT_LOG"
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --note "route evidence") || rc=$?
  expect_code 0 "$rc" "recording the Scott successor should succeed"$'\n'"$out"
  archive=$(printf '%s\n' "$out" | sed -n 's/^route: route=archive-tip archive=\([^ ]*\) .*/\1/p')
  case "$archive" in
    "archive/$TASK-submitted-"* | "archive/$TASK-pipeline-"*) ;;
    *) fail "the receipt must carry route=archive-tip and the matched archive name: $out" ;;
  esac
  assert_contains "$out" "successor=$SUCC" "the receipt route line must name the successor"
  row=$(admission_event record allow)
  [ -n "$row" ] || fail "no successor-branch-admission allow event was written at record time"
  assert_equals archive-tip "$(printf '%s' "$row" | jq -r .route)" "the record-time event must name the route"
  assert_equals "$SUCC" "$(printf '%s' "$row" | jq -r .successor)" "the record-time event must name the successor"
  assert_equals "$TASK" "$(printf '%s' "$row" | jq -r .task)" "the record-time event must name the task"
  rc=0
  out=$(run_control "$dir" "$TASK" relaunch --note "apply") || rc=$?
  expect_code 0 "$rc" "the relaunch should succeed"$'\n'"$out"
  if [ "$(uname -s)" = Darwin ]; then
    row=$(admission_event launch allow)
    [ -n "$row" ] || fail "no successor-branch-admission allow event was written at the launch that applies the grant"
    assert_equals archive-tip "$(printf '%s' "$row" | jq -r .route)" "the launch event must name the route"
    assert_equals "$SUCC" "$(printf '%s' "$row" | jq -r .successor)" "the launch event must name the successor"
  else
    printf 'skip: the launch grant is applied on macOS only; Linux remains unconfined\n'
  fi
  pass "Scott shape: the receipt names route=archive-tip and the matched archive, and the guard writes an event with route and successor at record time and at the launch that applies the grant"
}

# C4: the launch re-runs the whole admission and fails closed. Each hand-edited
# record below passes the name rule; each is refused at the launch, and no line
# for its name reaches a profile.
test_scott_launch_re_proves_the_whole_admission() {
  local dir out rc fx sb tip bad want
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case reprove)
  fx=$dir/fx
  sb=$dir/home/state/$TASK.write-confinement.sb
  tip=$(git -C "$fx/project" rev-parse "refs/heads/$OLD")
  git -C "$fx/project" branch "$OLD-unproved" "$(git -C "$fx/project" rev-parse main)"
  git -C "$fx/project" worktree add -q -b "$OLD-elsewhere" "$dir/wt-elsewhere" "$tip"
  git -C "$fx/project" branch develop "$tip"
  for bad in "$OLD-ghost" "$OLD-elsewhere" "$OLD-unproved" develop; do
    case "$bad" in
      "$OLD-ghost") want="does not exist in the project's ref store" ;;
      "$OLD-elsewhere") want="which is not this task's recorded copy" ;;
      "$OLD-unproved") want="is not proved to be this task's successor" ;;
      develop) want="outside the task's own name family" ;;
    esac
    sed -i.bak '/^successor_branch=/d' "$dir/home/state/$TASK.meta" && rm -f "$dir/home/state/$TASK.meta.bak"
    printf 'successor_branch=%s\n' "$bad" >> "$dir/home/state/$TASK.meta"
    rm -f "$sb"
    rc=0
    out=$(run_control "$dir" "$TASK" relaunch --note "hand edited") || rc=$?
    [ "$rc" != 0 ] || fail "a hand-edited successor '$bad' that the admission refuses must refuse the launch"$'\n'"$out"
    assert_contains "$out" "$want" "the launch refusal of '$bad' must name the missing proof"
    [ ! -f "$sb" ] || ! grep -qF -e "$bad\"" -e "$bad.lock\"" "$sb" || fail "a line for '$bad' reached the launch profile"
  done
  pass "Scott shape: a hand-edited record naming a missing branch, a branch checked out in another work tree, a branch neither route proves or a name outside the family is refused at the launch with no profile line for it"
}

# C4: --check on a successor the record already names proves it again.
test_scott_check_proves_a_recorded_successor_again() {
  local dir out rc fx
  dir=$(new_scott_case recheck)
  fx=$dir/fx
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --note "recorded") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --check) || rc=$?
  expect_code 0 "$rc" "--check of a still proved recorded successor should succeed"$'\n'"$out"
  assert_contains "$out" "route=archive-tip" "--check of a recorded successor must show the route it proved again"
  # The ref moves off every archive tip after it was recorded.
  git -C "$fx/project" update-ref "refs/heads/$SUCC" "$(git -C "$fx/project" rev-parse main)"
  rc=0
  out=$(sc "$dir" --branch "$SUCC" --check) || rc=$?
  expect_code 1 "$rc" "--check of a recorded successor that is no longer proved must refuse"$'\n'"$out"
  assert_contains "$out" "is no longer proved" "the refusal must say the recorded successor no longer holds"
  case "$out" in *"recorded earlier"*) fail "the check must not report a stale proof: $out" ;; esac
  pass "Scott shape: --check on a recorded successor proves it again and refuses once it is no longer proved"
}

# --- Round 2 (outside review of 71d56288f): failing-first tests on the Scott shape ---

# The changed paths between two copy fingerprints, one per line, sorted.
copy_delta() {  # <fingerprint-before> <fingerprint-after>
  diff "$1" "$2" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u
}

# The copy's wiring text with the one per-launch value neutralised: every relaunch
# mints a fresh generation id into its hooks (fm-spawn.sh, so an event from an
# earlier incarnation is rejected), which no relaunch can leave byte-identical.
wiring_without_generation() {  # <file>
  sed -E "s/--gen 'g[0-9]+\.[0-9]+\.[0-9]+'/--gen 'GEN'/g" "$1"
}

# F4: no filter list and no rewritten expectation. The operation leaves the copy
# byte-identical; the relaunch that follows changes exactly what a relaunch without
# a recorded successor changes (the same paths, and the same wiring text apart from
# the generation id it mints), so the successor adds nothing to the copy.
test_scott_relaunch_changes_the_copy_only_as_a_relaunch_without_the_successor_does() {
  local dir out rc copy delta_control delta_successor
  dir=$(new_scott_case twin)
  copy=$dir/fx/slots/22/project
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "control one") || rc=$?
  expect_code 0 "$rc" "the first control relaunch should succeed"$'\n'"$out"
  snap_scott "$dir" c1
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "control two") || rc=$?
  expect_code 0 "$rc" "the second control relaunch should succeed"$'\n'"$out"
  snap_scott "$dir" c2
  cp "$copy/.claude/settings.local.json" "$dir/wiring.c2"
  delta_control=$(copy_delta "$dir/snap/c1/copy" "$dir/snap/c2/copy")
  rc=0; out=$(sc "$dir" --branch "$SUCC" --note "twin check") || rc=$?
  expect_code 0 "$rc" "recording the Scott successor should succeed"$'\n'"$out"
  snap_scott "$dir" op
  same "$dir" c2 op "the operation" copy gate project-git binding custody
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "apply the successor") || rc=$?
  expect_code 0 "$rc" "the relaunch with the successor should succeed"$'\n'"$out"
  snap_scott "$dir" r
  cp "$copy/.claude/settings.local.json" "$dir/wiring.r"
  delta_successor=$(copy_delta "$dir/snap/op/copy" "$dir/snap/r/copy")
  printf 'note: a relaunch without the successor changed in the copy: %s\n' "$(printf '%s' "$delta_control" | tr '\n' ' ')"
  printf 'note: the relaunch with the successor changed in the copy:  %s\n' "$(printf '%s' "$delta_successor" | tr '\n' ' ')"
  assert_equals "$delta_control" "$delta_successor" "the relaunch with the successor must change the same copy paths as a relaunch without it"
  [ -n "$delta_successor" ] || fail "the oracle saw no relaunch rewrite at all; it can no longer tell the two relaunches apart"
  [ "$(wiring_without_generation "$dir/wiring.c2")" = "$(wiring_without_generation "$dir/wiring.r")" ] \
    || fail "the relaunch with the successor wrote wiring that a relaunch without it does not write: $(diff <(wiring_without_generation "$dir/wiring.c2") <(wiring_without_generation "$dir/wiring.r") | head -5)"
  pass "Scott shape: the operation leaves the copy byte-identical, and the relaunch changes only what a relaunch without the successor changes"
}

# F1 at the launch: another task's record that cannot be read refuses the grant.
test_scott_launch_refuses_when_another_task_record_cannot_be_read() {
  local dir out rc sb other
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case unreadable)
  mode_zero_binds "$dir/probe" || { printf 'skip: this user reads mode 000 files, so an unreadable record cannot be staged\n'; return 0; }
  sb=$dir/home/state/$TASK.write-confinement.sb
  other=$dir/home/state/other-owner.meta
  printf 'kind=ship\nbranch=%s\n' "$SUCC" > "$other"
  printf 'successor_branch=%s\n' "$SUCC" >> "$dir/home/state/$TASK.meta"
  chmod 000 "$other"
  rm -f "$sb"
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "owner unreadable") || rc=$?
  chmod 600 "$other"
  [ "$rc" != 0 ] || fail "a launch that cannot read another task's record must refuse the grant"$'\n'"$out"
  assert_contains "$out" "cannot read task other-owner's record" "the launch refusal must name the unreadable record"
  [ ! -f "$sb" ] || ! grep -qF "$SUCC\"" "$sb" || fail "a line for the successor reached the profile although the inventory was unreadable"
  # Matched control: a readable record that does not own the name lets the launch through.
  printf 'kind=ship\nbranch=fm/other-owner\n' > "$other"
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "owner readable") || rc=$?
  expect_code 0 "$rc" "a readable inventory with no owner of the name must let the launch through"$'\n'"$out"
  grep -qF "refs/heads/$SUCC\"" "$sb" || fail "the control launch must carry the successor"
  pass "Scott shape: a launch refuses the grant while another task's record cannot be read, and carries it once the inventory is readable"
}

# F2 (2) at the launch: the profile is derived from the copy's repository, so a copy
# in another repository must refuse the grant the project's archive would prove.
test_scott_launch_refuses_a_copy_outside_the_projects_ref_store() {
  local dir out rc sb fx
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case store)
  fx=$dir/fx
  sb=$dir/home/state/$TASK.write-confinement.sb
  git init -q -b main "$dir/other-repo"
  git -C "$dir/other-repo" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  git -C "$dir/other-repo" worktree add -q -b "$SUCC" "$dir/other-copy"
  cp -p "$dir/home/state/$TASK.meta" "$dir/meta.good"
  # The omp harness: a claude launch is stopped earlier by the workspace-trust pre-registration,
  # which refuses a copy that is not a worktree of the project, so for omp the proof is the
  # only guard between the record and the profile.
  sed -i.bak -e "s#^worktree=.*#worktree=$dir/other-copy#" -e 's#^harness=.*#harness=omp#' "$dir/home/state/$TASK.meta" && rm -f "$dir/home/state/$TASK.meta.bak"
  printf 'successor_branch=%s\n' "$SUCC" >> "$dir/home/state/$TASK.meta"
  # The control relaunches only an endpoint that sits in the recorded copy, so the fake
  # endpoint is moved into the other repository's copy as well; the proof is then what stops the launch.
  printf '%s' "$dir/other-copy" > "$dir/fake/cwd"
  rm -f "$sb"
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "mismatched repositories") || rc=$?
  [ "$rc" != 0 ] || fail "a launch whose copy is in another repository must refuse the grant"$'\n'"$out"
  assert_contains "$out" "does not share the project's ref store" "the launch refusal must name the missing proof"
  [ ! -f "$sb" ] || ! grep -qF "$SUCC\"" "$sb" || fail "a line for the successor reached the profile for a copy in another repository"
  # Matched control: the copy that shares the project's ref store, with the same record, launches.
  cp -p "$dir/meta.good" "$dir/home/state/$TASK.meta"
  sed -i.bak 's#^harness=.*#harness=omp#' "$dir/home/state/$TASK.meta" && rm -f "$dir/home/state/$TASK.meta.bak"
  printf 'successor_branch=%s\n' "$SUCC" >> "$dir/home/state/$TASK.meta"
  printf '%s' "$fx/slots/22/project" > "$dir/fake/cwd"
  rc=0; out=$(run_control "$dir" "$TASK" relaunch --note "matching repositories") || rc=$?
  expect_code 0 "$rc" "the copy that shares the project's ref store must launch"$'\n'"$out"
  grep -qF "refs/heads/$SUCC\"" "$sb" || fail "the matching control launch must carry the successor"
  pass "Scott shape: a launch refuses the grant for a copy outside the project's ref store, and carries it for the matching copy"
}

# F5 at the launch: the event that applies the grant is not best-effort.
test_scott_launch_requires_its_event_to_be_written() {
  local dir out rc sb log
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: the write profile is generated on macOS only; Linux remains unconfined\n'
    return 0
  fi
  dir=$(new_scott_case launch-sink)
  sb=$dir/home/state/$TASK.write-confinement.sb
  rc=0; out=$(sc "$dir" --branch "$SUCC" --note "event sink") || rc=$?
  expect_code 0 "$rc" "recording should succeed"$'\n'"$out"
  mkdir -p "$dir/event-sink-dir"
  rm -f "$sb"
  rc=0; out=$( export FM_GUARD_EVENT_LOG="$dir/event-sink-dir"; run_control "$dir" "$TASK" relaunch --note "sink broken" ) || rc=$?
  [ "$rc" != 0 ] || fail "a launch whose grant event cannot be written must refuse"$'\n'"$out"
  assert_contains "$out" "event" "the launch refusal must name the event"
  [ ! -f "$sb" ] || ! grep -qF "$SUCC\"" "$sb" || fail "the profile kept the successor although its event was not written"
  log=$dir/launch-events.jsonl
  rc=0; out=$( export FM_GUARD_EVENT_LOG="$log"; run_control "$dir" "$TASK" relaunch --note "sink fine" ) || rc=$?
  expect_code 0 "$rc" "a writable sink must let the launch through"$'\n'"$out"
  jq -e 'select(.guard == "successor-branch-admission" and .rule == "launch" and .decision == "allow")' "$log" >/dev/null \
    || fail "the launch event was not written to the sink"
  pass "Scott shape: a launch whose grant event cannot be written refuses and keeps no profile line, and a writable sink lets it through with the event"
}

control_relaunch_test_cases=(
test_scott_fixture_has_the_shape_the_amendment_names
test_scott_admission_proves_the_successor_by_the_task_own_archive_branch
test_scott_name_family_bounds_the_archive_route
test_scott_receipt_and_events_name_the_archive_tip_route
test_scott_launch_re_proves_the_whole_admission
test_scott_check_proves_a_recorded_successor_again
test_scott_relaunch_changes_the_copy_only_as_a_relaunch_without_the_successor_does
test_scott_launch_refuses_when_another_task_record_cannot_be_read
test_scott_launch_refuses_a_copy_outside_the_projects_ref_store
test_scott_launch_requires_its_event_to_be_written
test_scott_operation_then_relaunch_keeps_every_custody_relationship
test_scott_record_revocation_restores_the_launch_profile
test_scott_hand_edited_record_cannot_widen_a_launch
)

control_relaunch_run "$@"
