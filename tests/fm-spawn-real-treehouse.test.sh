#!/usr/bin/env bash
# Real-Treehouse cases of fm-spawn's pooled-copy acquisition. A copy the pool hands out that the spawn cannot take (a
# recovered lease, another holder's lease, a foreign claim marker beside it, a pool state that fails the strict proof) is
# passed over untouched and the next clean copy is taken, or the spawn refuses before any claim. Every pool, state file and
# lease comes from the installed treehouse binary on one scratch TREEHOUSE_ROOT per case; only the pane is faked.
# Every case needs jq and `treehouse get --lease`; without them the first output line is the runner's gate skip, naming
# what is missing, and the script exits 0. Some cases also need `treehouse lease --path` (CASE_NEEDS below names each
# case's needs); on a host without it those cases alone are left out, the first output line is the runner's gate skip
# naming them, and every other case still runs. The pooled-copy cases that need no Treehouse stay in
# tests/fm-spawn-pool-base-freshen.test.sh; both files share tests/fm-spawn-pool-helpers.sh.
# Usage: bash tests/fm-spawn-real-treehouse.test.sh [test_function_name ...]
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_test_require_real_treehouse get-lease

TMP_ROOT=$(fm_test_tmproot fm-spawn-real-treehouse)
# Every spawn in this file runs with its detached home-summary refresh stubbed (tests/fixtures.sh fm_test_spawn_script).
export FM_TEST_STUB_SUMMARY_REFRESH=1
# shellcheck source=tests/fm-spawn-pool-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-pool-helpers.sh"

# --- a copy that already carries another holder's lease: the REAL treehouse on a scratch pool ----------------
# The pool, its state file and every lease come from the installed treehouse binary (one scratch TREEHOUSE_ROOT per case,
# never a real pool). Only the pane is faked: the stub tmux enters the copies in the order SKIP_SLOTS names, which is how a
# get hands a copy whose lease was recovered while the pane stood in it (the shell was inside, so Treehouse kept the lease).
REAL_TREEHOUSE=$(command -v treehouse 2>/dev/null || true)

# real_th <treehouse args...>: the real binary, in the case's project, against the case's scratch pool.
real_th() {
  (cd "$PROJECT_DIR" && TREEHOUSE_ROOT="$CASE_DIR/th-root" "$REAL_TREEHOUSE" "$@")
}

# make_real_pool_case <name> <id> <count>: make_case plus <count> real pool slots in hand-out order (REAL_SLOTS), all
# returned to the pool (unleased, clean). Then the stub tmux (SKIP_SLOTS) and a treehouse stand-in that logs each call and
# runs the real binary. FM_TEST_FORGE_LEASE makes `lease` print the refusal text with no pool change at all.
make_real_pool_case() {
  local name=$1 id=$2 count=$3 rec n slot
  rec=$(make_case "$name" "$id")
  read_case_record "$rec"
  REAL_SLOTS=()
  for ((n = 1; n <= count; n++)); do
    slot=$(real_th get --lease --lease-holder "seed-$n" 2>/dev/null) || fail "the real treehouse did not make slot $n"
    REAL_SLOTS+=("$(CDPATH='' cd -- "$slot" && pwd -P)")
  done
  for slot in "${REAL_SLOTS[@]}"; do
    real_th return "$slot" >/dev/null 2>&1 || fail "the real treehouse did not return $slot"
  done
  SKIP_SLOTS=("${REAL_SLOTS[@]}")
  install_real_treehouse
}

# pool_state_file <slot>: the pool's state file for a slot.
pool_state_file() { printf '%s/treehouse-state.json\n' "$(dirname "$(dirname "$1")")"; }

# install_real_treehouse: needs SKIP_SLOTS (hand-out order), CASE_DIR, FAKEBIN_DIR and PROJECT_DIR.
install_real_treehouse() {
  POOL_DIR=${SKIP_SLOTS[0]}
  make_skip_transport
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$SKIP_LOG'
if [ "\${1:-}" = pool-dir ] && [ -n "\${FM_TEST_POOLDIR:-}" ]; then
  case "\$FM_TEST_POOLDIR" in
    fail) echo 'error: pool-dir failed' >&2; exit 1 ;;
    print:*) printf '%s\\n' "\${FM_TEST_POOLDIR#print:}"; exit 0 ;;
  esac
fi
if [ "\${1:-}" = lease ] && [ -n "\${FM_TEST_FORGE_LEASE:-}" ]; then
  echo 'worktree 1 is already leased (holder: "recovered: state file was corrupt or truncated; verify before reuse")' >&2
  exit 1
fi
TREEHOUSE_ROOT='$CASE_DIR/th-root' exec '$REAL_TREEHOUSE' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# make_recovered_lease <slot>...: leave tracked work in each slot, then truncate the pool's state file and let the real
# treehouse rebuild it, which gives every slot of the pool the recovered lease. Treehouse never frees a recovered lease by
# itself (`treehouse return --all` skips it); it stays until it is returned by name or acknowledged with
# `treehouse lease --recover`. So only the named slots keep it: each OTHER slot of the case (REAL_SLOTS) that still carries
# it is returned by name here, with `treehouse return`, in this private pool. The named slots are checked in the state
# before the spawn runs, and each other slot is checked to be free.
make_recovered_lease() {
  local state slot holder other named
  state=$(pool_state_file "$1")
  for slot in "$@"; do printf 'work in progress\n' >> "$slot/README.md"; done
  head -c 150 "$state" > "$state.cut" || fail "the pool state could not be truncated"
  mv "$state.cut" "$state" || fail "the truncated pool state could not be put in place"
  real_th status >/dev/null 2>&1
  for other in "${REAL_SLOTS[@]}"; do
    named=0
    for slot in "$@"; do [ "$slot" != "$other" ] || named=1; done
    [ "$named" = 0 ] || continue
    holder=$(state_entry "$other" | jq -r '.lease_holder // empty')
    case "$holder" in
      recovered:*) real_th return "$other" >/dev/null 2>&1 || fail "the real treehouse did not return $other by name" ;;
    esac
    [ "$(state_entry "$other" | jq -r '.leased // false')" = false ] || fail "slot $other is still leased after the rebuild"
  done
  for slot in "$@"; do
    holder=$(state_entry "$slot" | jq -r '.lease_holder // empty')
    case "$holder" in recovered:*) ;; *) fail "slot $slot has no recovered lease in the pool state (holder: '${holder:-none}')" ;; esac
  done
}

# state_entry <slot>: every entry of the slot's path in the pool's state file, as the exact bytes they have there (the file is
# read in binary, so LF and CRLF differ, and nothing is re-serialized). Fails when no entry is found. Callers keep
# the bytes in a file (save_entry) and compare with cmp.
state_entry() {
  python3 - "$(pool_state_file "$1")" "$1" <<'PY'
import json, sys
text = open(sys.argv[1], "rb").read().decode("utf-8")
dec = json.JSONDecoder()
i = text.index("[", text.index('"worktrees"')) + 1
found = 0
while True:
    while text[i] in " \t\r\n,":
        i += 1
    if text[i] == "]":
        break
    obj, j = dec.raw_decode(text, i)
    if obj.get("path") == sys.argv[2]:
        sys.stdout.buffer.write(text[i:j].encode("utf-8"))
        found += 1
    i = j
sys.exit(0 if found >= 1 else 1)
PY
}

# save_entry <slot> <file>: keep the slot's raw state entry in <file>.
save_entry() { state_entry "$1" > "$2" || fail "the state entry of $1 could not be read"; }

# slot_neighbourhood <slot>: the files beside the checkout in its slot folder (a claim file would show up here) with their
# bytes, so a replaced marker with other content is a change too.
# A file whose checksum cannot be made fails the reading (exit 1); it is never printed as an empty field.
slot_neighbourhood() {
  local dir f sum
  dir=$(dirname "$1")
  for f in "$dir"/.[!.]* "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -f "$f" ]; then
      sum=$(shasum -a 256 < "$f") && [ -n "$sum" ] || return 1
      printf '%s %s\n' "${f##*/}" "$sum"
    else
      printf '%s\n' "${f##*/}"
    fi
  done
}

# tree_stat_digest <slot>: what a write cannot restore. One line with the path, its kind, mode, inode, size, mtime and ctime in
# NANOSECONDS, and the sha256 of its bytes (a symlink: its target), for:
#   - EVERY file and folder of the slot folder (the checkout, the claim marker beside it, whatever else is there) and of the
#     copy's own Git administration folder (HEAD, index, its logs);
#   - the pool state file the copy's state entry is read from (pool_state_file);
#   - every loose ref FILE of the shared Git folder outside refs/remotes/ (refs/heads, refs/tags and any other namespace).
# ctime is set by the kernel on every write, chmod, rename and unlink in or of the entry; no user can set it, so a write that
# puts the bytes, the mode and the mtime back still changes it, with or without immutable flags on the host. A failed stat,
# read or checksum FAILS the digest (exit 1), never an empty field. Left to the logical comparisons only: refs/remotes/*
# (another copy's work legitimately refreshes them), packed-refs, and the folders of the shared refs (a ref another copy
# creates or updates there changes them); own_digest compares every ref but refs/remotes/* by value and assert_untouched
# the copy's raw state entry by bytes.
tree_stat_digest() {
  local gitdir common
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir) || return 1
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  [ -n "$gitdir" ] && [ -n "$common" ] || return 1
  python3 - "$(dirname "$1")" "$gitdir" "$(pool_state_file "$1")" "$common/refs" <<'PY'
import hashlib, os, stat, sys

def line(path):
    st = os.lstat(path)
    kind = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "f" if stat.S_ISREG(st.st_mode) else "o"
    if kind == "f":
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        digest = h.hexdigest()
    elif kind == "l":
        digest = os.readlink(path)
    else:
        digest = "-"
    return "%s\t%s\t%o\t%d\t%d\t%d\t%d\t%s" % (path, kind, stat.S_IMODE(st.st_mode), st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, digest)

def fail(err):
    raise err

slot_dir, gitdir, state, refs = sys.argv[1:]
out = []
for root in (slot_dir, gitdir):
    out.append(line(root))
    for cur, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        for name in sorted(dirs) + sorted(files):
            out.append(line(os.path.join(cur, name)))
out.append(line(state))
for cur, dirs, files in os.walk(refs, followlinks=False, onerror=fail):
    if cur == refs:
        dirs[:] = [d for d in dirs if d != "remotes"]
    for name in sorted(files):
        out.append(line(os.path.join(cur, name)))
print("STATSTART")
print("\n".join(sorted(set(out))))
print("STATEND")
PY
}

# own_digest <slot>: slot_digest without refs/remotes/*, the one allowed difference (remote-tracking refs live in the shared Git
# directory and are refreshed for the copy the spawn takes, exactly as a spawn with no skipped slot refreshes them), then the
# raw index file's checksum, then tree_stat_digest. Every part's own exit status is checked before its text is printed, so a
# failed read or checksum can never print as an empty field that equals another empty field.
own_digest() {
  local all gitdir idx stat refs
  all=$(slot_digest "$1") || return 1
  refs=$(printf '%s\n' "$all" | grep -v '^refs/remotes/' || [ "$?" = 1 ]) || return 1
  printf '%s\n' "$refs"
  # The raw index file as well (its bytes, not only what git reads from it): a version or ordering change is a change.
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir) || return 1
  [ -f "$gitdir/index" ] || return 1
  idx=$(shasum -a 256 < "$gitdir/index") || return 1
  [ -n "$idx" ] || return 1
  printf 'RAWINDEX %s\n' "$idx"
  stat=$(tree_stat_digest "$1") || return 1
  [ -n "$stat" ] || return 1
  printf '%s\n' "$stat"
}

# assert_entry_unchanged <slot> <entry-file> <label>: the slot's raw state entry still equals the bytes kept in <entry-file>.
assert_entry_unchanged() {
  state_entry "$1" > "$2.after" || fail "$3: the slot's state entry could not be read"
  cmp -s "$2" "$2.after" || fail "$3: the slot's state entry changed"
}

# assert_untouched <slot> <own-digest> <entry-file> <neighbourhood> <label> [<after-digest>]: nothing about the passed-over copy
# changed - files, HEAD, every ref but refs/remotes/*, the raw state entry (cmp against <entry-file>) and lease, the files beside
# it, and the bytes, inode, mtime and ctime in nanoseconds of every file and folder of the slot folder and of its own Git
# folder, of the pool state file and of every loose ref file outside refs/remotes/ (tree_stat_digest).
assert_untouched() {
  local slot=$1 digest=$2 entry=$3 beside=$4 label=$5 after after_entry after_beside
  # A case that makes the copy read-only or immutable and puts the modes back afterwards (the marker case) takes its own
  # reading BEFORE it restores them, since restoring is itself a ctime change, and passes it as the sixth argument.
  if [ "$#" -ge 6 ]; then after=$6; else after=$(own_digest "$slot") || fail "$label: the copy could not be read"; fi
  [ "$after" = "$digest" ] || fail "$label: the copy changed"$'\n'"$(diff <(printf '%s\n' "$digest") <(printf '%s\n' "$after") | head -20)"
  after_entry="$entry.after"
  state_entry "$slot" > "$after_entry" || fail "$label: the slot's state entry could not be read"
  cmp -s "$entry" "$after_entry" || fail "$label: the slot's state entry changed"
  after_beside=$(slot_neighbourhood "$slot") || fail "$label: the slot folder could not be read"
  [ "$after_beside" = "$beside" ] || fail "$label: the slot folder's contents changed"
}

test_a_copy_with_a_recovered_lease_is_left_alone_and_a_clean_copy_is_taken() {
  local id out status digest entry beside
  id='pool-skip-recovered-lease'
  make_real_pool_case recovered-lease "$id" 4
  make_recovered_lease "${REAL_SLOTS[0]}"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read before the spawn"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a copy that carries a recovered lease should be passed over and a clean copy used"$'\n'"$out"
  assert_contains "$out" "skipped: copy ${REAL_SLOTS[0]} already carries another holder's lease" "the pass-over was not reported"
  assert_contains "$out" "recovered: state file was corrupt or truncated" "the report did not name the lease holder"
  assert_contains "$out" "copies left untouched" "the listing did not name the untouched copy"
  assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the next clean copy"
  assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "the recovered-lease copy"
  assert_grep "${REAL_SLOTS[0]}" "$HOME_DIR/data/$id/skipped-copies.tsv" "the copy was not recorded"
  assert_grep "recovered: state file was corrupt or truncated" "$HOME_DIR/data/$id/skipped-copies.tsv" "the record did not name the lease holder"
  ! grep -Fq "firstmate-skipped:$id" "$HOME_DIR/data/$id/skipped-copies.tsv" || fail "the record claims a lease this home never took"
  ! grep -Eq '^(lease|return|destroy|prune|enter)( |$)' "$SKIP_LOG" || fail "the spawn leased, returned or removed a copy: $(grep -E '^(lease|return|destroy|prune|enter)' "$SKIP_LOG")"
  [ "$(cat "$CASE_DIR/get-count")" = 2 ] || fail "treehouse get was not typed exactly twice"
  [ "$(git -C "${REAL_SLOTS[1]}" rev-parse HEAD)" = "$(git -C "${REAL_SLOTS[1]}" rev-parse origin/main)" ] \
    || fail "the clean copy was not moved to origin's tip"
  pass "a recovered-lease copy is passed over untouched and the task runs in the next clean copy"
}

test_a_copy_leased_by_another_holder_is_left_alone_and_a_clean_copy_is_taken() {
  local id out status digest entry beside
  id='pool-skip-other-holder'
  make_real_pool_case other-holder "$id" 3
  printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"
  real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the other holder's lease could not be made"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read before the spawn"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a copy leased by another holder should be passed over"$'\n'"$out"
  assert_contains "$out" "holder: other-task" "the report did not name the other holder"
  assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the next clean copy"
  assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "the other holder's copy"
  ! grep -Eq '^(lease|return|destroy|prune|enter)( |$)' "$SKIP_LOG" || fail "the spawn leased, returned or removed a copy"
  pass "a copy leased by another holder is passed over untouched too"
}

# F1, R2-5 and R3-4: a claim marker another task left beside the passed-over copy is never created, replaced or removed, and
# the spawn never even asks for it. The operations are observed, not only the end bytes: every call of the claim and release
# functions is traced (tests/claim-trace.sh) with its arguments, and none may name the passed-over copy while the next clean
# copy IS claimed (the positive control, so an empty trace cannot pass); `rm` and `mv` run through a log. The marker and its
# folder are read-only, and immutable where the host supports it (chflags uchg), so a transient write or chmod fails loudly.
test_a_foreign_claim_marker_beside_a_passed_over_copy_is_never_touched() {
  local id out status digest after_digest entry beside marker before_bytes folder log trace why immutable=0
  [ "$(id -u)" != 0 ] || { echo "skip - root writes into a read-only folder"; return 0; }
  id='pool-skip-foreign-marker'
  make_real_pool_case foreign-marker "$id" 3
  make_recovered_lease "${REAL_SLOTS[0]}"
  folder=$(dirname "${REAL_SLOTS[0]}")
  marker="$folder/.fm-slot-owner"
  printf 'task=other-task\nhome=/somewhere/else\n' > "$marker"
  log="$CASE_DIR/mutation.log"; : > "$log"
  trace="$CASE_DIR/claim.trace"; : > "$trace"
  install_mutation_log "$log"
  before_bytes=$(shasum -a 256 < "$marker")
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"
  chmod 444 "$marker"
  chmod 555 "$folder"
  if why=$(immutable_on "$marker" "$folder"); then immutable=1; else echo "note: no immutable flag on the marker and its folder ($why); the read-only modes, the claim trace, the rm and mv log and the nanosecond ctime comparison carry this case"; fi
  # The reading is taken after the modes are set, since setting them is itself a ctime change, and again before they are put back.
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read before the spawn"

  # FM_TEST_MARKER_BASH_ENV is only for the self-test below, which runs this case unchanged against a mutant spawn.
  out=$(FM_TEST_CLAIM_TRACE="$trace" BASH_ENV="${FM_TEST_MARKER_BASH_ENV:-$ROOT/tests/claim-trace.sh}" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  after_digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the passed-over copy could not be read after the spawn"
  if [ "$immutable" = 1 ]; then chflags nouchg "$marker" "$folder"; fi
  chmod 755 "$folder"
  chmod 644 "$marker"
  expect_code 0 "$status" "the spawn could not pass over the copy beside a read-only marker"$'\n'"$out"
  [ "$(shasum -a 256 < "$marker")" = "$before_bytes" ] || fail "the foreign claim marker's bytes changed: $(cat "$marker" 2>&1)"
  assert_no_mutation_logged "$log" "$folder" "the passed-over copy with a foreign marker"
  assert_claim_trace_clear "$trace" "${REAL_SLOTS[0]}" "the passed-over copy with a foreign marker"
  assert_claim_trace_clear "$trace" "$folder" "the passed-over copy with a foreign marker"
  grep -Fq "fm_treehouse_slot_owner_claim"$'\t'"${REAL_SLOTS[1]}"$'\t' "$trace" || fail "the trace does not hold the claim of the next clean copy (the positive control): $(cat "$trace")"
  assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "the passed-over copy with a foreign marker" "$after_digest"
  assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the next clean copy"
  pass "a foreign marker beside a passed-over copy keeps its bytes; the claim trace and the rm and mv log never name it, and the next clean copy is claimed"
}

# run_marker_case_in <tmp-root> <bin-first-on-path> <spawn-bash-env>: the marker case, unchanged, in its own case root, with
# <bin-first-on-path> ahead of PATH and <spawn-bash-env> as the spawn's BASH_ENV. Run it in a command substitution: a case
# that fails exits.
run_marker_case_in() {
  local TMP_ROOT=$1 PATH="$2:$PATH" FM_TEST_MARKER_BASH_ENV=$3
  test_a_foreign_claim_marker_beside_a_passed_over_copy_is_never_touched
}

# R4-2: the marker case itself, unchanged, must reject the reviewer's direct mutant on a host where immutable flags are not
# available. The mutant is a BASH_ENV file for the spawn that, at the moment the spawn passes the copy over, makes the
# foreign marker owner-writable, overwrites it in place, writes its original bytes back and sets mode 444 again: no claim,
# no release, no rm, no mv, so neither the claim trace nor the rm and mv log sees it. chflags is replaced by a command that
# always fails, so the marker case runs without immutable flags and only its untouched oracle can catch the write.
test_the_marker_case_rejects_a_direct_overwrite_and_restore_without_immutable_flags() {
  local dir out rc=0 proof
  [ "$(id -u)" != 0 ] || { echo "skip - root writes into a read-only folder"; return 0; }
  dir="$TMP_ROOT/marker-direct-mutant"
  mkdir -p "$dir/bin" "$dir/root"
  printf '#!/bin/sh\nexit 1\n' > "$dir/bin/chflags"
  chmod +x "$dir/bin/chflags"
  proof="$dir/proof.log"; : > "$proof"
  cat > "$dir/mutant.sh" <<SH
# shellcheck shell=bash
. '$ROOT/tests/claim-trace.sh'
__fm_direct_mutant() {
  __fm_claim_trace
  case "\$BASH_COMMAND" in
    spawn_pass_over_copy)
      local m o
      m="\$(dirname "\$WT")/.fm-slot-owner"
      [ -f "\$m" ] || return 0
      o=\$(cat "\$m")
      if chmod u+w "\$m" && printf 'overwritten\\n' > "\$m" && printf '%s\\n' "\$o" > "\$m"; then echo performed >> '$proof'; fi
      chmod 444 "\$m"
      ;;
  esac
  return 0
}
set -T
trap '__fm_direct_mutant' DEBUG
SH
  out=$(run_marker_case_in "$dir/root" "$dir/bin" "$dir/mutant.sh" 2>&1) || rc=$?
  grep -qx performed "$proof" || fail "the mutant did not overwrite and restore the marker, so it tests nothing: $out"
  assert_contains "$out" "note: no immutable flag" "the marker case did not run without immutable flags"
  [ "$rc" != 0 ] || fail "the marker case accepted a direct overwrite and restore of the foreign marker"$'\n'"$out"
  assert_contains "$out" "the passed-over copy with a foreign marker: the copy changed" "the marker case failed, but not on the untouched oracle"$'\n'"$out"
  pass "with no immutable flags, the unchanged marker case rejects a direct overwrite that restores the marker's bytes and mode, on its untouched oracle"
}

test_a_known_doubt_copy_with_no_lease_is_still_leased_to_this_task() {
  local id out status
  id='pool-skip-unleased-dirty'
  make_real_pool_case unleased-dirty "$id" 3
  printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a dirty copy with no lease should be skipped as before"$'\n'"$out"
  [ "$(state_entry "${REAL_SLOTS[0]}" | jq -r '.lease_holder')" = "firstmate-skipped:$id" ] \
    || fail "the dirty copy was not leased to this task: $(state_entry "${REAL_SLOTS[0]}")"
  assert_grep "firstmate-skipped:$id" "$HOME_DIR/data/$id/skipped-copies.tsv" "the record did not name this task's lease"
  assert_contains "$out" "is leased in place for its owner" "the skip did not say it leased the copy"
  assert_not_contains "$out" "copies left untouched" "an ordinary skip was reported as an untouched copy"
  pass "a known-doubt copy nobody leased is still leased to this task, as before"
}

# R2-1 and F3: the pool state must show ONE consistent row for the copy. A second row for it - the same name or path, or a
# different name with a differently spelled path (a symlink) to the same directory, whatever the holders and their order -
# means no row can be read out of it. On a DIRTY copy the spawn is refused before any claim, exactly as for a clean copy
# (R2-2 below); the case asserts the refusal, that nothing launched, no get beyond the first, no claim marker and no record.
# make_conflicting_state <variant>: edit the case's pool state (REAL_SLOTS[0] has its recovered lease) into the variant.
make_conflicting_state() {
  local variant=$1 state alias_dir rows_before
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  rows_before=$(jq '.worktrees | length' "$state")
  alias_dir="$CASE_DIR/alias-links"
  mkdir -p "$alias_dir"
  ln -s "${REAL_SLOTS[0]}" "$alias_dir/alias"
  # shellcheck disable=SC2016 # the $w, $h and $a in these jq programs are jq variables, not shell expansions
  case "$variant" in
    recovered-then-other) jq '.worktrees |= (. as $w | [$w[0], ($w[0] | .lease_holder = "other-task")] + $w[1:])' "$state" > "$state.new" ;;
    other-then-recovered) jq '.worktrees |= (. as $w | [($w[0] | .lease_holder = "other-task"), $w[0]] + $w[1:])' "$state" > "$state.new" ;;
    own-then-other) jq --arg h "firstmate-skipped:$ID_FOR_STATE" '.worktrees |= (. as $w | [($w[0] | .lease_holder = $h), ($w[0] | .lease_holder = "other-task")] + $w[1:])' "$state" > "$state.new" ;;
    other-then-own) jq --arg h "firstmate-skipped:$ID_FOR_STATE" '.worktrees |= (. as $w | [($w[0] | .lease_holder = "other-task"), ($w[0] | .lease_holder = $h)] + $w[1:])' "$state" > "$state.new" ;;
    alias-other-other) jq --arg a "$alias_dir/alias" '.worktrees |= (. as $w | [($w[0] | .lease_holder = "other-task"), ($w[0] | .name = "alias" | .path = $a | .lease_holder = "other-task-two")] + $w[1:])' "$state" > "$state.new" ;;
    alias-own-first) jq --arg a "$alias_dir/alias" --arg h "firstmate-skipped:$ID_FOR_STATE" '.worktrees |= (. as $w | [($w[0] | .name = "alias" | .path = $a | .lease_holder = $h), ($w[0] | .lease_holder = "other-task")] + $w[1:])' "$state" > "$state.new" ;;
    alias-own-last) jq --arg a "$alias_dir/alias" --arg h "firstmate-skipped:$ID_FOR_STATE" '.worktrees |= (. as $w | [($w[0] | .lease_holder = "other-task"), ($w[0] | .name = "alias" | .path = $a | .lease_holder = $h)] + $w[1:])' "$state" > "$state.new" ;;
    *) fail "unknown conflict variant $variant" ;;
  esac
  mv "$state.new" "$state" || fail "$variant: the conflicting state could not be put in place"
  [ "$(jq '.worktrees | length' "$state")" -gt "$rows_before" ] || fail "$variant: the state does not hold a second row for the slot"
}

assert_refused_before_any_claim() { # <out> <status> <label> <slot>
  local out=$1 status=$2 label=$3 slot=$4
  [ "$status" -ne 0 ] || fail "$label: the spawn went on although the pool state is not one consistent record for the copy"$'\n'"$out"
  assert_contains "$out" "does not show copy" "$label: the refusal was not the pool-state refusal"$'\n'"$out"
  assert_no_launch "$CASE_DIR/launch.log"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "$label: another copy was requested"
  [ ! -e "$(dirname "$slot")/.fm-slot-owner" ] || fail "$label: a claim marker was written beside the copy"
  [ ! -f "$HOME_DIR/data/$ID_FOR_STATE/skipped-copies.tsv" ] || fail "$label: a conflicting record was written up as a pass-over"
}

test_conflicting_pool_records_for_a_copy_refuse_the_whole_spawn() {
  local id out status digest entry variant
  for variant in recovered-then-other other-then-recovered own-then-other other-then-own alias-other-other alias-own-first alias-own-last; do
    id="pool-skip-conflict-${variant}"
    ID_FOR_STATE=$id
    make_real_pool_case "conflict-$variant" "$id" 3
    make_recovered_lease "${REAL_SLOTS[0]}"
    make_conflicting_state "$variant"
    digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read before the spawn"
    entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"

    out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    assert_refused_before_any_claim "$out" "$status" "$variant" "${REAL_SLOTS[0]}"
    assert_entry_unchanged "${REAL_SLOTS[0]}" "$entry" "$variant"
  done
  pass "a second row for one copy - same name or path, or a symlink alias under another name, with either holder in either order - refuses the whole spawn before any claim"
}

# R2-2: the same refusal for a CLEAN copy (an unreadable or conflicting state used to fall through to the claim and admit the
# task), with the controls: a clean copy whose state is positively unleased goes on, and a dirty one is skipped as before.
test_an_unreadable_or_conflicting_pool_state_on_a_clean_copy_refuses_before_any_claim() {
  local id out status variant state hook
  [ "$(id -u)" != 0 ] || { echo "skip - root reads a state file with no permissions"; return 0; }
  for variant in unreadable unreadable-dirty state-missing state-symlink leased-string leased-number leased-null duplicate-name own-and-other alias; do
    id="pool-clean-${variant}"
    ID_FOR_STATE=$id
    make_real_pool_case "clean-$variant" "$id" 3
    state=$(pool_state_file "${REAL_SLOTS[0]}")
    hook=
    case "$variant" in
      unreadable-dirty) make_recovered_lease "${REAL_SLOTS[0]}" ;;
      duplicate-name) make_conflicting_state_clean other-then-own "$id" ;;
      own-and-other) make_conflicting_state_clean own-then-other "$id" ;;
      alias) make_conflicting_state_clean alias-own-last "$id" ;;
      leased-string) make_leased_value_state '"true"' ;;
      leased-number) make_leased_value_state '1' ;;
      leased-null) make_leased_value_state 'null' ;;
    esac
    # The state turns bad as the first get is typed (the copy is already in the pool and the spawn reads the state right after).
    case "$variant" in
      unreadable | unreadable-dirty) hook="chmod 000 '$state'" ;;
      state-missing) hook="mv '$state' '$state.moved'" ;;
      state-symlink) hook="mv '$state' '$state.moved' && ln -s '$state.moved' '$state'" ;;
    esac
    out=$(FM_TEST_AT_GET="$hook" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    # Put the state back for the cleanup.
    chmod 600 "$state" 2>/dev/null || true
    [ ! -L "$state" ] || rm -f "$state"
    [ ! -e "$state.moved" ] || mv -f "$state.moved" "$state"
    assert_refused_before_any_claim "$out" "$status" "clean copy, $variant state" "${REAL_SLOTS[0]}"
  done
  pass "an unreadable state (clean or dirty copy), two rows by name, an own-and-other pair and a symlink alias each refuse before any claim"
}

# make_leased_value_state <json-value>: the copy's one row gets that value for its leased key (a string, a number, null).
make_leased_value_state() {
  local state
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  jq --argjson v "$1" '.worktrees[0].leased = $v' "$state" > "$state.new" || fail "the leased value $1 could not be set"
  mv "$state.new" "$state" || fail "the leased value $1 could not be put in place"
}

# make_conflicting_state_clean <variant> <id>: the conflicting state on a copy that is clean and unleased (no recovered lease).
make_conflicting_state_clean() {
  local variant=$1 state
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  # An unleased row to build on: lease it to other-task first, so every variant starts from a leased row, then edit.
  real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the lease for the clean-copy variant could not be made"
  make_conflicting_state "$variant"
  # The copy itself stays clean: nothing was written to its files.
  [ -z "$(git -C "${REAL_SLOTS[0]}" status --porcelain)" ] || fail "the clean-copy variant has work in it"
}

test_a_clean_unleased_copy_goes_on_to_the_claim_and_is_used() {
  local id out status
  id='pool-clean-unleased-control'
  make_real_pool_case clean-unleased "$id" 2

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a clean, positively unleased copy should be used"$'\n'"$out"
  assert_grep "worktree=${REAL_SLOTS[0]}" "$HOME_DIR/state/$id.meta" "the clean copy was not used"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "a second copy was requested for a clean unleased copy"
  assert_not_contains "$out" "copies left untouched" "a clean unleased copy was reported as passed over"
  pass "a clean copy whose one pool row is positively unleased is claimed and used, as before"
}

# Control for the leased value: a row whose leased key is the JSON false is unleased too, and the copy is used.
test_a_row_with_leased_false_is_unleased_and_the_copy_is_used() {
  local id out status
  id='pool-clean-leased-false'
  make_real_pool_case clean-leased-false "$id" 2
  make_leased_value_state false

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a copy whose leased value is false should be used"$'\n'"$out"
  assert_grep "worktree=${REAL_SLOTS[0]}" "$HOME_DIR/state/$id.meta" "the copy was not used"
  pass "a row whose leased value is the JSON false is unleased and its copy is claimed and used"
}

# R4-1 / R4-5 mechanism A: no row of a state file is read as a classification (passed over OR claimed) unless the WHOLE file
# passes the strict proof (bin/fm-task-copy-lib.sh fm_task_copy_pool_state_strict), which reads it exactly as written.
#
# state_case_text <base-state-file> <spec>: the base state's text with one change, written as raw text so a number keeps its
# literal form and a key can appear twice (a JSON tool would normalize both away). <spec> is one of
#   row|<n>|<key>|<literal>       set (or add) <key> of row <n> to <literal>
#   rowdel|<n>|<key>              remove <key> from row <n>
#   dupbefore|<n>|<key>|<literal> put <key>: <literal> into row <n> just before its existing <key>
#   dupafter|<n>|<key>|<literal>  put <key>: <literal> into row <n> just after its existing <key>
#   top|<key>|<literal>           set (or add) <key> of the document to <literal>
#   raw|<shape>                   bom, trailing, twodocs, empty, array, nan, badutf8, unchanged
state_case_text() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys

class Obj(list):
    pass

class Raw:
    def __init__(self, text):
        self.text = text

def render(v):
    if isinstance(v, Raw):
        return v.text
    if isinstance(v, Obj):
        return "{" + ", ".join(json.dumps(k) + ": " + render(x) for k, x in v) + "}"
    if isinstance(v, list):
        return "[" + ", ".join(render(x) for x in v) + "]"
    return json.dumps(v)

def put(obj, key, lit):
    for i, (k, _) in enumerate(obj):
        if k == key:
            obj[i] = (key, Raw(lit))
            return
    obj.append((key, Raw(lit)))

base = open(sys.argv[1], "rb").read()
spec = sys.argv[2].split("|", 3)
out = sys.stdout.buffer
if spec[0] == "raw":
    shape = spec[1]
    doc = {
        "unchanged": base,
        "bom": b"\xef\xbb\xbf" + base,
        "trailing": base + b" trailing",
        "twodocs": base + base,
        "empty": b"",
        "array": b"[]",
        "nan": base.replace(b'"worktrees"', b'"nan_field": NaN, "worktrees"', 1),
        "badutf8": base.replace(b'"worktrees"', b'"bad": "\xff", "worktrees"', 1),
    }[shape]
    out.write(doc)
    sys.exit(0)
doc = json.loads(base, object_pairs_hook=Obj)
if spec[0] == "top":
    put(doc, spec[1], spec[2])
else:
    rows = dict(doc)["worktrees"]
    row = rows[int(spec[1])]
    key = spec[2]
    if spec[0] == "row":
        put(row, key, spec[3])
    elif spec[0] == "rowdel":
        row[:] = [(k, v) for k, v in row if k != key]
    else:
        at = [k for k, _ in row].index(key)
        row.insert(at if spec[0] == "dupbefore" else at + 1, (key, Raw(spec[3])))
out.write(render(doc).encode("utf-8"))
PY
}

# strict_verdict <state-file>: valid or refused, from the strict proof itself.
strict_verdict() {
  if (. "$ROOT/bin/fm-task-copy-lib.sh"; fm_task_copy_pool_state_strict "$1") >/dev/null 2>&1; then echo valid; else echo refused; fi
}

# cli_verdict <state-file> <base-file>: kept or corrupt, from the real treehouse CLI, which reads the state in the case's
# scratch pool (`treehouse status`). A state the CLI cannot read as written is one it refuses outright (an unsupported
# version) or rebuilds from the copies on disk, and a rebuilt state has a new row for every copy, each with a new created_at.
# A state it reads keeps the created_at of each row the case did not change. Neither the CLI's message nor this home's
# reading of the case decides it.
cli_verdict() {
  local after
  real_th status >/dev/null 2>&1 || { echo corrupt; return 0; }
  after=$(jq -r '.worktrees[].created_at' "$1" 2>/dev/null) || { echo corrupt; return 0; }
  if jq -r '.worktrees[].created_at' "$2" | grep -Fxq -f - <(printf '%s\n' "$after"); then echo kept; else echo corrupt; fi
}

# Each entry is "<spec>@<expected verdict of the proof>"; a <row> spec without a row number is applied to row 0 (the copy
# with another holder's lease) and to row 1 (another copy). The expected verdicts are what the proof is meant to say; the
# test checks them, and checks against the real CLI that the proof never accepts a state the CLI cannot read as written.
STRICT_ROW_CASES=(
  'name|"x"@valid' 'name|123@refused' 'name|true@refused' 'name|[]@refused' 'name|{}@refused' 'name|null@refused' 'name|1.5@refused'
  'path|123@refused' 'path|""@refused' 'path|null@refused' 'path|[]@refused' 'path|true@refused'
  'created_at|"2026-11-18T06:38:47Z"@valid' 'created_at|"2026-11-18T06:38:47.24829-06:00"@valid'
  'created_at|"2026-11-18T06:38:47.1234567891Z"@valid' 'created_at|"2026-11-18T06:38:47-00:00"@valid'
  'created_at|123@refused' 'created_at|"not a time"@refused' 'created_at|null@refused' 'created_at|true@refused' 'created_at|{}@refused'
  'created_at|"2026-02-30T01:00:00Z"@refused' 'created_at|"2026-13-01T01:00:00Z"@refused' 'created_at|"2026-11-18 06:38:47Z"@refused'
  'created_at|"2026-11-18t06:38:47Z"@refused' 'created_at|"2026-11-18T06:38:47z"@refused' 'created_at|"2026-11-18T23:59:60Z"@refused'
  'created_at|"2026-11-18T06:38:47.Z"@refused' 'created_at|"2026-11-18T06:38:47+24:00"@refused' 'created_at|"2026-11-18T06:38:47,5Z"@refused'
  'created_at|"0000-01-01T00:00:00Z"@refused'
  'leased|true@valid' 'leased|false@valid' 'leased|"true"@refused' 'leased|"false"@refused' 'leased|1@refused' 'leased|0@refused'
  'leased|null@refused' 'leased|[]@refused' 'leased|{}@refused'
  'lease_id|"abc"@valid' 'lease_id|123@refused' 'lease_id|true@refused' 'lease_id|null@refused' 'lease_id|[]@refused'
  'lease_holder|"someone"@valid' 'lease_holder|""@valid' 'lease_holder|123@refused' 'lease_holder|true@refused'
  'lease_holder|null@refused' 'lease_holder|[]@refused' 'lease_holder|{}@refused' 'lease_holder|1.5@refused'
  'leased_at|"2026-11-18T06:38:47Z"@valid' 'leased_at|123@refused' 'leased_at|"x"@refused' 'leased_at|null@refused'
  'owner_pid|7@valid' 'owner_pid|-1@valid' 'owner_pid|0@valid' 'owner_pid|-0@valid' 'owner_pid|2147483647@valid'
  'owner_pid|2147483648@refused' 'owner_pid|"7"@refused' 'owner_pid|1.5@refused' 'owner_pid|1.0@refused' 'owner_pid|1e3@refused'
  'owner_pid|1E3@refused' 'owner_pid|null@refused' 'owner_pid|true@refused'
  'owner_started_at|5@valid' 'owner_started_at|2147483648@valid' 'owner_started_at|9223372036854775807@valid'
  'owner_started_at|9223372036854775808@refused' 'owner_started_at|"2026-11-18T06:38:47Z"@refused' 'owner_started_at|"x"@refused'
  'owner_started_at|1.5@refused' 'owner_started_at|1.0@refused' 'owner_started_at|1e3@refused' 'owner_started_at|null@refused'
  'destroying|false@valid' 'destroying|"true"@refused' 'destroying|1@refused' 'destroying|null@refused'
  'seed_auth_identity|"id"@valid' 'seed_auth_identity|1@refused' 'seed_auth_identity|true@refused' 'seed_auth_identity|null@refused'
  'seed_backend|"b"@valid' 'seed_backend|1@refused' 'seed_backend|[]@refused' 'seed_backend|null@refused'
  'seeded_paths|[]@valid' 'seeded_paths|["a","b"]@valid' 'seeded_paths|"a"@refused' 'seeded_paths|[1]@refused' 'seeded_paths|[null]@refused'
  'seeded_paths|[["a"]]@refused' 'seeded_paths|{}@refused' 'seeded_paths|null@refused'
  'base_branch|"main"@valid' 'base_branch|1@refused' 'base_branch|true@refused' 'base_branch|null@refused'
  'seed_inventory_known|true@valid' 'seed_inventory_known|"yes"@refused' 'seed_inventory_known|1@refused' 'seed_inventory_known|null@refused'
  'seed_inventory_digest|"d"@valid' 'seed_inventory_digest|5@refused' 'seed_inventory_digest|null@refused'
  'Leased|true@refused' 'Lease_Holder|"x"@refused' 'Lease_holder|123@refused' 'CREATED_AT|"2026-11-18T06:38:47Z"@refused'
  'ſeed_inventory_digest|"d"@refused' 'ſeed_backend|1@refused' 'zé|1@refused' 'unrelated_field|{"a":[1,2]}@valid'
)
STRICT_DOC_CASES=(
  'raw|unchanged@valid'
  'top|version|4@valid' 'top|version|0@valid' 'top|version|4.0@refused' 'top|version|4e0@refused' 'top|version|5@refused'
  'top|version|-1@refused' 'top|version|"4"@refused' 'top|version|null@refused' 'top|version|1.5@refused'
  'top|worktrees|null@refused' 'top|worktrees|{}@refused' 'top|worktrees|"x"@refused'
  'top|Worktrees|[{"name": 5}]@refused' 'top|Version|"x"@refused' 'top|extra|5@valid'
  'rowdel|0|leased@valid' 'rowdel|0|created_at@refused' 'rowdel|1|path@refused' 'rowdel|0|name@refused'
  'dupbefore|0|lease_holder|123@refused' 'dupafter|0|lease_holder|123@refused' 'dupafter|0|lease_holder|"y"@refused'
  'dupbefore|0|created_at|123@refused' 'dupbefore|1|created_at|1.0@refused'
  'raw|bom@refused' 'raw|trailing@refused' 'raw|twodocs@refused' 'raw|empty@refused' 'raw|array@refused' 'raw|nan@refused'
  'raw|badutf8@refused'
)

test_the_strict_state_proof_never_accepts_a_state_the_real_treehouse_cannot_read() {
  local id state base mutated entry spec expected got cli row n=0 asked=0 bad=0 corrupt=0 stricter=0 cases=()
  id='pool-strict-table'
  make_real_pool_case strict-table "$id" 2
  printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"
  real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the lease could not be made"
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  [ "$(jq '.worktrees | length' "$state")" = 2 ] || fail "the sample state does not hold two rows"
  base="$CASE_DIR/base.json"; cp "$state" "$base"
  mutated="$CASE_DIR/mutated.json"
  for entry in "${STRICT_ROW_CASES[@]}"; do
    for row in 0 1; do cases+=("row|$row|${entry}"); done
  done
  cases+=("${STRICT_DOC_CASES[@]}")
  for entry in "${cases[@]}"; do
    spec=${entry%@*}; expected=${entry##*@}
    state_case_text "$base" "$spec" > "$mutated" || fail "$spec could not be written"
    got=$(strict_verdict "$mutated")
    n=$((n + 1))
    if [ "${spec#row|1|}" != "$spec" ]; then
      # Row 1 repeats row 0's field cases for the proof, which must judge the whole file; the CLI is asked once, for row 0.
      [ "$got" = "$expected" ] || { bad=$((bad + 1)); echo "wrong verdict for $spec: expected $expected, got $got" >&2; }
      continue
    fi
    cp "$mutated" "$state"
    cli=$(cli_verdict "$state" "$base")
    cp "$base" "$state"
    asked=$((asked + 1))
    [ "$cli" = kept ] || corrupt=$((corrupt + 1))
    if [ "$got" != "$expected" ]; then bad=$((bad + 1)); echo "wrong verdict for $spec: expected $expected, got $got (the CLI: $cli)" >&2; fi
    if [ "$got" = valid ] && [ "$cli" != kept ]; then bad=$((bad + 1)); echo "the proof accepted $spec, which the real treehouse cannot read as written" >&2; fi
    if [ "$got" = refused ] && [ "$cli" = kept ]; then stricter=$((stricter + 1)); echo "note: the proof refuses $spec, which the real treehouse reads" ; fi
  done
  [ "$bad" = 0 ] || fail "$bad of $n cases broke the proof's contract"
  [ "$corrupt" -gt 0 ] && [ "$corrupt" -lt "$asked" ] || fail "$corrupt of the $asked cases asked of the CLI were states it cannot read, so the CLI check did not tell them apart"
  [ "$(cli_verdict "$state" "$base")" = kept ] && [ "$(strict_verdict "$state")" = valid ] || fail "the restored base state is not read as written by both"
  [ "$(strict_verdict "$CASE_DIR/does-not-exist.json")" = refused ] || fail "a missing file was accepted"
  ln -s "$base" "$CASE_DIR/link.json"; [ "$(strict_verdict "$CASE_DIR/link.json")" = refused ] || fail "a symlink was accepted"
  mkdir "$CASE_DIR/folder.json"; [ "$(strict_verdict "$CASE_DIR/folder.json")" = refused ] || fail "a folder was accepted"
  pass "of $n state cases ($asked asked of the real treehouse, $corrupt of them states it cannot read as written), the proof gives each its expected verdict and accepts none the CLI cannot read ($stricter refused where the CLI is more lenient); a missing file, a symlink and a folder are refused"
}

# mutate_state <spec>: apply a state_case_text spec to the pool state of the case's first copy, in place.
mutate_state() {
  local state
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  state_case_text "$state" "$1" > "$state.new" || fail "$1: the state could not be edited"
  mv "$state.new" "$state" || fail "$1: the edited state could not be put in place"
}

# A copy that carries another holder's lease, in a state that fails the proof anywhere, is never passed over: the whole spawn
# is refused before any claim, exactly as for any state that cannot be read as one consistent record.
test_a_state_with_a_wrong_field_type_is_never_read_as_another_holders_lease() {
  local id out status spec n=0
  for spec in 'row|0|lease_holder|123' 'row|1|lease_holder|true' 'row|0|created_at|123' 'row|0|created_at|"not a time"' \
    'row|1|created_at|123' 'row|1|path|5' 'row|0|leased|"true"' 'row|0|lease_id|123' 'row|0|leased_at|"x"' \
    'row|0|Lease_Holder|123' 'row|0|owner_pid|1.0' 'row|1|owner_started_at|1e3' 'row|0|owner_pid|2147483648' \
    'dupbefore|0|lease_holder|123' 'top|version|5' 'top|Worktrees|[]' 'raw|trailing' 'raw|bom'; do
    n=$((n + 1))
    id="pool-strict-other-$n"
    ID_FOR_STATE=$id
    make_real_pool_case "strict-other-$n" "$id" 2
    printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"
    real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the other holder's lease could not be made"
    mutate_state "$spec"
    out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    assert_refused_before_any_claim "$out" "$status" "other holder, $spec" "${REAL_SLOTS[0]}"
    ! grep -Eq '^(lease|return|destroy|prune|enter)( |$)' "$SKIP_LOG" || fail "$spec: the spawn leased, returned or removed a copy"
  done
  pass "a copy with another holder's lease in a state that fails the strict proof ($n forms: wrong types in its row or another, 1.0 or 1e3 for a whole number, a number past its range, a key twice, a key in another case, an unread version, text after the document, a byte-order mark) is never passed over: the whole spawn is refused before any claim"
}

# The proof gates the claim too: a clean, unleased copy in a state that fails it anywhere is not claimed.
test_a_clean_unleased_copy_in_a_state_that_fails_the_proof_is_never_claimed() {
  local id out status spec n=0
  for spec in 'row|1|created_at|123' 'row|1|lease_holder|123' 'row|0|owner_pid|1.0' 'row|0|seeded_paths|[1]' \
    'dupafter|0|name|"1"' 'top|version|4.0' 'raw|nan'; do
    n=$((n + 1))
    id="pool-strict-unleased-$n"
    ID_FOR_STATE=$id
    make_real_pool_case "strict-unleased-$n" "$id" 2
    [ "$(jq -r '.worktrees[0].leased // false' "$(pool_state_file "${REAL_SLOTS[0]}")")" = false ] || fail "$spec: the first copy is not unleased"
    mutate_state "$spec"
    out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    assert_refused_before_any_claim "$out" "$status" "clean unleased copy, $spec" "${REAL_SLOTS[0]}"
    ! grep -Eq '^(lease|return|destroy|prune|enter)( |$)' "$SKIP_LOG" || fail "$spec: the spawn leased, returned or removed a copy"
  done
  pass "a clean, unleased copy in a state that fails the strict proof ($n forms, in its own row, in another row or in the document) is not claimed: the whole spawn is refused before any claim"
}

# R4-1: the pool slot test cannot tell a pool copy whose state went missing from a copy outside the pool, and a failed
# `treehouse pool-dir` proves nothing either. Only a pool directory Treehouse named, with the copy not under it, is a proof
# of "not in the pool".
test_a_copy_with_no_readable_state_is_refused_unless_the_named_pool_excludes_it() {
  local id out status variant state hook
  for variant in missing-and-no-pool-dir symlink-and-no-pool-dir missing-and-relative-pool-dir missing-and-empty-pool-dir missing-and-pool-dir-names-it; do
    id="pool-pooldir-${variant}"
    ID_FOR_STATE=$id
    make_real_pool_case "pooldir-$variant" "$id" 2
    real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the other holder's lease could not be made"
    state=$(pool_state_file "${REAL_SLOTS[0]}")
    hook="mv '$state' '$state.moved'"
    case "$variant" in symlink-and-no-pool-dir) hook="mv '$state' '$state.moved' && ln -s '$state.moved' '$state'" ;; esac
    case "$variant" in
      missing-and-no-pool-dir | symlink-and-no-pool-dir) out=$(FM_TEST_POOLDIR='fail' FM_TEST_AT_GET="$hook" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off) ;;
      missing-and-relative-pool-dir) out=$(FM_TEST_POOLDIR='print:relative/dir' FM_TEST_AT_GET="$hook" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off) ;;
      missing-and-empty-pool-dir) out=$(FM_TEST_POOLDIR='print:' FM_TEST_AT_GET="$hook" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off) ;;
      missing-and-pool-dir-names-it) out=$(FM_TEST_AT_GET="$hook" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off) ;;
    esac
    status=$?
    [ ! -L "$state" ] || rm -f "$state"
    [ ! -e "$state.moved" ] || mv -f "$state.moved" "$state"
    assert_refused_before_any_claim "$out" "$status" "$variant" "${REAL_SLOTS[0]}"
    [ "$(jq -r '.worktrees[0].lease_holder' "$state")" = other-task ] || fail "$variant: the other holder's lease did not survive"
  done
  pass "a pool copy whose state is missing or a symlink is refused before any claim when Treehouse names no pool directory (it fails, answers a relative path or nothing) and when the pool directory it names holds the copy"
}

# The pool directory is asked only for a copy that is not a readable pool slot. A pool slot with a state that passes the
# strict proof is classified from that state even when `treehouse pool-dir` fails: another holder's copy is passed over and
# the next clean copy is claimed, and a clean unleased copy is claimed.
test_a_pool_slot_with_a_readable_state_is_classified_from_it_when_pool_dir_fails() {
  local id out status variant
  for variant in other-holder unleased; do
    id="pool-pooldir-fails-$variant"
    ID_FOR_STATE=$id
    make_real_pool_case "pooldir-fails-$variant" "$id" 2
    if FM_TEST_POOLDIR=fail "$FAKEBIN_DIR/treehouse" pool-dir >/dev/null 2>&1; then fail "$variant: pool-dir did not fail in this world"; fi
    if [ "$variant" = other-holder ]; then
      printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"
      real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the other holder's lease could not be made"
    fi
    out=$(FM_TEST_POOLDIR=fail FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "$variant: a pool slot with a readable state should be classified from it when pool-dir fails"$'\n'"$out"
    if [ "$variant" = other-holder ]; then
      assert_contains "$out" "holder: other-task" "$variant: the report did not name the other holder"
      assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "$variant: the task was not recorded on the next clean copy"
      [ "$(jq -r '.worktrees[0].lease_holder' "$(pool_state_file "${REAL_SLOTS[0]}")")" = other-task ] || fail "$variant: the other holder's lease did not survive"
    else
      assert_grep "worktree=${REAL_SLOTS[0]}" "$HOME_DIR/state/$id.meta" "$variant: the clean unleased copy was not used"
    fi
  done
  pass "a pool slot whose state passes the strict proof is classified from it when treehouse pool-dir fails: another holder's copy is passed over, a clean unleased copy is claimed"
}

# R2-3: the acceptance assertion itself rejects a change that only swaps LF for CRLF inside the state entry (valid JSON, every
# value the same), and still accepts the untouched state.
test_the_acceptance_assertion_rejects_a_crlf_only_change_of_the_state_entry() {
  local id digest entry beside rc=0
  id='pool-mutant-crlf'
  make_real_pool_case mutant-crlf "$id" 1
  make_recovered_lease "${REAL_SLOTS[0]}"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"
  (assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "control") >/dev/null 2>&1 || fail "the untouched copy was rejected"
  python3 - "$(pool_state_file "${REAL_SLOTS[0]}")" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
assert b"\r" not in data
open(p, "wb").write(data.replace(b"\n", b"\r\n"))
PY
  jq -e '.worktrees' "$(pool_state_file "${REAL_SLOTS[0]}")" >/dev/null || fail "the CRLF state is no longer valid JSON"
  (assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "crlf mutant") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a CRLF-only change of the state entry was accepted"
  pass "the acceptance assertion rejects a CRLF-only change of the raw state entry and accepts the untouched one"
}

# R2-4: a failing git read must fail own_digest and assert_untouched, even when the copy also has changed work (the stable
# error text of a failing git is the same before and after, which used to compare equal).
test_the_acceptance_assertion_rejects_a_failed_git_read_with_changed_work() {
  local id digest entry beside shim rc=0
  id='pool-mutant-git'
  make_real_pool_case mutant-git "$id" 1
  make_recovered_lease "${REAL_SLOTS[0]}"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"
  printf 'changed after the snapshot\n' >> "${REAL_SLOTS[0]}/README.md"
  shim="$CASE_DIR/gitshim"
  mkdir -p "$shim"
  printf '#!/bin/sh\necho "fatal: simulated git failure" >&2\nexit 47\n' > "$shim/git"
  chmod +x "$shim/git"
  (PATH="$shim:$PATH" own_digest "${REAL_SLOTS[0]}") >/dev/null 2>&1 && fail "own_digest passed although git failed"
  (PATH="$shim:$PATH" assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "git mutant") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "assert_untouched passed although git could not be read and the copy had changed work"
  (assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "changed work") >/dev/null 2>&1 && fail "changed work in the copy was accepted"
  pass "own_digest and assert_untouched fail when git cannot be read, and when the copy's work changed"
}

# R3-3: a change of the raw index file that git still reads the same (index version 4) fails the acceptance assertion.
test_the_acceptance_assertion_rejects_a_raw_index_change() {
  local id digest entry beside rc=0
  id='pool-mutant-index'
  make_real_pool_case mutant-index "$id" 1
  make_recovered_lease "${REAL_SLOTS[0]}"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
  beside=$(slot_neighbourhood "${REAL_SLOTS[0]}") || fail "the slot folder could not be read before the spawn"
  (assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "control") >/dev/null 2>&1 || fail "the untouched copy was rejected"
  git -C "${REAL_SLOTS[0]}" update-index --index-version 4 || fail "the index version could not be changed"
  (assert_untouched "${REAL_SLOTS[0]}" "$digest" "$entry" "$beside" "index mutant") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a change of the raw index bytes was accepted"
  rc=0
  mv "$(git -C "${REAL_SLOTS[0]}" rev-parse --absolute-git-dir)/index" "$CASE_DIR/index.moved"
  (own_digest "${REAL_SLOTS[0]}") >/dev/null 2>&1 && rc=1
  [ "$rc" = 0 ] || fail "own_digest passed with an unreadable index"
  pass "the acceptance assertion rejects a raw index change that git reads the same, and an index that cannot be read"
}

# R4-2 / R4-3 mechanism B: the untouched oracle compares what a write cannot restore. ctime, in nanoseconds, is set by the
# kernel on every write, chmod, rename and unlink and no user can set it, so a write that restores the bytes, the mode and the
# mtime still changes it. These are the self-tests against the REAL assertion (own_digest and assert_untouched), on a host with
# no immutable flags in play: none of the mutants below uses, or needs, chflags.
test_the_acceptance_assertion_rejects_a_write_that_restores_bytes_mode_and_mtime() {
  local id slot folder marker digest entry beside mutant rc results=""
  id='pool-mutant-restore'
  make_real_pool_case mutant-restore "$id" 1
  make_recovered_lease "${REAL_SLOTS[0]}"
  slot=${REAL_SLOTS[0]}
  folder=$(dirname "$slot")
  marker="$folder/.fm-slot-owner"
  printf 'task=other-task\nhome=/somewhere/else\n' > "$marker"
  chmod 444 "$marker"
  entry="$CASE_DIR/entry.before"; save_entry "$slot" "$entry"
  beside=$(slot_neighbourhood "$slot") || fail "the slot folder could not be read before the spawn"
  for mutant in control direct-overwrite-and-restore chmod-only overwrite-restore-and-reset-mtime replace-by-rename-and-restore file-in-the-checkout-restored git-head-restored; do
    digest=$(own_digest "$slot") || fail "the slot could not be read"
    case "$mutant" in
      control) : ;;
      direct-overwrite-and-restore)
        # the reader's mutant: owner-writable, overwritten in place, bytes and mode 444 put back; no claim, no release, no rm, no mv
        chmod 644 "$marker"; printf 'overwritten\n' > "$marker"; printf 'task=other-task\nhome=/somewhere/else\n' > "$marker"; chmod 444 "$marker" ;;
      chmod-only) chmod 644 "$marker"; chmod 444 "$marker" ;;
      overwrite-restore-and-reset-mtime)
        python3 - "$marker" <<'PY'
import os, sys
p = sys.argv[1]
st = os.stat(p)
os.chmod(p, 0o644)
data = open(p, "rb").read()
open(p, "wb").write(b"overwritten\n")
open(p, "wb").write(data)
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
os.chmod(p, 0o444)
PY
        ;;
      replace-by-rename-and-restore)
        # a copy of the file moved over it: same bytes, same mode, a new inode
        cp -p "$marker" "$marker.copy" && mv -f "$marker.copy" "$marker" ;;
      file-in-the-checkout-restored)
        cp -p "$slot/README.md" "$CASE_DIR/readme.keep"; printf 'x\n' >> "$slot/README.md"; cp -p "$CASE_DIR/readme.keep" "$slot/README.md" ;;
      git-head-restored)
        # the copy's own HEAD file rewritten with the same bytes
        python3 - "$(git -C "$slot" rev-parse --absolute-git-dir)/HEAD" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
open(p, "wb").write(data)
PY
        ;;
    esac
    rc=0
    (assert_untouched "$slot" "$digest" "$entry" "$beside" "$mutant") >/dev/null 2>&1 || rc=$?
    case "$mutant" in
      control) [ "$rc" = 0 ] || fail "the untouched copy was rejected" ;;
      *) [ "$rc" != 0 ] || fail "the assertion accepted: $mutant" ;;
    esac
    results="$results $mutant"
    # The mutant's byte-for-byte restoration is real: the plain checksum of the marker is unchanged.
    case "$mutant" in direct-overwrite-and-restore | chmod-only | overwrite-restore-and-reset-mtime | replace-by-rename-and-restore)
      [ "$(cat "$marker")" = "$(printf 'task=other-task\nhome=/somewhere/else\n')" ] || fail "$mutant did not restore the marker's bytes, so it does not model a restore" ;; esac
  done
  pass "the acceptance assertion accepts the untouched copy and rejects each of: a direct overwrite that restores bytes and mode, a chmod only, a restore that also resets the mtime, a replacement by rename, a restored file in the checkout, a rewritten HEAD (no chflags involved)"
}

# R4-3: a failed raw-index checksum is a failure, not an empty field. The checksum of the index is made with a shim that fails
# only for that stdin read; the index is then changed in a way git reads the same (index version 4).
test_a_failed_raw_index_checksum_fails_the_acceptance_assertion() {
  local id slot digest entry beside shim real_sha rc=0
  id='pool-mutant-index-checksum'
  make_real_pool_case mutant-index-checksum "$id" 1
  make_recovered_lease "${REAL_SLOTS[0]}"
  slot=${REAL_SLOTS[0]}
  digest=$(own_digest "$slot") || fail "the slot could not be read"
  entry="$CASE_DIR/entry.before"; save_entry "$slot" "$entry"
  beside=$(slot_neighbourhood "$slot") || fail "the slot folder could not be read before the spawn"
  shim="$CASE_DIR/shashim"
  mkdir -p "$shim"
  # The reviewer's shim: `shasum -a 256` reading stdin (exactly those two arguments, as the raw-index read calls it) fails
  # with 47; a checksum that names its file runs the real program.
  real_sha=$(command -v shasum) || fail "no shasum"
  # shellcheck disable=SC2016 # the shim's own script text
  printf '#!/usr/bin/env bash\nif [ "$#" = 2 ] && [ "${1:-}" = -a ] && [ "${2:-}" = 256 ]; then echo "simulated raw index hash read failure" >&2; exit 47; fi\nexec %s "$@"\n' "'$real_sha'" > "$shim/shasum"
  chmod +x "$shim/shasum"
  (PATH="$shim:$PATH" own_digest "$slot") >/dev/null 2>&1 && fail "own_digest passed although the raw-index checksum failed, before any change"
  git -C "$slot" update-index --index-version 4 || fail "the index version could not be changed"
  (PATH="$shim:$PATH" own_digest "$slot") >/dev/null 2>&1 && fail "own_digest passed although the raw-index checksum failed"
  (PATH="$shim:$PATH" assert_untouched "$slot" "$digest" "$entry" "$beside" "failed checksum plus version 4") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "assert_untouched passed although the raw-index checksum failed and the index changed"
  rc=0
  (assert_untouched "$slot" "$digest" "$entry" "$beside" "version 4 alone") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "assert_untouched passed although the index changed"
  pass "a failed raw-index checksum fails own_digest and assert_untouched, with or without the index change"
}

# restore_rewrite <file>: overwrite <file> in place with other bytes, then write its own bytes back and set its mtime back to
# the nanosecond: the bytes, the inode, the mode and the mtime are as they were, and only the ctime the kernel set differs.
# Fails when the bytes or the mtime are not back, and when the ctime did not change: then the host shows no write and the
# case could show nothing, so it must not pass.
restore_rewrite() {
  python3 - "$1" <<'PY'
import os, sys
p = sys.argv[1]
before = os.stat(p)
data = open(p, "rb").read()
with open(p, "wb") as fh:
    fh.write(b"temporary bytes\n")
with open(p, "wb") as fh:
    fh.write(data)
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
after = os.stat(p)
if open(p, "rb").read() != data or after.st_mtime_ns != before.st_mtime_ns or after.st_ino != before.st_ino:
    sys.exit("the bytes, the inode or the mtime of %s did not come back" % p)
if after.st_ctime_ns == before.st_ctime_ns:
    sys.exit("inconclusive: the host did not change the ctime of %s on a write" % p)
PY
}

# Main 2889 F2: the untouched oracle compares the bytes, inode, mtime and ctime in nanoseconds of the pool state file the
# copy's entry is read from and of the copy's loose ref files, not only the entry's bytes and the refs' values. Each control
# is accepted; each rewrite that puts back the bytes and the mtime is rejected, though the entry's bytes and every ref's value
# read the same.
test_the_acceptance_assertion_rejects_a_restored_rewrite_of_the_pool_state_file() {
  local id slot state digest entry beside rc
  id='pool-mutant-state-file'
  make_real_pool_case mutant-state-file "$id" 2
  slot=${REAL_SLOTS[0]}
  real_th lease --path "$slot" --lease-holder other-task >/dev/null 2>&1 || fail "the real treehouse did not lease $slot"
  state=$(pool_state_file "$slot")
  entry="$CASE_DIR/entry.before"; save_entry "$slot" "$entry"
  beside=$(slot_neighbourhood "$slot") || fail "the slot folder could not be read"
  digest=$(own_digest "$slot") || fail "the slot could not be read"
  rc=0
  (assert_untouched "$slot" "$digest" "$entry" "$beside" "control") >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "the untouched copy was rejected"
  restore_rewrite "$state" || fail "the rewrite of the pool state file is not a restore"
  (assert_entry_unchanged "$slot" "$entry" "the restored state file") || fail "the restored state file does not give the copy's entry its old bytes, so this does not model a restore"
  rc=0
  (assert_untouched "$slot" "$digest" "$entry" "$beside" "state file rewritten and restored") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the assertion accepted a rewrite of the pool state file that restored its bytes and mtime"
  pass "the acceptance assertion accepts the untouched copy and rejects a rewrite of the pool state file that restores its bytes and mtime"
}

test_the_acceptance_assertion_rejects_a_restored_rewrite_of_a_loose_ref_file() {
  local id slot ref digest entry beside rc
  id='pool-mutant-ref-file'
  make_real_pool_case mutant-ref-file "$id" 1
  slot=${REAL_SLOTS[0]}
  git -C "$slot" update-ref refs/heads/held-by-the-copy HEAD || fail "the ref could not be made"
  ref="$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir)/refs/heads/held-by-the-copy"
  [ -f "$ref" ] || fail "the ref is not a loose file"
  entry="$CASE_DIR/entry.before"; save_entry "$slot" "$entry"
  beside=$(slot_neighbourhood "$slot") || fail "the slot folder could not be read"
  digest=$(own_digest "$slot") || fail "the slot could not be read"
  rc=0
  (assert_untouched "$slot" "$digest" "$entry" "$beside" "control") >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "the untouched copy was rejected"
  restore_rewrite "$ref" || fail "the rewrite of the loose ref file is not a restore"
  [ "$(git -C "$slot" rev-parse refs/heads/held-by-the-copy)" = "$(git -C "$slot" rev-parse HEAD)" ] || fail "the ref's value changed, so this does not model a restore"
  rc=0
  (assert_untouched "$slot" "$digest" "$entry" "$beside" "loose ref rewritten and restored") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the assertion accepted a rewrite of a loose ref file that restored its bytes and mtime"
  pass "the acceptance assertion accepts the untouched copy and rejects a rewrite of a loose ref file that restores its bytes and mtime"
}

# install_state_read_hook <slot>: a python3 on the spawn's PATH that counts in $CASE_DIR/state-reads each python3 run naming
# <slot>'s pool state file as an argument (one reading of that file), and runs FM_TEST_STATE_READ_BEFORE and
# FM_TEST_STATE_READ_AFTER as shell text, with that reading's number in $n, just before and just after it. Every other run is
# the real python3, unchanged. It lets a case change the pool state between two of the spawn's own readings, as a treehouse
# command run elsewhere can: Treehouse writes its state under its own lock, which the spawn does not hold.
install_state_read_hook() {
  local state real_py
  state=$(pool_state_file "$1")
  real_py=$(command -v python3) || fail "python3 is not installed"
  echo 0 > "$CASE_DIR/state-reads"
  cat > "$FAKEBIN_DIR/python3" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = '$state' ] || continue
  n=\$(( \$(cat '$CASE_DIR/state-reads') + 1 ))
  echo "\$n" > '$CASE_DIR/state-reads'
  [ -z "\${FM_TEST_STATE_READ_BEFORE:-}" ] || eval "\$FM_TEST_STATE_READ_BEFORE" </dev/null
  rc=0
  '$real_py' "\$@" || rc=\$?
  [ -z "\${FM_TEST_STATE_READ_AFTER:-}" ] || eval "\$FM_TEST_STATE_READ_AFTER" </dev/null
  exit "\$rc"
done
exec '$real_py' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/python3"
}

# write_state_change <name> <jq-filter>: a script $CASE_DIR/<name> that rewrites the pool state of REAL_SLOTS in place with
# <jq-filter> ($slot is the first slot's path), as a hook runs it.
write_state_change() {
  local state
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  cat > "$CASE_DIR/$1" <<SH
#!/usr/bin/env bash
jq --arg slot '${REAL_SLOTS[0]}' '$2' '$state' > '$CASE_DIR/$1.next' && cat '$CASE_DIR/$1.next' > '$state'
SH
  chmod +x "$CASE_DIR/$1"
}

# Main 2889 F1 (review r7): a pool state that the strict proof passed and that then fails it before the spawn's second
# reading is refused before any claim: no pass-over, no second copy, no worker, whether the change stays, is undone at the
# next get, or is in another copy's row. The spawn reads the state twice, so the change is seen at the second reading.
test_a_state_that_fails_the_proof_after_the_first_reading_refuses_before_any_claim() {
  local id out status variant state
  for variant in number-holder number-holder-undone-at-the-next-get other-row-number-created-at; do
    id="pool-state-race-$variant"
    ID_FOR_STATE=$id
    make_real_pool_case "state-race-$variant" "$id" 3
    state=$(pool_state_file "${REAL_SLOTS[0]}")
    if [ "$variant" != other-row-number-created-at ]; then
      printf 'other holder work\n' >> "${REAL_SLOTS[0]}/README.md"
      real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the real treehouse did not lease the first copy"
    fi
    cp "$state" "$CASE_DIR/valid-state.json"
    # shellcheck disable=SC2016 # jq expands $slot, which write_state_change passes with --arg.
    case "$variant" in
      other-row-number-created-at) write_state_change change '(.worktrees[] | select(.path != $slot) | .created_at) = 123' ;;
      *) write_state_change change '(.worktrees[] | select(.path == $slot) | .lease_holder) = 123' ;;
    esac
    install_state_read_hook "${REAL_SLOTS[0]}"
    out=$(FM_TEST_STATE_READ_AFTER="[ \"\$n\" != 1 ] || '$CASE_DIR/change'" \
      FM_TEST_AT_GET="$([ "$variant" != number-holder-undone-at-the-next-get ] || printf '%s' "[ \"\$n\" != 2 ] || cp '$CASE_DIR/valid-state.json' '$state'")" \
      FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    [ "$(cat "$CASE_DIR/state-reads")" -ge 1 ] || fail "$variant: the spawn never read the pool state, so the change was never made"
    assert_refused_before_any_claim "$out" "$status" "$variant" "${REAL_SLOTS[0]}"
    assert_not_contains "$out" "holder: 123" "$variant: a holder the proof refuses was read as a lease"
  done
  pass "a state that fails the proof after the first reading - a number holder that stays or is undone at the next get, or a number created_at in another row - is refused before any claim"
}

# Main 2889 F1: the copy is classified from the rows of the document the proof read, never from another reading of the file.
# A change made after the first reading and undone before the second is in neither proved document, so the copy is passed
# over under the holder the proof read, and the changed holder is never recorded or reported.
test_a_change_that_no_strict_reading_sees_never_classifies_the_copy() {
  local id out status state
  id='pool-state-unseen-change'
  ID_FOR_STATE=$id
  make_real_pool_case state-unseen-change "$id" 3
  printf 'other holder work\n' >> "${REAL_SLOTS[0]}/README.md"
  real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the real treehouse did not lease the first copy"
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  cp "$state" "$CASE_DIR/valid-state.json"
  # shellcheck disable=SC2016 # jq expands $slot, which write_state_change passes with --arg.
  write_state_change change '(.worktrees[] | select(.path == $slot) | .lease_holder) = 123'
  install_state_read_hook "${REAL_SLOTS[0]}"
  out=$(FM_TEST_STATE_READ_AFTER="[ \"\$n\" != 1 ] || '$CASE_DIR/change'" \
    FM_TEST_STATE_READ_BEFORE="[ \"\$n\" != 2 ] || cp '$CASE_DIR/valid-state.json' '$state'" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$(cat "$CASE_DIR/state-reads")" -ge 2 ] || fail "the spawn read the pool state fewer than two times, so the change was never undone"
  expect_code 0 "$status" "a copy whose proved state shows another holder's lease should be passed over and the next clean copy used"$'\n'"$out"
  assert_contains "$out" "skipped: copy ${REAL_SLOTS[0]} already carries another holder's lease in the pool state (holder: other-task)" "the pass-over did not name the holder the proof read"
  assert_not_contains "$out" "holder: 123" "a holder that no proved reading held was reported"
  assert_grep "other-task" "$HOME_DIR/data/$id/skipped-copies.tsv" "the record did not name the holder the proof read"
  ! grep -Fq "123" "$HOME_DIR/data/$id/skipped-copies.tsv" || fail "the record names a holder that no proved reading held: $(cat "$HOME_DIR/data/$id/skipped-copies.tsv")"
  assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the next clean copy"
  pass "a change made after the first proved reading and undone before the second never classifies the copy: it is passed over under the holder the proof read"
}

# The control for the second reading: Treehouse leasing ANOTHER copy between the two readings rewrites the file, but the
# copy's own row, state and holder are the same in both proved documents, so the spawn goes on.
test_a_valid_change_to_another_row_between_the_two_readings_does_not_refuse() {
  local id out status state
  id='pool-state-other-row-lease'
  make_real_pool_case state-other-row-lease "$id" 3
  printf 'other holder work\n' >> "${REAL_SLOTS[0]}/README.md"
  real_th lease --path "${REAL_SLOTS[0]}" --lease-holder other-task >/dev/null 2>&1 || fail "the real treehouse did not lease the first copy"
  state=$(pool_state_file "${REAL_SLOTS[0]}")
  cat > "$CASE_DIR/lease-third" <<SH
#!/usr/bin/env bash
cd '$PROJECT_DIR' && TREEHOUSE_ROOT='$CASE_DIR/th-root' '$REAL_TREEHOUSE' lease --path '${REAL_SLOTS[2]}' --lease-holder concurrent-cli >/dev/null 2>&1
SH
  chmod +x "$CASE_DIR/lease-third"
  install_state_read_hook "${REAL_SLOTS[0]}"
  out=$(FM_TEST_STATE_READ_AFTER="[ \"\$n\" != 1 ] || '$CASE_DIR/lease-third'" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$(jq -r --arg p "${REAL_SLOTS[2]}" '.worktrees[] | select(.path == $p) | .lease_holder // ""' "$state")" = concurrent-cli ] || fail "the third copy was not leased between the readings, so the control shows nothing"
  expect_code 0 "$status" "a change to another copy's row between the two readings should not refuse"$'\n'"$out"
  assert_contains "$out" "(holder: other-task)" "the first copy was not passed over under its holder"
  assert_grep "worktree=${REAL_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the next clean copy"
  pass "a valid lease of another copy between the two readings leaves the classification as it was and the spawn goes on"
}

test_forged_already_leased_text_without_the_pool_state_refuses_the_spawn() {
  local id out status digest entry
  id='pool-skip-forged-text'
  make_real_pool_case forged-text "$id" 3
  printf 'work in progress\n' >> "${REAL_SLOTS[0]}/README.md"
  digest=$(own_digest "${REAL_SLOTS[0]}") || fail "the slot could not be read before the spawn"
  entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"

  out=$(FM_TEST_FORGE_LEASE=1 FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn went on because a failing command said 'already leased'"
  assert_contains "$out" "could not lease skipped copy ${REAL_SLOTS[0]} durably" "the refusal was not the lease refusal"
  assert_no_launch "$CASE_DIR/launch.log"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "another copy was requested on the strength of the text alone"
  assert_entry_unchanged "${REAL_SLOTS[0]}" "$entry" "the forged-text case"
  pass "text that says 'already leased', with no such lease in the pool state, does not skip the copy"
}

test_a_pool_of_only_refused_copies_refuses_once_and_names_each() {
  local id out status
  id='pool-skip-all-refused'
  make_real_pool_case all-refused "$id" 2
  make_recovered_lease "${REAL_SLOTS[0]}" "${REAL_SLOTS[1]}"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a worker was admitted although every copy carried another holder's lease"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_contains "$out" "aborting acquisition" "the spawn did not end with its acquisition refusal"
  assert_contains "$out" "copies left untouched" "the refusal did not list the untouched copies"
  assert_contains "$out" "  ${REAL_SLOTS[0]} (" "the refusal did not name the first refused copy with its reason"
  assert_contains "$out" "  ${REAL_SLOTS[1]} (" "the refusal did not name the second refused copy with its reason"
  assert_contains "$out" "already carries another holder's lease" "the refusal did not carry the reason"
  ! grep -Eq '^(lease|return)( |$)' "$SKIP_LOG" || fail "the spawn leased or returned a copy"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  pass "when every copy carries another holder's lease the spawn ends in one refusal that names each copy and its reason"
}

test_a_refused_copy_handed_out_twice_does_not_loop() {
  local id out status
  id='pool-skip-handed-twice'
  make_real_pool_case handed-twice "$id" 2
  make_recovered_lease "${REAL_SLOTS[0]}"
  # The first copy is handed out again by the second get: only the stub's hand-out list changes.
  printf '%s\n' "${REAL_SLOTS[0]}" "${REAL_SLOTS[0]}" "${REAL_SLOTS[1]}" > "$CASE_DIR/slots"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn went on"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_contains "$out" "the pane is still in a copy this spawn skipped" "the repeated copy was not recognised as skipped"
  [ "$(printf '%s\n' "$out" | grep -c "^skipped: copy ${REAL_SLOTS[0]}")" = 1 ] || fail "the same copy was passed over twice"
  pass "a refused copy handed out again is not taken, tried again or looped on, and the spawn ends within its bound"
}

# install_window_log <log>: the case's tmux answers new-window with a window id and logs each new-window and kill-window
# call and each interrupt key sent, so a case sees whether the spawn closed or interrupted the pane it created. Every other
# call goes to the fixture's tmux stub.
install_window_log() {
  local log=$1 inner="$FAKEBIN_DIR/tmux.fixture"
  mv "$FAKEBIN_DIR/tmux" "$inner" || fail "the tmux stub could not be wrapped"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  new-window) printf '%s\\n' "\$*" >> '$log'; printf '@41\\n'; exit 0 ;;
  kill-window) printf '%s\\n' "\$*" >> '$log'; exit 0 ;;
  send-keys) [ "\${!#}" != C-c ] || printf '%s\\n' "\$*" >> '$log' ;;
esac
exec '$inner' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
}

# An abort never closes the pane while it sits in a copy this spawn passed over: the other holder's copy stays as it is.
# Both aborts below leave the pane in a passed-over copy: every copy refused, and a refused copy handed out again. The
# control is an abort before any copy is taken, which must close the pane the spawn created.
test_a_passed_over_pane_is_not_closed_on_abort() {
  local id out status log

  id='pool-pane-kept-all-refused'
  make_real_pool_case pane-kept-all-refused "$id" 2
  make_recovered_lease "${REAL_SLOTS[0]}" "${REAL_SLOTS[1]}"
  log="$CASE_DIR/window.log"; : > "$log"
  install_window_log "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_TICK_SECONDS=60 BASH_ENV="${FM_TEST_PANE_BASH_ENV:-$SKIP_CLOCK}" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a worker was admitted although every copy carried another holder's lease"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_contains "$out" "aborting acquisition" "the all-refused spawn did not end with its acquisition refusal"
  grep -Fq 'new-window' "$log" || fail "the spawn created no pane, so its close could not be observed"
  ! grep -Fq 'kill-window' "$log" || fail "the all-refused spawn closed the pane in a passed-over copy: $(cat "$log")"
  # This stub tmux reports no foreground processes, so the abort interrupts the pane but cannot prove the get gone: it
  # must say so plainly and record the pane, never report a clean abort.
  grep -Fq 'send-keys -t @41 C-c' "$log" || fail "the all-refused spawn did not interrupt the pane it kept open: $(cat "$log")"
  assert_contains "$out" "acquisition pane @41" "the abort did not name the pane it kept open"
  assert_contains "$out" "is not settled" "an abort that could not read the pane's foreground was not reported as unsettled"
  assert_not_contains "$out" "notice: acquisition pane" "an abort that could not read the pane's foreground was reported as settled"
  grep -q $'^@41\tunobservable\t' "$HOME_DIR/data/$id/acquisition-pane.tsv" \
    || fail "the kept pane was not recorded as unobservable: $(cat "$HOME_DIR/data/$id/acquisition-pane.tsv" 2>&1)"
  grep -q $'\t@41$' "$HOME_DIR/data/$id/skipped-copies.tsv" || fail "the passed-over rows do not name the acquisition pane: $(cat "$HOME_DIR/data/$id/skipped-copies.tsv")"

  id='pool-pane-kept-handed-twice'
  make_real_pool_case pane-kept-handed-twice "$id" 2
  make_recovered_lease "${REAL_SLOTS[0]}"
  printf '%s\n' "${REAL_SLOTS[0]}" "${REAL_SLOTS[0]}" "${REAL_SLOTS[1]}" > "$CASE_DIR/slots"
  log="$CASE_DIR/window.log"; : > "$log"
  install_window_log "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_TICK_SECONDS=60 BASH_ENV="${FM_TEST_PANE_BASH_ENV:-$SKIP_CLOCK}" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn went on although the only copy in the pane was passed over"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_contains "$out" "the pane is still in a copy this spawn skipped" "the repeated copy was not recognised as passed over"
  grep -Fq 'new-window' "$log" || fail "the spawn created no pane, so its close could not be observed"
  ! grep -Fq 'kill-window' "$log" || fail "the spawn closed the pane while it sat in a passed-over copy: $(cat "$log")"

  id='pool-pane-closed-control'
  make_skip_case pane-closed-control "$id" 2
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  log="$CASE_DIR/window.log"; : > "$log"
  install_window_log "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the control spawn went on although origin cannot be fetched"
  assert_no_launch "$CASE_DIR/launch.log"
  grep -Fq 'kill-window -t @41' "$log" || fail "the control did not close the pane it created: $(cat "$log")"
  pass "an abort leaves a pane in a passed-over copy open, and an abort before any copy closes the pane it created"
}

# A governed refusal of the clean copy reached after a pass-over records that copy in the task's recovery meta. The pane
# rests there with a shell and no get in its foreground (the case's tmux names a tty and the case's ps lists one bash on it
# once the refusal is recorded), so the abort stays not clean, and its error names the recovery meta, not an unrecorded copy.
test_a_governed_refusal_after_a_pass_over_names_its_record() {
  local id out status log real_ps meta
  id='pool-pane-governed-refusal'
  make_real_pool_case pane-governed-refusal "$id" 2
  write_refusing_slot_owner "$CASE_DIR/publisher"
  git -C "$CASE_DIR/publisher" add scripts
  git -C "$CASE_DIR/publisher" -c user.name=T -c user.email=t@example.invalid commit -qm 'add slot owner'
  git -C "$CASE_DIR/publisher" push --quiet origin "$DEFAULT_BRANCH"
  make_recovered_lease "${REAL_SLOTS[0]}"
  log="$CASE_DIR/window.log"; : > "$log"
  install_window_log "$log"
  meta="$HOME_DIR/state/$id.meta"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.logged" || fail "the tmux stub could not be wrapped"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_tty}'*) if grep -qx 'recovery=slot-provision-refused' '$meta' 2>/dev/null; then printf '/dev/fmtestpty\\n'; exit 0; fi ;;
esac
exec '$FAKEBIN_DIR/tmux.logged' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  real_ps=$(command -v ps)
  cat > "$FAKEBIN_DIR/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-t fmtestpty -o pid=,pgid=,tpgid=,comm=') printf '4242 4242 4242 bash\\n'; exit 0 ;;
  '-p 4242 -o comm=') printf 'bash\\n'; exit 0 ;;
esac
exec '$real_ps' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/ps"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" --mode no-mistakes --yolo off --owned-path scripts)
  status=$?
  [ "$status" -ne 0 ] || fail "a worker was admitted although the provisioner refused the clean copy"$'\n'"$out"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_grep 'recovery=slot-provision-refused' "$meta" "the governed refusal was not recorded"
  assert_contains "$out" "it rests in ${REAL_SLOTS[1]}, which is not a copy this spawn passed over or leased in place: that copy is recorded by the governed refusal in $meta, not in skipped-copies.tsv; this abort is not clean" \
    "the abort did not name the governed refusal's record"
  grep -q $'^@41\tunrecorded-copy\t' "$HOME_DIR/data/$id/acquisition-pane.tsv" \
    || fail "the kept pane was not recorded with its outcome: $(cat "$HOME_DIR/data/$id/acquisition-pane.tsv" 2>&1)"
  ! grep -Fq 'kill-window' "$log" || fail "the spawn closed the pane after a pass-over: $(cat "$log")"
  pass "a governed refusal after a pass-over names its recovery record and the abort stays not clean"
}

# run_after_clean_copy_case <claim|base|hold>: a spawn whose pool hands it a copy with a recovered lease (passed over), then a
# clean copy that is accepted and reached. The spawn then refuses at one point after that copy was reached: the claim (the
# claim marker beside the copy is a directory), the base check (under local-only, the copy shows an origin the primary does
# not) or the hold (the copy's idle proof cannot be read, so it is leased in place). The pane must stay open in each case.
run_after_clean_copy_case() {
  local kind=$1 id mode=no-mistakes out status log real_git
  id="pool-pane-after-clean-$kind"
  make_real_pool_case "after-clean-$kind" "$id" 2
  make_recovered_lease "${REAL_SLOTS[0]}"
  log="$CASE_DIR/window.log"; : > "$log"
  install_window_log "$log"
  real_git=$(command -v git)
  case "$kind" in
    claim) mkdir "$(dirname "${REAL_SLOTS[1]}")/.fm-slot-owner" || fail "the claim marker could not be made" ;;
    base)
      mode=local-only
      cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case "\$*" in *"${REAL_SLOTS[1]}"*' config '*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
      chmod +x "$FAKEBIN_DIR/git"
      ;;
    hold)
      cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case "\$*" in *"${REAL_SLOTS[1]}"*' status '*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
      chmod +x "$FAKEBIN_DIR/git"
      ;;
  esac
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" BASH_ENV="${FM_TEST_PANE_BASH_ENV:-/dev/null}" run_spawn "$id" --mode "$mode" --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "$kind: a worker was admitted"
  assert_no_launch "$CASE_DIR/launch.log"
  [ "$(cat "$CASE_DIR/get-count")" = 2 ] || fail "$kind: treehouse get was not typed exactly twice"$'\n'"$out"
  assert_grep "${REAL_SLOTS[0]}" "$HOME_DIR/data/$id/skipped-copies.tsv" "$kind: the passed-over copy was not recorded"
  case "$kind" in
    claim) assert_contains "$out" "could not claim Treehouse pool slot" "$kind: the spawn did not refuse at the claim" ;;
    base) assert_contains "$out" "qualification disagree" "$kind: the spawn did not refuse at the base check" ;;
    hold) assert_grep "firstmate-skipped:$id" "$HOME_DIR/data/$id/skipped-copies.tsv" "$kind: the reached copy was not held" ;;
  esac
  grep -Fq 'new-window' "$log" || fail "$kind: the spawn created no pane, so its close could not be observed"
  ! grep -Fq 'kill-window' "$log" || fail "$kind: the spawn closed the pane after a clean copy was reached: $(cat "$log")"
}

# An abort after a clean copy was reached leaves the pane open too: the pass-over ends the pane's close for this spawn.
test_an_abort_after_a_clean_copy_is_reached_keeps_the_pane() {
  run_after_clean_copy_case claim
  run_after_clean_copy_case base
  run_after_clean_copy_case hold
  pass "an abort after a passed-over copy and a clean copy was reached leaves the pane open at the claim, the base check and the hold"
}

# The mutant restores the close: at the start of the abort cleanup it points the endpoint back at the window the spawn
# created, as an abort without the pass-over would. The case above must reject it.
test_the_after_clean_copy_case_rejects_a_restored_close() {
  local dir rc=0 out
  dir="$TMP_ROOT/after-clean-mutant"
  mkdir -p "$dir"
  cat > "$dir/mutant.sh" <<SH
set -T
__fm_restore_close() {
  case "\$BASH_COMMAND" in
    'local status=\$? skill_meta_tmp') SPAWN_TREEHOUSE_ABORT_TARGET=@41 ;;
  esac
  return 0
}
trap '__fm_restore_close' DEBUG
SH
  out=$(FM_TEST_PANE_BASH_ENV="$dir/mutant.sh" test_an_abort_after_a_clean_copy_is_reached_keeps_the_pane 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the after-clean-copy case passed with a spawn that restores the close"
  pass "the after-clean-copy case rejects a spawn that restores the close"
}

# CASE_NEEDS: every case in run order, with the Treehouse capabilities it uses. lease-path marks a case that runs
# `treehouse lease --path` itself or through the spawn (holding a copy in place); the rest run with get --lease alone.
# The after-clean-copy control reruns its case, so it needs what that case needs.
CASE_NEEDS=(
  'test_a_copy_with_a_recovered_lease_is_left_alone_and_a_clean_copy_is_taken get-lease'
  'test_a_copy_leased_by_another_holder_is_left_alone_and_a_clean_copy_is_taken get-lease lease-path'
  'test_a_foreign_claim_marker_beside_a_passed_over_copy_is_never_touched get-lease'
  'test_the_marker_case_rejects_a_direct_overwrite_and_restore_without_immutable_flags get-lease'
  'test_a_known_doubt_copy_with_no_lease_is_still_leased_to_this_task get-lease lease-path'
  'test_conflicting_pool_records_for_a_copy_refuse_the_whole_spawn get-lease'
  'test_an_unreadable_or_conflicting_pool_state_on_a_clean_copy_refuses_before_any_claim get-lease lease-path'
  'test_a_clean_unleased_copy_goes_on_to_the_claim_and_is_used get-lease'
  'test_a_row_with_leased_false_is_unleased_and_the_copy_is_used get-lease'
  'test_the_strict_state_proof_never_accepts_a_state_the_real_treehouse_cannot_read get-lease lease-path'
  'test_a_state_with_a_wrong_field_type_is_never_read_as_another_holders_lease get-lease lease-path'
  'test_a_clean_unleased_copy_in_a_state_that_fails_the_proof_is_never_claimed get-lease'
  'test_a_copy_with_no_readable_state_is_refused_unless_the_named_pool_excludes_it get-lease lease-path'
  'test_a_pool_slot_with_a_readable_state_is_classified_from_it_when_pool_dir_fails get-lease lease-path'
  'test_the_acceptance_assertion_rejects_a_crlf_only_change_of_the_state_entry get-lease'
  'test_the_acceptance_assertion_rejects_a_failed_git_read_with_changed_work get-lease'
  'test_the_acceptance_assertion_rejects_a_raw_index_change get-lease'
  'test_the_acceptance_assertion_rejects_a_write_that_restores_bytes_mode_and_mtime get-lease'
  'test_a_failed_raw_index_checksum_fails_the_acceptance_assertion get-lease'
  'test_the_acceptance_assertion_rejects_a_restored_rewrite_of_the_pool_state_file get-lease lease-path'
  'test_the_acceptance_assertion_rejects_a_restored_rewrite_of_a_loose_ref_file get-lease'
  'test_a_state_that_fails_the_proof_after_the_first_reading_refuses_before_any_claim get-lease lease-path'
  'test_a_change_that_no_strict_reading_sees_never_classifies_the_copy get-lease lease-path'
  'test_a_valid_change_to_another_row_between_the_two_readings_does_not_refuse get-lease lease-path'
  'test_forged_already_leased_text_without_the_pool_state_refuses_the_spawn get-lease'
  'test_a_pool_of_only_refused_copies_refuses_once_and_names_each get-lease'
  'test_a_refused_copy_handed_out_twice_does_not_loop get-lease'
  'test_a_passed_over_pane_is_not_closed_on_abort get-lease'
  'test_a_governed_refusal_after_a_pass_over_names_its_record get-lease'
  'test_an_abort_after_a_clean_copy_is_reached_keeps_the_pane get-lease lease-path'
  'test_the_after_clean_copy_case_rejects_a_restored_close get-lease lease-path'
)

# Run the selected cases, or every case, through fm_test_real_treehouse_case_plan: a case this host cannot run is left
# out, and the plan's first line is then the runner's gate skip naming it.
selected_needs=()
if [ "$#" -gt 0 ]; then
  for selected_test in "$@"; do
    found=
    for entry in "${CASE_NEEDS[@]}"; do
      [ "${entry%% *}" = "$selected_test" ] && { found=$entry; break; }
    done
    if [ -z "$found" ] || ! declare -F "$selected_test" >/dev/null 2>&1; then
      fail "unknown selected test: $selected_test"
    fi
    selected_needs+=("$found")
  done
else
  selected_needs=("${CASE_NEEDS[@]}")
fi
case_plan=$(fm_test_real_treehouse_case_plan "${selected_needs[@]}")
planned_cases=()
while IFS= read -r planned; do
  case "$planned" in
    skip:*) printf '%s\n' "$planned" ;;
    test_*) planned_cases+=("$planned") ;;
  esac
done <<EOF
$case_plan
EOF
for planned in "${planned_cases[@]+"${planned_cases[@]}"}"; do
  "$planned"
done
[ "$#" -eq 0 ] || exit 0

echo "# every fm-spawn-real-treehouse case this host can run passed"
