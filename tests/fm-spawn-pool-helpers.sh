#!/usr/bin/env bash
# Shared fixtures of tests/fm-spawn-pool-base-freshen.test.sh and tests/fm-spawn-real-treehouse.test.sh: a fake world with
# a project, its origin and one pool copy (make_case), the spawn driver over it, the skip transport whose pane enters the
# next copy at each `treehouse get`, the copy digest and its assertions, and the rm/mv log and claim-trace checks.
# The sourcing script sets TMP_ROOT and ROOT (tests/fixtures.sh) first.

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial >/dev/null
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main >/dev/null
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  local record=${1##*$'\n'}
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$record
EOF
  case "$CASE_DIR" in /*) ;; *) fail "the case directory '$CASE_DIR' is not absolute" ;; esac
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

# A copy the slot rules skip is left as found and another is requested; this fake world has no other
# copy, so the acquisition wait must reach its no-progress limit. The clock below advances SECONDS
# by a minute per one-second sleep, so that wait ends at once and the refusal is what the case reads.
SKIP_CLOCK="$ROOT/tests/skip-clock.sh"

run_spawn_skipping() {
  FM_TEST_TICK_SECONDS=60 BASH_ENV="$SKIP_CLOCK" run_spawn "$@"
}

write_refusing_slot_owner() { # <repository>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import json
import os
import sys
from pathlib import Path

Path(os.environ["FM_TEST_PROVISION_CALLED"]).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
print(json.dumps({"state": "BLOCKED", "reason": "fixture_provisioner_must_refuse"}))
raise SystemExit(2)
PY
}

# make_skip_case <name> <id> <slot-count>: make_case plus extra pool slots at the same commit and a
# tmux whose pane enters the next slot each time `treehouse get` is typed into it (an empty answer
# once the slots run out). The treehouse stub records its calls; FM_TEST_LEASE_RC makes `lease` fail.
# Sets SKIP_SLOTS (the slot paths in hand-out order) and SKIP_LOG.
make_skip_case() {
  local name=$1 id=$2 count=$3 rec n slot
  rec=$(make_case "$name" "$id")
  read_case_record "$rec"
  SKIP_SLOTS=("$POOL_DIR")
  for ((n = 2; n <= count; n++)); do
    slot="$CASE_DIR/pool$n"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$slot" "$INITIAL_SHA"
    SKIP_SLOTS+=("$slot")
  done
  make_skip_transport
}

# make_skip_transport: with SKIP_SLOTS, CASE_DIR and FAKEBIN_DIR set, a tmux whose pane enters the next slot each time
# `treehouse get` is typed into it (staying put once the slots run out), and a treehouse stub that logs its calls.
make_skip_transport() {
  local real_tmux
  printf '%s\n' "${SKIP_SLOTS[@]}" > "$CASE_DIR/slots"
  : > "$CASE_DIR/panepath"
  echo 0 > "$CASE_DIR/get-count"
  SKIP_LOG="$CASE_DIR/treehouse.log"
  : > "$SKIP_LOG"
  real_tmux="$FAKEBIN_DIR/tmux.real"
  mv "$FAKEBIN_DIR/tmux" "$real_tmux"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_path}'*) cat '$CASE_DIR/panepath'; exit 0 ;;
  *send-keys*'treehouse get'*)
    n=\$(( \$(cat '$CASE_DIR/get-count') + 1 ))
    echo "\$n" > '$CASE_DIR/get-count'
    # A case may act at the moment a get is typed (FM_TEST_AT_GET, run as shell text with the get's number in \$n).
    [ -z "\${FM_TEST_AT_GET:-}" ] || eval "\$FM_TEST_AT_GET"
    line=\$(sed -n "\${n}p" '$CASE_DIR/slots')
    # Once the slots run out the pane stays where it is, as a real pane does while a get finds no copy.
    [ -z "\$line" ] || printf '%s\\n' "\$line" > '$CASE_DIR/panepath'
    exit 0 ;;
esac
exec '$real_tmux' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  # Like the real one, the stub names a pool folder for `treehouse pool-dir`: an empty one no slot of this world lies under.
  mkdir -p "$CASE_DIR/treehouse-pool"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$SKIP_LOG'
case "\${1:-}" in
  lease) eval "\${FM_TEST_LEASE_PROBE:-:}" >>'$SKIP_LOG' 2>&1; exit "\${FM_TEST_LEASE_RC:-0}" ;;
  pool-dir) printf '%s\n' '$(CDPATH='' cd -- "$CASE_DIR/treehouse-pool" && pwd -P)'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# slot_digest <slot>: HEAD, its branch, EVERY ref of the repository (the refs are shared by every copy), the index, and
# every file outside .git (a regular file by sha256, a symlink by its target). It FAILS (nonzero) when any read fails,
# so a failed read can never compare equal to another.
slot_digest() {
  local slot=$1 head sym refs
  (
    set -o pipefail
    head=$(git -C "$slot" rev-parse HEAD) || exit 1
    printf 'HEAD %s\n' "$head"
    sym=$(git -C "$slot" symbolic-ref -q HEAD) || { [ "$?" = 1 ] || exit 1; sym=detached; }
    printf 'SYMBOLIC %s\n' "$sym"
    # A symbolic ref is recorded with its target, so a retarget between two refs at one commit is a difference.
    refs=$(git -C "$slot" for-each-ref --format='%(refname)%09%(objectname)%09%(symref)') || exit 1
    printf 'REFS\n%s\nENDREFS\n' "$refs"
    git -C "$slot" ls-files -s --debug || exit 1
    cd "$slot" || exit 1
    # shellcheck disable=SC2016 # The inner sh expands its own $1.
    find . -path ./.git -prune -o \( -type f -o -type l \) -print0 | LC_ALL=C sort -z |
      xargs -0 -n1 sh -c 'if [ -L "$1" ]; then printf "LINK %s -> %s\n" "$1" "$(readlink "$1")"; else shasum -a 256 -- "$1"; fi' _
  ) 2>&1
}

# The refs a spawn may change while it works in ANOTHER copy: origin's default tracking ref and origin/HEAD (Main 003).
# New refs (the task's own branch, anchors) may appear. Nothing else that existed before may differ or vanish.

# second_copy_refs <id> [governed]: the "<ref>=<old>><new>" pairs that a spawn which skipped one copy and then MOVED another
# copy of the same repository legitimately writes into the shared ref set: origin's default tracking ref and origin/HEAD
# at origin's tip (recorded after the move succeeded) and, for a governed task, its branch and the preservation anchor
# of the detached copy it started from. The skipped copy's own digest may differ by exactly these and nothing else.
second_copy_refs() {
  local id=$1 tip
  tip=$(git -C "$CASE_DIR/origin.git" rev-parse --verify "refs/heads/$DEFAULT_BRANCH") || fail "origin's tip cannot be read"
  printf '%s\n' "refs/remotes/origin/$DEFAULT_BRANCH=absent>$tip" "refs/remotes/origin/HEAD=absent>$tip@refs/remotes/origin/$DEFAULT_BRANCH"
  if [ "${2:-}" = governed ]; then
    printf '%s\n' "refs/heads/fm/$id=absent>$tip" "refs/fm/anchor/$id-$(git -C "$PROJECT_DIR" rev-parse --short "$INITIAL_SHA")=absent>$INITIAL_SHA"
  fi
}

# assert_digest_unchanged <slot> <before-digest> <message>: the copy reads back as it did, and every ref that existed
# still has the same value, but for the two allowed ones.
# assert_digest_unchanged <slot> <before-digest> <label> [<ref>=<old>><new>...]: the digest now equals <before-digest> in HEAD,
# the branch, the index and every file, and the SET of refs, each with its symbolic target, is identical in both directions
# (a ref that is new, gone, moved or retargeted fails). The only exception is a ref named as <ref>=<old>><new> ("absent"
# for a ref that did not exist), which must go from exactly <old> to exactly <new>.
assert_digest_unchanged() {
  local slot=$1 before=$2 label=$3 after b_plain a_plain b_refs a_refs why
  shift 3
  after=$(slot_digest "$slot") || fail "$label (the slot could not be read)"
  b_plain=$(printf '%s\n' "$before" | awk '/^REFS$/{skip=1} !skip{print} /^ENDREFS$/{skip=0}')
  a_plain=$(printf '%s\n' "$after" | awk '/^REFS$/{skip=1} !skip{print} /^ENDREFS$/{skip=0}')
  [ "$b_plain" = "$a_plain" ] || fail "$label"
  b_refs=$(printf '%s\n' "$before" | awk '/^REFS$/{on=1;next} /^ENDREFS$/{on=0} on')
  a_refs=$(printf '%s\n' "$after" | awk '/^REFS$/{on=1;next} /^ENDREFS$/{on=0} on')
  why=$(python3 - "$b_refs" "$a_refs" "$@" <<'PY'
import sys
def parse(text):
    out = {}
    for line in text.splitlines():
        if line.strip():
            name, sha, target = (line.split("\t") + ["", ""])[:3]
            out[name] = sha + ("@" + target if target else "")
    return out
before, after = parse(sys.argv[1]), parse(sys.argv[2])
# A named change is "<ref>=<old>><new>" ("absent" for a ref that did not exist): the OLD value must be what the digest held
# and the NEW value must be exactly the one named. Anything else, or any unnamed difference, is a failure.
allowed = {}
for spec in sys.argv[3:]:
    name, _, rest = spec.partition("=")
    old, _, new = rest.partition(">")
    allowed[name] = (old, new)
bad = []
for name in sorted(set(before) | set(after)):
    old, new = before.get(name, "absent"), after.get(name, "absent")
    if old == new:
        continue
    if name in allowed and allowed[name] == (old, new):
        continue
    bad.append("%s: %s -> %s" % (name, old, new))
print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
  ) || fail "$label (the ref set changed: $why)"
}

# assert_no_launch <launch-log>: no harness was launched (the fake launcher logs each launch).
assert_no_launch() {
  [ ! -s "$1" ] || fail "a harness was launched: $(cat "$1")"
}

install_mutation_log() { # <log>: rm and mv stand-ins in the case's fakebin that log their arguments, then run the real tool
  local tool real
  for tool in rm mv; do
    real=$(command -v "$tool") || fail "no $tool"
    cat > "$FAKEBIN_DIR/$tool" <<SH
#!/usr/bin/env bash
printf '$tool %s\\n' "\$*" >> '$1'
exec '$real' "\$@"
SH
    chmod +x "$FAKEBIN_DIR/$tool"
  done
}

# assert_no_mutation_logged <log> <folder> <label>: no logged rm or mv call names the slot folder.
assert_no_mutation_logged() {
  ! grep -Fq -- "$2" "$1" || fail "$3: an attempt to change the slot folder was logged: $(grep -F -- "$2" "$1" | head -3)"
}

# assert_claim_trace_clear <trace> <slot> <label>: no traced claim or release names <slot>.
assert_claim_trace_clear() {
  ! grep -Fq -- "$2" "$1" || fail "$3: a claim or release naming the passed-over copy was traced: $(grep -F -- "$2" "$1" | head -3)"
}

# immutable_on <path>...: make each path immutable where the host can (chflags uchg). Prints the reason and returns 1 when it cannot.
immutable_on() {
  command -v chflags >/dev/null 2>&1 || { echo "no chflags on this host"; return 1; }
  local probe="$CASE_DIR/immutable-probe"
  : > "$probe"
  chflags uchg "$probe" 2>/dev/null || { rm -f "$probe" 2>/dev/null; echo "chflags uchg is refused on this filesystem"; return 1; }
  chflags nouchg "$probe" 2>/dev/null
  rm -f "$probe"
  chflags uchg "$@" 2>/dev/null || { echo "chflags uchg failed on the marker or its folder"; return 1; }
}
