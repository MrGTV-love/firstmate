#!/usr/bin/env bash
# Shared fixtures for the supersedence route tests in tests/fm-copy-sweep.test.sh
# and tests/fm-teardown-cleanup.test.sh (bin/fm-teardown-nested-lib.sh owns the
# route; its header owns the record format and the conditions). Sourced, never run.
#
# Everything here models the outside world and is labeled reduced evidence: the
# fake `gh` models the forge, the scripted driver models Vernant's closeout driver
# (the real one is never called), and the profile files carry only the two keys
# Firstmate reads. tests/fm-supersedence-route-helpers.sh is a helper, not a case.

# Consumed by the suites that source this file.
# shellcheck disable=SC2034
ROUTE_REPO=acme/widgets
# shellcheck disable=SC2034
ROUTE_REMOTE_URL=https://github.com/acme/widgets.git

# The driver options the route may pass. route_argv_check reads an argv as option
# and value bindings in any order, so the canonical order and the plain call's
# prefix order are the same call; anything outside the list, a missing or wrong
# binding, or a duplicate fails. ROUTE_ARGV_WHY names the first failure.
ROUTE_ARGV_WHY=
route_argv_check() {  # <plan|execute> <pr> <profile> <copy> <argument>...
  local stage=$1 pr=$2 profile=$3 copy=$4 tok
  local n_pr=0 n_profile=0 n_copy=0 n_execute=0 n_noev=0 v_pr='' v_profile='' v_copy=''
  shift 4
  ROUTE_ARGV_WHY=
  while [ "$#" -gt 0 ]; do
    tok=$1
    shift
    case "$tok" in
      --pr | --supersedence-profile | --cleanup-worktree)
        if [ "$#" -eq 0 ]; then
          ROUTE_ARGV_WHY="$tok has no value"
          return 1
        fi
        case "$tok" in
          --pr) n_pr=$((n_pr + 1)); v_pr=$1 ;;
          --supersedence-profile) n_profile=$((n_profile + 1)); v_profile=$1 ;;
          --cleanup-worktree) n_copy=$((n_copy + 1)); v_copy=$1 ;;
        esac
        shift
        ;;
      --execute-cleanup) n_execute=$((n_execute + 1)) ;;
      --no-evidence-files) n_noev=$((n_noev + 1)) ;;
      *)
        ROUTE_ARGV_WHY="argument $tok is outside the route's option list"
        return 1
        ;;
    esac
  done
  [ "$n_pr" = 1 ] && [ "$v_pr" = "$pr" ] || { ROUTE_ARGV_WHY="--pr is $n_pr time(s), value '$v_pr', want once as '$pr'"; return 1; }
  [ "$n_profile" = 1 ] && [ "$v_profile" = "$profile" ] || { ROUTE_ARGV_WHY="--supersedence-profile is $n_profile time(s), value '$v_profile'"; return 1; }
  [ "$n_copy" = 1 ] && [ "$v_copy" = "$copy" ] || { ROUTE_ARGV_WHY="--cleanup-worktree is $n_copy time(s), value '$v_copy'"; return 1; }
  [ "$n_noev" = 1 ] || { ROUTE_ARGV_WHY="--no-evidence-files is $n_noev time(s), want once"; return 1; }
  if [ "$stage" = execute ]; then
    [ "$n_execute" = 1 ] || { ROUTE_ARGV_WHY="--execute-cleanup is $n_execute time(s) at the execute"; return 1; }
  else
    [ "$n_execute" = 0 ] || { ROUTE_ARGV_WHY="--execute-cleanup was passed at the plan"; return 1; }
  fi
}

# Proves the comparator can fail: two accepted orders, then every named way to be
# wrong. Runs once per suite, so a comparator that accepts anything fails here.
route_argv_selftest() {
  local c=/w/copy p=/w/profile.json flag
  # The route's call always carries --no-evidence-files once (Main 1745): chk adds it.
  chk() { route_argv_check "$@" --no-evidence-files; }
  chk execute 7 "$p" "$c" --pr 7 --supersedence-profile "$p" --cleanup-worktree "$c" --execute-cleanup \
    || fail "argv comparator: the canonical order was refused: $ROUTE_ARGV_WHY"
  route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" --no-evidence-files \
    || fail "argv comparator: the plain call's prefix order was refused: $ROUTE_ARGV_WHY"
  chk plan 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a plan without --execute-cleanup was refused: $ROUTE_ARGV_WHY"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" --repair-primary-base \
    || fail "argv comparator: an added --repair-primary-base passed"
  for flag in --reap-branch --recover-partial-removal --allow-remote-tip --emit-profile-template --publish-preflight --check-egress --verify-only; do
    ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" "$flag" \
      || fail "argv comparator: an added $flag passed"
  done
  for flag in --bundle-record --base-strategy --capture; do
    ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" "$flag" x \
      || fail "argv comparator: an added $flag passed"
  done
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --supersedence-profile "$p" \
    || fail "argv comparator: a missing --pr passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 8 --supersedence-profile "$p" \
    || fail "argv comparator: a wrong --pr passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile /w/other.json \
    || fail "argv comparator: a wrong profile passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree /w/other --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a wrong copy passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a duplicated --pr passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a duplicated --execute-cleanup passed"
  ! chk execute 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: an execute without --execute-cleanup passed"
  ! chk plan 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a plan with --execute-cleanup passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" --no-evidence-files --no-evidence-files \
    || fail "argv comparator: a duplicated --no-evidence-files passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" \
    || fail "argv comparator: the plain call passed as a route call"
  ! route_argv_check execute 7 "$p" "$c" --pr 7 --supersedence-profile "$p" --cleanup-worktree "$c" --execute-cleanup \
    || fail "argv comparator: a route call without --no-evidence-files passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a route plan without --no-evidence-files passed"
}

# The driver's compact envelopes, as the --pr lane prints them (Vernant
# closeout_pr.py _compact_envelope): no top-level "allowed". Scripted answers only.
# ROUTE_CLEANUP_REQUESTED (default true, what the real driver prints for a call
# that names --cleanup-worktree) lets a case script the contradictory false.
route_envelope() {  # <state> <predicates-json> <worktree_removed> <recovery-reason-or-null> [<pr>]
  printf '{"base_ref":"origin/main","base_strategy":"merge-base","branch_delete":null,"branch_reap":null,"cleanup_recovery_reason":%s,"cleanup_requested":%s,"evidence_digest":"0","launch_cwd":null,"next_command":"scripted","owner":"agent","pr":%s,"predicates_failed":%s,"primary_checkout_repair":null,"state":"%s","worktree_removed":%s}\n' \
    "$4" "${ROUTE_CLEANUP_REQUESTED:-true}" "${5:-7}" "$2" "$1" "$3"
}
route_plan_allowed_envelope() { route_envelope BLOCKED '["cleanup_not_executed"]' false null "$@"; }
route_plan_refusal_envelope() { route_envelope BLOCKED '["cleanup_gate"]' false '"verification_stale_or_uncovered_paths"' "$@"; }
route_execute_success_envelope() { route_envelope DONE_WITH_SUPERSEDENCE '[]' true null "$@"; }

# route_write_profile <path> <pr> <tip>: a profile with the keys Firstmate reads;
# a tip of - leaves superseded_tip_sha out.
route_write_profile() {
  if [ "$3" = - ]; then
    printf '{"schema_version":"1.0.0","pr":%s,"superseded_by_ref":"origin/main"}\n' "$2" > "$1"
  else
    printf '{"schema_version":"1.0.0","pr":%s,"superseded_by_ref":"origin/main","superseded_tip_sha":"%s"}\n' "$2" "$3" > "$1"
  fi
}

# route_install_gh <fakebin> <table-dir>: a `gh` that answers only the route's
# read, `gh pr view <n> --repo acme/widgets --json <fields> -q ...`, from
# <table-dir>/pr-<n> (state TAB merge-commit TAB head-branch; FAIL; HANG; GARBAGE)
# and logs each such call to <table-dir>/gh.log. HANG records its pid in
# <table-dir>/gh.pids and becomes `sleep`, so that pid is the sleeper's own.
# HANGCHILD records its own pid and that of a `sleep` child it starts and waits
# for, both in gh.pids, so a read that is ended without its descendants is visible.
# EARLYEXIT (line 1, then the answer row) starts a `sleep` child that inherits gh's
# stdout and records its pid and the call time, prints the answer and exits at once:
# the parent is gone while a descendant still holds the pipe. APPEND <n> (line 1,
# then the carrier path, a row, and the answer row) appends that row to the carrier
# on the <n>th read of that PR or later, so a record can change while the forge is read.
# Anything else goes to the fixture's own gh (kept as gh.base) or fails.
route_install_gh() {
  local fakebin=$1 dir=$2
  mkdir -p "$dir"
  if [ -e "$fakebin/gh" ] && [ ! -e "$fakebin/gh.base" ]; then
    mv "$fakebin/gh" "$fakebin/gh.base"
  fi
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --repo "*) ;;
  *) if [ -x "$fakebin/gh.base" ]; then exec "$fakebin/gh.base" "\$@"; fi; exit 1 ;;
esac
printf '%s\n' "\$*" >> "$dir/gh.log"
[ "\${1:-}" = pr ] && [ "\${2:-}" = view ] && [ "\${4:-}" = --repo ] && [ "\${5:-}" = $ROUTE_REPO ] \\
  && [ "\${6:-}" = --json ] && [ "\${7:-}" = state,mergeCommit,headRefName ] || { echo "unexpected gh call: \$*" >&2; exit 2; }
file="$dir/pr-\$3"
[ -f "\$file" ] || { echo "no such pull request" >&2; exit 1; }
case "\$(head -n 1 "\$file")" in
  FAIL) echo "forge unavailable" >&2; exit 1 ;;
  HANG) printf '%s\\n' "\$\$" >> "$dir/gh.pids"; exec sleep 30 ;;
  HANGCHILD) printf '%s\\n' "\$\$" >> "$dir/gh.pids"; sleep 60 & printf '%s\\n' "\$!" >> "$dir/gh.pids"; wait ;;
  GARBAGE) echo "not a state row"; exit 0 ;;
  EARLYEXIT) sleep "\${ROUTE_EARLYEXIT_LIFE:-20}" & printf '%s\\n' "\$!" >> "$dir/gh.pids"; date +%s >> "$dir/gh.times"; tail -n +2 "\$file"; exit 0 ;;
  APPEND*)
    nth=\$(head -n 1 "\$file" | cut -d' ' -f2)
    if [ "\$(grep -c "^pr view \$3 " "$dir/gh.log")" -ge "\${nth:-1}" ]; then sed -n 3p "\$file" >> "\$(sed -n 2p "\$file")"; fi
    sed -n 4p "\$file"; exit 0 ;;
  *) cat "\$file"; exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

# route_set_pr <table-dir> <pr> <state> [<merge-commit> [<head-branch>]]: the
# forge's answer for a PR. No fixture's checkout is on the default head branch.
route_set_pr() {
  mkdir -p "$1"
  case "$3" in
    FAIL | HANG | HANGCHILD | GARBAGE) printf '%s\n' "$3" > "$1/pr-$2" ;;
    EARLYEXIT) printf 'EARLYEXIT\nMERGED\t%s\t%s\n' "${4:-}" "${5:-fm/pr-$2-head}" > "$1/pr-$2" ;;
    *) printf '%s\t%s\t%s\n' "$3" "${4:-}" "${5:-fm/pr-$2-head}" > "$1/pr-$2" ;;
  esac
}

# route_set_pr_append <table-dir> <pr> <nth-read> <carrier> <row> <merge-commit> [<head-branch>]:
# a MERGED answer that appends <row> to <carrier> on the <nth-read>th read of that PR or later.
route_set_pr_append() {
  mkdir -p "$1"
  printf 'APPEND %s\n%s\n%s\nMERGED\t%s\t%s\n' "$3" "$4" "$5" "$6" "${7:-fm/pr-$2-head}" > "$1/pr-$2"
}

# route_wait_for <path> <seconds>: 0 once <path> exists, 1 when it does not appear in time.
# A detached launch writes its marker some moments after the command that started it
# returns, so a check made at once can reject a run that is about to be right.
route_wait_for() {
  local path=$1 limit=$(($2 * 10)) i=0
  while [ ! -e "$path" ] && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$path" ]
}

# route_install_row_driver <slot> <log-dir> [plain-plan-allows]: a scripted driver,
# one answer set per copy. It logs "<cwd>|<argv>" to <log-dir>/closeout.log and
# answers by the copy's base name from <log-dir>/ans/<name>/: without --pr (the
# plain call) with the answer d7 reported for these copies (allowed false,
# verification_stale_or_uncovered_paths, exit 3), except that with
# plain-plan-allows a plain plan answers {"allowed": true} at exit 0, as the
# teardown suite's own fakes answer its entry plan; with --pr a plan answers
# plan.out/plan.exit (after plan.hook, or hanging while plan.hang exists), an
# execute answers exec.out/exec.exit (after exec.hook) after removing the copy
# when exec.remove exists. Each call also logs "<copy>|<plan|execute>|<branch>" to
# <log-dir>/startup.log, the slot's checkout when the driver started, and runs
# plan.after or exec.after (when present) once its answer is printed.
route_install_row_driver() {
  local slot=$1 log=$2 plain_plan=${3:-}
  mkdir -p "$log/ans"
  cat > "$slot/scripts/git-stability/closeout_pr.py" <<SH
export FAKE_DRIVER=1
printf '%s|%s\n' "\$PWD" "\$*" >> "$log/closeout.log"
printf '%s\n' "\$\$" >> "$log/driver.pids"
dir="$log/ans/\${2##*/}"
stage=plan
for arg in "\$@"; do [ "\$arg" != --execute-cleanup ] || stage=execute; done
printf '%s|%s|%s\n' "\${2##*/}" "\$stage" "\$(git -C "\$PWD" branch --show-current 2>/dev/null)" >> "$log/startup.log"
route=0
for arg in "\$@"; do [ "\$arg" != --pr ] || route=1; done
if [ "\$route" = 0 ]; then
  if [ "\$stage" = plan ] && [ "$plain_plan" = plain-plan-allows ]; then
    echo '{"allowed": true}'
    exit 0
  fi
  echo '{"allowed": false, "reason": "verification_stale_or_uncovered_paths"}'
  exit 3
fi
if [ "\${3:-}" != --execute-cleanup ]; then
  [ ! -e "\$dir/plan.hook" ] || bash "\$dir/plan.hook" "\$2" || exit 4
  if [ -e "\$dir/plan.hang" ]; then
    sleep 30 &
    printf '%s\n' "\$!" >> "$log/driver.pids"
    wait
    exit 0
  fi
  [ ! -e "\$dir/plan.err" ] || cat "\$dir/plan.err" >&2
  if [ ! -f "\$dir/plan.out" ] || [ ! -f "\$dir/plan.exit" ]; then
    echo "SCRIPTED-ANSWER-MISSING: no plan answer in \$dir" >&2
    exit 99
  fi
  cat "\$dir/plan.out"
  [ ! -e "\$dir/plan.after" ] || bash "\$dir/plan.after" "\$2"
  exit "\$(cat "\$dir/plan.exit")"
fi
[ ! -e "\$dir/exec.hook" ] || bash "\$dir/exec.hook" "\$2" || exit 4
if [ -e "\$dir/exec.unlock" ]; then
  git worktree unlock "\$2" || exit 4
fi
if [ -e "\$dir/exec.remove" ]; then
  git worktree unlock "\$2" || exit 4
  git worktree remove "\$2" || exit 4
fi
[ ! -e "\$dir/exec.err" ] || cat "\$dir/exec.err" >&2
if [ ! -f "\$dir/exec.out" ] || [ ! -f "\$dir/exec.exit" ]; then
  echo "SCRIPTED-ANSWER-MISSING: no execute answer in \$dir" >&2
  exit 99
fi
cat "\$dir/exec.out"
[ ! -e "\$dir/exec.after" ] || bash "\$dir/exec.after" "\$2"
exit "\$(cat "\$dir/exec.exit")"
SH
}

# route_checkout_digest <checkout>: the sha256 of a checkout's working tree, byte
# for byte: every path outside .git with each file's content hash (a symlink's
# target), then `git status --porcelain`, so tracked, modified and untracked files
# all count. A checkout nested inside it (a directory holding a .git entry) is a
# working tree of its own and is left out, so a nested copy released in the same
# run does not change the digest.
route_checkout_digest() {
  (
    cd "$1" || exit 1
    nested=()
    while IFS= read -r n; do
      [ "$n" = ./.git ] || nested+=("${n%/.git}")
    done < <(find . -name .git -prune -print | LC_ALL=C sort)
    prune=(-path ./.git)
    skip=()
    for n in ${nested[@]+"${nested[@]}"}; do
      prune+=(-o -path "$n")
      skip+=(":(exclude)${n#./}")
    done
    find . \( "${prune[@]}" \) -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then
        printf 'L %s %s\n' "$f" "$(readlink "$f")"
      elif [ -f "$f" ]; then
        printf 'F %s %s\n' "$f" "$(shasum -a 256 < "$f" | awk '{print $1}')"
      else
        printf 'D %s\n' "$f"
      fi
    done
    printf -- '--- status\n'
    git status --porcelain=v1 --untracked-files=all -- . ${skip[@]+"${skip[@]}"}
  ) | shasum -a 256 | awk '{print $1}'
}

# route_assert_digest_sees <checkout> <label>: the control that proves the digest
# can fail. A switch to main (what the driver's DONE-state finish does to a
# primary checkout on the PR's head branch), a tracked edit and an untracked file
# each change it; the checkout is put back after each.
route_assert_digest_sees() {
  local checkout=$1 label=$2 before branch file
  before=$(route_checkout_digest "$checkout")
  branch=$(git -C "$checkout" branch --show-current)
  git -C "$checkout" checkout -q main
  [ "$(route_checkout_digest "$checkout")" != "$before" ] || fail "$label: the digest missed a switch from $branch to main"
  git -C "$checkout" checkout -q "$branch"
  file=$(git -C "$checkout" ls-files | head -n 1)
  [ -n "$file" ] || fail "$label: the checkout has no tracked file to edit"
  printf 'planted\n' >> "$checkout/$file"
  [ "$(route_checkout_digest "$checkout")" != "$before" ] || fail "$label: the digest missed an edit of the tracked file $file"
  git -C "$checkout" checkout -q -- "$file"
  printf 'planted\n' > "$checkout/route-digest-planted.txt"
  [ "$(route_checkout_digest "$checkout")" != "$before" ] || fail "$label: the digest missed an untracked file"
  rm -f "$checkout/route-digest-planted.txt"
  assert_equals "$before" "$(route_checkout_digest "$checkout")" "$label: the checkout was not put back after the digest control"
}

# route_script_row <log-dir> <copy-name> <plan-kind> <execute-kind> [<pr>]: the
# scripted --pr answers of one copy. Plan kinds: allowed (the dry-run envelope,
# exit 3), refuse (a cleanup_gate refusal), unbound (cleanup_tip_unbound), two
# (the dry-run envelope with a second predicate), done (a DONE envelope, exit 0),
# error (exit 2 and a closeout_pr failure on stderr), allowed-doc (the plain
# call's {"allowed": true}), silent, hang, retain (the dry-run envelope with the
# ignored-payload retain key). Execute kinds: success, lie (the success envelope
# after it unlocked the copy but left it in place), intact (the success envelope
# with the copy and its lock untouched), success-done (state DONE), blocked (a cleanup_tip_unbound refusal), retained
# (the archived-tree-retained refusal), retained-both (that refusal in the stdout envelope and,
# as R4(c) words it, once more on stderr, with the disposition key the plan shape would carry),
# temporary (a lease conflict), allowed-doc,
# and malformed or contradictory temporary refusals that must not read as one
# (temporary-branch-delete and temporary-branch-reap carry a branch decision a BLOCKED
# answer cannot have):
# temporary-string (predicates_failed a string and worktree_removed true, the shape
# Main 010 F3 reproduced), temporary-string-kept (a string, worktree_removed false),
# temporary-removed (an array but worktree_removed true), temporary-removed-null,
# temporary-not-requested (a valid temporary envelope whose cleanup_requested is
# false although the call asked for cleanup) and temporary-retained-stderr (a valid
# temporary envelope on stdout with the archived-tree-retained signal on stderr only).
route_script_row() {
  local dir=$1/ans/$2 pr=${5:-7}
  mkdir -p "$dir"
  rm -f "$dir"/plan.* "$dir"/exec.*
  case "$3" in
    allowed) route_plan_allowed_envelope "$pr" > "$dir/plan.out"; printf 3 > "$dir/plan.exit" ;;
    refuse) route_plan_refusal_envelope "$pr" > "$dir/plan.out"; printf 3 > "$dir/plan.exit" ;;
    unbound) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_tip_unbound"' "$pr" > "$dir/plan.out"; printf 3 > "$dir/plan.exit" ;;
    two) route_envelope BLOCKED '["cleanup_not_executed","primary_checkout_repair"]' false null "$pr" > "$dir/plan.out"; printf 3 > "$dir/plan.exit" ;;
    done) route_envelope DONE '[]' false null "$pr" > "$dir/plan.out"; printf 0 > "$dir/plan.exit" ;;
    error) : > "$dir/plan.out"; printf 2 > "$dir/plan.exit"; echo "closeout_pr: failed: PR state != MERGED" > "$dir/plan.err" ;;
    allowed-doc) echo '{"allowed": true}' > "$dir/plan.out"; printf 0 > "$dir/plan.exit" ;;
    silent) : > "$dir/plan.out"; printf 0 > "$dir/plan.exit" ;;
    hang) : > "$dir/plan.out"; printf 0 > "$dir/plan.exit"; : > "$dir/plan.hang" ;;
    retain) route_plan_allowed_envelope "$pr" | sed 's/^{/{"ignored_payload_disposition":"archive_then_retain_tree",/' > "$dir/plan.out"; printf 3 > "$dir/plan.exit" ;;
    *) fail "route_script_row: unknown plan kind '$3' for $2 (a kind that is not scripted leaves no answer)" ;;
  esac
  case "${4:-success}" in
    success) route_execute_success_envelope "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.remove" ;;
    success-done) route_envelope DONE '[]' true null "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.remove" ;;
    lie) route_execute_success_envelope "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.unlock" ;;
    intact) route_execute_success_envelope "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit" ;;
    blocked) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_tip_unbound"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    retained) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_ignored_payload_archived_tree_retained"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    retained-both) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_ignored_payload_archived_tree_retained"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit"; echo "closeout_pr: ignored_payload_disposition=archive_then_retain_tree cleanup_ignored_payload_archived_tree_retained" > "$dir/exec.err" ;;
    temporary) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-string) route_envelope BLOCKED '"cleanup_gate"' true '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-string-kept) route_envelope BLOCKED '"cleanup_gate"' false '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-removed) route_envelope BLOCKED '["cleanup_gate"]' true '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-removed-null) route_envelope BLOCKED '["cleanup_gate"]' null '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-not-requested) ROUTE_CLEANUP_REQUESTED=false route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-branch-delete) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" | sed 's/"branch_delete":null/"branch_delete":{"state":"deleted_after_landing_proof"}/' > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-branch-reap) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" | sed 's/"branch_reap":null/"branch_reap":{"outcome":"reaped"}/' > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary-retained-stderr) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit"; echo "closeout_pr: cleanup_ignored_payload_archived_tree_retained" > "$dir/exec.err" ;;
    allowed-doc) echo '{"allowed": true}' > "$dir/exec.out"; printf 0 > "$dir/exec.exit" ;;
    *) fail "route_script_row: unknown execute kind '${4:-success}' for $2 (a kind that is not scripted leaves no answer)" ;;
  esac
}

# The abbreviated tips, classes, PRs and forge states the staged tables carry,
# read from the files, never typed here. route_table_rows prints one row per line
# as number TAB abbreviated-tip TAB class TAB pr TAB forge-state TAB kind TAB own,
# where kind is accept (a twin or an ancestor) or reject (everything else) and
# own is no for a row whose PR is only the nearest merged one (a misattributed-
# record negative).
# The rule for a row's PR is the first that applies: accept rows take the
# superseding merged PR of the table's column; any other row takes the copy's own
# PR named in the notes (CLOSED or OPEN), else the matching PR named there, else
# the nearest merged PR. d7 PR 3446 comes from the 2797 report.
route_table_rows() {  # <cases-dir>
  local table=$1/d7-supersedence-table.md report=$1/d7-closeout-driver-report.md twin
  awk -F ' \\| ' '
    /^\| [0-9]+ \|/ {
      n = $1; sub(/^\| /, "", n)
      tip = $4; cls = $9; col = $6; notes = $10; sub(/ \|$/, "", notes)
      pr = ""; state = ""; kind = "reject"; own = "yes"
      if (cls == "a" || cls == "other (history)") {
        kind = "accept"
        if (match(col, /pull\/[0-9]+/)) { pr = substr(col, RSTART + 5, RLENGTH - 5); state = "MERGED" }
      } else if (match(notes, /Own PR #[0-9]+ (is )?(CLOSED|OPEN)/)) {
        s = substr(notes, RSTART, RLENGTH); gsub(/Own PR #|is /, "", s)
        split(s, w, " "); pr = w[1]; state = w[2]
      } else if (match(notes, /matching PR #[0-9]+/)) {
        pr = substr(notes, RSTART + 13, RLENGTH - 13); state = "OPEN"
      } else if (match(col, /pull\/[0-9]+/)) {
        pr = substr(col, RSTART + 5, RLENGTH - 5); state = "MERGED"; own = "no"
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, tip, cls, pr, state, kind, own
    }' "$table"
  twin=$(sed -n 's/.*tip \([0-9a-f]\{8,\}\) vs PR \([0-9]\{1,\}\) head.*/\1 \2/p' "$report" | head -n 1)
  [ -z "$twin" ] || printf 'adopt-existing-branch\t%s\ttwin\t%s\tMERGED\taccept\tyes\n' "${twin% *}" "${twin#* }"
}

# route_table_counts <rows>: "a/history/b/other" counts of the table's classes.
route_table_counts() {
  printf '%s\n' "$1" | awk -F '\t' '
    $1 ~ /^[0-9]+$/ { if ($3 == "a") a++; else if ($3 == "other (history)") h++; else if ($3 == "b") b++; else if ($3 == "other") o++ }
    END { printf "%d/%d/%d/%d\n", a, h, b, o }'
}

# forge_reads_are_gone <table-dir> <seconds>: true once every pid the fake forge
# recorded in <table-dir>/gh.pids (a HANG read's sleeper, a HANGCHILD read's
# script and its child) is gone, polled for up to <seconds>. A killed process can
# stay a zombie for a moment, so it is polled, not read once. FORGE_ALIVE names
# the pids that remained.
FORGE_ALIVE=
forge_reads_are_gone() {
  local pid waited=0 alive
  FORGE_ALIVE=
  while [ "$waited" -le $(($2 * 10)) ]; do
    alive=
    if [ -f "$1/gh.pids" ]; then
      while IFS= read -r pid; do
        ! kill -0 "$pid" 2>/dev/null || alive="$alive $pid"
      done < "$1/gh.pids"
    fi
    [ -n "$alive" ] || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  FORGE_ALIVE=$alive
  return 1
}

# route_staged_cases_gate: the R5 recorded-cases tables read the captain-private staged d7
# cases, which no CI run has, so FM_SUPERSEDENCE_CASES decides (Main 1919 F7).
#   unset: prints one named skip line and returns 1; the caller then returns 0. The line
#     starts with "skip:", never "ok -", so the table is not counted as a pass, and CI=true
#     changes nothing: a CI run without the cases is not a failure. The grader runs the
#     table with the variable set (R5 Verify).
#   set (an empty value too): both staged files must be regular readable files in that
#     directory, or the case fails and names the variable and the path; returns 0 when they are.
route_staged_cases_gate() {
  local dir=${FM_SUPERSEDENCE_CASES-} name
  if [ -z "${FM_SUPERSEDENCE_CASES+x}" ]; then
    printf 'skip: R5 table owed to the grader: FM_SUPERSEDENCE_CASES unset\n'
    return 1
  fi
  [ -d "$dir" ] && [ -r "$dir" ] || fail "FM_SUPERSEDENCE_CASES is set to '$dir', which is not a readable directory; it must name the staged d7 cases directory"
  for name in d7-supersedence-table.md d7-closeout-driver-report.md; do
    [ -f "$dir/$name" ] && [ -r "$dir/$name" ] || fail "FM_SUPERSEDENCE_CASES is set to '$dir', where $name is not a readable file; it must name the staged d7 cases directory"
  done
  return 0
}

# route_ci_only_gate <what>: the real 60 s forge-read default (R2(d)) and the real 120 s plan
# default (R3(d)) are proved by waiting the production default with the real bounder and a
# real process-group kill, which Firstmate's own hosts bar (Main 1837, Main 1850, Main 2197).
# They run only on GitHub's CI runners, where GITHUB_ACTIONS is "true":
#   on a runner: returns 0 and prints nothing; the case then waits the real default.
#   anywhere else: prints one "skip:" line that names the case and the reason and returns 1;
#     the caller then returns 0. The line starts with "skip:", never "ok -", so it is not a pass.
route_ci_only_gate() {  # <what>
  [ "${GITHUB_ACTIONS:-}" != true ] || return 0
  printf 'skip: %s: runs only on GitHub CI (GITHUB_ACTIONS is not "true"); the real wait and process-group kill are barred on Firstmate hosts (Main 1837, 1850, 2197)\n' "$1"
  return 1
}

# route_ignored_digest <clone> [all]: the sha256 of every IGNORED path of a clone: the
# `git status --ignored` listing (one line per path) and, for each ignored file, its content
# hash (a symlink's target). `.claude/bug-evidence/tree-presence/` is the driver's named
# verification-report directory (R4(b), R6(c)) and is left out, and so is `.claude/worktrees/`,
# where the copies themselves live; with a second argument `all` nothing is left out (a control
# that the leave-out matters). Tracked and non-ignored files are route_checkout_digest's.
route_ignored_digest() {
  (
    cd "$1" || exit 1
    leave_out='^(\.claude/bug-evidence/tree-presence/|\.claude/worktrees/)'
    [ "${2:-}" != all ] || leave_out='^$'
    git status --porcelain=v1 --ignored --untracked-files=all | LC_ALL=C sort \
      | while IFS= read -r line; do
        case "$line" in '!!'*) ;; *) continue ;; esac
        printf '%s\n' "${line#!! }" | grep -q -E "$leave_out" || printf '%s\n' "$line"
      done
    printf -- '--- ignored files\n'
    git ls-files -z --others --ignored --exclude-standard | tr '\0' '\n' | LC_ALL=C sort | grep -v -E "$leave_out" \
      | while IFS= read -r f; do
        if [ -L "$f" ]; then
          printf 'L %s %s\n' "$f" "$(readlink "$f")"
        elif [ -f "$f" ]; then
          printf 'F %s %s\n' "$f" "$(shasum -a 256 < "$f" | awk '{print $1}')"
        else
          printf 'D %s\n' "$f"
        fi
      done
  ) | shasum -a 256 | awk '{print $1}'
}

# route_assert_ignored_digest_sees <clone> <label>: the control that the ignored-area digest
# can fail. A new ignored file, an edit of one and the deletion of one each change it, a
# write under the leave-out directory does not, and the clone is put back after each.
route_assert_ignored_digest_sees() {
  local clone=$1 label=$2 before before_all f
  before=$(route_ignored_digest "$clone")
  before_all=$(route_ignored_digest "$clone" all)
  f=$(cd "$clone" && git ls-files -z --others --ignored --exclude-standard | tr '\0' '\n' | grep -v -E '^(\.claude/bug-evidence/tree-presence/|\.claude/worktrees/)' | head -n 1)
  [ -n "$f" ] || fail "$label: the clone has no ignored file to edit"
  printf 'planted\n' > "$clone/ignored-area/route-digest-planted.txt"
  [ "$(route_ignored_digest "$clone")" != "$before" ] || fail "$label: the ignored-area digest missed a new ignored file"
  rm -f "$clone/ignored-area/route-digest-planted.txt"
  printf 'planted\n' >> "$clone/$f"
  [ "$(route_ignored_digest "$clone")" != "$before" ] || fail "$label: the ignored-area digest missed an edit of the ignored file $f"
  cp -p "$clone/$f" "$clone/$f.keep" && sed '$d' "$clone/$f.keep" > "$clone/$f" && rm -f "$clone/$f.keep"
  [ "$(route_ignored_digest "$clone")" = "$before" ] || fail "$label: the ignored file $f was not put back after the digest control"
  mv "$clone/$f" "$clone/$f.away"
  [ "$(route_ignored_digest "$clone")" != "$before" ] || fail "$label: the ignored-area digest missed the deletion of the ignored file $f"
  mv "$clone/$f.away" "$clone/$f"
  mkdir -p "$clone/.claude/bug-evidence/tree-presence"
  printf 'a report\n' > "$clone/.claude/bug-evidence/tree-presence/route-digest-control.json"
  [ "$(route_ignored_digest "$clone")" = "$before" ] || fail "$label: the ignored-area digest counted the tree-presence report directory"
  [ "$(route_ignored_digest "$clone" all)" != "$before_all" ] || fail "$label: the leave-out control (digest of every ignored path) missed the tree-presence report, so the leave-out proves nothing"
  rm -f "$clone/.claude/bug-evidence/tree-presence/route-digest-control.json"
  assert_equals "$before" "$(route_ignored_digest "$clone")" "$label: the clone was not put back after the ignored-area digest control"
}

# route_plant_unique_ignored <copy>: unique ignored files in a copy, the kinds a real copy holds
# that exist nowhere else (R4(c)): a text file, a binary file with a NUL and a high byte in a
# nested ignored directory, an empty file, and a symlink. The caller names these paths in the
# slot's info/exclude (unique.dat, unique-dir/, unique-link) so git ignores them.
route_plant_unique_ignored() {
  mkdir -p "$1/unique-dir/nested"
  printf 'unique retained bytes\n' > "$1/unique.dat"
  printf 'a\0b\377 binary\n' > "$1/unique-dir/nested/rows.bin"
  : > "$1/unique-dir/empty.txt"
  ln -s unique.dat "$1/unique-link"
}

# route_unique_sums <copy>: the planted files read directly, apart from route_ignored_digest:
# each file's sha256, the symlink's target and the sorted listing of the planted paths, so a
# missing, added or changed unique file shows in the text (stderr of a missing file is part of it).
route_unique_sums() {
  (
    cd "$1" || exit 1
    shasum -a 256 unique.dat unique-dir/nested/rows.bin unique-dir/empty.txt 2>&1
    printf 'link %s\n' "$(readlink unique-link 2>&1)"
    find unique.dat unique-dir unique-link 2>&1 | LC_ALL=C sort
  )
}

# route_retained_bytes_ok <copy> <digest-before> <sums-before>: the R4(c) decision rule. Returns 0
# only when the copy is still there and both its ignored-area digest and the planted files read
# directly equal what they were before the route. A route that kept the copy but lost, changed or
# added a unique ignored file returns 1.
route_retained_bytes_ok() {
  [ -d "$1" ] || return 1
  [ "$(route_ignored_digest "$1")" = "$2" ] || return 1
  [ "$(route_unique_sums "$1")" = "$3" ] || return 1
  return 0
}
