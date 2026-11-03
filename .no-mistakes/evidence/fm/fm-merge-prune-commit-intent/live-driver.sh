#!/usr/bin/env bash
# Live driver for the CommitIntent allowance of bin/fm-merge-prune.sh.
#
# Drives the REAL bin/fm-merge-prune.sh, bin/fm-merge-prune-lib.sh and the REAL
# bin/fm-teardown.sh of a given source tree against a disposable fake pool built
# by the suite's own world builder (make_e2e_world). Only the outside world is
# stubbed (gh, gh-axi, treehouse, no-mistakes, docker), exactly as the suite's
# section 5 does. Real ~/.treehouse and real FM_HOME are never touched.
#
# The treehouse `return` stand-in is changed in one way from the suite's: it
# does NOT delete ignored files (`git clean -ffdq`, no -x), the way the real
# tool left .claude/commit-intent.json in Vernant slot 252 after return.
#
# Usage: live-driver.sh <worktree-with-tests> <source-tree-under-test> <label>
set -u
SUITE_TREE=$1 SRC=$2 LABEL=$3
SUITE="$SUITE_TREE/tests/fm-merge-prune.test.sh"
HELP=$(mktemp -t fm-live-helpers.XXXXXX)
end=$(( $(grep -n '^ALL_TESTS=(' "$SUITE" | cut -d: -f1) - 1 ))
sed -n "1,${end}p" "$SUITE" | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$SUITE_TREE/tests/lib.sh\"#" > "$HELP"
# shellcheck disable=SC1090
. "$HELP"
rm -f "$HELP"
# Point the product under test at <source-tree-under-test>.
ROOT=$SRC
BIN_DIR=$SRC/bin
echo "== $LABEL: product under test: $BIN_DIR ($(git -C "$SUITE_TREE" rev-parse --short HEAD 2>/dev/null) suite helpers)"
echo "== python3: $(command -v python3) $(python3 --version 2>&1)"

keep_ignored_on_return() {
  # The real treehouse return keeps ignored files (slot 252 kept the intent).
  sed -i '' 's/git -C "\$wt" clean -ffdxq/git -C "$wt" clean -ffdq/' "$W/bin/treehouse"
}

world() {  # <recorded branch or ->
  make_e2e_world
  keep_ignored_on_return
  [ "${1:-fm/t1}" = - ] || printf 'branch=%s\n' "${1:-fm/t1}" >> "$STATE/t1.meta"
}

show() {  # <scenario>
  local st
  echo "-- result:"
  if [ -e "$COPY" ]; then echo "   copy: STILL ON DISK ($COPY)"; else echo "   copy: GONE"; fi
  echo "   treehouse calls: $(tr '\n' ';' < "$W/th.log")"
  echo "   destroy calls: $(destroy_calls)   wakes: $(wake_count)"
  st=$(rec_field t1 state)
  echo "   prune record state: ${st:-<no record>}   branch kept: $(rec_field t1 branch)"
  [ ! -s "$STATE/.wake-queue" ] || { echo "   wake queue:"; sed 's/^/     /' "$STATE/.wake-queue"; }
  [ ! -f "$DATA/t1/merge-prune.log" ] || { echo "   merge-prune.log:"; sed 's/^/     /' "$DATA/t1/merge-prune.log"; }
  if [ -e "$COPY" ]; then echo "   ignored files left in copy:"; git -C "$COPY" status --porcelain --ignored | sed 's/^/     /'; fi
}

run_once() {
  prune_real arm t1 >/dev/null 2>&1
  prune_real run t1 --now >/dev/null 2>&1
}

hdr() { echo; echo "################ $LABEL :: $1"; }

# L1 incident replay: returned slot, clean and detached at main, only an expired valid intent.
hdr "L1 returned slot holding only an EXPIRED valid CommitIntent (slot 252 shape), merge path arm --run"
world other/branch
put_intent "$COPY" 2000-01-01T00:00:00+00:00 other/branch
echo "   intent: $(cat "$COPY/.claude/commit-intent.json")"
prune_real arm t1 --run >/dev/null 2>&1
fm_test_wait_until --progress-file "$DATA/t1/merge-prune.log" -- grep -Eq 'reaped|retained|kept' "$DATA/t1/merge-prune.log" || true
sleep 2
show

# L2 unexpired intent naming the task's branch, returned slot (task record deleted by real teardown).
hdr "L2 returned slot holding an UNEXPIRED intent naming the task's branch fm/t1"
world fm/t1
put_intent "$COPY" 2999-01-01T00:00:00+00:00 fm/t1
run_once
echo "   task record after teardown: $([ -e "$STATE/t1.meta" ] && echo present || echo deleted)"
show

# L3 adversarial: unexpired, naming another branch.
hdr "L3 ADVERSARIAL unexpired intent naming another branch (fm/t1-extra)"
world fm/t1
put_intent "$COPY" 2999-01-01T00:00:00+00:00 fm/t1-extra
run_once
show

# L4 adversarial: expired and naming the task branch but not a CommitIntent.
hdr "L4 ADVERSARIAL expired, names task branch, artifacttype ReviewIntent"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00+00:00 fm/t1 '.artifacttype = "ReviewIntent"'
run_once
show

# L5 adversarial: expiry with no timezone.
hdr "L5 ADVERSARIAL expiry with no timezone (2000-01-01T00:00:00), names task branch"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00 fm/t1
run_once
show

# L6 adversarial: owned_paths escapes the repo.
hdr "L6 ADVERSARIAL owned_paths [\"../x\"], expired"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00+00:00 fm/t1 '.owned_paths = ["../x"]'
run_once
show

# L7 adversarial: lookalike path holding a spent payload.
hdr "L7 ADVERSARIAL lookalike .claude/commit-intent.json.bak with a spent payload"
world fm/t1
mkdir -p "$COPY/.claude"
intent_json 2000-01-01T00:00:00+00:00 fm/t1 > "$COPY/.claude/commit-intent.json.bak"
run_once
show

# L8 adversarial: spent intent beside other unique ignored data.
hdr "L8 ADVERSARIAL spent intent beside .claude/private/x"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00+00:00 fm/t1
mkdir -p "$COPY/.claude/private"; printf 'secret\n' > "$COPY/.claude/private/x"
run_once
show

# L9 fallback: real teardown refuses (closeout-driver false positive); fallback decides.
hdr "L9 fallback after a teardown refusal, only an EXPIRED valid intent"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00+00:00 other/branch
touch "$W/refuse"
run_once
show

# L10 adversarial: python3 older than 3.11 on PATH.
hdr "L10 ADVERSARIAL prune's python3 reports 3.10: expired valid intent"
world fm/t1
put_intent "$COPY" 2000-01-01T00:00:00+00:00 other/branch
real_py=$(command -v python3)
cat > "$W/bin/python3" <<SH
#!/usr/bin/env bash
# Answers the version probe as 3.10; otherwise runs the real interpreter.
for a in "\$@"; do case "\$a" in *version_info*) exit 3 ;; esac; done
exec "$real_py" "\$@"
SH
chmod +x "$W/bin/python3"
run_once
show
echo
echo "== $LABEL done"
