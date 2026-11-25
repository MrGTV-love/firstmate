#!/bin/bash
# usage: r8-late-foreign.sh <worktree> <evidence-dir>
# R8-1 adversarial, foreign kind, through the real library's
# teardown_dead_launcher_release (only the lock read, launcher, landing and
# holder probes are stood in; the preserve, final proof, unlock and remove are
# the product's own, with git unlock/remove recorded). An earlier preserve holds
# the old bytes; .cache/run.bin and .claude/channel-outbox/a.jsonl change just
# before the unlock. Expect: released, the NEW bytes preserved with SHA256SUMS
# lines, and the earlier preserve kept aside with the OLD bytes.
WT=$1 EV=$2
cd "$WT" || exit 2
tmpcase=$(mktemp -d /private/tmp/fm-r8-late.XXXXXX)
cat > "$tmpcase/case.sh" <<'CASE'
test_r8_late_foreign_change_is_preserved_again() {
  local body=$TMP_ROOT/r8-body.sh
  cat > "$body" <<'BODY'
teardown_copy_lock_file() { TEARDOWN_FOREIGN_LOCK='vernant-session-active owner=launcher:4194305 launcher=4194305'; TEARDOWN_FOREIGN_LOCK_FILE=/virtual/lock; TEARDOWN_FOREIGN_LOCK_SHA=s; return 0; }
teardown_launcher_gone() { return 0; }
teardown_launcher_live_since() { return 1; }
teardown_lock_is_first_seen() {
  printf 'run-v2\n' > "$copy/.cache/run.bin"
  printf 'two\n' > "$copy/.claude/channel-outbox/a.jsonl"
  return 0
}
teardown_landed() { teardown_admit "$1" landed "$(git -C "$1" rev-parse HEAD)" "refs/heads/main $(git -C "$1" rev-parse main)"; return 0; }
teardown_copy_git_protects() { return 1; }
teardown_admitted_bundles_current() { return 0; }
teardown_foreign_copy_unowned() { return 0; }
teardown_copy_holder_free() { return 0; }
fm_lock_path_mtime() { printf '1\n'; }
TEARDOWN_CLOSEOUT_PROOF=fixture META="$R5_BASE/task.meta"
r5_repo foreign-late
printf '/.claude/\n/.opencode/\n/notes/\n/.cache/\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore && git -C "$repo" commit -qm initial
git -C "$repo" worktree add -q -b f-late "$copy" main
mkdir -p "$copy/.claude/channel-outbox" "$copy/.cache" "$copy/notes"
printf 'run\n' > "$copy/.cache/run.bin"
printf 'one\n' > "$copy/.claude/channel-outbox/a.jsonl"
printf 'only here\n' > "$copy/notes/unique.dat"
r5_reset "$copy"
teardown_preserve_ignored "$copy" 2>/dev/null; echo "earlier-preserve rc=$?"
dest=$(r5_dest "$copy")
echo "earlier .cache=$(cat "$dest/files/.cache/run.bin" 2>/dev/null || echo absent)"
head=$(git -C "$copy" rev-parse HEAD)
: > "$R5_BASE/git"
git() { case " $* " in *' worktree unlock '*|*' worktree remove '*) printf '%s ' "$4" >> "$R5_BASE/git"; return 0 ;; esac; command git "$@"; }
rc=0; teardown_dead_launcher_release "$repo" "$copy" "$head" foreign 2>"$R5_BASE/release.err" || rc=$?
unset -f git
echo "release=$rc why=${TEARDOWN_RELEASE_WHY:-none} git=$(cat "$R5_BASE/git")"
for f in .cache/run.bin .claude/channel-outbox/a.jsonl notes/unique.dat; do
  sum=$(teardown_ignored_sha256 "$copy/$f")
  ok=no
  if [ "$(teardown_ignored_sha256 "$dest/files/$f" 2>/dev/null)" = "$sum" ] && grep -qxF "$sum  $f" "$dest/meta/SHA256SUMS"; then ok=yes; fi
  echo "current $f bytes=$(cat "$copy/$f") preserved-and-summed=$ok"
done
for a in "$dest".aside-* "$(dirname "$dest")"/.aside-*; do
  [ -d "$a" ] || continue
  echo "aside $(basename "$a") .cache=$(cat "$a/files/.cache/run.bin" 2>/dev/null || echo absent) a.jsonl=$(cat "$a/files/.claude/channel-outbox/a.jsonl" 2>/dev/null || echo absent)"
done
find "$(dirname "$dest")" -maxdepth 1 | sed "s|$(dirname "$dest")|<nested-copy-preserved>|"
BODY
  r5_harness r8-late "$body"
  cat "$R5_OUT"
  echo "--- stderr tail"; tail -5 "$R5_ERR"
  r5_expect 'release=0 why=none git=unlock remove ' 'r8-late: the foreign direct release did not complete'
  r5_expect 'current .cache/run.bin bytes=run-v2 preserved-and-summed=yes' 'r8-late: the changed .cache bytes were not preserved again'
  r5_expect 'current .claude/channel-outbox/a.jsonl bytes=two preserved-and-summed=yes' 'r8-late: the changed .claude bytes were not preserved again'
  r5_expect 'current notes/unique.dat bytes=only here preserved-and-summed=yes' 'r8-late: notes/unique.dat lost'
  grep -q '^aside .*\.cache=run a.jsonl=' "$R5_OUT" || fail 'r8-late: no earlier preserve kept aside with the old .cache bytes'
  pass 'R8-1: a foreign copy whose .cache and .claude files change before the unlock has the new bytes preserved again and the earlier preserve kept aside'
}
CASE
# Reuse the repository's own r5 harness block; load the extra case beside it.
FILE=$WT/tests/fm-teardown-cleanup.test.sh
mkdir -p /private/tmp/fm-fm-teardown-safe-leftovers-no-owner-ask
TMP_ROOT=$(mktemp -d /private/tmp/fm-fm-teardown-safe-leftovers-no-owner-ask/case.XXXXXX)
ROOT=$WT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }
block=$(sed -n '/^r5_harness() {/,/^teardown_test_cases=(/p' "$FILE" | sed '$d')
eval "$block"
. "$tmpcase/case.sh"
test_r8_late_foreign_change_is_preserved_again
rc=$?
rm -rf "$tmpcase" "$TMP_ROOT"
exit $rc
