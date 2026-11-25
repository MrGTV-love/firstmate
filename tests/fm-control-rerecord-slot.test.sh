#!/usr/bin/env bash
# fm-control.sh <id> rerecord-slot: re-record a governed task's renewed slot identity.
#
# Every case runs the real entry point, bin/fm-control.sh, in a hermetic fixture home: a governed ship task admitted by
# the fixture provisioner (tests/fm-control-relaunch-slot-helpers.sh), whose project main then moves forward, whose
# branch merges it and adds work, and whose durable slot record is then renewed (fixture F below). Each observation is
# read independently of the verb's exit code and message: the record's slot lines, the audit records and archives
# under data/<id>/slot-rerecord/, an inventory of the record and the verb's temporaries, the manifest directory, the
# provisioner sentinel, and the stub endpoint's send-keys log.
# Faults and sensitivity controls run a copy of bin/ with one override appended to the copied library that defines the
# function (the shim), so shipped code carries no seam and no bypass. A control passes only when the harm it names is
# positively observed.
# Each case and control appends one "<ID><TAB><result><TAB><observation>" line to $FM_RR_RESULTS when that is set.
# Shim overrides are single-quoted on purpose (they expand in the verb's shell), most runs pass no arguments to the run
# helpers, and an observation chain may fail on either side, so these hold for the whole file:
# shellcheck disable=SC2016,SC2119,SC2015,SC2031

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"
# shellcheck source=tests/fm-control-relaunch-slot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-slot-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

FM_REAL_MV=$(command -v mv)
RR_NOTE='Main 2345 ruling: re-record the renewed slot after the authorized forward merge'
RR_RESULTS=${FM_RR_RESULTS:-}
RR_CONTROL=
RR_TASK_ID=
RR_ACTOR=

rr_record() { # <id> <result> <observation>
  [ -z "$RR_RESULTS" ] || printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RR_RESULTS"
}

rr_ok() { # <id> <observation>
  rr_record "$1" pass "$2"
  pass "$1: $2"
}

rr_commit() { # <dir> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=Tests -c user.email=tests@example.invalid commit -qm "$2"
}

# The bash on PATH runs the EXIT trap at once when TERM reaches a shell whose foreground child is still running (bash
# 3.2.57 does). Cases whose observation depends on that order branch on this probe (review note N6).
RR_TERM_IMMEDIATE=
rr_term_runs_trap_with_child() {
  local d
  if [ -z "$RR_TERM_IMMEDIATE" ]; then
    d="$TMP_ROOT/sigprobe-$RANDOM"
    mkdir -p "$d"
    printf '%s\n' 'trap '"'"'echo trap >> "$1/log"'"'"' EXIT' '/bin/sleep 3' 'echo after >> "$1/log"' > "$d/p.sh"
    bash "$d/p.sh" "$d" &
    local pid=$! start=$SECONDS
    /bin/sleep 0.5
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if [ "$((SECONDS - start))" -lt 2 ] && grep -qx trap "$d/log" 2>/dev/null; then
      RR_TERM_IMMEDIATE=1
    else
      RR_TERM_IMMEDIATE=0
    fi
  fi
  [ "$RR_TERM_IMMEDIATE" = 1 ]
}

# --- stubs ---------------------------------------------------------------------------------------

rr_start_spawn_lock_holder() {
  start_spawn_lock_holder "$RR_DIR/home/state" "$RR_ID" "$RR_DIR/holder-ready.$RANDOM"
  RR_HOLDER_PID=$SPAWN_LOCK_HOLDER_PID
}

rr_stop_spawn_lock_holder() {
  kill "$RR_HOLDER_PID" 2>/dev/null
  wait "$RR_HOLDER_PID" 2>/dev/null
  return 0
}

# --- fixture F ----------------------------------------------------------------------------------

# rr_renew [--owner-id <id>] [--base-sha <sha>] [--worktree-path <path>] [--owned-path <path>]...: the live renewal:
# move the current manifest aside, then run the fixture provisioner again. Defaults: this task, M1, the copy, and
# src, lib, tools/x.sh.
rr_renew() {
  local owner=$RR_ID base=$RR_M1 wt="$RR_DIR/wt"
  local -a paths=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner-id) owner=$2; shift 2 ;;
      --base-sha) base=$2; shift 2 ;;
      --worktree-path) wt=$2; shift 2 ;;
      --owned-path) paths+=(--owned-path "$2"); shift 2 ;;
      *) fail "rr_renew: unknown argument $1" ;;
    esac
  done
  [ "${#paths[@]}" -gt 0 ] || paths=(--owned-path src --owned-path lib --owned-path tools/x.sh)
  mv "$RR_MANIFEST" "$RR_DIR/manifests/moved-aside.$RANDOM.json"
  FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
    python3 "$RR_DIR/proj/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$RR_DIR/proj" --worktree-path "$wt" --owner-id "$owner" --branch "fm/$RR_ID" \
    --base-sha "$base" "${paths[@]}" >/dev/null || fail "fixture renewal failed"
  : > "$ADOPT_SENTINEL"
}

# rr_main_commit <message> <file=content>...: a commit on the project's main, pushed and seen by the copy as origin/main.
rr_main_commit() {
  local msg=$1 pair
  shift
  for pair in "$@"; do
    mkdir -p "$(dirname "$RR_DIR/proj/${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$RR_DIR/proj/${pair%%=*}"
  done
  rr_commit "$RR_DIR/proj" "$msg"
  git -C "$RR_DIR/proj" push -q origin HEAD:main
  git -C "$RR_DIR/wt" update-ref refs/remotes/origin/main "$(git -C "$RR_DIR/proj" rev-parse HEAD)"
  git -C "$RR_DIR/proj" rev-parse HEAD
}

rr_branch_commit() { # <message> <file=content>...
  local msg=$1 pair
  shift
  for pair in "$@"; do
    mkdir -p "$(dirname "$RR_DIR/wt/${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$RR_DIR/wt/${pair%%=*}"
  done
  rr_commit "$RR_DIR/wt" "$msg"
}

rr_branch_merge_main() {
  git -C "$RR_DIR/wt" -c user.name=Tests -c user.email=tests@example.invalid merge -q --no-edit refs/remotes/origin/main
}

# rr_make_f <name> [--no-renew]: fixture F. Sets RR_DIR, RR_ID, RR_META, RR_MANIFEST, RR_M0, RR_M1, RR_H.
rr_make_f() {
  local name=$1 renew=1
  [ "${2:-}" != --no-renew ] || renew=0
  RR_ID=rrt
  make_adopt_case "rr-$name" "$RR_ID" src
  RR_DIR=$ADOPT_DIR
  RR_META=$ADOPT_META
  RR_MANIFEST=$ADOPT_MANIFEST
  RR_CONTROL=
  RR_TASK_ID=
  RR_ACTOR=
  make_mv_failure_stub "$RR_DIR"
  fm_fake_crash_injector "$RR_DIR/fakebin"
  RR_M0=$(git -C "$RR_DIR/proj" rev-parse HEAD)
  RR_M1=$(rr_main_commit 'main M1' docs.txt=docs-at-m1 lib/a.py=a tools/x.sh=x tools/y.sh=y tools/sub/z.sh=z src/other.txt=other)
  git -C "$RR_DIR/wt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  rr_branch_commit 'own change K' src/owned.txt=owned-by-k
  rr_branch_merge_main
  rr_branch_commit 'new lib file and tools change' lib/new.py=new tools/x.sh=x-changed
  RR_H=$(git -C "$RR_DIR/wt" rev-parse HEAD)
  [ "$renew" = 0 ] || rr_renew
  stage_gone "$RR_DIR" "$RR_ID" server-dead
  make_continuation_owner_fixture "$RR_DIR"
}

rr_alive() { rm -f "$RR_DIR/fake/server-dead"; printf 'claude' > "$RR_DIR/fake/command"; }
rr_dead_pane() { rm -f "$RR_DIR/fake/server-dead"; printf 'zsh' > "$RR_DIR/fake/command"; }

rr_manifest_set() { # <field> <json-value>
  python3 - "$RR_MANIFEST" "$1" "$2" <<'PY'
import json, sys
path, field, value = sys.argv[1:4]
record = json.load(open(path, encoding="utf-8"))
record[field] = json.loads(value)
open(path, "w", encoding="utf-8").write(json.dumps(record, sort_keys=True))
PY
}

# rr_record_slots <base> <entry>...: rewrite the record's slot lines in place (a hand edit).
rr_record_slots() {
  python3 - "$RR_META" "$@" <<'PY'
import sys
path, base = sys.argv[1:3]
scope = sys.argv[3:]
lines = open(path, "rb").read().splitlines(keepends=True)
block = ("slot_base_sha=%s\n" % base + "".join("slot_owned_path=%s\n" % e for e in scope)).encode()
out, done = [], False
for line in lines:
    if line.startswith(b"slot_base_sha=") or line.startswith(b"slot_owned_path="):
        if not done:
            out.append(block)
            done = True
        continue
    out.append(line)
open(path, "wb").write(b"".join(out))
PY
}

rr_journal() { # <phase-line-or-empty> [extra-line]...: state/<id>.control-relaunch, write_relaunch_journal's shape
  local phase=$1 line
  shift
  {
    printf 'v1\ntask=%s\n' "$RR_ID"
    [ -z "$phase" ] || printf '%s\n' "$phase"
    printf 'ts=2026-01-01T00:00:00Z\nbackend=tmux\nendpoint=fmses:fm-%s\nworktree=%s\nkind=ship\n' "$RR_ID" "$RR_DIR/wt"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$RR_DIR/home/state/$RR_ID.control-relaunch"
}

# --- runs ----------------------------------------------------------------------------------------

rr_msha() { shasum -a 256 "$RR_MANIFEST" | awk '{print $1}'; }

rr_run() { # <args...>: the verb, through the shim when RR_CONTROL is set
  (
    unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    [ -z "$RR_TASK_ID" ] || export FM_TASK_ID="$RR_TASK_ID"
    [ -z "$RR_ACTOR" ] || export FM_SUPERVISION_ACTOR="$RR_ACTOR"
    if [ -n "$RR_CONTROL" ]; then
      export FM_ROOT_OVERRIDE=$ROOT
      CONTROL=$RR_CONTROL
    fi
    run_control "$RR_DIR" "$RR_ID" rerecord-slot "$@"
  )
}

# shellcheck disable=SC2120 # most cases pass no extra arguments
rr_write() { rr_run --manifest-sha "$(rr_msha)" --note "$RR_NOTE" "$@"; }

rr_relaunch() {
  (
    unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal'
  )
}

# rr_shim <library> <override>: append <override> to the case's copy of bin/<library>; later runs use the copy.
rr_shim() {
  local root="$RR_DIR/shim-root"
  if [ ! -d "$root/bin" ]; then
    mkdir -p "$root"
    cp -R "$ROOT/bin" "$root/bin"
  fi
  printf '\n%s\n' "$2" >> "$root/bin/$1"
  RR_CONTROL="$root/bin/fm-control.sh"
}

rr_shim_allow() { # <function> [success-line]: an allow-override printing exactly the success output callers parse
  if [ -n "${2:-}" ]; then
    rr_shim fm-slot-provision-lib.sh "$1() { printf '%s\\n' '$2'; return 0; }"
  else
    rr_shim fm-slot-provision-lib.sh "$1() { return 0; }"
  fi
}

rr_wrap() { # <library> <function>: rename <function> to real_<function> in the copy, so an override can call it
  rr_shim "$1" "eval \"\$(declare -f $2 | sed '1s/^$2 /real_$2 /')\""
}

# --- observations --------------------------------------------------------------------------------

rr_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
rr_slot_lines() { grep -E '^(slot_base_sha|slot_owned_path)=' "$RR_META"; }
rr_other_lines() { grep -vE '^(slot_base_sha|slot_owned_path)=' "$1"; }
rr_audit_dir() { printf '%s\n' "$RR_DIR/home/data/$RR_ID/slot-rerecord"; }
rr_audits() { ls "$(rr_audit_dir)"/*.record 2>/dev/null; }
rr_archives() { ls "$(rr_audit_dir)"/prior-meta.* 2>/dev/null; }
rr_count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
rr_field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
rr_audit_for() { # <prior-sha>: the audit record of the run that started from that record
  local a
  for a in $(rr_audits); do
    [ "$(rr_field "$a" prior_sha256)" != "$1" ] || { printf '%s\n' "$a"; return 0; }
  done
  return 1
}
rr_results() { local a; for a in $(rr_audits); do rr_field "$a" result; done | sort | tr '\n' ' ' | sed 's/ $//'; }
rr_leftovers() {
  local entry
  for entry in "$RR_DIR/home/state/.$RR_ID.meta.rerecord"*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    printf '%s\n' "${entry##*/}"
  done
}
rr_block_sha() { { grep -E '^(slot_base_sha|slot_owned_path)=' "$1" || true; } | shasum -a 256 | awk '{print $1}'; }

# rr_agrees <audit>: the audit record's result agrees with the record's current bytes.
rr_agrees() {
  local a=$1 result
  result=$(rr_field "$a" result)
  case "$result" in
    published|published-recovered) [ "$(rr_block_sha "$RR_META")" = "$(rr_field "$a" staged_block_sha256)" ] ;;
    refused|abandoned|rolled-back) [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" prior_sha256)" ] ;;
    superseded-new) [ "$(rr_block_sha "$RR_META")" = "$(rr_field "$a" staged_block_sha256)" ] ;;
    superseded-prior) [ "$(rr_block_sha "$RR_META")" = "$(rr_field "$a" prior_block_sha256)" ] ;;
    superseded-other)
      [ "$(rr_block_sha "$RR_META")" != "$(rr_field "$a" staged_block_sha256)" ] &&
        [ "$(rr_block_sha "$RR_META")" != "$(rr_field "$a" prior_block_sha256)" ] ;;
    *) return 1 ;;
  esac
}

# rec_inventory: the record's identity (inode, mode, size, sha256, mtime_ns, ctime_ns), the audit directory listing
# (absent counts as one) and this task's temporaries under state/; "unchanged" means identical, so a same-byte rewrite
# of the record or a created-then-deleted entry changes it.
rec_inventory() {
  python3 - "$RR_META" "$(rr_audit_dir)" "$RR_DIR/home/state" ".$RR_ID.meta.rerecord" <<'PY'
import hashlib, os, sys
meta, audit, state, prefix = sys.argv[1:5]
def row(path):
    info = os.lstat(path)
    digest = "-"
    if os.path.isfile(path) and not os.path.islink(path):
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    return "%s ino=%d mode=%o size=%d sha=%s mtime=%d ctime=%d" % (path, info.st_ino, info.st_mode, info.st_size, digest, info.st_mtime_ns, info.st_ctime_ns)
print(row(meta))
if os.path.lexists(audit):
    print(row(audit))
    for name in sorted(os.listdir(audit)):
        print(row(os.path.join(audit, name)))
else:
    print("audit-dir absent")
for name in sorted(os.listdir(state)):
    if name.startswith(prefix):
        print(row(os.path.join(state, name)))
PY
}

rr_manifest_inventory() {
  python3 - "$(dirname "$RR_MANIFEST")" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
def row(path):
    info = os.lstat(path)
    digest = "-"
    if os.path.isfile(path) and not os.path.islink(path):
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    return "%s ino=%d mode=%o size=%d sha=%s mtime=%d ctime=%d" % (path, info.st_ino, info.st_mode, info.st_size, digest, info.st_mtime_ns, info.st_ctime_ns)
print(row(root))
for name in sorted(os.listdir(root)):
    print(row(os.path.join(root, name)))
PY
}

rr_sendkeys() { cat "$RR_DIR/fake/literal" "$RR_DIR/fake/keys" 2>/dev/null; }

# rr_expect_refusal <id> <reason> [run args...]: a write run (or the given args) refuses by name and writes nothing.
rr_expect_refusal() {
  local id=$1 reason=$2 before mbefore out rc
  shift 2
  before=$(rec_inventory)
  mbefore=$(rr_manifest_inventory)
  if [ "$#" -gt 0 ]; then out=$(rr_run "$@"); rc=$?; else out=$(rr_write); rc=$?; fi
  [ "$rc" != 0 ] || fail "$id: the run was expected to refuse $reason"$'\n'"$out"
  assert_contains "$out" "error: slot rerecord refused: $reason" "$id: the refusal must name $reason"
  assert_not_contains "$out" "slot adoption refused" "$id: the verb must not print an adoption refusal"
  assert_not_contains "$out" "slot provisioning refused" "$id: the verb must not print a provisioning refusal"
  [ "$before" = "$(rec_inventory)" ] || fail "$id: a refused run changed the record, wrote an archive or audit record, or left a temporary"$'\n'"$before"$'\n---\n'"$(rec_inventory)"
  [ "$mbefore" = "$(rr_manifest_inventory)" ] || fail "$id: a refused run changed the manifest directory"
  [ ! -s "$ADOPT_SENTINEL" ] || fail "$id: the provisioner ran"
  [ -z "$(rr_sendkeys)" ] || fail "$id: lifecycle input was sent"
  RR_OUT=$out
  rr_ok "$id" "refuses $reason; rec_inventory, manifest inventory, sentinel and send-keys log unchanged"
}

# rr_expect_published <id> <base> <entry>...: a write that published exactly these slot lines.
rr_assert_published() {
  local id=$1 base=$2 expected
  shift 2
  expected=$(printf 'slot_base_sha=%s\n' "$base"; printf 'slot_owned_path=%s\n' "$@")
  [ "$(rr_slot_lines)" = "$expected" ] || fail "$id: slot lines are not the renewal's"$'\n'"$(rr_slot_lines)"
}

# rr_control_harm <control> <case>: the shimmed run published (the harm), so slot_lines differ from before.
rr_control_published() { # <control> <case> <before-slot-lines> <out> <rc>
  local control=$1 case_id=$2 before=$3 out=$4 rc=$5
  [ "$rc" = 0 ] || fail "$control/$case_id: the shimmed run did not publish (rc $rc), so the control has no result"$'\n'"$out"
  [ "$before" != "$(rr_slot_lines)" ] || fail "$control/$case_id: slot_lines unchanged under the control"
  [ "$(rr_results)" = published ] || fail "$control/$case_id: audit_result is '$(rr_results)', not published"
  assert_not_contains "$out" "slot rerecord refused" "$control/$case_id: the shimmed run refused"
}

# --- the oracle ---------------------------------------------------------------------------------

test_rec_inventory_oracle_rejects_both_mutants() {
  local before
  rr_make_f oracle
  before=$(rec_inventory)
  [ "$before" = "$(rec_inventory)" ] || fail 'the oracle rejected an untouched record'
  /bin/sleep 0.05
  cp "$RR_META" "$RR_DIR/meta.copy" && cat "$RR_DIR/meta.copy" > "$RR_META"
  [ "$before" != "$(rec_inventory)" ] || fail 'the oracle missed a same-byte rewrite of the record'
  before=$(rec_inventory)
  mkdir -p "$(rr_audit_dir)"
  before=$(rec_inventory)
  /bin/sleep 0.05
  : > "$(rr_audit_dir)/prior-meta.x" && rm -f "$(rr_audit_dir)/prior-meta.x"
  [ "$before" != "$(rec_inventory)" ] || fail 'the oracle missed a created-then-deleted archive'
  rr_ok ORACLE "rec_inventory catches a same-byte rewrite and a created-then-deleted archive"
}

# --- the shared journal classifier (supplement) ---------------------------------------------------

test_journal_verdict_classes() {
  local j
  rr_make_f journal-classes
  j="$RR_DIR/home/state/$RR_ID.control-relaunch"
  assert_equals absent "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "no journal"
  rr_journal phase=complete
  assert_equals complete "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "complete"
  assert_equals unreadable "$(fm_control_relaunch_journal_verdict "$j" other)" "other task"
  for r in prior-record-kept prior-record-kept-agent-dead instructions-restored; do
    rr_journal phase=failed:launching "rollback=$r"
    assert_equals failed-closed "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "rollback $r"
  done
  for r in instructions-restored-agent-alive instructions-restored-agent-state-unknown; do
    rr_journal phase=failed:stopping "rollback=$r"
    assert_equals failed-needs-stopped "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "rollback $r"
  done
  for r in none-new-agent-confirmed none-new-record-kept 'instructions-restored-agent-state-a b' ''; do
    rr_journal phase=failed:launching ${r:+"rollback=$r"}
    assert_equals failed-open "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "rollback '$r'"
  done
  for p in phase=launching phase=failed: ''; do
    rr_journal "$p"
    assert_equals in-flight "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "phase '$p'"
  done
  rm -f "$j"; rr_journal phase=complete; mv "$j" "$j.target"; ln -s "$j.target" "$j"
  assert_equals unreadable "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "symlink"
  rm -f "$j"; mkdir "$j"
  assert_equals unreadable "$(fm_control_relaunch_journal_verdict "$j" "$RR_ID")" "directory"
  rr_ok JOURNAL-CLASSES "every class of fm_control_relaunch_journal_verdict"
}

# --- legitimate cases -----------------------------------------------------------------------------

rr_assert_l1() { # <id> <out> <prior-record-copy>
  local id=$1 out=$2 prior=$3 a
  rr_assert_published "$id" "$RR_M1" src lib tools/x.sh
  [ "$(rr_other_lines "$prior")" = "$(rr_other_lines "$RR_META")" ] || fail "$id: a line other than the slot lines changed"
  [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "$id: expected one archive"
  [ "$(rr_sha "$(rr_archives)")" = "$(rr_sha "$prior")" ] || fail "$id: the archive is not the prior record"
  a=$(rr_audits)
  [ "$(rr_results)" = published ] || fail "$id: audit_result is '$(rr_results)'"
  rr_agrees "$a" || fail "$id: the audit record disagrees with the record"
  assert_contains "$out" 'added_scope=lib rule=c' "$id"
  assert_contains "$out" 'added_scope=tools/x.sh rule=b' "$id"
  assert_contains "$out" 'rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0' "$id"
  assert_contains "$out" 'added_uncommitted_newly_covered=0' "$id"
  assert_not_contains "$out" 'side_branch_' "$id"
  [ ! -s "$ADOPT_SENTINEL" ] || fail "$id: the provisioner ran"
  [ -z "$(rr_sendkeys)" ] || fail "$id: lifecycle input was sent"
  [ -z "$(rr_leftovers)" ] || fail "$id: temporaries left: $(rr_leftovers)"
}

test_L1_publishes_the_renewal() {
  local out rc minv
  rr_make_f L1
  cp "$RR_META" "$RR_DIR/prior.meta"
  minv=$(rr_manifest_inventory)
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L1"$'\n'"$out"
  rr_assert_l1 L1 "$out" "$RR_DIR/prior.meta"
  [ "$minv" = "$(rr_manifest_inventory)" ] || fail "L1: the manifest directory changed"
  assert_contains "$out" "rerecord-slot $RR_ID: base $RR_M0 -> $RR_M1; scope 3 entries (2 added, 0 released, 0 side-branch)" "L1 summary"
  rr_ok L1 "exit 0; slot_lines are M1 and the manifest scope; one archive equal to the prior record; audit published; labels as frozen"
}

test_L2_a_rolled_back_journal_is_judged_by_the_stopped_proof() {
  local out rc jsum
  rr_make_f L2
  rr_journal phase=failed:launching rollback=prior-record-kept
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L2"$'\n'"$out"
  rr_assert_l1 L2 "$out" "$RR_DIR/prior.meta"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "L2: the journal changed"
  rr_ok L2 "exit 0 as L1; journal bytes unchanged"
}

test_L3_a_second_run_is_a_no_op() {
  local out rc before
  rr_make_f L3
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L3 first"$'\n'"$out"
  before=$(rec_inventory)
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L3 second"$'\n'"$out"
  assert_contains "$out" "rerecord-slot $RR_ID: already recorded" "L3"
  [ "$before" = "$(rec_inventory)" ] || fail "L3: the no-op wrote something"
  [ "$(rr_count "$(rr_archives)")" = 1 ] && [ "$(rr_count "$(rr_audits)")" = 1 ] || fail "L3: expected one archive and one audit record"
  rr_ok L3 "second exit 0 already recorded; rec_inventory unchanged; one archive and one audit record"
}

test_L4_check_reports_without_writing() {
  local out rc before jsum minv
  rr_make_f L4
  rr_alive
  before=$(rec_inventory); minv=$(rr_manifest_inventory)
  out=$(rr_run --check); rc=$?
  expect_code 0 "$rc" "L4"$'\n'"$out"
  assert_contains "$out" "manifest_sha256=$(rr_msha)" "L4"
  assert_contains "$out" "base=$RR_M0 -> $RR_M1" "L4"
  assert_contains "$out" 'added_scope=lib rule=c' "L4"
  assert_contains "$out" 'added_scope=tools/x.sh rule=b' "L4"
  assert_contains "$out" 'launch_proof=ok' "L4"
  assert_contains "$out" 'journal_proof=absent' "L4"
  assert_contains "$out" 'stopped_proof=agent_not_proven_stopped' "L4"
  assert_contains "$out" 'write_would=refuse:agent_not_proven_stopped' "L4"
  assert_contains "$out" "rerecord-slot --manifest-sha $(rr_msha) --note" "L4 command"
  [ "$before" = "$(rec_inventory)" ] || fail "L4: --check wrote something"
  [ "$minv" = "$(rr_manifest_inventory)" ] || fail "L4: the manifest changed"
  [ ! -e "$RR_DIR/home/state/$RR_ID.control-relaunch" ] || fail "L4: a journal appeared"
  [ -z "$(rr_sendkeys)" ] || fail "L4: lifecycle input was sent"
  rr_ok L4 "--check exit 0 with the frozen lines; rec_inventory, journal and manifest unchanged; send-keys empty"
}

test_L4b_check_with_a_live_spawn_lock_holder() {
  local out rc before
  rr_make_f L4b
  rr_start_spawn_lock_holder
  before=$(rec_inventory)
  out=$(rr_run --check); rc=$?
  expect_code 0 "$rc" "L4b"$'\n'"$out"
  assert_contains "$out" 'launch_proof=launch_in_progress' "L4b"
  assert_contains "$out" 'write_would=refuse:launch_in_progress' "L4b"
  [ "$before" = "$(rec_inventory)" ] || fail "L4b: --check wrote something"
  [ "$(cat "$RR_DIR/home/state/.spawn-$RR_ID.lock/pid")" = "$RR_HOLDER_PID" ] && kill -0 "$RR_HOLDER_PID" \
    || fail "L4b: the live holder lost its lock"
  rr_stop_spawn_lock_holder
  rr_ok L4b "--check with a live spawn-lock holder exits 0 advisory: launch_proof=launch_in_progress, write_would=refuse:launch_in_progress; holder keeps the lock"
}

rr_setup_L5() { rr_make_f "$1"; rr_renew --owned-path src/owned.txt --owned-path lib --owned-path tools/x.sh; }

test_L5_a_narrowing_releases_the_old_entry() {
  local out rc
  rr_setup_L5 L5
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L5"$'\n'"$out"
  assert_contains "$out" 'released_scope=src' "L5"
  grep -qx 'released_scope=src' "$(rr_audits)" || fail "L5: released_scope=src is not in the audit record"
  rr_assert_published L5 "$RR_M1" src/owned.txt lib tools/x.sh
  rr_ok L5 "exit 0; released_scope=src printed and in the audit record"
}

rr_setup_L6() {
  local peer
  rr_make_f "$1" --no-renew
  git -C "$RR_DIR/wt" branch -q peer "$RR_M1"
  peer="$RR_DIR/peer"
  git -C "$RR_DIR/proj" worktree add -q "$peer" peer
  printf 'y-peer\n' > "$peer/tools/y.sh"
  printf 'peer\n' > "$peer/lib/peer.py"
  rr_commit "$peer" 'peer work'
  git -C "$RR_DIR/wt" -c user.name=Tests -c user.email=tests@example.invalid merge -q --no-ff --no-edit peer
  RR_H=$(git -C "$RR_DIR/wt" rev-parse HEAD)
  rr_renew --owned-path src --owned-path lib --owned-path tools/x.sh --owned-path tools/y.sh
}

test_L6_side_branch_paths_are_labelled() {
  local out rc
  rr_setup_L6 L6
  out=$(rr_run --check); rc=$?
  expect_code 0 "$rc" "L6 check"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep '^side_branch_' | sort)" = "$(printf '%s\n' 'side_branch_mixed=lib paths=1/2' 'side_branch_only=tools/y.sh paths=1/1')" ] \
    || fail "L6: --check side-branch lines differ"$'\n'"$out"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L6 write"$'\n'"$out"
  [ "$(grep '^side_branch_' "$(rr_audits)" | sort)" = "$(printf '%s\n' 'side_branch_mixed=lib paths=1/2' 'side_branch_only=tools/y.sh paths=1/1')" ] \
    || fail "L6: the audit record's side-branch lines differ"
  ! grep -E '^side_branch_.*=(tools/x.sh|src) ' "$(rr_audits)" || fail "L6: a side-branch line names tools/x.sh or src"
  rr_ok L6 "side_branch_only=tools/y.sh paths=1/1 and side_branch_mixed=lib paths=1/2 in --check and in the audit record; none for tools/x.sh or src"
}

rr_setup_L7() {
  rr_make_f "$1" --no-renew
  rr_branch_commit 'nested new file' tools/sub/new.sh=new
  rr_renew --owned-path src --owned-path lib --owned-path tools/x.sh --owned-path "${2:-tools/sub}"
}

test_L7_a_nested_new_file_admits_its_deepest_tracked_directory() {
  local out rc
  rr_setup_L7 L7
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L7"$'\n'"$out"
  assert_contains "$out" 'added_scope=tools/sub rule=c' "L7"
  rr_ok L7 "exit 0; added_scope=tools/sub rule=c"
}

rr_setup_L8() { rr_make_f "$1"; rr_record_slots "$RR_M1" src lib tools/x.sh; }

test_L8_a_hand_synced_record_is_a_no_op() {
  local out rc before
  rr_setup_L8 L8
  before=$(rec_inventory)
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L8"$'\n'"$out"
  assert_contains "$out" "rerecord-slot $RR_ID: already recorded" "L8"
  [ "$before" = "$(rec_inventory)" ] || fail "L8: the no-op wrote something"
  rr_ok L8 "exit 0 already recorded; rec_inventory unchanged; no archive or audit record"
}

test_L9_the_live_failed_shape_on_a_synced_record() {
  local out rc before jsum mode
  rr_setup_L8 L9
  rr_journal phase=failed:launching rollback=none-new-record-kept
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  before=$(rec_inventory)
  for mode in check write; do
    if [ "$mode" = check ]; then out=$(rr_run --check); rc=$?; else out=$(rr_write); rc=$?; fi
    expect_code 0 "$rc" "L9 $mode"$'\n'"$out"
    assert_contains "$out" 'already recorded' "L9 $mode"
    assert_contains "$out" 'journal_proof=failed-open' "L9 $mode"
    assert_contains "$out" 'stopped_proof=ok' "L9 $mode"
  done
  [ "$before" = "$(rec_inventory)" ] || fail "L9: something was written"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "L9: the journal changed"
  rr_ok L9 "--check and write exit 0 already recorded with journal_proof=failed-open and stopped_proof=ok; nothing written"
}

test_L9b_the_live_complete_shape_with_the_agent_alive() {
  local out rc before jsum mode
  rr_setup_L8 L9b
  rr_alive
  rr_journal phase=complete
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  before=$(rec_inventory)
  for mode in check write; do
    if [ "$mode" = check ]; then out=$(rr_run --check); rc=$?; else out=$(rr_write); rc=$?; fi
    expect_code 0 "$rc" "L9b $mode"$'\n'"$out"
    assert_contains "$out" 'already recorded' "L9b $mode"
    assert_contains "$out" 'journal_proof=complete' "L9b $mode"
    assert_contains "$out" 'stopped_proof=agent_not_proven_stopped' "L9b $mode"
    [ "$mode" != check ] || assert_contains "$out" 'write_would=already recorded' "L9b: --check must predict the write's no-op"
  done
  [ "$before" = "$(rec_inventory)" ] || fail "L9b: something was written"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "L9b: the journal changed"
  [ -z "$(rr_sendkeys)" ] || fail "L9b: lifecycle input was sent"
  rr_ok L9b "--check and write exit 0 already recorded with journal_proof=complete and stopped_proof=agent_not_proven_stopped; --check predicts write_would=already recorded; nothing written; send-keys empty"
}

rr_setup_L10() {
  rr_make_f "$1"
  rr_journal phase=failed:launching rollback=none-new-record-kept
  { grep -vE '^(slot_base_sha|slot_owned_path)=' "$RR_META"; printf 'slot_base_sha=%s\nslot_owned_path=src\n' "$RR_M0"; } \
    > "$RR_DIR/home/state/$RR_ID.control-relaunch.meta-prior"
}

test_L10_a_failed_launch_journal_with_the_agent_stopped() {
  local out rc jsum psum
  rr_setup_L10 L10
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  psum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch.meta-prior")
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L10"$'\n'"$out"
  rr_assert_l1 L10 "$out" "$RR_DIR/prior.meta"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "L10: the journal changed"
  [ "$psum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch.meta-prior")" ] || fail "L10: .meta-prior changed"
  rr_ok L10 "exit 0 as L1; journal and .meta-prior unchanged; published lines are the renewal's"
}

test_L11_an_uncommitted_file_under_a_new_directory_is_counted() {
  local out rc
  rr_make_f L11
  printf 'scratch\n' > "$RR_DIR/wt/lib/scratch.py"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L11"$'\n'"$out"
  assert_contains "$out" 'rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=1' "L11"
  assert_contains "$out" 'added_uncommitted_newly_covered=1' "L11"
  grep -qx 'rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=1' "$(rr_audits)" || fail "L11: audit record"
  grep -qx 'added_uncommitted_newly_covered=1' "$(rr_audits)" || fail "L11: audit record total"
  [ "$(cat "$RR_DIR/wt/lib/scratch.py")" = scratch ] || fail "L11: the copy changed"
  rr_ok L11 "uncommitted_newly_covered=1 and added_uncommitted_newly_covered=1 in the output and audit record; copy unchanged"
}

test_L12_a_stale_spawn_lock_is_reclaimed() {
  local out rc jsum psum
  rr_setup_L10 L12
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  psum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch.meta-prior")
  rr_start_spawn_lock_holder
  rr_stop_spawn_lock_holder
  [ -d "$RR_DIR/home/state/.spawn-$RR_ID.lock" ] || fail "L12: the stale lock was not left behind"
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "L12"$'\n'"$out"
  rr_assert_l1 L12 "$out" "$RR_DIR/prior.meta"
  [ ! -e "$RR_DIR/home/state/.spawn-$RR_ID.lock" ] || fail "L12: the spawn lock remains after the run"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "L12: the journal changed"
  [ "$psum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch.meta-prior")" ] || fail "L12: .meta-prior changed"
  rr_ok L12 "exit 0 as L10 over a dead holder's spawn lock; no spawn lock remains"
}

# rr_setup_L13 <name>: a write SIGKILLed after its publish leaves the staged record under a pending audit record (R6a),
# then the copy's HEAD moves inside the scope, so the write's reconciliation must roll that record back. Sets RR_L13_AUDIT.
rr_setup_L13() {
  local p
  rr_make_f "$1"
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  RR_L13_AUDIT=$(rr_audit_for "$p") || fail "$1: no audit record after the crash"
  [ "$(rr_field "$RR_L13_AUDIT" result)" = pending ] && [ "$(rr_sha "$RR_META")" = "$(rr_field "$RR_L13_AUDIT" staged_sha256)" ] \
    || fail "$1: the crash did not leave the staged bytes under a pending audit record"
  rr_branch_commit 'own change after the crash' src/owned.txt=owned-after-the-crash
}

# rr_expect_write_rolls_back_the_crash <id>: the write the --check reports on: it rolls the crashed write back, then
# publishes its own.
rr_expect_write_rolls_back_the_crash() {
  local id=$1 out rc
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "$id write"$'\n'"$out"
  assert_not_contains "$out" 'already recorded' "$id write"
  [ "$(rr_field "$RR_L13_AUDIT" result)" = rolled-back ] || fail "$id: the crashed write's audit is '$(rr_field "$RR_L13_AUDIT" result)'"
  [ "$(rr_results)" = 'published rolled-back' ] || fail "$id: audit results are '$(rr_results)'"
}

test_L13_check_names_a_pending_reconcile() {
  local out rc before
  rr_setup_L13 L13
  before=$(rec_inventory)
  out=$(rr_run --check); rc=$?
  expect_code 0 "$rc" "L13"$'\n'"$out"
  assert_contains "$out" "pending_audit=$RR_L13_AUDIT result=pending state=untouched-staged" "L13"
  assert_contains "$out" "write_would=reconcile-pending:${RR_L13_AUDIT##*/}" "L13"
  assert_contains "$out" "manifest_sha256=$(rr_msha)" "L13"
  assert_contains "$out" "command: bin/fm-control.sh $RR_ID rerecord-slot --manifest-sha $(rr_msha) --note" "L13"
  assert_not_contains "$out" 'already recorded' "L13"
  [ "$before" = "$(rec_inventory)" ] || fail "L13: --check wrote something"
  rr_expect_write_rolls_back_the_crash L13
  rr_ok L13 "pending untouched-staged audit, HEAD moved inside scope: --check prints write_would=reconcile-pending naming the audit record, the digest and the command, and writes nothing; the write then rolls the crash back and publishes"
}

# --- end to end -----------------------------------------------------------------------------------

test_E1_relaunch_after_rerecord_adopts() {
  local out rc sum
  rr_make_f E1
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "E1 rerecord"$'\n'"$out"
  sum=$(rr_sha "$RR_MANIFEST")
  # The frozen F stops the agent as server-dead; a proven-gone tmux endpoint is replaced only on Herdr, so the relaunch
  # step is staged on a dead pane in the same endpoint. The server-dead attempt is recorded as an observation.
  out=$(rr_relaunch); rc=$?
  rr_record E1-server-dead observation "relaunch on the frozen server-dead endpoint after rerecord: exit $rc; $(printf '%s\n' "$out" | grep -E '^error:' | head -n 2 | tr '\n' ' ')"
  assert_not_contains "$out" 'slot adoption refused' "E1: adoption refused on the server-dead attempt"
  rr_dead_pane
  out=$(rr_relaunch); rc=$?
  expect_code 0 "$rc" "E1 relaunch"$'\n'"$out"
  assert_not_contains "$out" 'slot adoption refused' "E1"
  [ "$(journal_field "$RR_DIR" "$RR_ID" phase)" = complete ] || fail "E1: the journal is not complete"
  [ "$(cat "$RR_DIR/fake/command")" = claude ] || fail "E1: no new agent"
  [ "$sum" = "$(rr_sha "$RR_MANIFEST")" ] || fail "E1: the manifest changed"
  [ ! -s "$ADOPT_SENTINEL" ] || fail "E1: the provisioner ran"
  rr_ok E1 "relaunch after rerecord exits 0, journal complete, new agent alive, no adoption refusal, manifest unchanged, sentinel empty (relaunch staged on a dead pane rather than server-dead; see report)"
}

test_E2_relaunch_without_rerecord_refuses_base_mismatch() {
  local out rc before
  rr_make_f E2
  rr_dead_pane
  before=$(rr_sha "$RR_META")
  out=$(rr_relaunch); rc=$?
  [ "$rc" != 0 ] || fail "E2: the relaunch was admitted"$'\n'"$out"
  assert_contains "$out" 'base_mismatch' "E2"
  [ "$before" = "$(rr_sha "$RR_META")" ] || fail "E2: the record changed"
  [ ! -s "$ADOPT_SENTINEL" ] || fail "E2: the provisioner ran"
  rr_ok E2 "relaunch on F refuses base_mismatch; record unchanged; sentinel empty"
}


# --- harmful cases (H) and their setups -------------------------------------------------------------
# Each rr_setup_<ID> builds F and changes its decisive fact; the sensitivity controls reuse the same setups.

rr_setup_H1() { rr_make_f "$1"; rr_renew --owner-id other-task; }
rr_setup_H2() {
  rr_make_f "$1" --no-renew
  git -C "$RR_DIR/proj" worktree add -q "$RR_DIR/wt2" -b other-copy "$RR_M1"
  rr_renew --worktree-path "$RR_DIR/wt2"
}
rr_setup_H3() {
  local side
  rr_make_f "$1"
  side=$(git -C "$RR_DIR/proj" -c user.name=Tests -c user.email=tests@example.invalid commit-tree -p "$RR_M0" -m side "$RR_M0^{tree}")
  git -C "$RR_DIR/proj" update-ref refs/heads/side "$side"
  rr_record_slots "$side" src
}
rr_setup_H4() { rr_make_f "$1"; rr_renew --base-sha "$RR_H" --owned-path src; }
rr_setup_H5() {
  rr_make_f "$1"
  RR_M2=$(rr_main_commit 'main M2' lib/a.py=a-at-m2)
  rr_branch_merge_main
}
rr_setup_H6() { rr_make_f "$1"; rr_renew --owned-path src --owned-path lib --owned-path tools/x.sh --owned-path docs.txt; }
rr_setup_H7() { rr_make_f "$1"; rr_renew --owned-path src --owned-path lib --owned-path tools; }
rr_setup_H8() { rr_make_f "$1"; rr_renew --owned-path src --owned-path lib; }
rr_setup_H9() { rr_setup_L5 "$1"; printf 'uncommitted edit\n' > "$RR_DIR/wt/src/other.txt"; }
rr_setup_H9b() {
  rr_setup_L5 "$1"
  git -C "$RR_DIR/wt" update-index --assume-unchanged src/other.txt
  printf 'hidden edit\n' > "$RR_DIR/wt/src/other.txt"
}
# SF2: a recorded entry with a trailing slash is normalized before the coverage and strand tests.
rr_setup_H9c() {
  rr_setup_L5 "$1"
  rr_record_slots "$RR_M0" src/
  printf 'uncommitted edit\n' > "$RR_DIR/wt/src/other.txt"
}
rr_setup_H10() {
  local durable
  rr_make_f "$1"
  durable=$(bash -c '. "$1/bin/fm-slot-provision-lib.sh" && fm_slot_record_paths "$2" "$3" | head -n 1' _ "$ROOT" "$RR_DIR/proj" "$RR_DIR/wt")
  mkdir -p "$(dirname "$durable")"
  cp "$RR_MANIFEST" "$durable"
}
rr_setup_H11() { rr_make_f "$1"; rr_alive; }
rr_setup_H12() { rr_setup_L10 "$1"; rr_journal phase=launching rollback=none-new-record-kept; }
rr_setup_H12b() { rr_setup_L10 "$1"; rr_journal '' rollback=none-new-record-kept; }
rr_setup_H13a() { rr_make_f "$1"; RR_TASK_ID=some-worker; }
rr_setup_H13b() { rr_make_f "$1"; printf '%s\n' 999999 > "$RR_DIR/home/state/.lock"; }
rr_setup_H13c() { rr_make_f "$1"; }
rr_setup_H14() {
  rr_make_f "$1"
  RR_STALE_SHA=$(rr_msha)
  rr_manifest_set created_at_iso '"2099-01-01T00:00:00+00:00"'
}
rr_setup_H15() { rr_make_f "$1"; printf 'slot_source_ref=refs/heads/main\n' >> "$RR_META"; }
rr_setup_H17() { rr_setup_L7 "$1" tools; }
rr_setup_H18() {
  rr_setup_L8 "$1"
  RR_M2=$(rr_main_commit 'main M2' lib/a.py=a-at-m2)
  rr_branch_merge_main
}
rr_setup_H19() { rr_setup_L10 "$1"; rr_alive; }
rr_setup_H19b() { rr_make_f "$1"; rr_journal phase=failed:launching rollback=none-new-agent-confirmed; rr_alive; }
rr_setup_H20() { rr_setup_L10 "$1"; rr_start_spawn_lock_holder; }
rr_setup_H21() {
  local j
  rr_make_f "$1"
  rr_journal phase=complete
  j="$RR_DIR/home/state/$RR_ID.control-relaunch"
  mv "$j" "$RR_DIR/closed-journal"
  ln -s "$RR_DIR/closed-journal" "$j"
}
rr_setup_H22() { rr_make_f "$1"; : > "$RR_DIR/home/state/$RR_ID.backlog-close"; }

rr_h() { # <id> <reason> [run args...]
  local id=$1
  shift
  "rr_setup_$id" "$id"
  rr_expect_refusal "$id" "$@"
}

test_H1_owner_mismatch() { rr_h H1 owner_mismatch; }
test_H2_worktree_path_mismatch() { rr_h H2 worktree_path_mismatch; }
test_H3_base_not_forward() { rr_h H3 base_not_forward; }
test_H4_base_not_on_default() { rr_h H4 base_not_on_default; }
test_H5_base_not_merge_base() { rr_h H5 base_not_merge_base; }
test_H6_scope_entry_not_own_work_docs() { rr_h H6 'scope_entry_not_own_work: docs.txt'; }
test_H7_scope_entry_not_own_work_tools() { rr_h H7 'scope_entry_not_own_work: tools'; }
test_H8_scope_uncovered_change() { rr_h H8 'scope_uncovered_change: tools/x.sh'; }
test_H9_scope_release_strands_work() {
  local sum
  rr_setup_H9 H9
  sum=$(rr_sha "$RR_DIR/wt/src/other.txt")
  rr_expect_refusal H9 'scope_release_strands_work: src/other.txt'
  [ "$sum" = "$(rr_sha "$RR_DIR/wt/src/other.txt")" ] || fail "H9: the copy changed"
}
test_H9b_scope_release_strands_hidden_work() {
  local sum flags
  rr_setup_H9b H9b
  sum=$(rr_sha "$RR_DIR/wt/src/other.txt")
  flags=$(git -C "$RR_DIR/wt" ls-files -v src/other.txt)
  rr_expect_refusal H9b 'scope_release_strands_work: src/other.txt'
  [ "$sum" = "$(rr_sha "$RR_DIR/wt/src/other.txt")" ] || fail "H9b: the copy changed"
  [ "$flags" = "$(git -C "$RR_DIR/wt" ls-files -v src/other.txt)" ] || fail "H9b: the index flags changed"
}
test_H9c_a_trailing_slash_prior_entry_is_normalized() {
  rr_setup_H9c H9c
  rr_expect_refusal H9c 'scope_release_strands_work: src/other.txt'
}
test_H10_manifest_shadowed() { rr_h H10 manifest_shadowed; }
test_H11_agent_not_proven_stopped() {
  rr_h H11 agent_not_proven_stopped
  [ "$(cat "$RR_DIR/fake/command")" = claude ] || fail "H11: the agent is no longer alive"
}
test_H12_relaunch_unfinished_in_flight() {
  local jsum
  rr_setup_H12 H12
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  rr_expect_refusal H12 relaunch_unfinished
  assert_contains "$RR_OUT" fm-relaunch-inflight-journal-recovery "H12: the refusal must name the follow-up item"
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "H12: the journal changed"
}
test_H12b_relaunch_unfinished_no_phase() {
  local jsum
  rr_setup_H12b H12b
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  rr_expect_refusal H12b relaunch_unfinished
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "H12b: the journal changed"
}
test_H13a_actor_not_main_worker() { rr_h H13a actor_not_main; RR_TASK_ID=; }
test_H13b_session_lock_not_owned() { rr_h H13b session_lock_not_owned; }
test_H13c_note_required() { rr_setup_H13c H13c; rr_expect_refusal H13c note_required --manifest-sha "$(rr_msha)"; }
test_H14_manifest_sha_mismatch() {
  rr_setup_H14 H14
  rr_expect_refusal H14 manifest_sha_mismatch --manifest-sha "$RR_STALE_SHA" --note "$RR_NOTE"
}
test_H15_local_only_source_unsupported() { rr_h H15 local_only_source_unsupported; }
test_H17_scope_entry_not_own_work_nested() { rr_h H17 'scope_entry_not_own_work: tools'; }
test_H18_the_no_op_does_not_mask_a_stale_base() { rr_h H18 base_not_merge_base; }
test_H19_agent_alive_after_a_failed_launch() {
  local jsum
  rr_setup_H19 H19
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  rr_expect_refusal H19 agent_not_proven_stopped
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "H19: the journal changed"
  [ "$(cat "$RR_DIR/fake/command")" = claude ] || fail "H19: the agent is no longer alive"
}
test_H19b_agent_alive_after_a_confirmed_launch() {
  local jsum
  rr_setup_H19b H19b
  jsum=$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")
  rr_expect_refusal H19b agent_not_proven_stopped
  [ "$jsum" = "$(rr_sha "$RR_DIR/home/state/$RR_ID.control-relaunch")" ] || fail "H19b: the journal changed"
  [ "$(cat "$RR_DIR/fake/command")" = claude ] || fail "H19b: the agent is no longer alive"
}
test_H20_launch_in_progress() {
  rr_setup_H20 H20
  rr_expect_refusal H20 launch_in_progress
  assert_contains "$RR_OUT" "pid $RR_HOLDER_PID" "H20: the refusal must name the holder's pid"
  assert_contains "$RR_OUT" "holder of the task's spawn lock" "H20: the refusal names the lock's holder"
  [ "$(cat "$RR_DIR/home/state/.spawn-$RR_ID.lock/pid")" = "$RR_HOLDER_PID" ] && kill -0 "$RR_HOLDER_PID" \
    || fail "H20: the live helper no longer holds the spawn lock"
  rr_stop_spawn_lock_holder
}
test_H21_relaunch_unfinished_symlink() {
  local tsum
  rr_setup_H21 H21
  tsum=$(rr_sha "$RR_DIR/closed-journal")
  rr_expect_refusal H21 relaunch_unfinished
  [ -L "$RR_DIR/home/state/$RR_ID.control-relaunch" ] && [ "$tsum" = "$(rr_sha "$RR_DIR/closed-journal")" ] \
    || fail "H21: the symlink or its target changed"
}
test_H22_backlog_close_pending() { rr_h H22 backlog_close_pending; }

# --- named refusals (N) -----------------------------------------------------------------------------

rr_setup_N1() { rr_make_f "$1"; printf 'kind=ship\n' >> "$RR_META"; }
rr_setup_N2() { rr_make_f "$1"; grep -v '^slot_base_sha=' "$RR_META" > "$RR_META.tmp" && cat "$RR_META.tmp" > "$RR_META" && rm -f "$RR_META.tmp"; }
rr_setup_N3() { rr_make_f "$1"; printf 'recovery=slot-provision-refused\n' >> "$RR_META"; }
rr_setup_N4() {
  rr_make_f "$1"
  ln -s "$RR_MANIFEST" "$RR_DIR/manifests/link.json"
  sed "s#^slot_manifest=.*#slot_manifest=$RR_DIR/manifests/link.json#" "$RR_META" > "$RR_META.tmp" && cat "$RR_META.tmp" > "$RR_META" && rm -f "$RR_META.tmp"
}
rr_setup_N5() { rr_make_f "$1"; rr_manifest_set lifecycle_state '"worktree_released"'; }
rr_setup_N6() { rr_make_f "$1"; rr_manifest_set branch '"fm/other"'; }
rr_setup_N7() {
  rr_make_f "$1"
  fm_git_init_commit "$RR_DIR/unrelated"
  rr_manifest_set repo_root "\"$RR_DIR/unrelated\""
}
rr_setup_N8() {
  rr_make_f "$1"
  sed "s#^worktree=.*#worktree=$RR_DIR/proj#" "$RR_META" > "$RR_META.tmp" && cat "$RR_META.tmp" > "$RR_META" && rm -f "$RR_META.tmp"
  rr_manifest_set worktree_path "\"$(cd "$RR_DIR/proj" && pwd -P)\""
}
rr_setup_N9() { rr_make_f "$1"; git -C "$RR_DIR/wt" rev-parse HEAD > "$(git -C "$RR_DIR/wt" rev-parse --path-format=absolute --git-path MERGE_HEAD)"; }
rr_setup_N10() {
  rr_make_f "$1"
  git -C "$RR_DIR/wt" symbolic-ref --delete refs/remotes/origin/HEAD
  git -C "$RR_DIR/wt" update-ref -d refs/remotes/origin/main
  git -C "$RR_DIR/proj" show-ref --verify --quiet refs/heads/main || fail "N10: the project has no local main"
}
rr_setup_N11() { rr_make_f "$1"; rr_manifest_set base_ref '"origin/develop"'; }
rr_setup_N12() { rr_make_f "$1"; rr_manifest_set base_sha "\"${RR_M1:0:12}\""; }
rr_setup_N13() {
  rr_make_f "$1"
  RR_M2=$(rr_main_commit 'main M2' lib/a.py=a-at-m2)
  rr_renew --base-sha "$RR_M2"
}
rr_setup_N14() { rr_make_f "$1"; rr_manifest_set owned_paths '["src", "lib", "tools/x.sh", "../outside"]'; }
rr_setup_N15() { rr_make_f "$1"; rr_manifest_set owned_paths '["src", "lib/", "tools/x.sh"]'; }
rr_setup_N16() { rr_make_f "$1"; rr_manifest_set owned_paths '["src", "lib", "tools/x.sh", "newdir"]'; }
rr_setup_N17() { rr_make_f "$1"; RR_ACTOR=branch; }
rr_setup_N18() { rr_make_f "$1"; printf '{not json' > "$RR_MANIFEST"; }

test_N1_not_ship_or_scout() { rr_h N1 not_ship_or_scout; }
test_N2_not_recorded() { rr_h N2 not_recorded; }
test_N3_not_adoption_route() { rr_h N3 not_adoption_route; }
test_N4_manifest_missing() { rr_h N4 manifest_missing; }
test_N5_lifecycle_state_mismatch() { rr_h N5 lifecycle_state_mismatch; }
test_N6_branch_mismatch() { rr_h N6 branch_mismatch; }
test_N7_repository_mismatch() { rr_h N7 repository_mismatch; }
test_N8_not_isolated() { rr_h N8 not_isolated; }
test_N9_operation_in_progress() { rr_h N9 operation_in_progress; }
test_N10_default_branch_unreadable() { rr_h N10 default_branch_unreadable; }
test_N11_base_ref_mismatch() { rr_h N11 base_ref_mismatch; }
test_N12_base_invalid() { rr_h N12 base_invalid; }
test_N13_base_not_in_head() { rr_h N13 base_not_in_head; }
test_N14_scope_invalid() { rr_h N14 scope_invalid; }
test_N15_scope_not_canonical() { rr_h N15 scope_not_canonical; }
test_N16_scope_not_tracked() { rr_h N16 scope_not_tracked; }
test_N17_actor_not_main_branch() { rr_h N17 actor_not_main; RR_ACTOR=; }
test_N18_manifest_unreadable() { rr_h N18 manifest_unreadable; }

# Every option the verb does not take refuses before anything is read.
# Each refused option is named by its own parse refusal, so a dropped option check cannot pass by refusing later.
test_options_are_refused() {
  local out rc args want before
  rr_make_f options
  before=$(rec_inventory)
  while IFS='|' read -r args want; do
    # shellcheck disable=SC2086
    out=$(rr_run $args); rc=$?
    expect_code 1 "$rc" "options: '$args'"$'\n'"$out"
    assert_contains "$out" "error: $want" "options: '$args' was not refused by its own parse check"
    assert_not_contains "$out" 'slot rerecord refused' "options: '$args' reached the proofs"
  done <<'EOF'
--check --note x|rerecord-slot --check writes nothing, so it takes neither --note, --note-file, nor --manifest-sha
--check --manifest-sha abc|rerecord-slot --check writes nothing, so it takes neither --note, --note-file, nor --manifest-sha
--harness codex --note x|--harness, --model, --effort, --claude-debug, --captain-model-pin, --recover-launch, --reconcile-only, and --worktree do not apply to 'rerecord-slot'
--worktree /tmp --note x|--harness, --model, --effort, --claude-debug, --captain-model-pin, --recover-launch, --reconcile-only, and --worktree do not apply to 'rerecord-slot'
--owned-path src --note x|--owned-path applies to 'relaunch' only
--manifest-sha|--manifest-sha requires a value
EOF
  for args in '--check' '--manifest-sha abc'; do
    # shellcheck disable=SC2086
    out=$(run_control "$RR_DIR" "$RR_ID" exit $args); rc=$?
    expect_code 1 "$rc" "options: exit $args"$'\n'"$out"
    assert_contains "$out" "error: --check and --manifest-sha apply to 'rerecord-slot' only" "options: exit $args"
  done
  [ "$before" = "$(rec_inventory)" ] || fail "options: a refused option wrote something"
  rr_ok OPTIONS "each refused option prints its own parse refusal (exit 1, never a proof refusal), and --check or --manifest-sha on another verb names rerecord-slot; nothing written"
}

# --- faults, crashes and signals (R) ----------------------------------------------------------------

# rr_hook <name> <script body>: a fixture script a shim override runs, so the override text stays one line.
rr_hook() {
  local path="$RR_DIR/hook-$1.sh"
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'RR_DIR=%q\nRR_ID=%q\nRR_META=%q\nRR_MANIFEST=%q\n' "$RR_DIR" "$RR_ID" "$RR_META" "$RR_MANIFEST"
    printf '%s\n' "$2"
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# The merge of a new main commit M2 into the branch, run from inside the verb by a shim (R1a, SF4).
RR_MERGE_M2_BODY='
printf "docs-at-m2\n" > "$RR_DIR/proj/docs.txt"
git -C "$RR_DIR/proj" add -A
git -C "$RR_DIR/proj" -c user.name=Tests -c user.email=tests@example.invalid commit -qm "main M2"
git -C "$RR_DIR/proj" push -q origin HEAD:main
git -C "$RR_DIR/wt" update-ref refs/remotes/origin/main "$(git -C "$RR_DIR/proj" rev-parse HEAD)"
git -C "$RR_DIR/wt" -c user.name=Tests -c user.email=tests@example.invalid merge -q --no-edit refs/remotes/origin/main
'

rr_after_archive() { # <hook-path>: a shim that runs <hook-path> right after the real archive
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_archive
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_archive() { real_fm_slot_rerecord_archive \"\$@\" || return; bash '$1' >/dev/null 2>&1; }"
}

rr_setup_R1a() { rr_make_f "$1"; rr_after_archive "$(rr_hook r1a "$RR_MERGE_M2_BODY")"; }
rr_setup_R1b() {
  rr_make_f "$1"
  rr_after_archive "$(rr_hook r1b 'python3 - "$RR_MANIFEST" <<'"'"'PY'"'"'
import json, sys
r = json.load(open(sys.argv[1])); r["owned_paths"].append("docs.txt"); open(sys.argv[1], "w").write(json.dumps(r))
PY')"
}
rr_setup_R4() { rr_make_f "$1"; rr_after_archive "$(rr_hook r4 'printf "x_note=1\n" >> "$RR_META"')"; }

rr_expect_refused_after_archive() { # <id>: input_changed_during_rerecord, the record as the prior plus <extra>
  local id=$1 out rc
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] || fail "$id: expected a refusal"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: input_changed_during_rerecord' "$id"
  [ "$(rr_results)" = refused ] || fail "$id: audit_result is '$(rr_results)'"
  [ -z "$(rr_leftovers)" ] || fail "$id: temporaries left"
  RR_OUT=$out
}

test_R1a_head_moved_after_archive() {
  local before
  rr_setup_R1a R1a
  before=$(rec_inventory | head -n 1)
  rr_expect_refused_after_archive R1a
  [ "$before" = "$(rec_inventory | head -n 1)" ] || fail "R1a: the record changed"
  rr_ok R1a "input_changed_during_rerecord; record inventory unchanged; audit refused"
}
test_R1b_manifest_changed_after_archive() {
  local before
  rr_setup_R1b R1b
  before=$(rec_inventory | head -n 1)
  rr_expect_refused_after_archive R1b
  [ "$before" = "$(rec_inventory | head -n 1)" ] || fail "R1b: the record changed"
  rr_ok R1b "input_changed_during_rerecord; record inventory unchanged; audit refused"
}
test_R4_record_changed_after_archive() {
  rr_setup_R4 R4
  rr_expect_refused_after_archive R4
  [ "$(cat "$RR_DIR/prior.meta"; printf 'x_note=1\n')" = "$(cat "$RR_META")" ] || fail "R4: the appended line did not survive as the only change"
  rr_ok R4 "input_changed_during_rerecord; the record is the prior bytes plus the appended line; audit refused"
}

rr_setup_R2() { rr_make_f "$1"; }
test_R2_commit_rename_fails() {
  local out rc
  rr_setup_R2 R2
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(FM_FAKE_PUBLISHED_AUDIT_MV_FAIL=1 rr_write); rc=$?
  [ "$rc" != 0 ] || fail "R2: expected nonzero"$'\n'"$out"
  [ "$(rr_sha "$RR_META")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "R2: the record was not restored"
  [ "$(rr_sha "$(rr_archives)")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "R2: the archive is not P"
  [ "$(rr_results)" = rolled-back ] || fail "R2: audit_result is '$(rr_results)'"
  rr_ok R2 "nonzero; record restored to P; archive kept with sha P; audit exactly rolled-back"
}

rr_custody_fails_second_call() {
  rr_wrap fm-slot-provision-lib.sh fm_slot_custody_check
  rr_shim fm-slot-provision-lib.sh "fm_slot_custody_check() { local n; n=\$(cat '$RR_DIR/custody-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$RR_DIR/custody-calls'; if [ \"\$n\" = 2 ]; then fm_slot_custody_fail custody_slot_claim 'injected second-call refusal'; return 1; fi; real_fm_slot_custody_check \"\$@\"; }"
}
rr_setup_R3() { rr_make_f "$1"; rr_custody_fails_second_call; }
test_R3_postcheck_adoption_fails() {
  local out rc
  rr_setup_R3 R3
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] || fail "R3: expected nonzero"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: adopt_postcheck_failed' "R3"
  assert_not_contains "$out" 'slot adoption refused' "R3: the adoption prefix must not be printed"
  [ "$(rr_sha "$RR_META")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "R3: the record was not restored"
  [ "$(rr_sha "$(rr_archives)")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "R3: the archive is not P"
  [ "$(rr_results)" = rolled-back ] || fail "R3: audit_result is '$(rr_results)'"
  rr_ok R3 "adopt_postcheck_failed; rolled back to P; archive kept; audit rolled-back"
}

rr_stage_rewrite() { # <sed-expression>: a shim rewriting the staged record right after the real staging
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_stage
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_stage() { real_fm_slot_rerecord_stage \"\$@\" || return; sed '$1' \"\$3\" > \"\$3.x\" && cat \"\$3.x\" > \"\$3\" && rm -f \"\$3.x\"; }"
}
rr_setup_R5() { rr_make_f "$1"; rr_stage_rewrite 's#^slot_owned_path=lib$#slot_owned_path=docs.txt#'; }
rr_setup_R5b() { rr_make_f "$1"; rr_stage_rewrite 's#^model=.*#model=injected#'; }
rr_expect_precheck_refusal() { # <id>
  local id=$1 before out rc
  before=$(rec_inventory)
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] || fail "$id: expected a refusal"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: adopt_precheck_failed' "$id"
  [ "$before" = "$(rec_inventory)" ] || fail "$id: something was written (an archive, an audit record or a staged file)"
  rr_ok "$id" "adopt_precheck_failed; rec_inventory unchanged; no archive, no staged file, no audit record"
}
test_R5_staged_slot_line_corrupted() { rr_setup_R5 R5; rr_expect_precheck_refusal R5; }
test_R5b_staged_other_line_corrupted() { rr_setup_R5b R5b; rr_expect_precheck_refusal R5b; }

# rr_crash_run <target> <before|after> <nth> [run args]: a write run SIGKILLed by the mv stub around its <nth> mv onto
# <target>.
rr_crash_run() {
  local target=$1 when=$2 nth=$3 out rc
  rm -f "$RR_DIR/fake/mv-target-count"
  out=$(FM_FAKE_MV_CRASH_TARGET=$target FM_FAKE_MV_CRASH_WHEN=$when FM_FAKE_MV_CRASH_NTH=$nth rr_write); rc=$?
  [ "$rc" = 137 ] || fail "crash run: expected the verb to be killed (137), got $rc"$'\n'"$out"
}

test_R6a_sigkill_after_publish_is_recovered() {
  local out rc p a
  rr_make_f R6a
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  a=$(rr_audit_for "$p") || fail "R6a: no audit record"
  [ "$(rr_field "$a" result)" = pending ] || fail "R6a: audit is '$(rr_field "$a" result)' after the kill"
  [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" staged_sha256)" ] || fail "R6a: the record does not hold the staged bytes"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6a second run"$'\n'"$out"
  assert_contains "$out" 'already recorded' "R6a"
  [ "$(rr_field "$a" result)" = published-recovered ] || fail "R6a: audit is '$(rr_field "$a" result)'"
  [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "R6a: expected one archive"
  rr_agrees "$a" || fail "R6a: audit disagrees"
  rr_ok R6a "after the kill: staged bytes and pending; second run exit 0 already recorded; published-recovered; one archive; audit_agrees"
}

test_R6b_recovery_rolls_back_against_a_changed_manifest() {
  local out rc p a
  rr_make_f R6b
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  rr_manifest_set created_at_iso '"2099-01-01T00:00:00+00:00"'
  a=$(rr_audit_for "$p")
  out=$(rr_run --manifest-sha "$(rr_field "$a" manifest_sha256)" --note "$RR_NOTE"); rc=$?
  [ "$rc" != 0 ] || fail "R6b: the second run was expected to refuse"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: manifest_sha_mismatch' "R6b"
  [ "$(rr_sha "$RR_META")" = "$p" ] || fail "R6b: the crashed write was not rolled back"
  [ "$(rr_field "$a" result)" = rolled-back ] || fail "R6b: audit is '$(rr_field "$a" result)'"
  rr_ok R6b "second run rolls the crashed write back (record P, first audit rolled-back), then refuses manifest_sha_mismatch"
}

test_R6c_another_writer_supersedes_the_crashed_write() {
  local out rc p a
  rr_make_f R6c
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  cp "$RR_META" "$RR_DIR/staged.meta"
  printf 'x_note=1\n' >> "$RR_META"
  a=$(rr_audit_for "$p")
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6c"$'\n'"$out"
  assert_contains "$out" 'already recorded' "R6c"
  [ "$(cat "$RR_DIR/staged.meta"; printf 'x_note=1\n')" = "$(cat "$RR_META")" ] || fail "R6c: the record is not the staged record plus the line"
  [ "$(rr_field "$a" result)" = superseded-new ] || fail "R6c: audit is '$(rr_field "$a" result)'"
  [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "R6c: the archive count changed"
  rr_ok R6c "second exit 0 already recorded; record is staged plus the appended line; first audit superseded-new; no rollback"
}

# N7: the two other superseded classes.
test_R6f_superseded_prior() {
  local out rc p a
  rr_make_f R6f
  cp "$RR_META" "$RR_DIR/prior.meta"
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  { cat "$RR_DIR/prior.meta"; printf 'x_note=1\n'; } > "$RR_DIR/other.meta" && cat "$RR_DIR/other.meta" > "$RR_META"
  a=$(rr_audit_for "$p")
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6f"$'\n'"$out"
  [ "$(rr_field "$a" result)" = superseded-prior ] || fail "R6f: audit is '$(rr_field "$a" result)'"
  rr_assert_published R6f "$RR_M1" src lib tools/x.sh
  grep -qx 'x_note=1' "$RR_META" || fail "R6f: the other writer's line was lost"
  rr_ok R6f "a crashed write superseded by a record with the prior slot block closes superseded-prior; the run then publishes"
}
test_R6g_superseded_other() {
  local out rc p a
  rr_make_f R6g
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  rr_record_slots "$RR_M0" src docs.txt
  a=$(rr_audit_for "$p")
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6g"$'\n'"$out"
  [ "$(rr_field "$a" result)" = superseded-other ] || fail "R6g: audit is '$(rr_field "$a" result)'"
  rr_assert_published R6g "$RR_M1" src lib tools/x.sh
  rr_ok R6g "a crashed write superseded by a record with another slot block closes superseded-other; the run then publishes"
}

rr_setup_R6d() { rr_make_f "$1"; rr_custody_fails_second_call; }
test_R6d_sigkill_after_the_restore_publish() {
  local out rc p a b
  rr_setup_R6d R6d
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 2
  a=$(rr_audit_for "$p")
  [ "$(rr_sha "$RR_META")" = "$p" ] || fail "R6d: the restore did not land before the kill"
  [ "$(rr_field "$a" result)" = rolling-back ] || fail "R6d: audit is '$(rr_field "$a" result)' after the kill"
  RR_CONTROL=
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6d second run"$'\n'"$out"
  [ "$(rr_field "$a" result)" = rolled-back ] || fail "R6d: first audit is '$(rr_field "$a" result)'"
  [ "$(rr_count "$(rr_audits)")" = 2 ] || fail "R6d: expected two audit records"
  for b in $(rr_audits); do [ "$b" = "$a" ] || { [ "$(rr_field "$b" result)" = published ] && rr_agrees "$b"; } || fail "R6d: second audit"; done
  [ "$(rr_count "$(rr_archives)")" = 2 ] || fail "R6d: expected two archives"
  rr_ok R6d "after the kill: record P, audit rolling-back; second run: first rolled-back, second published, two archives, audit_agrees"
}
test_R6e_sigkill_before_the_restore_publish() {
  local out rc p a b
  rr_setup_R6d R6e
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" before 2
  a=$(rr_audit_for "$p")
  [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" staged_sha256)" ] || fail "R6e: the record does not hold the staged bytes"
  [ "$(rr_field "$a" result)" = rolling-back ] || fail "R6e: audit is '$(rr_field "$a" result)'"
  rr_leftovers | grep -q 'rerecord-restore' || fail "R6e: no leftover restore file"
  RR_CONTROL=
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R6e second run"$'\n'"$out"
  [ "$(rr_field "$a" result)" = rolled-back ] || fail "R6e: first audit is '$(rr_field "$a" result)'"
  for b in $(rr_audits); do [ "$b" = "$a" ] || { [ "$(rr_field "$b" result)" = published ] && rr_agrees "$b"; } || fail "R6e: second audit"; done
  [ -z "$(rr_leftovers)" ] || fail "R6e: leftovers remain: $(rr_leftovers)"
  rr_ok R6e "after the kill: staged bytes, rolling-back, a leftover restore file; second run: first rolled-back, second published, no leftover"
}

test_R7_sigkill_before_publish_is_abandoned() {
  local out rc p a b
  rr_make_f R7
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" before 1
  a=$(rr_audit_for "$p")
  [ "$(rr_sha "$RR_META")" = "$p" ] || fail "R7: the record changed"
  rr_leftovers | grep -q "^\.$RR_ID\.meta\.rerecord\." || fail "R7: no leftover staged file"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R7 second run"$'\n'"$out"
  [ "$(rr_field "$a" result)" = abandoned ] || fail "R7: first audit is '$(rr_field "$a" result)'"
  [ -z "$(rr_leftovers)" ] || fail "R7: leftovers remain"
  for b in $(rr_audits); do [ "$b" = "$a" ] || [ "$(rr_field "$b" result)" = published ] || fail "R7: second audit"; done
  rr_ok R7 "after the kill: record P and a leftover staged file; second run: first abandoned, no leftover, second published"
}

test_R8_a_failed_publish_leaves_the_record() {
  local out rc before
  rr_make_f R8
  before=$(rec_inventory | head -n 1)
  out=$(FM_FAKE_META_PUBLISH_MV_FAIL=$RR_META rr_write); rc=$?
  [ "$rc" != 0 ] || fail "R8: expected nonzero"$'\n'"$out"
  [ "$before" = "$(rec_inventory | head -n 1)" ] || fail "R8: the record changed"
  [ -z "$(rr_leftovers)" ] || fail "R8: a staged file was left"
  [ "$(rr_results)" = refused ] || fail "R8: audit is '$(rr_results)'"
  rr_ok R8 "nonzero; record inode and sha256 unchanged; no staged file; audit refused"
}

rr_signal_in_postcheck() { # <SIG>
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_postcheck() { kill -$1 \$\$; }"
}
rr_expect_signal_rollback() { # <id> <SIG> <rc>
  local id=$1 out rc
  rr_make_f "$id"
  rr_signal_in_postcheck "$2"
  if [ "${RR_SIGINT_DEFAULT:-0}" = 1 ]; then
    printf '#!/bin/sh\nexec perl -e %s /bin/bash %s "$@"\n' "'\$SIG{INT} = \"DEFAULT\"; exec @ARGV or die'" "'$RR_CONTROL'" > "$RR_DIR/sigint-default.sh"
    chmod +x "$RR_DIR/sigint-default.sh"
    RR_CONTROL="$RR_DIR/sigint-default.sh"
  fi
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  expect_code "$3" "$rc" "$id"$'\n'"$out"
  [ "$(rr_sha "$RR_META")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "$id: not rolled back"
  [ "$(rr_sha "$(rr_archives)")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "$id: archive is not P"
  [ "$(rr_results)" = rolled-back ] || fail "$id: audit is '$(rr_results)'"
  rr_agrees "$(rr_audits)" || fail "$id: audit disagrees"
  rr_ok "$id" "exit $3 under $2 in stage published; rolled back; archive P; audit rolled-back; audit_agrees (BASH_VERSION $(bash -c 'echo "$BASH_VERSION"'))"
}
test_R9a_term_in_published_rolls_back() { rr_expect_signal_rollback R9a TERM 143; }
test_R9b_hup_in_published_rolls_back() { rr_expect_signal_rollback R9b HUP 129; }
# A shell started with SIGINT ignored (a non-interactive parent's background job, as some runners start suites) can
# neither trap nor be stopped by SIGINT, so R9c launches the verb through a wrapper that resets SIGINT to its default
# before exec; the verb then sees SIGINT as an interactive operator's shell would deliver it.
test_R9c_int_in_published_rolls_back() { RR_SIGINT_DEFAULT=1 rr_expect_signal_rollback R9c INT 130; }

# rr_signal_run [match-line]: TERM sent by the mv stub to the verb while its publish mv (or, with a match line, the mv
# whose source holds that line) is still to land; the stub waits for the verb to exit before its mv lands.
rr_signal_run() {
  local match=${1:-} out rc
  rm -f "$RR_DIR/fake/mv-target-count" "$RR_DIR/fake/mv-signal-matched"
  out=$(FM_FAKE_MV_SIGNAL=TERM FM_FAKE_MV_CRASH_TARGET=$RR_META FM_FAKE_MV_CRASH_NTH=1 FM_FAKE_MV_SIGNAL_MATCH=$match \
    FM_FAKE_MV_SIGNAL_WAIT=$RR_TERM_IMMEDIATE rr_write); rc=$?
  RR_OUT=$out
  RR_RC=$rc
}

test_R9d_term_while_the_publish_is_pending() {
  local out rc p a
  rr_make_f R9d
  rr_term_runs_trap_with_child || true
  p=$(rr_sha "$RR_META")
  rr_signal_run
  a=$(rr_audit_for "$p")
  if [ "$RR_TERM_IMMEDIATE" = 1 ]; then
    expect_code 143 "$RR_RC" "R9d first run"$'\n'"$RR_OUT"
  fi
  [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" staged_sha256)" ] || fail "R9d: the record does not hold the staged bytes"
  [ "$(rr_field "$a" result)" = pending ] || fail "R9d: audit is '$(rr_field "$a" result)'"
  [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "R9d: a restore was attempted"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R9d second"$'\n'"$out"
  assert_contains "$out" 'already recorded' "R9d"
  [ "$(rr_field "$a" result)" = published-recovered ] || fail "R9d: audit is '$(rr_field "$a" result)'"
  rr_agrees "$a" || fail "R9d: audit disagrees"
  rr_ok R9d "first run exit $RR_RC (TERM runs the trap at once: $RR_TERM_IMMEDIATE); staged bytes, pending, no restore; second run already recorded, published-recovered, one archive, audit_agrees"
}

test_R9e_term_while_the_commit_rename_is_pending() {
  local out rc p a
  rr_make_f R9e
  rr_term_runs_trap_with_child || true
  p=$(rr_sha "$RR_META")
  rr_signal_run result=published
  a=$(rr_audit_for "$p")
  if [ "$RR_TERM_IMMEDIATE" = 1 ]; then
    expect_code 143 "$RR_RC" "R9e first run"$'\n'"$RR_OUT"
  fi
  [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" staged_sha256)" ] || fail "R9e: the record does not hold the staged bytes"
  [ "$(rr_field "$a" result)" = published ] || fail "R9e: audit is '$(rr_field "$a" result)'"
  rr_agrees "$a" || fail "R9e: audit disagrees"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R9e second"$'\n'"$out"
  assert_contains "$out" 'already recorded' "R9e"
  [ "$(rr_field "$a" result)" = published ] && [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "R9e: second run changed the audit trail"
  rr_ok R9e "first run exit $RR_RC; staged bytes, audit published by the late rename, no restore, audit_agrees; second run unchanged, one archive"
}

test_R10_an_unverified_archive_refuses() {
  local out rc before
  rr_make_f R10
  make_cp_corrupt_stub "$RR_DIR"
  before=$(rec_inventory | head -n 1)
  out=$(FM_FAKE_CP_CORRUPT_GLOB='*/slot-rerecord/prior-meta.*' rr_write); rc=$?
  [ "$rc" != 0 ] || fail "R10: expected a refusal"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: archive_unverified' "R10"
  [ "$before" = "$(rec_inventory | head -n 1)" ] || fail "R10: the record changed"
  [ -z "$(rr_audits)" ] || fail "R10: an audit record was written"
  [ -z "$(rr_leftovers)" ] || fail "R10: a staged file was left"
  [ "$(rr_count "$(rr_archives)")" = 1 ] || fail "R10: the unverified archive was not kept"
  rr_ok R10 "archive_unverified; record unchanged; no audit record; no staged file; the unverified archive kept"
}

test_R11_an_unreadable_audit_record_refuses_until_moved_aside() {
  local out rc p a before
  rr_make_f R11
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" before 1
  a=$(rr_audit_for "$p")
  grep -v '^prior_sha256=' "$a" > "$RR_DIR/a.tmp" && cat "$RR_DIR/a.tmp" > "$a"
  before=$(rec_inventory | head -n 1)
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] || fail "R11: expected a refusal"$'\n'"$out"
  assert_contains "$out" "error: slot rerecord refused: rerecord_audit_unreadable: the audit record $a" "R11"
  [ "$before" = "$(rec_inventory | head -n 1)" ] || fail "R11: the record changed"
  mv "$a" "$RR_DIR/moved-aside.record"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "R11 rerun"$'\n'"$out"
  [ "$(rr_results)" = published ] || fail "R11: audit is '$(rr_results)'"
  rr_ok R11 "rerecord_audit_unreadable naming the file; record unchanged; after moving it aside the rerun publishes"
}

# --- review should-fix cases -------------------------------------------------------------------------

# SF4: an input changed after the rebind returned is caught by the post-publish comparison.
rr_after_rebind() { # <hook-path>: run <hook-path> right after the first (rebind) call of fm_slot_rerecord_inputs_unchanged
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_inputs_unchanged
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_inputs_unchanged() { local n; n=\$(cat '$RR_DIR/inputs-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$RR_DIR/inputs-calls'; real_fm_slot_rerecord_inputs_unchanged \"\$@\" || return; if [ \"\$n\" = 1 ]; then bash '$1' >/dev/null 2>&1; fi; }"
}
rr_setup_SF4head() { rr_make_f "$1"; rr_after_rebind "$(rr_hook sf4 "$RR_MERGE_M2_BODY")"; }
rr_after_rebind_binding() { # <hook-path>: run <hook-path> right after the rebind's fm_slot_rerecord_binding_ok (its second call)
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_binding_ok
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_binding_ok() { local n; n=\$(cat '$RR_DIR/binding-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$RR_DIR/binding-calls'; real_fm_slot_rerecord_binding_ok \"\$@\" || return; if [ \"\$n\" = 2 ]; then bash '$1' >/dev/null 2>&1; fi; }"
}
rr_setup_SF4owner() { rr_make_f "$1"; rr_after_rebind_binding "$(rr_hook sf4o 'python3 - "$RR_MANIFEST" <<'"'"'PY'"'"'
import json, sys
r = json.load(open(sys.argv[1])); r["owner_id"] = "other-task"; open(sys.argv[1], "w").write(json.dumps(r))
PY')"; }
rr_expect_postcheck_rollback() { # <id>
  local id=$1 out rc
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] || fail "$id: expected a refusal"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: adopt_postcheck_failed' "$id"
  [ "$(rr_sha "$RR_META")" = "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "$id: not rolled back"
  [ "$(rr_results)" = rolled-back ] || fail "$id: audit is '$(rr_results)'"
  RR_OUT=$out
}
test_SF4_head_moved_after_the_rebind() {
  rr_setup_SF4head SF4-head
  rr_expect_postcheck_rollback SF4-head
  rr_ok SF4-head "HEAD moved after the rebind returned: adopt_postcheck_failed, rolled back to P, audit rolled-back"
}
test_SF4_owner_changed_after_the_rebind() {
  rr_setup_SF4owner SF4-owner
  rr_expect_postcheck_rollback SF4-owner
  rr_ok SF4-owner "manifest owner_id changed after the rebind returned: adopt_postcheck_failed, rolled back, audit rolled-back"
}

# SF5: a TERM to a real fm-control relaunch leaves a failed:* journal and a free control lock while fm-spawn still holds
# the task's spawn lock; rerecord-slot refuses launch_in_progress.
test_SF5_term_to_relaunch_leaves_the_launcher_holding_the_spawn_lock() {
  local out rc pid i=0 spawn_pid phase
  rr_make_f SF5 --no-renew
  rr_record_slots "$(sed -n 's/^slot_base_sha=//p' "$RR_META")" src
  rr_alive
  : > "$RR_DIR/fake/hold-relocation-cd"
  (rr_relaunch > "$RR_DIR/relaunch.out" 2>&1) &
  while [ ! -e "$RR_DIR/fake/relocation-cd-held" ] && [ "$i" -lt 3000 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  [ -e "$RR_DIR/fake/relocation-cd-held" ] || { : > "$RR_DIR/fake/relocation-cd-release"; wait; fail "SF5: the launch owner never reached the held endpoint step"$'\n'"$(cat "$RR_DIR/relaunch.out")"; }
  pid=$(cat "$RR_DIR/home/state/.control-$RR_ID.lock/pid")
  spawn_pid=$(cat "$RR_DIR/home/state/.spawn-$RR_ID.lock/pid")
  kill -TERM "$pid"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 400 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  ! kill -0 "$pid" 2>/dev/null || { : > "$RR_DIR/fake/relocation-cd-release"; fail "SF5: fm-control did not exit on TERM"; }
  phase=$(journal_field "$RR_DIR" "$RR_ID" phase)
  case "$phase" in failed:?*) ;; *) : > "$RR_DIR/fake/relocation-cd-release"; fail "SF5: the journal reads '$phase', not failed:*"; ;; esac
  [ ! -e "$RR_DIR/home/state/.control-$RR_ID.lock" ] || { : > "$RR_DIR/fake/relocation-cd-release"; fail "SF5: the control lock is still held"; }
  kill -0 "$spawn_pid" 2>/dev/null || { : > "$RR_DIR/fake/relocation-cd-release"; fail "SF5: the launch owner is no longer running"; }
  out=$(rr_run --manifest-sha "$(rr_msha)" --note "$RR_NOTE"); rc=$?
  : > "$RR_DIR/fake/relocation-cd-release"
  wait
  [ "$rc" != 0 ] || fail "SF5: rerecord was admitted while the launcher ran"$'\n'"$out"
  assert_contains "$out" 'error: slot rerecord refused: launch_in_progress' "SF5"
  assert_contains "$out" "pid $spawn_pid" "SF5: the refusal names the launcher"
  rr_ok SF5 "TERM to fm-control relaunch: journal $phase, control lock free, fm-spawn (pid $spawn_pid) still holds the spawn lock, rerecord refuses launch_in_progress naming it"
}

# --- sensitivity controls (S) ---------------------------------------------------------------------
# Each control runs a named case through the shim with every enforcement point that reads the decisive fact set to
# allow, and passes only when the named assertion fails with the expected observation (the harm itself). A shimmed run
# that refuses, rolls back or fails for any other reason fails the control.

rr_adopt_verdict_allow='fm_slot_adopt_verdict() { printf "ok\t%s\n" "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(\"repo_root\", \"\"))" "$1")"; }'

# rr_control_run <control> <case> [run args]: run the case's write through the shim and require that it published.
rr_control_run() {
  local control=$1 case_id=$2 before out rc
  shift 2
  before=$(rr_slot_lines)
  if [ "$#" -gt 0 ]; then out=$(rr_run "$@"); rc=$?; else out=$(rr_write); rc=$?; fi
  rr_control_published "$control" "$case_id" "$before" "$out" "$rc"
  RR_OUT=$out
}

test_S1a_identity_verdict() {
  rr_setup_H1 S1a-H1
  rr_shim_allow fm_slot_rerecord_identity_verdict ok
  rr_control_run S1a H1
  rr_ok S1a "H1 under the allow: the other-owner manifest's base and scope were published, audit published"
}
test_S1b_identity_and_adopt_verdicts() {
  local id
  for id in H2 N5 N6; do
    "rr_setup_$id" "S1b-$id"
    rr_shim_allow fm_slot_rerecord_identity_verdict ok
    rr_shim fm-slot-provision-lib.sh "$rr_adopt_verdict_allow"
    rr_control_run S1b "$id"
  done
  rr_ok S1b "H2, N5 and N6 under the allows: the foreign-copy, released and other-branch manifests were published"
}
test_S2_adopt_records() {
  rr_setup_H10 S2-H10
  rr_shim_allow fm_slot_adopt_records ok
  rr_control_run S2 H10
  rr_ok S2 "H10 under the allow: the shadowed pointer's base and scope were published"
}
test_S3_base_verdict() {
  local id
  for id in H3 H4 H5 N11 N12 N13; do
    "rr_setup_$id" "S3-$id"
    rr_shim_allow fm_slot_rerecord_base_verdict ok
    rr_control_run S3 "$id"
  done
  rr_ok S3 "H3, H4, H5, N11, N12 and N13 under the allow: each wrong base was published"
}
test_S4_scope_verdict() {
  local id
  for id in H6 H7 H8 H17 N14 N15 N16; do
    "rr_setup_$id" "S4-$id"
    rr_shim_allow fm_slot_rerecord_scope_verdict ok
    rr_control_run S4 "$id"
  done
  rr_ok S4 "H6, H7, H8, H17, N14, N15 and N16 under the allow: each wrong scope was published"
}
test_S5_prove_stopped() {
  local id
  for id in H11 H19 H19b; do
    "rr_setup_$id" "S5-$id"
    rr_shim_allow fm_slot_rerecord_prove_stopped
    rr_control_run S5 "$id"
    [ -z "$(rr_sendkeys)" ] || fail "S5/$id: lifecycle input was sent"
    [ "$(cat "$RR_DIR/fake/command")" = claude ] || fail "S5/$id: the agent was stopped"
  done
  rr_ok S5 "H11, H19 and H19b under the allow: written under a live agent; send-keys still empty and the agent still alive"
}
test_S6_binding() {
  rr_setup_H14 S6-H14
  rr_shim_allow fm_slot_rerecord_binding_ok
  rr_control_run S6 H14 --manifest-sha "$RR_STALE_SHA" --note "$RR_NOTE"
  rr_ok S6 "H14 under the allow: published against bytes the operator never named"
}
test_S7_inputs_unchanged() {
  local mb
  rr_setup_R1a S7-R1a
  rr_shim_allow fm_slot_rerecord_inputs_unchanged
  rr_control_run S7 R1a
  mb=$(git -C "$RR_DIR/wt" merge-base refs/remotes/origin/main HEAD)
  [ "$mb" != "$RR_M1" ] || fail "S7/R1a: the fixture's merge-base did not move"
  git -C "$RR_DIR/wt" diff --name-only "$RR_M1" HEAD | grep -qx docs.txt || fail "S7/R1a: docs.txt is not in the fixture's diff"
  rr_assert_published S7-R1a "$RR_M1" src lib tools/x.sh
  rr_setup_R4 S7-R4
  rr_shim_allow fm_slot_rerecord_inputs_unchanged
  rr_control_run S7 R4
  ! grep -qx 'x_note=1' "$RR_META" || fail "S7/R4: the appended line survived"
  rr_ok S7 "R1a: base M1 published while the fixture's merge-base is $mb and docs.txt is uncovered; R4: the appended line is gone"
}
# The design expected R1b under S7 to reach the post-publish adoption check; the rebind's own digest binding
# (fm_slot_rerecord_binding_ok, which also reads the manifest bytes) refuses it first. Either way it is not an S7 result.
test_S7_R1b_defense_in_depth() {
  local out rc where
  rr_setup_R1b S7-R1b
  rr_shim_allow fm_slot_rerecord_inputs_unchanged
  cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] && [ "$(rr_sha "$RR_META")" = "$(rr_sha "$RR_DIR/prior.meta")" ] \
    || fail "S7/R1b: expected a refusal that leaves the prior record"$'\n'"$out"
  case "$out" in
    *'refused: manifest_sha_mismatch'*) where="the rebind's digest binding refused manifest_sha_mismatch before publish (audit $(rr_results))" ;;
    *'refused: adopt_postcheck_failed'*) where="the post-publish adoption check refused and rolled back (audit $(rr_results))" ;;
    *) fail "S7/R1b: an unexpected refusal"$'\n'"$out" ;;
  esac
  rr_record S7-R1b observation "R1b under S7: $where; defense in depth, not an S7 result"
  pass "S7-R1b: defense-in-depth observation recorded"
}
rr_rollback_noop() { rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_rollback() { return 0; }'; }
test_S8_rollback() {
  local out rc p
  rr_setup_R2 S8-R2; rr_rollback_noop; cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(FM_FAKE_PUBLISHED_AUDIT_MV_FAIL=1 rr_write); rc=$?
  [ "$rc" != 0 ] && [ "$(rr_sha "$RR_META")" != "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "S8/R2: the new record did not stay published"$'\n'"$out"
  rr_setup_R3 S8-R3; rr_rollback_noop; cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" != 0 ] && [ "$(rr_sha "$RR_META")" != "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "S8/R3: the new record did not stay published"$'\n'"$out"
  rr_make_f S8-R6b; p=$(rr_sha "$RR_META"); rr_crash_run "$RR_META" after 1
  rr_manifest_set created_at_iso '"2099-01-01T00:00:00+00:00"'
  rr_rollback_noop
  out=$(rr_run --manifest-sha "$(rr_field "$(rr_audit_for "$p")" manifest_sha256)" --note "$RR_NOTE"); rc=$?
  [ "$rc" = 0 ] && case "$out" in *'was rolled back'*'already recorded'*) true ;; *) false ;; esac \
    || fail "S8/R6b: the second run did not take the reconciliation's rollback branch and then the no-op"$'\n'"$out"
  [ "$(rr_sha "$RR_META")" != "$p" ] || fail "S8/R6b: the crashed write was rolled back"$'\n'"$out"
  rr_make_f S8-R9a; rr_signal_in_postcheck TERM; rr_rollback_noop; cp "$RR_META" "$RR_DIR/prior.meta"
  out=$(rr_write); rc=$?
  [ "$rc" = 143 ] && [ "$(rr_sha "$RR_META")" != "$(rr_sha "$RR_DIR/prior.meta")" ] || fail "S8/R9a: the new record did not stay published"$'\n'"$out"
  rr_ok S8 "R2, R3, R6b and R9a with a no-op rollback: the new record stays published after the failure or signal"
}
test_S9_precheck() {
  local out rc
  rr_setup_R5 S9-R5
  rr_shim_allow fm_slot_rerecord_precheck
  out=$(rr_write); rc=$?
  [ "$(rr_count "$(rr_archives)")" = 1 ] && [ "$(rr_results)" = rolled-back ] || fail "S9/R5: expected the corrupted record published then rolled back"$'\n'"$out"
  assert_contains "$out" adopt_postcheck_failed "S9/R5"
  rr_setup_R5b S9-R5b
  rr_shim_allow fm_slot_rerecord_precheck
  out=$(rr_write); rc=$?
  [ "$rc" = 0 ] && [ "$(rr_results)" = published ] && grep -qx 'model=injected' "$RR_META" || fail "S9/R5b: the altered model= line was not published"$'\n'"$out"
  rr_ok S9 "R5: an archive exists and audit rolled-back from adopt_postcheck_failed; R5b: the altered model= line was published"
}
test_S10_authorized() {
  local id
  for id in H13a H13b N17; do
    "rr_setup_$id" "S10-$id"
    rr_shim_allow fm_slot_rerecord_authorized
    rr_control_run S10 "$id"
  done
  RR_TASK_ID=; RR_ACTOR=
  rr_ok S10 "H13a, H13b and N17 under the allow: published by a worker, by a session without the lock, and by the supervision branch"
}
test_S11_note() {
  rr_setup_H13c S11-H13c
  rr_shim_allow fm_slot_rerecord_note_ok
  rr_control_run S11 H13c --manifest-sha "$(rr_msha)"
  grep -qx 'note=""' "$(rr_audits)" || fail "S11: the audit record does not carry an empty note"
  rr_ok S11 "H13c under the allow: published with an empty note in the audit record"
}
test_S12_journal_disposition() {
  local id jsum
  for id in H12 H12b H21; do
    "rr_setup_$id" "S12-$id"
    jsum=$(cat "$RR_DIR/home/state/$RR_ID.control-relaunch" 2>/dev/null | shasum -a 256)
    rr_shim_allow fm_slot_rerecord_journal_disposition
    rr_control_run S12 "$id"
    [ "$jsum" = "$(cat "$RR_DIR/home/state/$RR_ID.control-relaunch" 2>/dev/null | shasum -a 256)" ] || fail "S12/$id: the journal changed"
  done
  rr_ok S12 "H12, H12b and H21 under the allow: published during an in-flight or unreadable journal; journal bytes unchanged"
}
test_S13_shape() {
  local id
  for id in H15 N1 N3; do
    "rr_setup_$id" "S13-$id"
    rr_shim_allow fm_slot_rerecord_prove_shape
    rr_control_run S13 "$id"
  done
  rr_ok S13 "H15, N1 and N3 under the allow: the local-only, double-kind and refused-provisioning records were rewritten"
}
test_S14a_own_line_is_everything() {
  local out rc
  rr_setup_L6 S14a
  rr_shim fm-slot-provision-lib.sh "fm_slot_own_line_paths() { git -C \"\$1\" log --name-only -z --format= \"\$2..\$3\"; }"
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "S14a"$'\n'"$out"
  ! printf '%s\n' "$out" | grep -q '^side_branch_' || fail "S14a: a side-branch line was printed"
  ! grep -q '^side_branch_' "$(rr_audits)" || fail "S14a: a side-branch line was recorded"
  rr_ok S14a "L6 with every changed path on the own line: no side-branch line printed or recorded (L6's assertion fails)"
}
test_S14b_own_line_is_nothing() {
  local out rc
  rr_setup_L6 S14b
  rr_shim fm-slot-provision-lib.sh 'fm_slot_own_line_paths() { return 0; }'
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "S14b"$'\n'"$out"
  printf '%s\n' "$out" | grep -qx 'side_branch_only=tools/x.sh paths=1/1' || fail "S14b: tools/x.sh is not labelled side-branch-only"$'\n'"$out"
  rr_ok S14b "L6 with an empty own line: tools/x.sh is listed as side-branch-only (L6's assertion fails)"
}
rr_reconcile_noop() { rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_reconcile_pending() { return 0; }'; }
test_S15_reconcile() {
  local out rc p a
  rr_make_f S15-R6b; p=$(rr_sha "$RR_META"); rr_crash_run "$RR_META" after 1; a=$(rr_audit_for "$p")
  rr_manifest_set created_at_iso '"2099-01-01T00:00:00+00:00"'
  rr_reconcile_noop
  out=$(rr_run --manifest-sha "$(rr_field "$a" manifest_sha256)" --note "$RR_NOTE"); rc=$?
  expect_code 0 "$rc" "S15/R6b: the shimmed run did not reach the no-op"$'\n'"$out"
  assert_contains "$out" 'already recorded' "S15/R6b: the shimmed run did not reach the no-op"
  [ "$(rr_sha "$RR_META")" != "$p" ] || fail "S15/R6b: the crashed write was rolled back"$'\n'"$out"
  rr_setup_R6d S15-R6d; p=$(rr_sha "$RR_META"); rr_crash_run "$RR_META" after 2; a=$(rr_audit_for "$p")
  RR_CONTROL=; rr_reconcile_noop
  out=$(rr_write); rc=$?
  [ "$rc" = 0 ] && [ "$(rr_count "$(rr_audits)")" = 2 ] && printf '%s\n' "$(rr_results)" | grep -q published \
    || fail "S15/R6d: the shimmed run did not publish its own write"$'\n'"$out"
  [ "$(rr_field "$a" result)" = rolling-back ] || fail "S15/R6d: the first audit record is '$(rr_field "$a" result)'"$'\n'"$out"
  rr_setup_R6d S15-R6e; p=$(rr_sha "$RR_META"); rr_crash_run "$RR_META" before 2; a=$(rr_audit_for "$p")
  RR_CONTROL=; rr_reconcile_noop
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "S15/R6e: the shimmed run did not reach the no-op"$'\n'"$out"
  assert_contains "$out" 'already recorded' "S15/R6e: the shimmed run did not reach the no-op"
  [ "$(rr_field "$a" result)" = rolling-back ] || fail "S15/R6e: the first audit record is '$(rr_field "$a" result)'"$'\n'"$out"
  rr_make_f S15-R7; p=$(rr_sha "$RR_META"); rr_crash_run "$RR_META" before 1; a=$(rr_audit_for "$p")
  rr_reconcile_noop
  out=$(rr_write); rc=$?
  [ "$rc" = 0 ] && [ "$(rr_count "$(rr_audits)")" = 2 ] || fail "S15/R7: the shimmed run did not publish its own write"$'\n'"$out"
  [ "$(rr_field "$a" result)" = pending ] && rr_leftovers | grep -q "^\.$RR_ID\.meta\.rerecord\." \
    || fail "S15/R7: the audit record left pending with the staged file remaining was not observed"$'\n'"$out"
  rr_make_f S15-R9d; rr_term_runs_trap_with_child || true; p=$(rr_sha "$RR_META"); rr_signal_run; a=$(rr_audit_for "$p")
  rr_reconcile_noop
  out=$(rr_write); rc=$?
  expect_code 0 "$rc" "S15/R9d: the shimmed run did not reach the no-op"$'\n'"$out"
  assert_contains "$out" 'already recorded' "S15/R9d: the shimmed run did not reach the no-op"
  [ "$(rr_field "$a" result)" = pending ] || fail "S15/R9d: the first audit record is '$(rr_field "$a" result)'"$'\n'"$out"
  rr_ok S15 "with a no-op reconciliation: R6b stays published against the changed manifest, R6d and R6e stay rolling-back, R7 stays pending with its staged file, R9d stays pending"
}
test_S16_pending_state() {
  local out rc p a
  rr_make_f S16
  p=$(rr_sha "$RR_META")
  rr_crash_run "$RR_META" after 1
  printf 'x_note=1\n' >> "$RR_META"
  rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_pending_state() { printf "untouched-staged\n"; }'
  out=$(rr_write); rc=$?
  ! grep -qx 'x_note=1' "$RR_META" || fail "S16: the other writer's line survived"$'\n'"$out"
  a=$(rr_audit_for "$p")
  [ "$(rr_field "$a" result)" = rolled-back ] || fail "S16: the crashed write was not rolled back (audit '$(rr_field "$a" result)')"
  rr_ok S16 "R6c with every record read as untouched-staged: the post-publish check fails, the rollback restores P and the other writer's line is gone"
}
test_S17_strand() {
  local id
  for id in H9 H9b; do
    "rr_setup_$id" "S17-$id"
    rr_shim_allow fm_slot_rerecord_prove_no_strand
    rr_control_run S17 "$id"
    rr_slot_lines | grep -qx 'slot_owned_path=src' && fail "S17/$id: src was not released"
  done
  rr_ok S17 "H9 and H9b under the allow: the narrowing is published and src/other.txt's uncommitted edit lies outside the new scope"
}
test_S18_launch() {
  rr_setup_H20 S18-H20
  rr_shim_allow fm_slot_rerecord_prove_no_launch
  rr_control_run S18 H20
  [ "$(cat "$RR_DIR/home/state/.spawn-$RR_ID.lock/pid")" = "$RR_HOLDER_PID" ] && kill -0 "$RR_HOLDER_PID" || fail "S18: the helper lost the lock"
  rr_stop_spawn_lock_holder
  rr_ok S18 "H20 under the allow: published while the live helper holds the spawn lock"
}
test_S19_archive_readback() {
  local out rc
  rr_make_f S19-R10
  make_cp_corrupt_stub "$RR_DIR"
  rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_archive_verified() { return 0; }'
  out=$(FM_FAKE_CP_CORRUPT_GLOB='*/slot-rerecord/prior-meta.*' rr_write); rc=$?
  [ "$rc" = 0 ] && [ "$(rr_results)" = published ] || fail "S19: the record was not published"$'\n'"$out"
  [ "$(rr_sha "$(rr_archives)")" != "$(rr_field "$(rr_audits)" prior_sha256)" ] || fail "S19: the archive is intact"
  rr_ok S19 "R10 with the read-back comparison removed: published while the archive's sha256 is not P"
}
test_S20_publishing_rolls_back() {
  local p a
  rr_make_f S20-R9d
  if ! rr_term_runs_trap_with_child; then
    rr_record S20 unverified "this bash holds TERM until the foreground child exits, so the publishing window cannot be entered"
    pass "S20: unverified on this bash"; return 0
  fi
  rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_trap_action() { case "${1:-}" in staged) echo discard ;; published|publishing) echo rollback ;; committing|restoring) echo keep ;; *) echo none ;; esac; }'
  p=$(rr_sha "$RR_META")
  rr_signal_run
  a=$(rr_audit_for "$p")
  ! rr_agrees "$a" || fail "S20: audit_agrees held"
  [ "$(rr_field "$a" result)" = rolled-back ] && [ "$(rr_sha "$RR_META")" = "$(rr_field "$a" staged_sha256)" ] \
    || fail "S20: expected the staged bytes under a rolled-back audit record"
  rr_ok S20 "R9d with publishing mapped to rollback: the trap rolls back, the pending mv lands, staged bytes stand under a rolled-back audit record"
}
test_S21_backlog_close() {
  rr_setup_H22 S21-H22
  rr_shim_allow fm_slot_rerecord_prove_no_backlog_close
  rr_control_run S21 H22
  rr_ok S21 "H22 under the allow: published while the backlog close is pending"
}
test_S22_committing_rolls_back() {
  local p a
  rr_make_f S22-R9e
  if ! rr_term_runs_trap_with_child; then
    rr_record S22 unverified "this bash holds TERM until the foreground child exits, so the committing window cannot be entered"
    pass "S22: unverified on this bash"; return 0
  fi
  rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_trap_action() { case "${1:-}" in staged) echo discard ;; published|committing) echo rollback ;; publishing|restoring) echo keep ;; *) echo none ;; esac; }'
  p=$(rr_sha "$RR_META")
  rr_signal_run result=published
  a=$(rr_audit_for "$p")
  ! rr_agrees "$a" || fail "S22: audit_agrees held"
  [ "$(rr_field "$a" result)" = published ] && [ "$(rr_sha "$RR_META")" = "$p" ] \
    || fail "S22: expected the prior record under a published audit record"
  rr_ok S22 "R9e with committing mapped to rollback: the trap restores P, the late commit rename lands, P stands under a published audit record"
}
# SF4's control: remove only the post-publish comparison (the second fm_slot_rerecord_inputs_unchanged call).
test_SF4c_post_publish_comparison() {
  rr_setup_SF4head SF4c
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_inputs_unchanged() { local n; n=\$(cat '$RR_DIR/inputs-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$RR_DIR/inputs-calls'; if [ \"\$n\" = 1 ]; then real_fm_slot_rerecord_inputs_unchanged \"\$@\" || return; bash '$RR_DIR/hook-sf4.sh' >/dev/null 2>&1; return 0; fi; return 0; }"
  rr_control_run SF4c SF4-head
  rr_ok SF4c "SF4-head with only the post-publish comparison removed: published with a stale HEAD; audit published"
}
# Should-fix 2: the post-publish owner re-read is decisive on its own. The owner changes after the rebind returned, and
# only the post-publish comparison is removed, so the identity re-read is the one check that can see it.
rr_skip_post_publish_comparison() {
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_inputs_unchanged
  rr_shim fm-slot-provision-lib.sh "fm_slot_rerecord_inputs_unchanged() { local n; n=\$(cat '$RR_DIR/inputs-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$RR_DIR/inputs-calls'; if [ \"\$n\" = 1 ]; then real_fm_slot_rerecord_inputs_unchanged \"\$@\"; return; fi; return 0; }"
}
test_SF4_owner_reread_alone_refuses() {
  rr_setup_SF4owner SF4-owner-reread
  rr_skip_post_publish_comparison
  rr_expect_postcheck_rollback SF4-owner-reread
  assert_contains "$RR_OUT" "the live manifest no longer names this task's lease: owner_mismatch" "SF4-owner-reread: the refusal must come from the owner re-read"
  rr_ok SF4-owner-reread "owner changed after the rebind, post-publish comparison removed: the owner re-read alone refuses adopt_postcheck_failed naming the lease (owner_mismatch); rolled back, audit rolled-back"
}
test_SF4o_control_owner_reread() {
  rr_setup_SF4owner SF4o
  rr_skip_post_publish_comparison
  rr_shim_allow fm_slot_rerecord_identity_verdict ok
  rr_control_run SF4o SF4-owner-reread
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["owner_id"])' "$RR_MANIFEST")" = other-task ] \
    || fail "SF4o: the fixture's manifest does not name the other owner"
  rr_ok SF4o "SF4-owner-reread with the owner re-read also removed: published while the live manifest names another owner (adoption never compares owner); audit published"
}
# L13's control: drop the pending audit names after the reconciliation reports them, which restores the old no-op claim.
test_S23_check_pending_noop_claim() {
  local out rc
  rr_setup_L13 S23-L13
  rr_wrap fm-slot-provision-lib.sh fm_slot_rerecord_reconcile_pending
  rr_shim fm-slot-provision-lib.sh 'fm_slot_rerecord_reconcile_pending() { real_fm_slot_rerecord_reconcile_pending "$@" || return; FM_RR_PENDING=; }'
  out=$(rr_run --check); rc=$?
  expect_code 0 "$rc" "S23/L13: the shimmed --check did not finish"$'\n'"$out"
  assert_contains "$out" "pending_audit=$RR_L13_AUDIT result=pending state=untouched-staged" "S23/L13"
  assert_contains "$out" 'write_would=already recorded' "S23/L13: the shimmed --check did not claim the no-op"
  assert_not_contains "$out" 'manifest_sha256=' "S23/L13"
  assert_not_contains "$out" 'command: ' "S23/L13"
  RR_CONTROL=
  rr_expect_write_rolls_back_the_crash S23-L13
  rr_ok S23 "L13 with the pending names dropped: --check claims write_would=already recorded with no digest or command, while the write rolls the crash back and publishes"
}
#__REGISTRY__
control_relaunch_test_cases=(
test_rec_inventory_oracle_rejects_both_mutants
test_journal_verdict_classes
test_L1_publishes_the_renewal
test_L2_a_rolled_back_journal_is_judged_by_the_stopped_proof
test_L3_a_second_run_is_a_no_op
test_L4_check_reports_without_writing
test_L4b_check_with_a_live_spawn_lock_holder
test_L5_a_narrowing_releases_the_old_entry
test_L6_side_branch_paths_are_labelled
test_L7_a_nested_new_file_admits_its_deepest_tracked_directory
test_L8_a_hand_synced_record_is_a_no_op
test_L9_the_live_failed_shape_on_a_synced_record
test_L9b_the_live_complete_shape_with_the_agent_alive
test_L10_a_failed_launch_journal_with_the_agent_stopped
test_L11_an_uncommitted_file_under_a_new_directory_is_counted
test_L12_a_stale_spawn_lock_is_reclaimed
test_L13_check_names_a_pending_reconcile
test_E1_relaunch_after_rerecord_adopts
test_E2_relaunch_without_rerecord_refuses_base_mismatch
test_H1_owner_mismatch
test_H2_worktree_path_mismatch
test_H3_base_not_forward
test_H4_base_not_on_default
test_H5_base_not_merge_base
test_H6_scope_entry_not_own_work_docs
test_H7_scope_entry_not_own_work_tools
test_H8_scope_uncovered_change
test_H9_scope_release_strands_work
test_H9b_scope_release_strands_hidden_work
test_H9c_a_trailing_slash_prior_entry_is_normalized
test_H10_manifest_shadowed
test_H11_agent_not_proven_stopped
test_H12_relaunch_unfinished_in_flight
test_H12b_relaunch_unfinished_no_phase
test_H13a_actor_not_main_worker
test_H13b_session_lock_not_owned
test_H13c_note_required
test_H14_manifest_sha_mismatch
test_H15_local_only_source_unsupported
test_H17_scope_entry_not_own_work_nested
test_H18_the_no_op_does_not_mask_a_stale_base
test_H19_agent_alive_after_a_failed_launch
test_H19b_agent_alive_after_a_confirmed_launch
test_H20_launch_in_progress
test_H21_relaunch_unfinished_symlink
test_H22_backlog_close_pending
test_N1_not_ship_or_scout
test_N2_not_recorded
test_N3_not_adoption_route
test_N4_manifest_missing
test_N5_lifecycle_state_mismatch
test_N6_branch_mismatch
test_N7_repository_mismatch
test_N8_not_isolated
test_N9_operation_in_progress
test_N10_default_branch_unreadable
test_N11_base_ref_mismatch
test_N12_base_invalid
test_N13_base_not_in_head
test_N14_scope_invalid
test_N15_scope_not_canonical
test_N16_scope_not_tracked
test_N17_actor_not_main_branch
test_N18_manifest_unreadable
test_options_are_refused
test_R1a_head_moved_after_archive
test_R1b_manifest_changed_after_archive
test_R4_record_changed_after_archive
test_R2_commit_rename_fails
test_R3_postcheck_adoption_fails
test_R5_staged_slot_line_corrupted
test_R5b_staged_other_line_corrupted
test_R6a_sigkill_after_publish_is_recovered
test_R6b_recovery_rolls_back_against_a_changed_manifest
test_R6c_another_writer_supersedes_the_crashed_write
test_R6f_superseded_prior
test_R6g_superseded_other
test_R6d_sigkill_after_the_restore_publish
test_R6e_sigkill_before_the_restore_publish
test_R7_sigkill_before_publish_is_abandoned
test_R8_a_failed_publish_leaves_the_record
test_R9a_term_in_published_rolls_back
test_R9b_hup_in_published_rolls_back
test_R9c_int_in_published_rolls_back
test_R9d_term_while_the_publish_is_pending
test_R9e_term_while_the_commit_rename_is_pending
test_R10_an_unverified_archive_refuses
test_R11_an_unreadable_audit_record_refuses_until_moved_aside
test_SF4_head_moved_after_the_rebind
test_SF4_owner_changed_after_the_rebind
test_SF5_term_to_relaunch_leaves_the_launcher_holding_the_spawn_lock
test_S1a_identity_verdict
test_S1b_identity_and_adopt_verdicts
test_S2_adopt_records
test_S3_base_verdict
test_S4_scope_verdict
test_S5_prove_stopped
test_S6_binding
test_S7_inputs_unchanged
test_S7_R1b_defense_in_depth
test_S8_rollback
test_S9_precheck
test_S10_authorized
test_S11_note
test_S12_journal_disposition
test_S13_shape
test_S14a_own_line_is_everything
test_S14b_own_line_is_nothing
test_S15_reconcile
test_S16_pending_state
test_S17_strand
test_S18_launch
test_S19_archive_readback
test_S20_publishing_rolls_back
test_S21_backlog_close
test_S22_committing_rolls_back
test_SF4c_post_publish_comparison
test_SF4_owner_reread_alone_refuses
test_SF4o_control_owner_reread
test_S23_check_pending_noop_claim
)
control_relaunch_run "$@"
