#!/usr/bin/env bash
# bin/fm-lint.sh's modes and refusals: CI and fast mode, version pins, the
# installer's platform, checksum and retry behavior, a missing or wrong
# ShellCheck, and the policy refusals around direct beads and ambient options.
# Changed-file selection lives in tests/fm-lint.test.sh; host slots, scheduling
# and memory-limit retry in tests/fm-lint-slots.test.sh; memory fallback and
# evidence, required bounds, the sidecar, seeded parity and CI inputs in
# tests/fm-lint-report.test.sh.
# The groups are contiguous slices of the former registration order, so these
# themes are approximate at the slice edges.
# Shared fixtures: tests/fm-lint-helpers.sh.

# shellcheck source=tests/fm-lint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-lint-helpers.sh"

test_ci_rejects_explicit_fast_mode() {
  local tmp fakebin log fixture out rc
  tmp=$(fm_test_tmproot fm-lint-ci-reject-fast)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/fixture.sh"
  log="$tmp/shellcheck.log"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  chmod +x "$fixture"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  rc=0
  out=$(PATH="$fakebin:$PATH" CI=true GITHUB_ACTIONS=true FM_LINT_JOBS=1 \
    "$LINT" --fast "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "CI accepted explicit fast lint mode (exit $rc)"$'\n'"$out"
  assert_contains "$out" "--fast is local-only" \
    "CI fast-mode rejection did not explain the policy"
  [ ! -s "$log" ] || fail "CI invoked ShellCheck after rejecting fast mode"
  pass "fm-lint.sh rejects explicit --fast mode in CI"
}

test_fast_mode_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): fast lint-defect regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-fast-bad)
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(GITHUB_ACTIONS='' CI='' "$LINT" --fast "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fast lint mode passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fast lint mode did not report the expected ShellCheck finding"
  pass "fm-lint.sh --fast catches an ordinary shell lint defect"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Reproduce the CI incident: the release endpoint returned 503 for all three
  # formerly configured attempts before recovering. Force linux/x86_64 so the
  # retry path stays the CI archive even when this suite runs on macOS.
  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_installer_selects_platform_archive_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha
  tmp=$(fm_test_tmproot fm-shellcheck-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m archive sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    assert_contains "$(cat "$url_log")" \
      "https://github.com/koalaman/shellcheck/releases/download/v${REQUIRED}/${archive}" \
      "installer used the wrong URL for ${uname_s}/${uname_m}"
    [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	amd64	shellcheck-v${REQUIRED}.linux.x86_64.tar.xz	$SHELLCHECK_SHA_LINUX_X86_64
Linux	aarch64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Linux	arm64	shellcheck-v${REQUIRED}.linux.aarch64.tar.xz	$SHELLCHECK_SHA_LINUX_AARCH64
Darwin	x86_64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	amd64	shellcheck-v${REQUIRED}.darwin.x86_64.tar.xz	$SHELLCHECK_SHA_DARWIN_X86_64
Darwin	arm64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
Darwin	aarch64	shellcheck-v${REQUIRED}.darwin.aarch64.tar.xz	$SHELLCHECK_SHA_DARWIN_AARCH64
EOF
  pass "ShellCheck installer selects the official archive, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "shellcheck-v${REQUIRED}.linux.x86_64.tar.xz" \
    "mismatch did not name the selected archive"
  assert_contains "$out" "$SHELLCHECK_SHA_LINUX_X86_64" \
    "mismatch did not name the pinned linux/x86_64 checksum"
  [ ! -e "$destination/shellcheck" ] || fail "installer installed ShellCheck after a checksum mismatch"
  pass "ShellCheck installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(fm_test_tmproot fm-shellcheck-shasum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  for tool in bash dirname mktemp rm awk mkdir install cat chmod; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Restricted PATH: shasum is present, sha256sum is not.
  : > "$hasher_log"
  out=$(CURL_URL_LOG="$tmp/curl-url.log" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck via shasum"
  pass "ShellCheck installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(fm_test_tmproot fm-shellcheck-sha256sum-pref)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_shellcheck "$fakebin"
  fm_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  PATH="$fakebin:$PATH" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$SHELLCHECK_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "ShellCheck installer prefers sha256sum when both hashers are present"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-shellcheck-unsupported)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"

  rc=0
  out=$(FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  pass "ShellCheck installer rejects an unsupported OS or architecture"
}

test_missing_shellcheck_fails_closed() {
  local tmp fakebin out rc tool
  tmp=$(fm_test_tmproot fm-lint-noshellcheck)
  fakebin=$(fm_fakebin "$tmp")
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  rc=0
  out=$(PATH="$fakebin" CI=true GITHUB_ACTIONS=true "$LINT" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "missing ShellCheck expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "ShellCheck not found" \
    "missing ShellCheck did not name the required linter"
  assert_contains "$out" "$REQUIRED" \
    "missing ShellCheck did not name the pinned version"
  assert_contains "$out" "fm-install-shellcheck.sh" \
    "missing ShellCheck did not name the pinned installer"
  pass "missing ShellCheck fails closed"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_rejects_direct_beads_cli_invocations() {
  local tmp fakebin log lint_copy invocation out rc
  tmp=$(fm_test_tmproot fm-lint-backend-purity)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  mkdir -p "$tmp/repo/bin/backends" "$tmp/repo/tests"
  lint_copy="$tmp/repo/bin/fm-lint.sh"
  cp "$LINT" "$lint_copy"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/repo/bin/"
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
  chmod +x "$lint_copy" "$tmp/repo/bin/fm-lint-workflows.sh"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  for invocation in \
    'bd update fm-example --status in_progress' \
    'BD_ACTOR=firstmate bd update fm-example --status closed' \
    'env bd close fm-example' \
    'env -i BD_ACTOR=firstmate bd close fm-example' \
    'env -u BD_ACTOR bd close fm-example' \
    'env -- bd close fm-example' \
    '/usr/local/bin/bd close fm-example' \
    '"/usr/local/bin/bd" close fm-example' \
    "'/usr/local/bin/bd' close fm-example" \
    "b'd' close fm-example" \
    "/usr/local/bin/b'd' close fm-example" \
    "\$'bd' close fm-example" \
    '$"bd" close fm-example' \
    "\$'\\x62\\x64' close fm-example" \
    "\$'\\142\\144' close fm-example" \
    "b\$'\\x64' close fm-example"
  do
    printf '#!/usr/bin/env bash\n%s\n' "$invocation" > "$tmp/repo/bin/direct-beads.sh"
    rc=0
    out=$(cd "$tmp/repo" && CI=true PATH="$fakebin:$PATH" "$lint_copy" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "lint accepted a direct Beads CLI invocation: $invocation"
    assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
      "lint did not identify the backend-boundary violation: $invocation"
  done
  pass "fm-lint.sh rejects direct Beads CLI invocations in firstmate core"
}

test_rejects_direct_beads_cli_in_explicit_core_path() {
  local tmp fakebin log lint_copy target spelling out rc
  tmp=$(fm_test_tmproot fm-lint-explicit-backend-purity)
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  mkdir -p "$tmp/repo/bin/backends"
  lint_copy="$tmp/repo/bin/fm-lint.sh"
  target="$tmp/repo/bin/direct-beads.sh"
  cp "$LINT" "$lint_copy"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/repo/bin/"
  printf '#!/usr/bin/env bash\nbd close fm-example\n' > "$target"
  chmod +x "$lint_copy"
  fm_lint_stub_shellcheck "$fakebin" "$log"

  for spelling in bin/direct-beads.sh bin/../bin/direct-beads.sh; do
    rc=0
    out=$(cd "$tmp/repo" && PATH="$fakebin:$PATH" "$lint_copy" "$spelling" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "explicit core path bypassed backend-purity lint: $spelling"
    assert_contains "$out" "direct Beads CLI invocation bypasses tasks-axi" \
      "explicit core path did not report the backend-boundary violation: $spelling"
  done
  pass "fm-lint.sh enforces backend purity for explicit core paths"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

fm_lint_test_cases=(
test_ci_rejects_explicit_fast_mode
test_fast_mode_catches_a_real_lint_defect
test_pins_an_explicit_version
test_installer_retries_transient_download_failure
test_installer_selects_platform_archive_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_rejects_unsupported_platform
test_missing_shellcheck_fails_closed
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_rejects_direct_beads_cli_invocations
test_rejects_direct_beads_cli_in_explicit_core_path
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
)
fm_lint_run "$@"
