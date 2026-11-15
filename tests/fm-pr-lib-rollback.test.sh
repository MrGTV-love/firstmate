#!/usr/bin/env bash
# Helper-level tests of the merge poll publisher's rollback in bin/fm-pr-lib.sh
# (Main 1871 P-E): a failed publication deletes the check name only when its
# current bytes hash-equal the bytes this run wrote, with no trust record, and
# leaves anything else in place. Only that library is sourced; stubs of mv and ln
# on PATH insert each interleaving. No watcher, teardown, timed or killed process.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
REAL_MV=$(command -v mv)
REAL_LN=$(command -v ln)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
FAILED=0
CASE_FAILED=0
fail() { printf 'not ok - %s\n' "$*"; FAILED=1; CASE_FAILED=1; }
pass() { [ "$CASE_FAILED" = 1 ] || printf 'ok - %s\n' "$*"; CASE_FAILED=0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-lib-rollback.XXXXXX") || exit 1
trap 'rm -rf -- "${WORK:?}"' EXIT
CUSTOM=$(printf '#!/usr/bin/env bash\necho custom check output\n')

# world <name>: STATE is a state directory with task-a's earlier poll published, and
# a replacement prepared for PR 2 in this shell (the publisher's globals).
world() {
  STATE="$WORK/$1/state"
  mkdir -p "$STATE" "$WORK/$1/fakebin"
  printf 'window=fm-task-a\npr=https://github.com/o/r/pull/1\n' > "$STATE/task-a.meta"
  fm_pr_poll_prepare "$STATE" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" >/dev/null || return 1
  fm_pr_poll_publish_prepared || return 1
  printf 'window=fm-task-a\npr=https://github.com/o/r/pull/2\n' > "$STATE/task-a.meta"
  fm_pr_poll_prepare "$STATE" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" >/dev/null || return 1
}

# hook_after_link <dir> <script>: run <script> once, right after the publisher links
# its new check into the name.
hook_after_link() {
  cat > "$1/fakebin/ln" <<SH
#!/usr/bin/env bash
"$REAL_LN" "\$@" || exit \$?
case "\${@: -2:1}" in */.fm-pr-poll-check.*) ;; *) exit 0 ;; esac
[ -e "$1/fired" ] && exit 0
: > "$1/fired"
$2
SH
  chmod +x "$1/fakebin/ln"
}

test_in_place_rewrite_after_placement_is_left() {
  local state dir
  world rewrite || { fail "fixture: $FM_PR_POLL_DATA_TMP"; return; }
  state=$STATE
  dir="$WORK/rewrite"
  # A custom writer truncates and rewrites the placed check in place, before any trust record.
  hook_after_link "$dir" "printf '%s\n' '#!/usr/bin/env bash' 'echo custom check output' > '$state/task-a.check.sh'"
  if PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared 2> "$dir/err"; then
    fail "a publication whose check was rewritten in place was reported as success"
  fi
  fm_pr_poll_cleanup
  [ -e "$dir/fired" ] || fail "the in-place rewrite never happened"
  [ "$(cat "$state/task-a.check.sh" 2>/dev/null)" = "$CUSTOM" ] || fail "the rollback removed or changed bytes this run did not write"
  [ ! -e "$state/task-a.pr-poll" ] && [ ! -e "$state/task-a.pr-poll-registration" ] || fail "the rollback left its own sidecar or registration"
  grep -q 'no longer holds the bytes this publication wrote' "$dir/err" || fail "the rollback did not report the file it left: $(cat "$dir/err")"
  pass "a check rewritten in place after placement keeps its new bytes; the rollback leaves it and says so"
}

test_unchanged_failed_poll_is_revoked() {
  local state dir
  world unchanged || { fail "fixture: $FM_PR_POLL_DATA_TMP"; return; }
  state=$STATE
  dir="$WORK/unchanged"
  # Validation fails for another reason: the sidecar's mode changes after placement.
  hook_after_link "$dir" "chmod 0644 '$state/task-a.pr-poll'"
  if PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared 2> "$dir/err"; then
    fail "a publication whose sidecar became invalid was reported as success"
  fi
  fm_pr_poll_cleanup
  [ -e "$dir/fired" ] || fail "the sidecar fault never happened"
  [ ! -e "$state/task-a.check.sh" ] && [ ! -L "$state/task-a.check.sh" ] || fail "the rollback left its own unchanged check"
  [ ! -e "$state/task-a.pr-poll" ] && [ ! -e "$state/task-a.pr-poll-registration" ] || fail "the rollback left its own sidecar or registration"
  pass "a failed publication whose check still holds the bytes it wrote removes that check"
}

test_trusted_custom_check_is_left() {
  local state dir hash
  world trusted || { fail "fixture: $FM_PR_POLL_DATA_TMP"; return; }
  state=$STATE
  dir="$WORK/trusted"
  hash=$(printf '%s\n' '#!/usr/bin/env bash' 'echo custom check output' | shasum -a 256 | cut -d' ' -f1)
  # A custom check is written in place and its trust record committed, all after placement.
  hook_after_link "$dir" "printf '%s\n' '#!/usr/bin/env bash' 'echo custom check output' > '$state/task-a.check.sh'; printf 'fm-custom-check-v1\n%s\n' '$hash' > '$state/task-a.check-trust'"
  if PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared 2> "$dir/err"; then
    fail "a publication over a trusted custom check was reported as success"
  fi
  fm_pr_poll_cleanup
  [ "$(cat "$state/task-a.check.sh" 2>/dev/null)" = "$CUSTOM" ] && [ -f "$state/task-a.check-trust" ] \
    || fail "the rollback removed a trusted custom check or its trust record"
  pass "a custom check trusted after placement is left with its trust record"
}

test_prior_poll_is_left_when_this_run_never_placed_its_check() {
  local state dir before
  world prior || { fail "fixture: $FM_PR_POLL_DATA_TMP"; return; }
  state=$STATE
  dir="$WORK/prior"
  before=$(shasum -a 256 < "$state/task-a.check.sh")
  # The new sidecar fails validation before any check is placed.
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
"$REAL_MV" "\$@" || exit \$?
[ "\${!#}" = "$state/task-a.pr-poll" ] && chmod 0644 "$state/task-a.pr-poll"
exit 0
SH
  chmod +x "$dir/fakebin/mv"
  if PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared 2> "$dir/err"; then
    fail "a publication whose sidecar failed was reported as success"
  fi
  fm_pr_poll_cleanup
  [ "$(shasum -a 256 < "$state/task-a.check.sh" 2>/dev/null)" = "$before" ] || fail "the rollback removed a prior check this run did not write"
  [ ! -e "$state/task-a.pr-poll" ] && [ ! -e "$state/task-a.pr-poll-registration" ] || fail "the rollback left its own sidecar or registration"
  # The leftover prior poll has no sidecar or registration, and a retry replaces it by its bytes.
  fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" >/dev/null || fail "retry prepare"
  PATH="$BASE_PATH" fm_pr_poll_publish_prepared || fail "the retry did not publish over the template's own bytes"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "the retry did not leave a valid poll"
  pass "a prior check this run never replaced is left by the rollback, and a retry publishes over it"
}

# A poll from an older template is judged by its generator mark, never classed as a
# custom check by default (Main 1871). The earliest version's header is the fixture. Controls:
# a custom check without the mark, a marked check with a trust record, and the mark
# below the first line are not merge polls.
test_older_template_poll_is_judged_by_its_generator_mark() {
  local state="$WORK/older/state"
  mkdir -p "$state"
  # The first two lines of the earliest template (commit 064aa67c2) and a body.
  printf '%s\n' '#!/usr/bin/env bash' '# Static watcher program for a validated PR poll sidecar.' 'set -u' 'exit 0' > "$state/task-a.check.sh"
  cmp -s "$POLL" "$state/task-a.check.sh" && fail "fixture: the earliest template equals the current one"
  fm_pr_poll_check_dest_replaceable "$state" task-a "$POLL" || fail "an older template's poll was classed as another check"
  printf '%s\n' '#!/usr/bin/env bash' 'echo custom check output' > "$state/task-a.check.sh"
  ! fm_pr_poll_check_dest_replaceable "$state" task-a "$POLL" || fail "a custom check without the mark was taken for a poll"
  printf '%s\n' '#!/usr/bin/env bash' 'echo first' '# Static watcher program for a validated PR poll sidecar.' > "$state/task-a.check.sh"
  ! fm_pr_poll_check_dest_replaceable "$state" task-a "$POLL" || fail "a mark below the second line was taken for a poll"
  printf '%s\n' '#!/usr/bin/env bash' '# Static watcher program for a validated PR poll sidecar.' 'set -u' 'exit 0' > "$state/task-a.check.sh"
  printf 'trust\n' > "$state/task-a.check-trust"
  ! fm_pr_poll_check_dest_replaceable "$state" task-a "$POLL" || fail "a marked check with a trust record was taken for a poll"
  pass "an older template's poll is judged by its generator mark; an unmarked, misplaced or trusted check is not a poll"
}

test_in_place_rewrite_after_placement_is_left
test_unchanged_failed_poll_is_revoked
test_trusted_custom_check_is_left
test_prior_poll_is_left_when_this_run_never_placed_its_check
test_older_template_poll_is_judged_by_its_generator_mark
exit "$FAILED"
