#!/usr/bin/env bash
# bin/fm-lint.sh's reporting and selection modes: the per-root sidecar, the
# exit status it reflects, CI and main-branch inputs, explicit paths, an empty
# diff, and the external-source rules around them.
# Changed-file selection lives in tests/fm-lint.test.sh; modes and installer
# refusals in tests/fm-lint-policy.test.sh; host slots and memory in
# tests/fm-lint-slots.test.sh.
# Shared fixtures: tests/fm-lint-helpers.sh.

# shellcheck source=tests/fm-lint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-lint-helpers.sh"

test_memory_fallback_spends_only_the_remaining_root_deadline() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): fallback deadline check"
    return
  fi
  local tmp fakebin fixture log out rc duration_ms
  tmp=$(fm_test_tmproot fm-lint-fallback-deadline)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/teardown.sh"
  log="$tmp/attempts.log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'follow\n' >> "$FM_TEST_ATTEMPT_LOG"
    sleep "$FM_TEST_FIRST_SECS"
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
printf 'fallback\n' >> "$FM_TEST_ATTEMPT_LOG"
sleep 60
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  # A 3s first attempt leaves about 3s of the 6s deadline, so the retry is
  # killed there; a fresh deadline would let the root run for about 9s.
  : > "$log"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
    FM_LINT_ROOT_SECONDS=6 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_ATTEMPT_LOG="$log" FM_TEST_FIRST_SECS=3 \
    "$LINT" --telemetry "$tmp/partial.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fallback cut off by the root deadline unexpectedly passed"
  [ "$(cat "$log")" = "$(printf 'follow\nfallback')" ] \
    || fail "the root did not retry once with its remaining time"$'\n'"$(cat "$log")"
  assert_contains "$out" "fallback reason=timeout" \
    "the fallback was not stopped by the root's remaining deadline"$'\n'"$out"
  duration_ms=$(awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ { print $8 }' "$tmp/partial.roots.tsv")
  [ "$duration_ms" -lt 7000 ] \
    || fail "the first attempt and fallback together exceeded the root deadline plus grace: ${duration_ms}ms"

  # With under a second of the deadline left, no retry starts.
  : > "$log"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
    FM_LINT_ROOT_SECONDS=6 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_ATTEMPT_LOG="$log" FM_TEST_FIRST_SECS=5.2 \
    "$LINT" --telemetry "$tmp/spent.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a memory failure with no deadline left unexpectedly passed"
  [ "$(cat "$log")" = follow ] \
    || fail "a fallback started with no time left in the root deadline"$'\n'"$(cat "$log")"
  assert_contains "$out" "no time left in its 6s deadline to retry without it" \
    "the skipped fallback was not explained"$'\n'"$out"
  awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $10 == "memory" && $12 == 1 { found=1 } END { exit !found }' \
    "$tmp/spent.roots.tsv" || fail "the unretried memory failure was not recorded as a source-following memory failure"
  pass "a memory fallback runs only within the time left in its root's original deadline"
}

test_memory_evidence_outranks_findings_and_signal_reasons() {
  local tmp fakebin roots_log out rc name reason bounded
  local -a roots modes
  tmp=$(fm_test_tmproot fm-lint-memory-evidence)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  roots=()
  for name in oom-exit1 oom-perl oom-heap oom-kill oom-text-findings; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$name.sh"
    roots+=("$tmp/$name.sh")
  done
  modes=(0)
  if fm_lint_bounds_supported; then
    modes+=(1)
  fi

  # A memory death reports memory whether the runtime exits 1 with a
  # program-prefixed OOM error or Perl's bare one, exits with GHC's
  # heap-exhaustion status, or is SIGKILLed after printing OOM text; a findings
  # root whose echoed source line merely quotes "out of memory" stays findings.
  for bounded in "${modes[@]}"; do
    roots_log="$tmp/lint.$bounded.roots.tsv"
    rc=0
    if [ "$bounded" = 1 ]; then
      out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
        "$LINT" --telemetry "$tmp/lint.$bounded.tsv" "${roots[@]}" 2>&1) || rc=$?
    else
      out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
        "$LINT" --telemetry "$tmp/lint.$bounded.tsv" "${roots[@]}" 2>&1) || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "memory deaths unexpectedly passed (bounded=$bounded)"
    for name in oom-exit1 oom-perl oom-heap oom-kill oom-text-findings; do
      reason=$(awk -F '\t' -v root="/$name.sh" \
        '$1 == "end" && substr($3, length($3) - length(root) + 1) == root { print $10 }' \
        "$roots_log")
      case "$name" in
        oom-text-findings)
          [ "$reason" = findings ] \
            || fail "$name was classified '$reason', expected findings (bounded=$bounded)"$'\n'"$out"
          ;;
        *)
          [ "$reason" = memory ] \
            || fail "$name was classified '$reason', expected memory (bounded=$bounded)"$'\n'"$out"
          ;;
      esac
    done
  done
  pass "explicit memory evidence outranks findings and signal reasons (modes: ${modes[*]})"
}

test_source_excerpt_with_oom_text_stays_findings() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): OOM-text source excerpt check"
    return
  fi
  local tmp fixture out rc reason
  tmp=$(fm_test_tmproot fm-lint-oom-text-excerpt)
  fixture="$tmp/excerpt.sh"
  # The finding's echoed source excerpt reads like a runtime OOM error; the
  # root still exits with ordinary findings and must be reported as findings.
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
x=$1
shellcheck: out of memory $x
SH
  rc=0
  out=$("$LINT" --telemetry "$tmp/lint.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a root with an ordinary finding exited $rc, expected 1"$'\n'"$out"
  assert_contains "$out" "shellcheck: out of memory" "the source excerpt was not echoed with the finding"
  assert_contains "$out" "SC2086" "the ordinary finding was not reported"
  reason=$(awk -F '\t' '$1 == "end" && $3 ~ /excerpt\.sh$/ { print $10 }' "$tmp/lint.roots.tsv")
  [ "$reason" = findings ] \
    || fail "a source excerpt quoting OOM text was classified '$reason', expected findings"$'\n'"$out"

  # A root whose path contains OOM words and cannot be opened fails with an
  # ordinary file error that names the path on stderr; it is an error, not a
  # memory death.
  rc=0
  out=$("$LINT" --telemetry "$tmp/missing.tsv" "$tmp/out of memory.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing root unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "out of memory.sh" "the missing root's file error did not name its path"
  reason=$(awk -F '\t' '$1 == "end" && $3 ~ /out of memory\.sh$/ { print $10 }' "$tmp/missing.roots.tsv")
  case "$reason" in
    error:*) ;;
    *) fail "a missing root named with OOM words was classified '$reason', expected error"$'\n'"$out" ;;
  esac
  pass "OOM words in a source excerpt or a root path never classify a root as memory"
}

test_require_bounds_refuses_when_enforcement_is_missing() {
  local tmp fakebin stub_log fixture out rc lone_dir
  tmp=$(fm_test_tmproot fm-lint-require-bounds)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_shellcheck "$fakebin" "$tmp/stub.log"
  stub_log="$tmp/stub.log"
  fixture="$tmp/clean.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"

  # A script copied without its sibling watchdog library cannot enforce the
  # wall deadline, so a required-bounds run must refuse before ShellCheck.
  lone_dir="$tmp/lone"
  mkdir -p "$lone_dir"
  cp "$LINT" "$lone_dir/fm-lint.sh"
  cp "$ROOT/bin/fm-lint-cache.pl" "$lone_dir/"
  chmod +x "$lone_dir/fm-lint.sh"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
    "$lone_dir/fm-lint.sh" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a watchdog-less run under REQUIRE_BOUNDS exited $rc, expected 2"
  assert_contains "$out" "fm-timeout-lib.sh" "the refusal did not name the missing watchdog library"
  assert_contains "$out" "refusing to lint uncapped" "the refusal did not explain itself"
  [ ! -s "$stub_log" ] \
    || fail "a watchdog-refused run still invoked ShellCheck"

  if ( ulimit -v 65536 ) 2>/dev/null; then
    # The host accepts the memory limit, so a required-bounds run proceeds and
    # still lints the root.
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "an enforceable bounded run was refused"$'\n'"$out"
    [ -s "$stub_log" ] || fail "an enforceable bounded run never invoked ShellCheck"
  else
    # The host rejects the address-space limit outright (macOS), so the run
    # must refuse by name rather than lint uncapped.
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "an unenforceable memory limit under REQUIRE_BOUNDS exited $rc, expected 2"
    assert_contains "$out" "FM_LINT_ROOT_MEMORY_KIB" \
      "the refusal did not name the unenforceable memory limit"
    assert_contains "$out" "refusing to lint uncapped" "the refusal did not explain itself"
    [ ! -s "$stub_log" ] \
      || fail "a bound-refused run still invoked ShellCheck"
  fi
  pass "FM_LINT_REQUIRE_BOUNDS refuses missing enforcement and proceeds when enforceable"
}

test_pinned_shellcheck_memory_limit() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): pinned memory-envelope check"
    return
  fi
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): pinned memory-envelope check"
    return
  fi
  local tmp telemetry roots_log out rc fixture
  tmp=$(fm_test_tmproot fm-lint-pinned-memory)
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  fixture="$tmp/small.sh"
  printf '#!/usr/bin/env bash\nprintf ok\n' > "$fixture"

  # The pinned ShellCheck must start and lint under the configured memory
  # limit - this is what proves the address-space cap leaves GHC enough head
  # room instead of discovering the conflict mid-partition in CI.
  rc=0
  out=$(FM_LINT_REQUIRE_BOUNDS=1 "$LINT" \
    --telemetry "$telemetry" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "pinned ShellCheck did not lint under the default memory limit"$'\n'"$out"
  grep -q $'^meta\tbounds_enforced\t1$' "$roots_log" \
    || fail "the sidecar did not record enforced bounds"
  grep -q $'^meta\troot_memory_limit_kib\t12582912$' "$roots_log" \
    || fail "the sidecar did not record the applied memory limit"
  awk -F '\t' '$1 == "end" && $3 ~ /small\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the pinned root did not complete ok under the memory limit"

  # A limit below the pinned binary's own mapped size must bind the same
  # pinned root: it is refused or killed and named, never silently uncapped.
  # GHC shrinks its heap reservation to fit a larger cap, so a small file can
  # still lint under a few hundred MiB; only a cap under the binary itself
  # binds on every Linux architecture.
  rc=0
  out=$(FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=8192 \
    "$LINT" --telemetry "$tmp/tiny.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "pinned ShellCheck ignored an 8 MiB address-space limit"
  assert_contains "$out" "small.sh" "the memory-bound pinned root was not named"
  awk -F '\t' '$1 == "end" && $3 ~ /small\.sh$/ && $10 != "ok" && $10 != "findings" { found=1 } END { exit !found }' \
    "$tmp/tiny.roots.tsv" || fail "the over-limit pinned root was not recorded as an abnormal end"$'\n'"$out"
  pass "the pinned ShellCheck both respects and survives under the memory envelope"
}

test_sidecar_result_exit_reflects_final_status() {
  local tmp fakebin log telemetry roots_log out rc
  tmp=$(fm_test_tmproot fm-lint-sidecar-result)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  mkdir -p "$tmp/repo/bin/backends" "$tmp/repo/tests" "$tmp/repo/.github/workflows"
  cp "$LINT" "$tmp/repo/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/repo/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$tmp/repo/bin/fm-timeout-lib.sh"
  cat > "$tmp/repo/bin/fm-lint-workflows.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/bin/backends/noop.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$tmp/repo/tests/noop.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  printf '#!/usr/bin/env bash\nbd close fm-example\n' > "$tmp/repo/bin/direct-beads.sh"
  chmod +x "$tmp/repo/bin/fm-lint.sh" "$tmp/repo/bin/fm-lint-workflows.sh"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  # Every ShellCheck root passes, then the backend-purity check fails the run:
  # the retained records must carry that final status, not the clean lint exit.
  rc=0
  out=$(cd "$tmp/repo" && CI=true PATH="$fakebin:$PATH" \
    "$tmp/repo/bin/fm-lint.sh" --telemetry "$telemetry" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a backend-purity failure did not fail the lint run (exit $rc)"$'\n'"$out"
  assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
    "the run did not report its backend-purity failure"
  grep -q $'^meta\tresult_exit\t1$' "$roots_log" \
    || fail "the sidecar recorded the pre-check status instead of the final exit"
  grep -q $'^result_exit\t1$' "$telemetry" \
    || fail "telemetry recorded the pre-check status instead of the final exit"
  pass "the roots sidecar and telemetry record the run's final exit status"
}

test_roots_sidecar_records_per_root_lifecycle() {
  local tmp fakebin stub_log telemetry roots_log out rc
  local alpha beta gamma
  tmp=$(fm_test_tmproot fm-lint-roots-log)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_shellcheck "$fakebin" "$tmp/stub.log"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  alpha="$tmp/alpha.sh"; beta="$tmp/beta.sh"; gamma="$tmp/gamma.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$alpha"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$beta"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$gamma"

  rc=0
  out=$(PATH="$fakebin:$PATH" FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$telemetry" "$alpha" "$beta" "$gamma" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a clean bounded run failed"$'\n'"$out"
  [ -f "$roots_log" ] || fail "the run wrote no per-root sidecar beside telemetry"
  grep -q $'^format\tfm-lint-roots-v1$' "$roots_log" \
    || fail "the sidecar is missing its format header"
  grep -q $'^meta\tbounds_enforced\t0$' "$roots_log" \
    || fail "the sidecar did not record the unenforced bounds state"
  grep -q $'^meta\ttiming_mechanism\tnone$' "$roots_log" \
    || fail "the sidecar did not record the timing mechanism"
  grep -q $'^meta\troot_deadline_seconds\tunbounded$' "$roots_log" \
    || fail "the sidecar did not record the unbounded deadline state"
  grep -q $'^meta\troot_memory_limit_kib\tunbounded$' "$roots_log" \
    || fail "the sidecar did not record the unbounded memory state"
  grep -q $'^meta\troots_completed\t3$' "$roots_log" \
    || fail "the sidecar did not count three completed roots"
  [ "$(grep -c '^begin' "$roots_log")" -eq 3 ] \
    || fail "the sidecar did not log a begin record per root"
  [ "$(awk -F '\t' '$1 == "end" && $10 == "ok" { n++ } END { print n + 0 }' "$roots_log")" -eq 3 ] \
    || fail "the sidecar did not log an ok end record per root"
  [ "$(awk -F '\t' '$1 == "end" && ($8 == "" || $8 !~ /^[0-9]+$/) { n++ } END { print n + 0 }' "$roots_log")" -eq 0 ] \
    || fail "an end record is missing its exit status"
  pass "the retained sidecar records each root's lifecycle with a mode, reason, and duration"
}

test_seeded_joint_source_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded joint-source parity check"
    return
  fi
  local tmp adapter dispatcher dep owner test_root out rc
  tmp=$(fm_test_tmproot fm-lint-parity)
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=$adapter
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$dep
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=$owner
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  pass "jointly sourced dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

test_ci_forces_full_lint_even_with_empty_diff() {
  local tmp repo fakebin diff_file log expected listed out run
  tmp=$(fm_test_tmproot fm-lint-ci-inventory)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/backends/fixture.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/fixture.test.sh"
  chmod +x "$repo/bin/backends/fixture.sh" "$repo/tests/fixture.test.sh"
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"
  expected=$(find "$repo/bin" "$repo/bin/backends" "$repo/tests" -maxdepth 1 -type f -name '*.sh' -print \
    | while IFS= read -r path; do printf '%s\n' "${path#"$repo/"}"; done | LC_ALL=C sort)
  listed=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS='' FM_TEST_GIT_DIFF_FILE="$diff_file" \
    "$repo/bin/fm-lint.sh" --list-files)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "CI=true did not force the full canonical file set"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" --jobs 1 bin/consumer.sh 2>&1) \
    || fail "local cache warm-up failed: $out"
  for run in 1 2; do
    : > "$log"
    out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
      FM_TEST_GIT_DIFF_FILE="$diff_file" \
      "$repo/bin/fm-lint.sh" --jobs 1 2>&1) || fail "CI inventory lint failed: $out"
    [ "$(LC_ALL=C sort "$log")" = "$expected" ] \
      || fail "CI run $run did not analyze the complete uncached inventory: $(cat "$log")"
    assert_not_contains "$out" 'cache hit ' "CI reused local lint successes"
  done
  pass "CI=true checks the complete uncached inventory even with an empty diff"
}

test_main_branch_forces_full_lint() {
  local tmp fakebin listed expected
  tmp=$(fm_test_tmproot fm-lint-main-full)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"

  # Clear CI/GITHUB_ACTIONS so the on-main branch is what forces the full lint,
  # not the ambient CI signal a real CI run would otherwise supply.
  listed=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' \
    FM_TEST_GIT_BRANCH=main "$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh did not force a full lint when HEAD is on main"
  pass "fm-lint.sh forces a full lint when HEAD is on main"
}

test_explicit_path_bypasses_changed_logic() {
  local tmp fakebin log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-override)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  # The git stub reports a broken merge-base, which would force a full lint
  # under the no-args default. Clearing CI/GITHUB_ACTIONS keeps changed-file
  # selection live so this proves the explicit path bypasses it, not that CI
  # already forced full mode. An explicit path must never even consult git.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_MERGE_BASE_OK=0 \
    "$LINT" "$target" 2>&1) || fail "explicit-path lint failed"$'\n'"$out"
  [ "$(cat "$log")" = "$target" ] \
    || fail "explicit path lint did not run on exactly the requested file"$'\n'"logged: $(cat "$log")"
  pass "fm-lint.sh explicit paths bypass changed-file mode selection"
}

test_explicit_root_can_equal_the_private_execution_marker() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): leading-dash root"; return; }
  local tmp repo out rc
  tmp=$(fm_test_tmproot fm-lint-execution-marker)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$repo/--execute"
  out=$(CI='' GITHUB_ACTIONS='' "$repo/bin/fm-lint.sh" -- --execute 2>&1) \
    || fail "a valid explicit leading-dash root failed: $out"
  cat > "$repo/--execute" <<'SH'
#!/usr/bin/env bash
bad() {
  local a= b=
  printf '%s\n' "$a$b"
}
bad
SH
  rc=0
  out=$(CI='' GITHUB_ACTIONS='' "$repo/bin/fm-lint.sh" -- --execute 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "the leading-dash root's finding returned $rc: $out"
  assert_contains "$out" SC1007 "the explicit operand was interpreted as a private command marker"
  pass "an explicit leading-dash root retains real ShellCheck findings"
}

test_zero_changed_files_exits_clean() {
  local tmp fakebin diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-zero-changed)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  # Clear CI/GITHUB_ACTIONS so changed-file mode runs and can reach the empty
  # target set; a CI run would otherwise force a full lint instead.
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_TEST_GIT_BRANCH=feature \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "zero changed lint targets must exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck 0.11.0" "zero-changed run did not print the ShellCheck version line"
  assert_contains "$out" "no changed lint targets" "zero-changed run did not note the empty target set"
  assert_contains "$out" "workflow files valid" \
    "zero-changed run skipped workflow YAML validation"
  pass "fm-lint.sh exits 0 with a note when the local branch has no changed lint targets"
}

test_ci_keeps_external_sources_without_local_exclusions() {
  local tmp fakebin log flag_log mode_log fixture out
  tmp=$(fm_test_tmproot fm-lint-ci-follow)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  mode_log="$tmp/mode.log"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    FM_TEST_FLAG_LOG="$flag_log" FM_TEST_MODE_LOG="$mode_log" \
    "$LINT" "$fixture" 2>&1) \
    || fail "CI lint with explicit path failed"$'\n'"$out"
  [ "$(cat "$mode_log")" = on ] \
    || fail "CI lint disabled dataflow analysis"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh CI keeps source following without the local exclusion list"
}

test_main_branch_keeps_external_sources() {
  local tmp fakebin log flag_log out
  tmp=$(fm_test_tmproot fm-lint-main-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=main \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" 2>&1) \
    || fail "main-branch lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh on main keeps source following without the local exclusion list"
}

test_merge_base_less_keeps_external_sources() {
  local tmp fakebin log flag_log out
  tmp=$(fm_test_tmproot fm-lint-nomergebase-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature FM_TEST_GIT_MERGE_BASE_OK=0 \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" 2>&1) \
    || fail "merge-base-less lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh without a merge-base keeps source following without the local exclusion list"
}

test_explicit_path_keeps_external_sources() {
  local tmp fakebin log flag_log out target
  tmp=$(fm_test_tmproot fm-lint-explicit-follow)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_git "$fakebin"
  log="$tmp/shellcheck.log"
  flag_log="$tmp/flags.log"
  fm_lint_stub_shellcheck "$fakebin" "$log"
  target="bin/fm-install-shellcheck.sh"

  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_BRANCH=feature \
    FM_TEST_FLAG_LOG="$flag_log" "$LINT" "$target" 2>&1) \
    || fail "explicit-path lint failed"$'\n'"$out"
  fm_lint_assert_flag_log "$flag_log" yes none
  pass "fm-lint.sh explicit paths keep source following"
}

fm_lint_test_cases=(
test_memory_fallback_spends_only_the_remaining_root_deadline
test_memory_evidence_outranks_findings_and_signal_reasons
test_source_excerpt_with_oom_text_stays_findings
test_require_bounds_refuses_when_enforcement_is_missing
test_pinned_shellcheck_memory_limit
test_sidecar_result_exit_reflects_final_status
test_roots_sidecar_records_per_root_lifecycle
test_seeded_joint_source_parity
test_ci_forces_full_lint_even_with_empty_diff
test_main_branch_forces_full_lint
test_explicit_path_bypasses_changed_logic
test_explicit_root_can_equal_the_private_execution_marker
test_zero_changed_files_exits_clean
test_ci_keeps_external_sources_without_local_exclusions
test_main_branch_keeps_external_sources
test_merge_base_less_keeps_external_sources
test_explicit_path_keeps_external_sources
)
fm_lint_run "$@"
