#!/usr/bin/env bash
# partition-mutate.sh <checkout-root> <mutation>
# Edits one throwaway checkout the way a PR (or a bad split) would.
set -eu
r=$1 m=$2 t=$r/tests
# define <file> <name>: add "name() { :; }" just before the file's first registry line
define() { awk -v n="$2" '!d && /^[a-z_]+_test_cases\+?=\(/ { print n "() { :; }"; print ""; d=1 } { print }' "$1" > "$1.new" && mv "$1.new" "$1"; }
# register <file> <name> [<nth registry>]: add name as the first entry of the nth registry (default 1)
# The entry copies the indentation of the registry's existing first entry.
register() { awk -v n="$2" -v k="${3:-1}" '{ print } /^[[:space:]]*[a-z_]+_test_cases\+?=\($/ { if (++c == k) { getline nx; ind = nx; sub(/[^[:space:]].*$/, "", ind); print ind n; print nx } }' "$1" > "$1.new" && mv "$1.new" "$1"; }
case $m in
  add-pr-merge)  define "$t/fm-pr-merge-checks.test.sh" test_added_by_a_pr; register "$t/fm-pr-merge-checks.test.sh" test_added_by_a_pr ;;
  add-teardown)  define "$t/fm-teardown-cleanup.test.sh" test_added_by_a_pr; register "$t/fm-teardown-cleanup.test.sh" test_added_by_a_pr ;;
  add-control)   define "$t/fm-control-relaunch-recovery.test.sh" test_added_by_a_pr; register "$t/fm-control-relaunch-recovery.test.sh" test_added_by_a_pr 2 ;;
  add-lint)      define "$t/fm-lint-report.test.sh" test_added_by_a_pr; register "$t/fm-lint-report.test.sh" test_added_by_a_pr ;;
  add-watch)     printf '\ntest_added_by_a_pr() { :; }\n' >> "$t/fm-watch-triage-helpers.sh"
                 awk '{ print } !d && /^test_[A-Za-z0-9_]+$/ { print "test_added_by_a_pr"; d=1 }' "$t/fm-watch-triage-waits-away.test.sh" > "$t/x.new" && mv "$t/x.new" "$t/fm-watch-triage-waits-away.test.sh" ;;
  unregistered)  define "$t/fm-pr-merge-checks.test.sh" test_defined_never_registered ;;
  ghost)         register "$t/fm-teardown-cleanup.test.sh" test_registered_never_defined ;;
  dup-register)  register "$t/fm-pr-merge-forges.test.sh" test_multi_pr_task_merges_named_pr_when_copy_head_is_a_merged_siblings_head ;;
  dup-define)    define "$t/fm-teardown-cleanup.test.sh" test_teardown_never_holds_up_a_steer_to_another_task ;;
  control-orphan) define "$t/fm-control-relaunch-backends.test.sh" test_defined_never_registered ;;
  watch-orphan)  printf '\ntest_defined_never_called() { :; }\n' >> "$t/fm-watch-triage-helpers.sh" ;;
  watch-twice)   awk '{ print } !d && /^test_[A-Za-z0-9_]+$/ { print; d=1 }' "$t/fm-watch-triage-waits-away.test.sh" > "$t/x.new" && mv "$t/x.new" "$t/fm-watch-triage-waits-away.test.sh" ;;
  comment-heredoc) awk '!d && /^[a-z_]+_test_cases\+?=\(/ { print "# the stub is fed with <<EOF when needed"; print "test_hidden_after_comment() { :; }"; d=1 } { print }' "$t/fm-lint-report.test.sh" > "$t/x.new" && mv "$t/x.new" "$t/fm-lint-report.test.sh" ;;
  copy-not-moved) define "$t/fm-pr-merge-forges.test.sh" test_derived_author_coverage; register "$t/fm-pr-merge-forges.test.sh" test_derived_author_coverage ;;
  unlisted-group) cp "$t/fm-pr-merge-forges.test.sh" "$t/fm-pr-merge-extra.test.sh" ;;
  *) echo "unknown mutation $m" >&2; exit 2 ;;
esac
