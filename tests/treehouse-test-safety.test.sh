#!/usr/bin/env bash
# Exercise confinement and cleanup with the installed allocator, without a
# terminal server or model call. Negative cases only touch a private HOME.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/git-config-helpers.sh
. "$ROOT/tests/git-config-helpers.sh"
# shellcheck source=tests/treehouse-test-safety.sh
. "$ROOT/tests/treehouse-test-safety.sh"
command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found'; exit 0; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-safety.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

make_project() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'fixture\n' > "$1/README.md"
  fm_test_treehouse_project "$1"
  git -C "$1" add README.md treehouse.toml
  git -C "$1" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
  git clone -q --bare "$1" "$1.origin.git"
  git -C "$1" remote add origin "file://$1.origin.git"
}

# Every negative path below gets a fake user root, never the operator's HOME.
export HOME="$TMP_ROOT/user"
mkdir -p "$HOME"
fm_test_treehouse_init "$TMP_ROOT"
PROJECT="$TMP_ROOT/scratch-project"
make_project "$PROJECT"
# A pane can lack the controller environment. Project configuration alone must
# confine the real allocation, including its persistent durable lease.
WT=$(cd "$PROJECT" && env -u TREEHOUSE_ROOT -u TREEHOUSE_WORKTREE_PATH treehouse get --lease --no-fetch)
case "$WT" in
  "$FM_TEST_TREEHOUSE_ROOT"/.treehouse/*) : ;;
  *) fail "allocation escaped project sandbox: $WT" ;;
esac
if fm_test_treehouse_assert_clean 2>"$TMP_ROOT/leaked.err"; then
  fail 'a leftover pool and lease passed the exit check'
fi
cat "$TMP_ROOT/leaked.err"
fm_test_treehouse_cleanup || fail 'cleanup did not remove the leased pool'
[ ! -e "$WT" ] || fail 'leased checkout survived cleanup'
[ ! -e "$HOME/.treehouse" ] || fail 'allocation wrote to the fake user root'
printf 'ok - project config confines allocation without controller environment; cleanup removes its lease\n'

# Removing the project config recreates the old default-root behavior; the
# same exit check must reject it, even though its own sandbox was cleaned.
fm_test_treehouse_init "$TMP_ROOT"
rm "$PROJECT/treehouse.toml"
(cd "$PROJECT" && env -u TREEHOUSE_ROOT -u TREEHOUSE_WORKTREE_PATH treehouse get --lease --no-fetch) >"$TMP_ROOT/escaped-path"
if fm_test_treehouse_cleanup 2>"$TMP_ROOT/escaped.err"; then
  fail 'a write to the fake user root passed the exit check'
fi
cat "$TMP_ROOT/escaped.err"
[ -d "$(cat "$TMP_ROOT/escaped-path")" ] || fail 'negative allocation did not create a checkout'
printf 'ok - exit check rejects the unfixed default-root allocation\n'
