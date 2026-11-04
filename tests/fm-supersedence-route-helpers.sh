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
  [ "$n_noev" -le 1 ] || { ROUTE_ARGV_WHY="--no-evidence-files is duplicated"; return 1; }
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
  route_argv_check execute 7 "$p" "$c" --pr 7 --supersedence-profile "$p" --cleanup-worktree "$c" --execute-cleanup \
    || fail "argv comparator: the canonical order was refused: $ROUTE_ARGV_WHY"
  route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" --no-evidence-files \
    || fail "argv comparator: the plain call's prefix order was refused: $ROUTE_ARGV_WHY"
  route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a plan without --execute-cleanup was refused: $ROUTE_ARGV_WHY"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" --repair-primary-base \
    || fail "argv comparator: an added --repair-primary-base passed"
  for flag in --reap-branch --recover-partial-removal --allow-remote-tip --emit-profile-template --publish-preflight --check-egress --verify-only; do
    ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" "$flag" \
      || fail "argv comparator: an added $flag passed"
  done
  for flag in --bundle-record --base-strategy --capture; do
    ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" "$flag" x \
      || fail "argv comparator: an added $flag passed"
  done
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --supersedence-profile "$p" \
    || fail "argv comparator: a missing --pr passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 8 --supersedence-profile "$p" \
    || fail "argv comparator: a wrong --pr passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile /w/other.json \
    || fail "argv comparator: a wrong profile passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree /w/other --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a wrong copy passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a duplicated --pr passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a duplicated --execute-cleanup passed"
  ! route_argv_check execute 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: an execute without --execute-cleanup passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" --execute-cleanup --pr 7 --supersedence-profile "$p" \
    || fail "argv comparator: a plan with --execute-cleanup passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" --pr 7 --supersedence-profile "$p" --no-evidence-files --no-evidence-files \
    || fail "argv comparator: a duplicated --no-evidence-files passed"
  ! route_argv_check plan 7 "$p" "$c" --cleanup-worktree "$c" \
    || fail "argv comparator: the plain call passed as a route call"
}

# The driver's compact envelopes, as the --pr lane prints them (Vernant
# closeout_pr.py _compact_envelope): no top-level "allowed". Scripted answers only.
route_envelope() {  # <state> <predicates-json> <worktree_removed> <recovery-reason-or-null> [<pr>]
  printf '{"base_ref":"origin/main","base_strategy":"merge-base","branch_delete":null,"branch_reap":null,"cleanup_recovery_reason":%s,"cleanup_requested":true,"evidence_digest":"0","launch_cwd":null,"next_command":"scripted","owner":"agent","pr":%s,"predicates_failed":%s,"primary_checkout_repair":null,"state":"%s","worktree_removed":%s}\n' \
    "$4" "${5:-7}" "$2" "$1" "$3"
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
# and logs each such call to <table-dir>/gh.log.
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
  HANG) sleep 30; exit 0 ;;
  GARBAGE) echo "not a state row"; exit 0 ;;
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
    FAIL | HANG | GARBAGE) printf '%s\n' "$3" > "$1/pr-$2" ;;
    *) printf '%s\t%s\t%s\n' "$3" "${4:-}" "${5:-fm/pr-$2-head}" > "$1/pr-$2" ;;
  esac
}

# route_install_row_driver <slot> <log-dir>: a scripted driver, one answer set per
# copy. It logs "<cwd>|<argv>" to <log-dir>/closeout.log and answers by the copy's
# base name from <log-dir>/ans/<name>/: without --pr (the plain call) with the
# answer d7 reported for these copies (allowed false,
# verification_stale_or_uncovered_paths, exit 3); with --pr a plan answers
# plan.out/plan.exit (after plan.hook, or hanging while plan.hang exists), an
# execute answers exec.out/exec.exit (after exec.hook) after removing the copy
# when exec.remove exists.
route_install_row_driver() {
  local slot=$1 log=$2
  mkdir -p "$log/ans"
  cat > "$slot/scripts/git-stability/closeout_pr.py" <<SH
export FAKE_DRIVER=1
printf '%s|%s\n' "\$PWD" "\$*" >> "$log/closeout.log"
printf '%s\n' "\$\$" >> "$log/driver.pids"
dir="$log/ans/\${2##*/}"
route=0
for arg in "\$@"; do [ "\$arg" != --pr ] || route=1; done
if [ "\$route" = 0 ]; then
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
  cat "\$dir/plan.out"
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
cat "\$dir/exec.out"
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
# after it unlocked the copy but left it in place), success-done (state DONE), blocked (a cleanup_tip_unbound refusal), retained
# (the archived-tree-retained refusal), temporary (a lease conflict), allowed-doc.
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
  esac
  case "${4:-success}" in
    success) route_execute_success_envelope "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.remove" ;;
    success-done) route_envelope DONE '[]' true null "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.remove" ;;
    lie) route_execute_success_envelope "$pr" > "$dir/exec.out"; printf 0 > "$dir/exec.exit"; : > "$dir/exec.unlock" ;;
    blocked) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_tip_unbound"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    retained) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_ignored_payload_archived_tree_retained"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    temporary) route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' "$pr" > "$dir/exec.out"; printf 3 > "$dir/exec.exit" ;;
    allowed-doc) echo '{"allowed": true}' > "$dir/exec.out"; printf 0 > "$dir/exec.exit" ;;
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
