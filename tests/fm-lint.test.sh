#!/usr/bin/env bash
# bin/fm-lint.sh's changed-file and cache selection: which roots a source
# change selects, when cached findings must be invalidated, and the dataflow
# findings that survive a joint or private source.
# Modes, installer and policy refusals live in tests/fm-lint-policy.test.sh;
# host slots, memory and scheduling in tests/fm-lint-slots.test.sh; the
# sidecar, selection modes and CI inputs in tests/fm-lint-report.test.sh.
# Shared fixtures: tests/fm-lint-helpers.sh.

# shellcheck source=tests/fm-lint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-lint-helpers.sh"

test_command_words_exclude_inert_source_text() {
  local tmp repo fakebin diff_file listed out attempt
  tmp=$(fm_test_tmproot fm-lint-inert-words)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  cat > "$repo/bin/inert.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'source bin/library.sh' ". bin/library.sh"
"if" source bin/library.sh
"X=literal" source bin/library.sh
jq '. > 1 | . source' /dev/null
awk '{ source = "."; print source }' /dev/null
local_example() {
  local source
  source=literal
  printf '%s\n' "$source"
}
[[ source == source ]]
(( source > 1 ))
case "${1:-}" in ''|.|..) : ;; esac
cat <<'DATA'
source bin/library.sh
. "$unresolved"
# shellcheck source=bin/library.sh
DATA
# source bin/library.sh
SH
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "inert-text selection failed"
  assert_not_contains "$listed" bin/inert.sh "inert source text selected a non-consumer"
  for attempt in 1 2; do
    out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 bin/inert.sh 2>&1) || fail "inert-word lint failed: $out"
  done
  assert_contains "$out" 'cache hit bin/inert.sh' "inert source text disabled successful-result reuse"
  pass "inert quoted programs, prose, comments, conditionals, and heredocs are not imports"
}

test_child_shell_imports_select_and_invalidate_callers() {
  local tmp repo fakebin diff_file listed root out attempt state
  tmp=$(fm_test_tmproot fm-lint-child-imports)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  cat > "$repo/bin/child.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$(pwd)
bash -c '
  . "$1/bin/library.sh"
' _ "$ROOT"
sh -c '. "$1"' _ "$ROOT/bin/library.sh"
SH
  cat > "$repo/bin/child-caller.sh" <<'SH'
#!/usr/bin/env bash
. bin/child.sh
SH
  cat > "$repo/bin/substitution.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(source bin/library.sh; printf ok)" "`source bin/library.sh; printf ok`"
SH
  cat > "$repo/bin/nested.sh" <<'SH'
#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/library.sh"
SH
  cat > "$repo/bin/nested-caller.sh" <<'SH'
#!/usr/bin/env bash
. bin/nested.sh
SH
  diff_file="$tmp/diff.nul"
  for state in unchanged changed deleted; do
    if [ "$state" = changed ]; then printf '\n' >> "$repo/bin/library.sh"; fi
    if [ "$state" = deleted ]; then rm "$repo/bin/library.sh"; fi
    fm_lint_write_diff_file "$diff_file" bin/library.sh
    listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
      "$repo/bin/fm-lint.sh" --list-files) || fail "$state child import selection failed"
    for root in bin/child.sh bin/child-caller.sh bin/substitution.sh bin/nested.sh bin/nested-caller.sh; do
      assert_contains "$listed" "$root" "$state import did not select $root"
      for attempt in 1 2; do
        out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 "$root" 2>&1) || fail "$state $root check failed: $out"
        if [ "$attempt" -eq 1 ]; then
          assert_not_contains "$out" "cache hit $root" "$state child import reused stale analysis"
        else
          assert_contains "$out" "cache hit $root" "resolved $state child import was not reusable"
        fi
      done
    done
  done
  fm_lint_write_diff_file "$diff_file" unrelated-input
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "unrelated child selection failed"
  assert_not_contains "$listed" bin/child.sh "unrelated input selected a resolved child import"
  cat > "$repo/bin/unresolved-child.sh" <<'SH'
#!/usr/bin/env bash
bash -c '
  . "$1"
' _ "$runtime_target"
SH
  for attempt in 1 2; do
    out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 bin/unresolved-child.sh 2>&1) || fail "unresolved child lint failed: $out"
    assert_not_contains "$out" 'cache hit bin/unresolved-child.sh' "unresolved child import authorized reuse"
  done
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "unresolved child selection failed"
  assert_contains "$listed" bin/unresolved-child.sh "unresolved child import lost conservative selection"
  pass "child-shell positional imports and executable substitutions govern selection and cache inputs"
}

test_stdin_heredoc_imports_select_and_invalidate_callers() {
  local tmp repo fakebin diff_file listed root state attempt out
  tmp=$(fm_test_tmproot fm-lint-stdin-imports)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  cat > "$repo/bin/stdin.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$(pwd)
bash -s -- "$ROOT" <<'BASH'
. "$1/bin/library.sh"
BASH
sh -es "$ROOT/bin/library.sh" <<'POSIX'
. "$1"
POSIX
SH
  cat > "$repo/bin/default-stdin.sh" <<'SH'
#!/usr/bin/env bash
bash <<'BASH'
. bin/library.sh
BASH
sh <<-'POSIX'
	. bin/library.sh
	POSIX
SH
  cat > "$repo/bin/stdin-caller.sh" <<'SH'
#!/usr/bin/env bash
. bin/stdin.sh
SH
  cat > "$repo/bin/dash-stdin.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$(pwd)
bash - "$ROOT/bin/library.sh" <<'END'
. "$1"
END
SH
  cat > "$repo/bin/options-dash-stdin.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$(pwd)
bash -- - "$ROOT/bin/library.sh" <<'END'
. "$1"
END
SH
  cat > "$repo/bin/escaped-stdin.sh" <<'SH'
#!/usr/bin/env bash
ROOT=$(pwd)
bash -s "$ROOT/bin/library.sh" <<\END
. "$1"
END
SH
  cat > "$repo/bin/static-stdin.sh" <<'SH'
#!/usr/bin/env bash
bash <<END; sh -c ':'
. bin/library.sh
END
SH
  diff_file="$tmp/diff.nul"
  for state in unchanged changed deleted; do
    if [ "$state" = changed ]; then printf '\n' >> "$repo/bin/library.sh"; fi
    if [ "$state" = deleted ]; then rm "$repo/bin/library.sh"; fi
    fm_lint_write_diff_file "$diff_file" bin/library.sh
    listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
      "$repo/bin/fm-lint.sh" --list-files) || fail "$state stdin import selection failed"
    for root in bin/stdin.sh bin/default-stdin.sh bin/stdin-caller.sh \
      bin/dash-stdin.sh bin/options-dash-stdin.sh bin/escaped-stdin.sh bin/static-stdin.sh; do
      assert_contains "$listed" "$root" "$state stdin import did not select $root"
      for attempt in 1 2; do
        out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 "$root" 2>&1) || fail "$state $root check failed: $out"
        if [ "$attempt" -eq 1 ]; then
          assert_not_contains "$out" "cache hit $root" "$state stdin import reused stale analysis"
        else
          assert_contains "$out" "cache hit $root" "resolved $state stdin import was not reusable"
        fi
      done
    done
  done
  fm_lint_write_diff_file "$diff_file" unrelated-input
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "unrelated stdin selection failed"
  for root in bin/stdin.sh bin/default-stdin.sh bin/stdin-caller.sh \
    bin/dash-stdin.sh bin/options-dash-stdin.sh bin/escaped-stdin.sh bin/static-stdin.sh; do
    assert_not_contains "$listed" "$root" "unrelated input selected resolved $root"
  done
  cat > "$repo/bin/unknown-stdin.sh" <<'SH'
#!/usr/bin/env bash
bash -s -- "$runtime_target" <<'BASH'
. "$1"
BASH
SH
  cat > "$repo/bin/expanded-stdin.sh" <<'SH'
#!/usr/bin/env bash
bash <<END
. "$runtime_target"
END
SH
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "unknown stdin selection failed"
  for root in bin/unknown-stdin.sh bin/expanded-stdin.sh; do
    assert_contains "$listed" "$root" "unknown child stdin lost conservative selection"
    for attempt in 1 2; do
      out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
        "$repo/bin/fm-lint.sh" --jobs 1 "$root" 2>&1) || fail "unknown stdin lint failed: $out"
      assert_not_contains "$out" "cache hit $root" "unknown child stdin authorized reuse"
    done
  done
  pass "executable stdin imports select direct and transitive callers and invalidate reusable closures"
}

test_nonprogram_heredocs_remain_inert() {
  local tmp repo fakebin diff_file listed attempt out
  tmp=$(fm_test_tmproot fm-lint-inert-stdin)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  cat > "$repo/bin/inert-stdin.sh" <<'SH'
#!/usr/bin/env bash
bash -c ':' <<'DATA'
. bin/library.sh
. "$unknown"
DATA
sh bin/plain.sh <<'DATA'
. bin/library.sh
. "$unknown"
DATA
bash -s 3<<'DATA'
. bin/library.sh
. "$unknown"
DATA
bash -s <<'DATA' </dev/null; cat <<'OTHER'
. bin/library.sh
. "$unknown"
DATA
. bin/library.sh
OTHER
SH
  printf '#!/usr/bin/env sh\n:\n' > "$repo/bin/plain.sh"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "inert stdin selection failed"
  assert_not_contains "$listed" bin/inert-stdin.sh "nonprogram heredocs selected an inert root"
  for attempt in 1 2; do
    out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 bin/inert-stdin.sh 2>&1) || fail "inert stdin lint failed: $out"
  done
  assert_contains "$out" 'cache hit bin/inert-stdin.sh' "nonprogram heredocs disabled successful reuse"
  pass "command-string, script-file, and non-stdin heredocs remain import data"
}

test_production_fixture_stdin_imports_invalidate_cache() {
  local tmp repo fakebin diff_file listed helper attempt state out root
  tmp=$(fm_test_tmproot fm-lint-fixture-stdin)
  repo="$tmp/repo"
  fm_lint_production_repo "$repo"
  cp "$ROOT"/tests/*.sh "$repo/tests/"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  diff_file="$tmp/diff.nul"
  root=tests/fm-test-fixtures.test.sh
  for helper in secondmate-helpers wake-helpers herdr-test-safety; do
    for state in unchanged changed deleted; do
      if [ "$state" = changed ]; then printf '\n' >> "$repo/tests/$helper.sh"; fi
      if [ "$state" = deleted ]; then rm "$repo/tests/$helper.sh"; fi
      fm_lint_write_diff_file "$diff_file" "tests/$helper.sh"
      listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
        "$repo/bin/fm-lint.sh" --list-files) || fail "$state $helper selection failed"
      assert_contains "$listed" "$root" "$state $helper did not select its production stdin consumer"
      for attempt in 1 2; do
        out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 "$root" 2>&1) || fail "$state $helper lint failed: $out"
        if [ "$attempt" -eq 1 ] || [ "$helper" != herdr-test-safety ]; then
          assert_not_contains "$out" "cache hit $root" "$state $helper authorized stale or unknown reuse"
        fi
      done
    done
    cp "$ROOT/tests/$helper.sh" "$repo/tests/$helper.sh"
  done
  pass "production fixture stdin helper imports select callers and never authorize stale reuse"
}

test_production_nested_sources_and_pending_reply_cache() {
  local tmp repo fakebin root attempt out
  tmp=$(fm_test_tmproot fm-lint-production-closure)
  repo="$tmp/repo"
  fm_lint_production_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_shellcheck "$fakebin" "$tmp/checks"
  for root in bin/fm-backlog-transition-lib.sh bin/fm-config-inherit-lib.sh \
    bin/fm-ff-lib.sh bin/fm-arm-pretool-check.sh bin/fm-cd-pretool-check.sh \
    bin/fm-vendor-auth-probe.sh bin/fm-worker-account-lib.sh; do
    for attempt in 1 2; do
      out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/nested-cache" \
        "$repo/bin/fm-lint.sh" --jobs 1 "$root" 2>&1) || fail "$root lint failed: $out"
    done
    assert_contains "$out" "cache hit $root" "balanced production source words disabled reuse for $root"
  done
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): real pending-reply closure cache regression"
    return
  fi
  for attempt in 1 2; do
    out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/real-cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 bin/fm-pending-reply-lib.sh 2>&1) \
      || fail "production pending-reply check $attempt failed: $out"
  done
  assert_contains "$out" 'cache hit bin/fm-pending-reply-lib.sh' \
    "unchanged successful production pending-reply closure was not reusable"
  printf '\n' >> "$repo/bin/fm-composer-lib.sh"
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/real-cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/fm-pending-reply-lib.sh 2>&1) \
    || fail "changed production source check failed: $out"
  assert_not_contains "$out" 'cache hit bin/fm-pending-reply-lib.sh' \
    "a real adapter source mutation reused stale pending-reply analysis"
  pass "production nested source words reuse results and the real pending-reply closure invalidates on adapter sources"
}

test_unresolved_runtime_sources_select_possible_callers() {
  local tmp repo diff_file selection listed caller changed override
  tmp=$(fm_test_tmproot fm-lint-possible-callers)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  diff_file="$tmp/diff.nul"
  selection="$tmp/selection.nul"
  for override in /dev/null bin/library.sh; do
    cat > "$repo/bin/runtime.sh" <<SH
#!/usr/bin/env bash
target=bin/library.sh
target=\${1:-\$target}
# shellcheck source=$override
. "\$target"
SH
    cat > "$repo/bin/transitive.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/runtime.sh
. bin/runtime.sh
SH
    for changed in bin/library.sh bin/deleted.sh; do
      fm_lint_write_diff_file "$diff_file" "$changed"
      perl "$repo/bin/fm-lint-cache.pl" select "$repo" < "$diff_file" > "$selection" \
        || fail "possible-caller selection failed"
      listed=$'\n'
      while IFS= read -r -d '' caller; do listed+="$caller"$'\n'; done < "$selection"
      for caller in bin/runtime.sh bin/transitive.sh; do
        assert_contains "$listed" $'\n'"$caller"$'\n' \
          "$override omitted possible caller $caller for $changed"
      done
      assert_not_contains "$listed" $'\n''bin/fm-lint-workflows.sh'$'\n' \
        "possible-caller fallback selected a source-free root"
    done
    for changed in '' unrelated-input; do
      fm_lint_write_diff_file "$diff_file" "$changed"
      perl "$repo/bin/fm-lint-cache.pl" select "$repo" < "$diff_file" > "$selection" \
        || fail "unrelated selection failed"
      [ ! -s "$selection" ] || fail "empty or unrelated change selected possible callers"
    done
  done
  for changed in bin/fm-operational-input.sh bin/fm-tmux-lib.sh \
    bin/fm-supervise-daemon.sh bin/fm-gate-refuse-lib.sh; do
    fm_lint_write_diff_file "$diff_file" "$changed"
    perl "$ROOT/bin/fm-lint-cache.pl" select "$ROOT" < "$diff_file" > "$selection" \
      || fail "assigned-variable consumer selection failed"
    listed=$'\n'
    while IFS= read -r -d '' caller; do listed+="$caller"$'\n'; done < "$selection"
    case "$changed" in
      bin/fm-operational-input.sh) caller=tests/fm-operational-input.test.sh ;;
      bin/fm-tmux-lib.sh) caller=tests/fm-composer-ghost.test.sh ;;
      bin/fm-supervise-daemon.sh)
        assert_contains "$listed" $'\n''tests/fm-afk-inject-herdr-e2e.test.sh'$'\n' \
          "daemon change omitted its Herdr sourcing consumer"
        caller=tests/fm-afk-inject-e2e.test.sh ;;
      bin/fm-gate-refuse-lib.sh) caller=tests/fm-gate-refuse.test.sh ;;
    esac
    assert_contains "$listed" $'\n'"$caller"$'\n' "assigned source omitted $caller"
  done
  pass "unresolved runtime sources select possible direct and transitive callers"
}

test_unresolved_runtime_sources_refuse_cached_success() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): runtime cache safety"; return; }
  local tmp repo out attempt
  tmp=$(fm_test_tmproot fm-lint-runtime-uncertainty)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
needs_argument() {
  printf 'initial\n'
}
SH
  cat > "$repo/bin/runtime.sh" <<'SH'
#!/usr/bin/env bash
target=${1:-bin/library.sh}
# shellcheck source=bin/library.sh
. "$target"
needs_argument
SH
  cat > "$repo/bin/transitive.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/runtime.sh
. bin/runtime.sh
needs_argument
SH
  for attempt in 1 2; do
    out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" bin/transitive.sh 2>&1) \
      || fail "runtime consumer check failed: $out"
    assert_not_contains "$out" 'cache hit bin/transitive.sh' \
      "unproved runtime closure reused successful analysis"
  done
  cat > "$repo/bin/runtime.sh" <<'SH'
#!/usr/bin/env bash
target=${1:-bin/library.sh}
# shellcheck source=/dev/null
. "$target"
printf 'ok\n'
SH
  for attempt in 1 2; do
    out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" bin/transitive.sh 2>&1) \
      || fail "isolated runtime consumer check failed: $out"
    assert_not_contains "$out" 'cache hit bin/transitive.sh' \
      "a /dev/null override authorized reuse of an unproved runtime closure"
  done
  cat > "$repo/bin/runtime.sh" <<'SH'
#!/usr/bin/env bash
target=${1:-bin/library.sh}
# shellcheck source=bin/library.sh
. "$target"
needs_argument
SH
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
needs_argument() {
  printf '%s\n' "$1"
}
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" bin/transitive.sh 2>&1) \
    && fail "runtime consumer hid a changed imported argument requirement"
  assert_contains "$out" SC2119 "runtime consumer lost its joint missing-argument finding"
  pass "unproved transitive runtime closures never reuse successful analysis"
}

test_source_spellings_keep_changed_and_cached_dataflow_findings() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): source spelling regression"; return; }
  local tmp repo fakebin diff_file command_line index=0 out attempt listed
  tmp=$(fm_test_tmproot fm-lint-source-spelling)
  repo="$tmp/repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_small_repo "$repo"
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  printf '%s\n' '#!/usr/bin/env bash' 'export module_value=ok' > "$repo/bin/library.sh"
  for command_line in '\source bin/library.sh' 'sour\
ce bin/library.sh' 'source 2>/dev/null bin/library.sh' 'source b"in"/library.sh' \
    "X=\"\$(printf x)\" source bin/library.sh" 'time -p source bin/library.sh' \
    '</dev/null source bin/library.sh' \
    "case \"\${1:-}\" in a) source bin/library.sh ;; esac"; do
    index=$((index + 1))
    printf '%s\n' '#!/usr/bin/env bash' "$command_line" \
      "printf '%s\\n' \"\$module_value\"" > "$repo/bin/spelling-$index.sh"
    out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 "bin/spelling-$index.sh" 2>&1) \
      || fail "source spelling $index did not initially pass: $out"
  done
  cat > "$repo/bin/unparsed.sh" <<'SH'
#!/usr/bin/env bash
builtin source bin/library.sh
SH
  for attempt in 1 2; do
    out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$repo/bin/fm-lint.sh" --jobs 1 bin/unparsed.sh 2>&1) \
      || fail "unsupported source wrapper check $attempt failed: $out"
    assert_not_contains "$out" 'cache hit bin/unparsed.sh' \
      "an unparsed source form authorized successful-result reuse"
  done
  fm_lint_write_diff_file "$diff_file" unrelated-input
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "unparsed source selection failed"
  assert_not_contains "$listed" bin/unparsed.sh "an unrelated change selected a root with an unparsed source form"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  printf '%s\n' '#!/usr/bin/env bash' 'export other_value=ok' > "$repo/bin/library.sh"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --jobs 1 2>&1) && fail "source spelling hid changed imported state"
  assert_contains "$out" SC2154 "source spelling or cached success hid the dataflow warning"
  for index in 1 2 3 4 5 6 7 8; do
    assert_contains "$out" "In bin/spelling-$index.sh line" \
      "changed imported state did not recheck source spelling $index"
  done
  pass "source spellings and command prefixes retain changed/cached dataflow findings"
}

test_joint_sources_keep_call_dependent_findings() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): joint-source call regression"; return; }
  local tmp repo fakebin diff_file out rc mode
  tmp=$(fm_test_tmproot fm-lint-joint-call)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
needs_argument() {
  printf '%s\n' "$1"
}
SH
  cat > "$repo/bin/consumer.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/library.sh
. "$(dirname "${BASH_SOURCE[0]}")/library.sh"
needs_argument supplied
SH
  # Prove this exact joint call passed and was cached before mutating the caller.
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/warm-cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    || fail "argument-bearing joint call did not pass: $out"
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/warm-cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    || fail "argument-bearing cached joint call did not pass: $out"
  assert_contains "$out" 'cache hit bin/consumer.sh' "clean joint call was not cached"
  cat > "$repo/bin/consumer.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/library.sh
. "$(dirname "${BASH_SOURCE[0]}")/library.sh"
needs_argument
SH
  # The definition alone is clean; only source-aware caller analysis catches it.
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/library.sh 2>&1) \
    || fail "owner-only fixture should be clean: $out"
  assert_not_contains "$out" SC2119 "owner-only analysis unexpectedly caught the call-dependent defect"
  for mode in explicit changed cold-cache mutated-cache ci; do
    rc=0
    case "$mode" in
      explicit)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
          "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) || rc=$?
        ;;
      changed)
        out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
          FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
          "$repo/bin/fm-lint.sh" --jobs 1 2>&1) || rc=$?
        ;;
      cold-cache)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cold-cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) || rc=$?
        ;;
      mutated-cache)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/warm-cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) || rc=$?
        assert_not_contains "$out" 'cache hit bin/consumer.sh' \
          "consumer mutation reused its argument-bearing cached result"
        ;;
      ci)
        out=$(CI=true GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/warm-cache" \
          "$repo/bin/fm-lint.sh" --jobs 1 2>&1) || rc=$?
        assert_not_contains "$out" 'cache hit ' "CI reused local lint successes"
        ;;
    esac
    [ "$rc" -eq 1 ] || fail "$mode joint source analysis did not reject the missing argument: $out"
    assert_contains "$out" SC2119 "$mode joint source analysis lost the call-dependent warning"
    assert_contains "$out" 'In bin/consumer.sh line' "$mode did not analyze the calling consumer"
  done
  pass "joint-source calls retain SC2119 in explicit, changed, cold, mutated-cache, and CI modes"
}

test_private_source_keeps_changed_call_dependent_findings() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): private-source call regression"; return; }
  local tmp repo fakebin diff_file out rc mode
  tmp=$(fm_test_tmproot fm-lint-private-source-call)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
needs_argument() {
  printf 'initial\n'
}
SH
  cat > "$repo/bin/consumer.sh" <<'SH'
#!/usr/bin/env bash
_load_library() {
  # shellcheck source=bin/library.sh
  . "$(dirname "${BASH_SOURCE[0]}")/library.sh"
}
_load_library "$@"
needs_argument
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) \
    || fail "private-source consumer did not initially pass: $out"
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) \
    || fail "private-source consumer did not reuse its clean result: $out"
  assert_contains "$out" 'cache hit bin/consumer.sh' "private-source consumer was not cached"
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
needs_argument() {
  printf '%s\n' "$1"
}
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
    "$repo/bin/fm-lint.sh" bin/library.sh 2>&1) \
    || fail "private-source owner alone should remain clean: $out"
  for mode in explicit changed cold-cache mutated-cache ci; do
    rc=0
    case "$mode" in
      explicit)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
          "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) || rc=$?
        ;;
      changed)
        out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR=off \
          FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_DIFF_FILE="$diff_file" \
          "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
        ;;
      cold-cache)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cold-cache" \
          "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) || rc=$?
        ;;
      mutated-cache)
        out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
          "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) || rc=$?
        assert_not_contains "$out" 'cache hit bin/consumer.sh' "changed private import reused a stale success"
        ;;
      ci)
        out=$(CI=true GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
          "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
        assert_not_contains "$out" 'cache hit ' "CI reused a private-source success"
        ;;
    esac
    [ "$rc" -eq 1 ] || fail "$mode private source hid the changed argument requirement: $out"
    assert_contains "$out" SC2119 "$mode private source lost the imported call-site diagnostic"
    assert_contains "$out" 'In bin/consumer.sh line' "$mode did not analyze the private import's consumer"
  done
  pass "private-source imports retain changed-library call diagnostics across selection and cache modes"
}

test_declaration_source_words_do_not_disable_cache() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): declaration cache regression"; return; }
  local tmp repo out
  tmp=$(fm_test_tmproot fm-lint-declaration-cache)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
library_value() { # <source>
  local source rest
  source=one
  rest=two
  printf '%s\n' "$source" "$rest"
}
SH
  cat > "$repo/bin/consumer.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/library.sh
. bin/library.sh
library_value
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    || fail "declaration fixture did not pass: $out"
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    || fail "cached declaration fixture did not pass: $out"
  assert_contains "$out" 'cache hit bin/consumer.sh' \
    "a declaration argument or inline function comment disabled consumer reuse"
  cat > "$repo/bin/library.sh" <<'SH'
#!/usr/bin/env bash
library_value() {
  printf '%s\n' "$1"
}
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    && fail "cached declaration consumer hid a changed argument requirement"
  assert_contains "$out" SC2119 "changed library argument requirement was hidden"
  assert_not_contains "$out" 'cache hit bin/consumer.sh' "changed declaration library reused a cached caller"
  pass "declaration words permit reuse without hiding changed cross-file argument requirements"
}

test_fast_cache_cannot_hide_full_analysis_findings() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): analysis-mode cache boundary"; return; }
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-mode-cache)
  cat > "$tmp/unused.sh" <<'SH'
#!/usr/bin/env bash
outer() {
  (
    helper() { printf 'unused\n'; }
    printf 'outer\n'
  )
}
outer
SH
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$LINT" --fast "$tmp/unused.sh" 2>&1) || fail "fast fixture did not pass: $out"
  rc=0
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$LINT" "$tmp/unused.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "full analysis reused the fast success: $out"
  assert_contains "$out" SC2329 "a fast cache entry hid the full-analysis finding"
  pass "a fast-mode success cannot satisfy source-aware extended analysis"
}

test_changed_dependencies_and_deleted_sources_retain_findings() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): dependency finding regression"; return; }
  local tmp repo fakebin diff_file listed out rc
  tmp=$(fm_test_tmproot fm-lint-source-changes)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff"
  fm_lint_write_diff_file "$diff_file" bin/library.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files)
  assert_contains "$listed" bin/caller.sh "changed library did not select its transitive caller"
  assert_contains "$listed" bin/consumer.sh "changed library did not select its direct caller"
  assert_contains "$listed" bin/library.sh "changed library did not select the library"
  cat >> "$repo/bin/library.sh" <<'SH'
bad() {
  local a= b=
  printf '%s\n' "$a$b"
}
bad
SH
  rc=0
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "changed dependency defect was not rejected: $out"
  assert_contains "$out" SC1007 "changed mode lost the seeded library finding"
  rc=0
  out=$(CI=true "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "CI lint did not reject the same dependency defect: $out"
  assert_contains "$out" SC1007 "CI lint lost the seeded library finding"
  rm "$repo/bin/library.sh"
  rc=0
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "deleted source was not rejected: $out"
  assert_contains "$out" SC1091 "changed mode hid a deleted source"
  pass "changed and deleted libraries recheck transitive callers with the full diagnostic rules"
}

test_selection_adds_no_unchanged_imported_roots() {
  local tmp repo fakebin diff_file log listed out
  tmp=$(fm_test_tmproot fm-lint-no-imported-roots)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  fm_lint_write_diff_file "$diff_file" bin/consumer.sh
  listed=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files) || fail "changed consumer selection failed"
  assert_contains "$listed" bin/consumer.sh "changed consumer was not selected"
  assert_contains "$listed" bin/caller.sh "changed consumer did not select its caller"
  assert_not_contains "$listed" bin/library.sh "changed consumer selected its unchanged imported library"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_JOBS=1 FM_LINT_CACHE_DIR=off \
    "$repo/bin/fm-lint.sh" bin/caller.sh 2>&1) || fail "explicit caller lint failed: $out"
  [ "$(cat "$log")" = bin/caller.sh ] \
    || fail "explicit path added imported roots"$'\n'"logged: $(cat "$log")"
  pass "selection analyzes unchanged imports only through changed or explicit callers"
}

test_runtime_backend_changes_select_every_dispatcher_consumer() {
  local tmp diff_file selection caller backend listed
  tmp=$(fm_test_tmproot fm-lint-runtime-selection)
  diff_file="$tmp/diff.nul"
  selection="$tmp/selection.nul"
  for backend in tmux herdr zellij orca cmux; do
    fm_lint_write_diff_file "$diff_file" "bin/backends/$backend.sh"
    perl "$ROOT/bin/fm-lint-cache.pl" select "$ROOT" < "$diff_file" > "$selection" \
      || fail "$backend dependency selection failed"
    listed=$'\n'
    while IFS= read -r -d '' caller; do
      listed+="$caller"$'\n'
    done < "$selection"
    assert_contains "$listed" $'\n'"bin/backends/$backend.sh"$'\n' \
      "$backend change did not select its adapter root"
    for caller in bin/fm-backend.sh bin/fm-spawn.sh bin/fm-send.sh bin/fm-watch.sh \
      tests/fm-pending-reply.test.sh; do
      assert_contains "$listed" $'\n'"$caller"$'\n' \
        "$backend change did not select dispatcher consumer $caller"
    done
    if [ "$backend" = herdr ]; then
      assert_contains "$listed" $'\n''tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh'$'\n' \
        "Herdr change omitted its real multiline child-shell consumer"
    fi
  done
  fm_lint_write_diff_file "$diff_file" unrelated-input
  perl "$ROOT/bin/fm-lint-cache.pl" select "$ROOT" < "$diff_file" > "$selection" \
    || fail "unrelated-input dependency selection failed"
  [ ! -s "$selection" ] || fail "an unrelated input selected runtime backend consumers"
  pass "each runtime backend change selects every direct and transitive dispatcher consumer"
}

test_runtime_backend_inputs_invalidate_dispatcher_cache() {
  local tmp repo fakebin log backend root attempt state out
  tmp=$(fm_test_tmproot fm-lint-runtime-cache)
  repo="$tmp/repo"
  fm_lint_production_repo "$repo"
  cat >> "$repo/bin/consumer.sh" <<'SH'
# shellcheck source=bin/fm-backend.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-backend.sh"
SH
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  for backend in tmux herdr zellij orca cmux; do
    for attempt in 1 2; do
      for root in bin/fm-backend.sh bin/caller.sh; do
        out=$(perl "$repo/bin/fm-lint-cache.pl" check "$tmp/cache" "$repo" \
          "$fakebin/shellcheck" --norc --external-sources -- "$root" 2>&1) \
          || fail "$backend cache warm-up $attempt failed for $root: $out"
        if [ "$attempt" -eq 2 ]; then
          assert_contains "$out" "cache hit $root" "clean $root result was not reusable"
        fi
      done
    done
    for state in changed deleted; do
      if [ "$state" = changed ]; then
        printf '\n' >> "$repo/bin/backends/$backend.sh"
      else
        rm "$repo/bin/backends/$backend.sh"
      fi
      : > "$log"
      for root in bin/fm-backend.sh bin/caller.sh; do
        out=$(perl "$repo/bin/fm-lint-cache.pl" check "$tmp/cache" "$repo" \
          "$fakebin/shellcheck" --norc --external-sources -- "$root" 2>&1) \
          || fail "$state $backend check failed for $root: $out"
        assert_not_contains "$out" "cache hit $root" "$state $backend reused stale $root analysis"
      done
      [ "$(cat "$log")" = $'bin/fm-backend.sh\nbin/caller.sh' ] \
        || fail "$state $backend did not recheck dispatcher and transitive caller: $(cat "$log")"
    done
    cp "$ROOT/bin/backends/$backend.sh" "$repo/bin/backends/$backend.sh"
  done
  pass "changes and deletions of every runtime backend invalidate dispatcher and caller caches"
}

test_shared_cache_reuses_only_identical_successful_inputs() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): shared cache regression"; return; }
  local tmp one two fakebin real log out rc before after first second
  tmp=$(fm_test_tmproot fm-lint-cache)
  one="$tmp/one"
  two="$tmp/two"
  fm_lint_small_repo "$one"
  fm_lint_small_repo "$two"
  fakebin=$(fm_fakebin "$tmp")
  real=$(command -v shellcheck)
  log="$tmp/checks"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" != --version ]; then
  printf '%s\n' "\${!#}" >> "$log"
  sleep 0.2
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/shellcheck"
  PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$one/bin/fm-lint.sh" bin/consumer.sh bin/library.sh > "$tmp/one.out" 2>&1 &
  first=$!
  PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$two/bin/fm-lint.sh" bin/consumer.sh bin/library.sh > "$tmp/two.out" 2>&1 &
  second=$!
  wait "$first" || fail "first simultaneous cache miss failed: $(cat "$tmp/one.out")"
  wait "$second" || fail "second simultaneous cache miss failed: $(cat "$tmp/two.out")"
  [ "$(LC_ALL=C sort "$log")" = $'bin/consumer.sh\nbin/library.sh' ] \
    || fail "identical simultaneous roots were checked more than once: $(cat "$log")"
  printf '#!/usr/bin/env bash\nexport SHARED_VALUE=changed\n' > "$two/bin/library.sh"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$two/bin/fm-lint.sh" bin/consumer.sh bin/library.sh 2>&1) || fail "changed source check failed: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 4 ] \
    || fail "source content mutation reused an obsolete successful result"
  before=$(wc -l < "$log" | tr -d ' ')
  printf '\n' >> "$fakebin/shellcheck"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$two/bin/fm-lint.sh" bin/consumer.sh bin/library.sh 2>&1) || fail "changed binary check failed: $out"
  after=$(wc -l < "$log" | tr -d ' ')
  [ "$after" -eq "$((before + 2))" ] || fail "changed ShellCheck binary reused obsolete results"
  cat >> "$two/bin/library.sh" <<'SH'
bad() {
  local a= b=
  printf '%s\n' "$a$b"
}
bad
SH
  for rc in 1 2; do
    out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      "$two/bin/fm-lint.sh" bin/consumer.sh bin/library.sh 2>&1) && fail "cached library defect unexpectedly passed"
    assert_contains "$out" SC1007 "a cached result hid the seeded source defect"
  done
  [ "$(grep -c '^bin/library.sh$' "$log")" = 5 ] \
    || fail "a finding was reused instead of rechecked"
  rm "$two/bin/library.sh"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$two/bin/fm-lint.sh" bin/consumer.sh 2>&1) && fail "cached result hid a deleted source"
  assert_contains "$out" SC1091 "deleted cached source did not invalidate the caller"
  pass "shared cache single-flights identical misses and invalidates sources, binaries and failures"
}

test_list_files_reports_the_shell_inventory() {
  local listed expected
  # CI=true forces the full canonical set regardless of the ambient branch or
  # working-tree diff a local test run happens to have, so this stays a pure
  # inventory check independent of fm-lint.sh's own changed-file mode below.
  listed=$(CI=true "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh --list-files did not return the complete shell inventory"
  pass "fm-lint.sh --list-files reports the complete shell inventory"
}

test_canonical_partitions_preserve_full_lint() {
  local tmp fakebin all part selected log flags mode rc option invocation_count root_count
  tmp=$(fm_test_tmproot fm-lint-partitions)
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  all=$(CI=true "$LINT" --list-files | LC_ALL=C sort)
  : > "$tmp/union"
  for part in 1of3 2of3 3of3; do
    selected=$(CI=false GITHUB_ACTIONS=false "$LINT" --partition "$part" --list-files) \
      || fail "partition $part must select full canonical roots even on a local branch"
    [ -n "$selected" ] || fail "empty lint partition $part"
    printf '%s\n' "$selected" >> "$tmp/union"
    [ "$selected" = "$("$LINT" --partition "$part" --list-files)" ] \
      || fail "partition $part is nondeterministic"
    log="$tmp/$part.roots"
    flags="$tmp/$part.flags"
    mode="$tmp/$part.mode"
    fm_lint_stub_shellcheck "$fakebin" "$log"
    PATH="$fakebin:$PATH" FM_TEST_FLAG_LOG="$flags" FM_TEST_MODE_LOG="$mode" \
      "$LINT" --partition "$part" > "$tmp/$part.out" 2>&1 \
      || fail "canonical partition $part failed: $(cat "$tmp/$part.out")"
    [ "$(LC_ALL=C sort "$log")" = "$(printf '%s\n' "$selected" | LC_ALL=C sort)" ] \
      || fail "partition $part executed a different root set than it listed"
    [ "$(LC_ALL=C sort -u "$flags")" = "$(printf 'exclude=none\nexternal-sources=yes')" ] \
      || fail "partition $part weakened source-aware analysis"
    [ "$(LC_ALL=C sort -u "$mode")" = on ] || fail "partition $part disabled full analysis"
    root_count=$(printf '%s\n' "$selected" | grep -c .)
    invocation_count=$(grep -c '^external-sources=' "$flags" || true)
    [ "$invocation_count" -eq "$root_count" ] \
      || fail "partition $part used $invocation_count ShellCheck calls for $root_count roots"
    [ "$(grep -c '^fm-lint: begin ' "$tmp/$part.out" || true)" -eq "$root_count" ] \
      || fail "partition $part did not stream a begin record per root"
    [ "$(grep -c '^fm-lint: end ' "$tmp/$part.out" || true)" -eq "$root_count" ] \
      || fail "partition $part did not stream an end record per root"
  done
  [ "$(LC_ALL=C sort "$tmp/union")" = "$all" ] || fail "lint partitions lose or duplicate canonical roots"
  for option in 0of3 4of3 1of2; do
    rc=0
    "$LINT" --partition "$option" --list-files > "$tmp/refused" 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "invalid partition $option was not refused"
  done
  rc=0
  "$LINT" --partition 1of3 --fast > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted --fast"
  rc=0
  "$LINT" --partition 1of3 bin/fm-lint.sh > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted an explicit subset"
  pass "three canonical lint partitions preserve complete source-aware coverage and reject weakened modes"
}

test_canonical_partitions_balance_measured_cost() {
  local tmp part selected cost all
  tmp=$(fm_test_tmproot fm-lint-measured-balance)
  mkdir -p "$tmp/repo/bin/backends" "$tmp/repo/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/repo/bin/backends/noop.sh"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/repo/bin/"
  # Equal-sized roots deliberately make direct bytes a misleading cost proxy.
  # Seed independent duration evidence; assert only the executable selection.
  python3 - "$tmp/repo" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
hints = []
for name, weight in zip("abcdef", [600, 500, 400, 300, 200, 100]):
    path = f"tests/{name}.test.sh"
    (root / path).write_text("#!/usr/bin/env bash\nexit 0\n")
    hints.append(f"{path}\t{weight}")
runner = root / "bin/fm-lint.sh"
text = runner.read_text()
start = text.index("  cat <<'EOF'\n", text.index("fm_lint_partition_weight_hints() {")) + len("  cat <<'EOF'\n")
end = text.index("\nEOF", start)
# Include the runner and backend roots in the fixture's cost model.
runner.write_text(text[:start] + "\n".join(hints + ["bin/fm-lint.sh\t1", "bin/backends/noop.sh\t1"]) + text[end:])
PY
  : > "$tmp/union"
  for part in 1of3 2of3 3of3; do
    selected=$(cd "$tmp/repo" && bin/fm-lint.sh --partition "$part" --list-files) \
      || fail "measured-cost partition $part refused the fixture"
    printf '%s\n' "$selected" >> "$tmp/union"
    cost=$(printf '%s\n' "$selected" | awk '
      /tests\/a.test.sh$/ { cost+=600 }
      /tests\/b.test.sh$/ { cost+=500 }
      /tests\/c.test.sh$/ { cost+=400 }
      /tests\/d.test.sh$/ { cost+=300 }
      /tests\/e.test.sh$/ { cost+=200 }
      /tests\/f.test.sh$/ { cost+=100 }
      END { print cost+0 }
    ')
    [ "$cost" -eq 700 ] || fail "partition $part packs $cost ms instead of 700 ms of measured test work"
  done
  all=$(cd "$tmp/repo" && CI=true bin/fm-lint.sh --list-files | LC_ALL=C sort)
  [ "$(LC_ALL=C sort "$tmp/union")" = "$all" ] || fail "cost-balanced partitions lose or duplicate roots"
  pass "canonical partitions balance measured analysis cost rather than equal direct bytes"
}

fm_lint_test_cases=(
test_command_words_exclude_inert_source_text
test_child_shell_imports_select_and_invalidate_callers
test_stdin_heredoc_imports_select_and_invalidate_callers
test_nonprogram_heredocs_remain_inert
test_production_fixture_stdin_imports_invalidate_cache
test_production_nested_sources_and_pending_reply_cache
test_unresolved_runtime_sources_select_possible_callers
test_unresolved_runtime_sources_refuse_cached_success
test_source_spellings_keep_changed_and_cached_dataflow_findings
test_joint_sources_keep_call_dependent_findings
test_private_source_keeps_changed_call_dependent_findings
test_declaration_source_words_do_not_disable_cache
test_fast_cache_cannot_hide_full_analysis_findings
test_changed_dependencies_and_deleted_sources_retain_findings
test_selection_adds_no_unchanged_imported_roots
test_runtime_backend_changes_select_every_dispatcher_consumer
test_runtime_backend_inputs_invalidate_dispatcher_cache
test_shared_cache_reuses_only_identical_successful_inputs
test_list_files_reports_the_shell_inventory
test_canonical_partitions_preserve_full_lint
test_canonical_partitions_balance_measured_cost
)
fm_lint_run "$@"
