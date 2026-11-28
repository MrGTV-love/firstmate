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
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8G59TERS71VSSY5JN2K95T9/tests/fixtures.sh"
fm_test_require_real_treehouse get-lease

TMP_ROOT=$(fm_test_tmproot fm-spawn-real-treehouse)
# Every spawn in this file runs with its detached home-summary refresh stubbed (tests/fixtures.sh fm_test_spawn_script).
export FM_TEST_STUB_SUMMARY_REFRESH=1
# shellcheck source=tests/fm-spawn-pool-helpers.sh
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8G59TERS71VSSY5JN2K95T9/tests/fm-spawn-pool-helpers.sh"

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

# ---- evidence driver: one slot with a recovered lease, three clean slots ----
show() { printf '\n===== %s =====\n' "$1"; }
id='evidence-recovered-slot'
make_real_pool_case evidence "$id" 4
make_recovered_lease "${REAL_SLOTS[0]}"
show "pool state BEFORE spawn (real treehouse, one row per slot: path, leased, lease_holder)"
jq -r '.worktrees[] | [.path, (.leased|tostring), (.lease_holder // "-")] | @tsv' "$(pool_state_file "${REAL_SLOTS[0]}")"
digest_before=$(own_digest "${REAL_SLOTS[0]}")
entry="$CASE_DIR/entry.before"; save_entry "${REAL_SLOTS[0]}" "$entry"
beside=$(slot_neighbourhood "${REAL_SLOTS[0]}")
show "pool hand-out order typed by the stub pane (refused slot first)"
printf '%s\n' "${SKIP_SLOTS[@]}"
show "\$ bin/fm-spawn.sh $id <project> --mode no-mistakes --yolo off   (output)"
out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
printf '%s\n' "$out"
show "exit status"; echo "$status"
show "state/$id.meta worktree line"; grep '^worktree=' "$HOME_DIR/state/$id.meta"
show "data/$id/skipped-copies.tsv"; cat "$HOME_DIR/data/$id/skipped-copies.tsv"
show "pool state AFTER spawn"
jq -r '.worktrees[] | [.path, (.leased|tostring), (.lease_holder // "-")] | @tsv' "$(pool_state_file "${REAL_SLOTS[0]}")"
show "refused slot unchanged? (worktree digest, raw state entry bytes, slot folder listing)"
[ "$(own_digest "${REAL_SLOTS[0]}")" = "$digest_before" ] && echo "worktree digest: identical" || echo "worktree digest: CHANGED"
state_entry "${REAL_SLOTS[0]}" > "$entry.after"; cmp -s "$entry" "$entry.after" && echo "state entry bytes: identical" || echo "state entry bytes: CHANGED"
[ "$(slot_neighbourhood "${REAL_SLOTS[0]}")" = "$beside" ] && echo "slot folder: identical" || echo "slot folder: CHANGED"
show "treehouse calls the spawn made (stand-in log over real binary)"; cat "$SKIP_LOG"
