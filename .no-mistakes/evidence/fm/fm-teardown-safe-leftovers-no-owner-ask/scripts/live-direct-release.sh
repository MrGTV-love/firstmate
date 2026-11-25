#!/usr/bin/env bash
# live-direct-release.sh <worktree> <out-dir> [shape...]
# Drives the real bin/fm-teardown.sh (attended, no --force) on disposable fixtures built by
# tests/fm-teardown-helpers.sh: a scratch home, a scratch project, a pool slot leased from the
# REAL treehouse binary in a scratch TREEHOUSE_ROOT under the case dir, a Vernant creation lock
# naming a real exited pid (or a real live sleep), the REAL ps, the REAL lsof, and the REAL git
# behind a wrapper that only logs worktree argv (and, for the late shapes, writes one file into
# the copy at the `git worktree unlock` call, i.e. after the preserve and before the final proof).
# The Vernant closeout driver is made unavailable (exit 127 route): the foreign copy's driver
# script is removed from the slot, the own copy's interpreter path points nowhere.
set -u
W=$1 OUT=$2
shift 2
SHAPES=("$@")
[ "${#SHAPES[@]}" -gt 0 ] || SHAPES=(foreign-claude-only foreign-forced-cache own-retained own-late-claude foreign-late-change foreign-forced-late-cache own-new-late-selected own-live-launcher)
cd "$W" || exit 2
# shellcheck disable=SC1091
. "$W/tests/fm-teardown-helpers.sh"
export FM_TEST_REAL_TREEHOUSE
FM_TEST_REAL_TREEHOUSE=$(command -v treehouse) || { echo "no treehouse on PATH" >&2; exit 2; }
mkdir -p "$OUT"

# One git wrapper: log every worktree argv; on the first `worktree unlock`, run mutate.sh once.
live_git_wrapper() {  # <case>
  local c=$1
  cat > "$c/fakebin/git" <<SH
#!/usr/bin/env bash
args=("\$@")
for a in "\$@"; do
  if [ "\$a" = worktree ]; then printf '%s\n' "\$*" >> "$c/git-worktree.log"; break; fi
done
case " \$* " in
  *" worktree unlock "*)
    if [ -f "$c/mutate.sh" ] && [ ! -e "$c/mutate.done" ]; then : > "$c/mutate.done"; bash "$c/mutate.sh"; fi ;;
esac
exec "\${REAL_GIT_FOR_TEST:?}" "\${args[@]}"
SH
  chmod +x "$c/fakebin/git"
}

ignore_and_fill() {  # <copy> : ignored .claude, .opencode, top-level .cache and notes/ files
  local copy=$1 exclude
  exclude=$(git -C "$copy" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' '/.claude/' '/.opencode/' '/.cache/' '/notes/' >> "$exclude"
  mkdir -p "$copy/.claude/channel-outbox" "$copy/.claude/bug-evidence" "$copy/.opencode/state" "$copy/.cache"
  printf 'one\n' > "$copy/.claude/channel-outbox/a.jsonl"
  printf 'closeout record\n' > "$copy/.claude/bug-evidence/record.json"
  printf 'evidence\n' > "$copy/.opencode/state/log.json"
  printf 'run v1\n' > "$copy/.cache/run.bin"
}

snapshot() {  # <phase> <dir>
  local phase=$1 d=$2
  {
    echo "## git worktree list --porcelain ($phase)"
    git -C "$CASE/project" worktree list --porcelain 2>&1
    echo "## copy files ($phase)"
    if [ -d "$COPY" ]; then (cd "$COPY" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -c1-16)" "$f"; done); else echo "(copy absent)"; fi
    echo "## treehouse status --json ($phase)"
    (cd "$CASE/project" && TREEHOUSE_ROOT="$TREEHOUSE_ROOT" treehouse status --json </dev/null 2>&1) | jq -c '[.[] | {name, status, lease_holder}]' 2>&1
  } > "$d/$phase.state.txt"
}

preserve_report() {  # <dir>
  local d=$1 p
  {
    echo "## every preserve under data/task-x1/nested-copy-preserved"
    for p in "$CASE"/data/task-x1/nested-copy-preserved/*; do
      [ -d "$p" ] || continue
      echo "### ${p##*/}"
      (cd "$p" && find . -type f | LC_ALL=C sort)
      if [ -f "$p/meta/SHA256SUMS" ]; then
        echo "--- meta/SHA256SUMS"; cat "$p/meta/SHA256SUMS"
        echo "--- independent check: shasum -a 256 -c over files/ against meta/SHA256SUMS"
        (cd "$p/files" && shasum -a 256 -c "../meta/SHA256SUMS" 2>&1)
      fi
    done
  } > "$d/preserve.txt" 2>&1
}

find_bytes() {  # <text> : list preserve files holding exactly <text>
  grep -rlxF "$1" "$CASE/data/task-x1/nested-copy-preserved" 2>/dev/null | sed "s#^$CASE/data/task-x1/nested-copy-preserved/##" | paste -sd, -
}

summary=$OUT/summary.txt
: > "$summary"
for shape in "${SHAPES[@]}"; do
  d=$OUT/$shape
  rm -rf "$d"; mkdir -p "$d"
  live=
  dead_launcher_pid
  pid=$FOREIGN_DEAD_PID
  case "$shape" in
    foreign-*) make_foreign_copy_case "live-$shape" "$pid" ;;
    *) make_own_locked_copy_case "live-$shape" enclosing "$pid" ;;
  esac
  CASE=$FOREIGN_CASE COPY=$FOREIGN_COPY
  export TREEHOUSE_ROOT=$CASE/realroot
  rm -f "$CASE/fakebin/lsof"              # the real lsof scans the real process table
  live_git_wrapper "$CASE"
  case "$shape" in
    foreign-*) rm -f "$FOREIGN_SLOT/scripts/git-stability/closeout_pr.py" ;;  # driver unavailable
    *) rm -f "$CASE/vernant-python" ;;                                         # interpreter unavailable
  esac
  case "$shape" in
    own-new-late-selected)
      # Only the .claude and .opencode trees: nothing selected at #380's dispose, so no own preserve.
      ignore_and_fill "$COPY"; rm -rf "$COPY/.cache"
      printf 'printf "late selected\\n" > %q\n' "$COPY/notes/late.dat" > "$CASE/mutate.sh"
      printf 'mkdir -p %q\n' "$COPY/notes" | cat - "$CASE/mutate.sh" > "$CASE/mutate.tmp" && mv "$CASE/mutate.tmp" "$CASE/mutate.sh"
      ;;
    foreign-claude-only|foreign-late-change)
      # Only the .claude and .opencode trees: a non-forced close holds a foreign copy whose other
      # ignored files exist nowhere else (base rule), so these shapes carry only the two trees.
      ignore_and_fill "$COPY"; rm -rf "$COPY/.cache"
      ;;
    *)
      ignore_and_fill "$COPY"
      mkdir -p "$COPY/notes"; printf 'only here\n' > "$COPY/notes/unique.dat"
      ;;
  esac
  FOREIGN_TEARDOWN_ARGS=()
  case "$shape" in foreign-forced-*) FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)") ;; esac
  case "$shape" in
    own-late-claude)
      printf 'printf "late claude\\n" > %q\n' "$COPY/.claude/channel-outbox/c.jsonl" > "$CASE/mutate.sh" ;;
    foreign-late-change)
      printf 'printf "one v2\\n" > %q; printf "late claude\\n" > %q\n' "$COPY/.claude/channel-outbox/a.jsonl" "$COPY/.claude/channel-outbox/c.jsonl" > "$CASE/mutate.sh" ;;
    foreign-forced-late-cache)
      printf 'printf "run v2\\n" > %q\n' "$COPY/.cache/run.bin" > "$CASE/mutate.sh" ;;
    own-live-launcher)
      sleep 900 &
      live=$!
      git -C "$CASE/project" worktree unlock "$COPY"
      git -C "$CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$live launcher=$live" "$COPY"
      pid=$live
      ;;
  esac
  lock_before=$(git -C "$CASE/project" worktree list --porcelain | grep -A5 -F "worktree $COPY" | grep '^locked' || true)
  snapshot before "$d"
  [ ! -f "$CASE/mutate.sh" ] || cp "$CASE/mutate.sh" "$d/mutate.sh"
  printf 'command: run_foreign_teardown rc TREEHOUSE_ROOT=%s  (=> %s task-x1 %s, scratch FM_HOME %s)\n' "$TREEHOUSE_ROOT" "$TEARDOWN" "${FOREIGN_TEARDOWN_ARGS[*]:-(no flags)}" "$CASE/home" > "$d/command.txt"
  rc=0
  run_foreign_teardown rc "TREEHOUSE_ROOT=$TREEHOUSE_ROOT"
  cp "$CASE/stdout" "$d/teardown.stdout"; cp "$CASE/stderr" "$d/teardown.stderr"; echo "exit $rc" > "$d/teardown.exit"
  cp "$CASE/git-worktree.log" "$d/git-worktree.log" 2>/dev/null || : > "$d/git-worktree.log"
  cp "$CASE/treehouse.calls.log" "$d/treehouse.calls.log" 2>/dev/null || true
  snapshot after "$d"
  preserve_report "$d"
  lock_after=$(git -C "$CASE/project" worktree list --porcelain | grep -A5 -F "worktree $COPY" | grep '^locked' || true)
  copy_state=gone; [ ! -e "$COPY/.git" ] || copy_state=kept
  force=no; ! grep -Eq -- '(^| )(-f|--force)( |$)' "$d/git-worktree.log" || force=YES
  unlocks=$(grep -c 'worktree unlock' "$d/git-worktree.log" || true)
  removes=$(grep -c 'worktree remove' "$d/git-worktree.log" || true)
  released=no; ! grep -q "released creation lock" "$d/teardown.stderr" || released=yes
  owner_cmd=no; ! grep -Eq 'run: *git worktree unlock|fm-captain-hold.sh hold' "$d/teardown.stderr" || owner_cmd=YES
  refused=$(grep -m1 -E '^REFUSED|refus' "$d/teardown.stderr" | cut -c1-400)
  {
    echo "=== $shape"
    echo "exit=$rc copy=$copy_state released-line=$released owner-command-printed=$owner_cmd force-used=$force unlock-calls=$unlocks remove-calls=$removes"
    echo "lock-before=${lock_before:-none}"
    echo "lock-after=${lock_after:-none}"
    echo "args=${FOREIGN_TEARDOWN_ARGS[*]:-none}"
    echo "preserved 'one' (.claude/channel-outbox/a.jsonl): $(find_bytes one)"
    echo "preserved 'one v2' (late a.jsonl change): $(find_bytes 'one v2')"
    echo "preserved 'closeout record' (.claude/bug-evidence): $(find_bytes 'closeout record')"
    echo "preserved 'evidence' (.opencode/state/log.json): $(find_bytes evidence)"
    echo "preserved 'run v1' (.cache/run.bin): $(find_bytes 'run v1')"
    echo "preserved 'run v2' (late .cache change): $(find_bytes 'run v2')"
    echo "preserved 'late claude' (late .claude file): $(find_bytes 'late claude')"
    echo "preserved 'only here' (notes/unique.dat): $(find_bytes 'only here')"
    echo "preserved 'late selected' (notes/late.dat): $(find_bytes 'late selected')"
    if [ "$copy_state" = kept ]; then
      echo "late files still in copy: $( (cd "$COPY" && ls .claude/channel-outbox/c.jsonl notes/late.dat 2>/dev/null) | paste -sd, -)"
    fi
    echo "release/refusal line: $(grep -m1 'released creation lock' "$d/teardown.stderr" | cut -c1-300)"
    echo "first refusal text: ${refused:-none}"
    if [ -n "$live" ]; then
      echo "live launcher $live still alive after teardown: $(kill -0 "$live" 2>/dev/null && echo yes || echo no)"
    fi
  } | tee -a "$summary"
  if [ -n "$live" ]; then kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; fi
done
