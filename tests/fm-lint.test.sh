#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh is the single owner invoked by CI
# (.github/workflows/ci.yml) and by the pre-push gate (.no-mistakes.yaml
# commands.lint). CI and the local gate deliberately select different roots;
# bin/fm-lint.sh owns their analysis modes, memory fallback, configuration,
# and tool versions.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic shell lint, so PRs passed local
# validation yet failed CI on info/warning findings such as SC2015, SC1007, and
# SC2034. A second axis was tool-version skew: CI's ShellCheck floated with the
# runner image and still emitted SC2015, which ShellCheck retired in 0.11.0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)
# Ordinary regressions must not read or populate the operator's shared cache.
export FM_LINT_CACHE_DIR=off
# Nor may they queue on the operator's shared host-wide ShellCheck slots.
export FM_LINT_SLOT_DIR=off

# Official GitHub release asset sha256 values for shellcheck v0.11.0 .tar.xz
# archives (https://github.com/koalaman/shellcheck/releases/tag/v0.11.0). Tests
# compare installer behavior against these published digests, not script source.
SHELLCHECK_SHA_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA_LINUX_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
SHELLCHECK_SHA_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

# fm_install_stub_uname <fakebin>: uname -s / uname -m from FM_TEST_UNAME_S/M.
fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_install_stub_curl <fakebin>: log the URL, fail CURL_FAIL_UNTIL times, then
# write an empty file at -o. CURL_COUNT and CURL_URL_LOG are paths the stub
# updates when invoked.
fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

# fm_install_stub_hasher <fakebin> <name>: sha256sum or shasum stub that prints
# SHA256_STUB_HASH and records the invocation on HASHER_LOG. shasum requires -a 256.
fm_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

fm_install_stub_tar_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
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
  for part in 1of2 2of2; do
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
  for option in 0of2 3of2 1of3; do
    rc=0
    "$LINT" --partition "$option" --list-files > "$tmp/refused" 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "invalid partition $option was not refused"
  done
  rc=0
  "$LINT" --partition 1of2 --fast > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted --fast"
  rc=0
  "$LINT" --partition 1of2 bin/fm-lint.sh > "$tmp/refused" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "partition accepted an explicit subset"
  pass "two canonical lint partitions preserve complete source-aware coverage and reject weakened modes"
}

# fm_lint_stub_git <fakebin-dir>: install a git stub for the changed-file mode
# tests below. Its answers are driven by env vars the caller sets before
# invoking fm-lint.sh, so those tests can steer git state without depending on
# this worktree's actual branch, remotes, or history:
#   FM_TEST_GIT_INSIDE_WORKTREE  1 (default) or 0
#   FM_TEST_GIT_BRANCH           branch name for `rev-parse --abbrev-ref HEAD`
#   FM_TEST_GIT_HAS_ORIGIN_MAIN  1 (default) or 0
#   FM_TEST_GIT_HAS_MAIN         1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE_OK    1 (default) or 0
#   FM_TEST_GIT_MERGE_BASE       merge-base value to print when OK
#   FM_TEST_GIT_DIFF_FILE        path to a file of NUL-separated changed paths
fm_lint_stub_git() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree")
    [ "${FM_TEST_GIT_INSIDE_WORKTREE:-1}" = 1 ] || exit 1
    printf 'true\n'
    exit 0
    ;;
  "rev-parse --abbrev-ref HEAD")
    printf '%s\n' "${FM_TEST_GIT_BRANCH:-feature}"
    exit 0
    ;;
  "rev-parse --verify -q origin/main")
    [ "${FM_TEST_GIT_HAS_ORIGIN_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "rev-parse --verify -q main")
    [ "${FM_TEST_GIT_HAS_MAIN:-1}" = 1 ] && exit 0 || exit 1
    ;;
  "merge-base "*)
    if [ "${FM_TEST_GIT_MERGE_BASE_OK:-1}" = 1 ]; then
      printf '%s\n' "${FM_TEST_GIT_MERGE_BASE:-fakebase123}"
      exit 0
    fi
    exit 1
    ;;
  "diff --name-only --no-renames -z "*)
    if [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && [ -f "$FM_TEST_GIT_DIFF_FILE" ]; then
      cat "$FM_TEST_GIT_DIFF_FILE"
    fi
    exit 0
    ;;
  "ls-files --others --exclude-standard -z")
    [ -z "${FM_TEST_GIT_UNTRACKED_FILE:-}" ] || cat "$FM_TEST_GIT_UNTRACKED_FILE"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/git"
}

# fm_lint_write_diff_file <file> <path>...: writes NUL-separated changed paths
# in the shape `git diff --name-only -z` produces, for FM_TEST_GIT_DIFF_FILE.
fm_lint_write_diff_file() {
  local file=$1
  shift
  printf '%s\0' "$@" > "$file"
}

# fm_lint_stub_shellcheck <fakebin-dir> <log-file>: install a ShellCheck stub
# that answers --version with the pinned version and otherwise logs the file
# roots it was asked to check (one per line) instead of actually analyzing
# them, so changed-file mode tests can assert exactly which files fm-lint.sh
# selected without depending on real ShellCheck findings. When
# FM_TEST_MODE_LOG is set, it records the effective analysis mode, treating
# ShellCheck's default as full analysis. When FM_TEST_FLAG_LOG is set, it
# records whether --external-sources was passed and the --exclude value.
fm_lint_stub_shellcheck() {
  local fakebin=$1 log=$2
  : > "$log"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
mode=on
follow=no
exclude=none
while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do
  case "\$1" in
    --extended-analysis=false) mode=off ;;
    --external-sources) follow=yes ;;
    --exclude=*) exclude=\${1#--exclude=} ;;
    --exclude)
      shift
      exclude=\${1:-none}
      ;;
  esac
  shift
done
if [ -n "\${FM_TEST_MODE_LOG:-}" ]; then
  printf '%s\n' "\$mode" >> "\$FM_TEST_MODE_LOG"
fi
if [ -n "\${FM_TEST_FLAG_LOG:-}" ]; then
  printf 'external-sources=%s\nexclude=%s\n' "\$follow" "\$exclude" >> "\$FM_TEST_FLAG_LOG"
fi
[ "\$#" -eq 0 ] || shift
printf '%s\n' "\$@" >> "$log"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

# fm_lint_bounds_supported: the platform pair the bounded per-root envelope
# needs - a watchdog mechanism and an enforceable address-space limit. macOS
# rejects ulimit -v, so bounded-mode tests run there only when this is true.
fm_lint_bounds_supported() {
  [ -r "$ROOT/bin/fm-timeout-lib.sh" ] || return 1
  ( ulimit -v 65536 ) 2>/dev/null || return 1
  command -v perl >/dev/null 2>&1 \
    || command -v timeout >/dev/null 2>&1 \
    || command -v gtimeout >/dev/null 2>&1 || return 1
  return 0
}

# fm_lint_stub_reactive_shellcheck <fakebin-dir>: a ShellCheck stub whose
# behavior is steered by the basename of the root it is asked to analyze, so
# bounded-execution tests can mix a hang, a memory-limit death, and clean
# roots in one run. A *blocker* root spawns a tracked child (pid written to
# FM_TEST_CHILD_PID), records its own pid on FM_TEST_STUB_PID, and then blocks;
# a *hoarder* root runs a perl allocator that grows to 512 MiB and fails only
# when perl itself reports that the allocation was refused, forwarding perl's
# own error and exiting with GHC's heap-exhaustion status 251, as ShellCheck
# does when its runtime is refused memory; an allocation that succeeds falls
# through like any other root.
# Anything else records its path on FM_TEST_STUB_LOG and exits cleanly.
fm_lint_stub_reactive_shellcheck() {
  local fakebin=$1
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
target=${!#}
case "$target" in
  *blocker*)
    sleep "${FM_TEST_BLOCK_SECS:-300}" &
    printf '%s\n' "$!" > "${FM_TEST_CHILD_PID:-/dev/null}"
    printf '%s\n' "$$" > "${FM_TEST_STUB_PID:-/dev/null}"
    exec sleep "${FM_TEST_BLOCK_SECS:-300}"
    ;;
  *hoarder*)
    alloc_rc=0
    alloc_err=$(perl -e 'my $s = ""; for (1..512) { $s .= "x" x 1048576 }' 2>&1 >/dev/null) \
      || alloc_rc=$?
    if [ "$alloc_rc" -ne 0 ]; then
      printf '%s\n' "$alloc_err" >&2
      case "$alloc_err" in
        *"Out of memory"*) exit 251 ;;
      esac
      exit "$alloc_rc"
    fi
    ;;
  *oom-exit1*)
    printf 'shellcheck: malloc: resource exhausted (out of memory)\n' >&2
    exit 1
    ;;
  *oom-perl*)
    printf 'Out of memory!\n' >&2
    exit 1
    ;;
  *oom-heap*)
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
    ;;
  *oom-kill*)
    printf 'shellcheck: out of memory (requested 1048576 bytes)\n' >&2
    kill -KILL "$$"
    ;;
  *oom-text-findings*)
    printf '\nIn %s line 2:\nshellcheck: out of memory $x\n                          ^-- SC2086 (info): Double quote to prevent globbing and word splitting.\n' "$target"
    exit 1
    ;;
esac
printf '%s\n' "$target" >> "${FM_TEST_STUB_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}


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


fm_lint_assert_flag_log() {
  local flag_log=$1 expected_follow=$2 expected_exclude=$3
  [ -s "$flag_log" ] || fail "ShellCheck was not invoked; flag log is empty"
  awk -v follow="$expected_follow" -v exclude="$expected_exclude" '
    BEGIN { bad=0; saw=0 }
    /^external-sources=/ { saw=1; if ($0 != "external-sources=" follow) bad=1 }
    /^exclude=/ { if ($0 != "exclude=" exclude) bad=1 }
    END { exit (saw && !bad) ? 0 : 1 }
  ' "$flag_log" \
    || fail "ShellCheck flags were not external-sources=$expected_follow exclude=$expected_exclude"$'\n'"$(cat "$flag_log")"
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

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'analysis_mode\tfull' "$telemetry" "telemetry did not record full analysis mode"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

# Counted design comparison (architectural requirements, not timing estimates):
# Design                              Host bound  Lone workers  New daemons  Stale-slot cleanup
# A per-run only                           0           2             0                0
# B FM_LINT_JOBS=1 default                  0           1             0                0
# C bash mkdir slot dirs                   1           2             0                1
# D central lint daemon                    1           2             1                0
# E flock slot pool in the Perl helper     1           2             0                0 (chosen)
# E supplies a host bound without a daemon or stale-lock reclamation protocol.
# Supplied paired reproduction: identical workloads of six roots per run,
# --jobs 2, gate disabled with FM_LINT_SLOT_DIR=off versus enabled with cap 3.
# Concurrent runs:                    1     4     8    16
# Peak live ShellCheck, disabled:     2     8    16    32 (2 x runs)
# Peak live ShellCheck, enabled:      2     3     3     3 (min(2 x runs, cap))
# A lone run still peaks at two; fleet-day measurements remain out of scope.
#
fm_lint_stub_counting_shellcheck() {
  local fakebin=$1 activity=$2 peak=$3 real_perl
  real_perl=$(command -v perl)
  mkdir -p "$activity"
  : > "$peak"
  cat > "$fakebin/shellcheck" <<PL
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes qw(time sleep);
if ((\$ARGV[0] // '') eq '--version') {
    print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n";
    exit 0;
}
open(my \$lock, '>>', "$peak.lock") or die "\$!";
flock(\$lock, LOCK_EX) or die "\$!";
open(my \$active, '>', "$activity/\$\$") or die "\$!";
close \$active;
my @active = glob "$activity/*";
open(my \$peak, '>>', "$peak") or die "\$!";
print {\$peak} scalar(@active), "\n";
close \$peak;
close \$lock;
my \$deadline = time() + 90;
while (\$ENV{FM_LINT_COUNT_HOLD} && !-e "$peak.release") {
    if (time() > \$deadline) { unlink "$activity/\$\$"; exit 1; }
    sleep 0.01;
}
unlink "$activity/\$\$";
exit 0;
PL
  chmod +x "$fakebin/shellcheck"
  cat > "$fakebin/perl" <<PL
#!$real_perl
use strict;
use warnings;
use Time::HiRes qw(time sleep);
if (\$ENV{FM_LINT_COUNT_HOLD} && (\$ARGV[0] // '') =~ m{/fm-lint-cache[.]pl\\z}
    && ((\$ARGV[1] // '') eq 'gate'
        || ((\$ARGV[1] // '') eq 'check' && (\$ENV{FM_LINT_INTERNAL_SLOT_DIR} // 'off') eq 'off'))) {
    my \$dir = \$ENV{FM_LINT_COUNT_READY_DIR};
    open(my \$ready, '>', "\$dir/ready.\$\$") or die "\$!";
    close \$ready;
    my \$deadline = time() + 30;
    until (-e "\$dir/start") {
        die "contender start deadline exceeded\\n" if time() > \$deadline;
        sleep 0.01;
    }
    open(my \$attempt, '>', "\$dir/attempt.\$\$") or die "\$!";
    close \$attempt;
}
exec "$real_perl", @ARGV or die "exec perl: \$!";
PL
  chmod +x "$fakebin/perl"
}

fm_lint_concurrent_runs() {
  local runs=$1 tmp=$2 fakebin=$3 expected=$4 run pid rc=0 ready_rc=0
  local -a pids roots
  roots=("$tmp/a.sh" "$tmp/b.sh" "$tmp/c.sh" "$tmp/d.sh")
  rm -f "$tmp/peak.release"
  rm -rf "$tmp/contenders"
  mkdir -p "$tmp/contenders"
  for run in $(seq 1 "$runs"); do
    FM_LINT_COUNT_HOLD=1 FM_LINT_COUNT_READY_DIR="$tmp/contenders" \
      PATH="$fakebin:$PATH" "$LINT" --jobs 2 "${roots[@]}" > "$tmp/run.$run.out" 2>&1 &
    pids+=("$!")
  done
  perl - "$tmp/peak" "$expected" "$tmp/contenders" "$((2 * runs))" <<'PL' || ready_rc=$?
use Time::HiRes qw(time sleep);
my ($peak, $expected, $dir, $contenders) = @ARGV;
my $deadline = time() + 30;
while (1) {
    my @ready = glob "$dir/ready.*";
    last if @ready >= $contenders;
    die "contender readiness deadline exceeded\n" if time() > $deadline;
    sleep 0.01;
}
open(my $start, '>', "$dir/start") or die "$!";
close $start;
$deadline = time() + 30;
while (1) {
    my @attempts = glob "$dir/attempt.*";
    last if @attempts >= $contenders;
    die "contender admission attempt deadline exceeded\n" if time() > $deadline;
    sleep 0.01;
}
$deadline = time() + 30;
while (1) {
    open(my $fh, '<', $peak) or die "$!";
    my @counts = <$fh>;
    close $fh;
    last if grep { /\A[0-9]+\n\z/ && $_ >= $expected } @counts;
    die "concurrent admission deadline exceeded\n" if time() > $deadline;
    sleep 0.01;
}
sleep 3;
PL
  touch "$tmp/contenders/start" "$tmp/peak.release"
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=$?
  done
  [ "$ready_rc" -eq 0 ] || fail "concurrent runs did not reach $expected held ShellCheck processes"$'\n'"$(cat "$tmp"/run.*.out)"
  [ "$rc" -eq 0 ] || fail "a concurrent fm-lint.sh run failed (rc=$rc)"$'\n'"$(cat "$tmp"/run.*.out)"
  sort -n "$tmp/peak" | tail -1
}

fm_lint_slot_fixture() {  # <name> -> prints the tmp dir
  local tmp root
  tmp=$(fm_test_tmproot "$1")
  mkdir -p "$tmp/bin"
  for root in a b c d; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"
  done
  fm_lint_stub_counting_shellcheck "$tmp/bin" "$tmp/active" "$tmp/peak"
  printf '%s\n' "$tmp"
}

test_host_slots_bound_concurrent_runs() {
  local tmp peak lone baseline
  tmp=$(fm_lint_slot_fixture fm-lint-slots)
  # One run keeps its two workers: the host-wide bound never throttles a lone run.
  lone=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=3 FM_TEST_SEAM=1 FM_LINT_SLOT_LOAD=0 \
    fm_lint_concurrent_runs 1 "$tmp" "$tmp/bin" 2)
  [ "$lone" -eq 2 ] || fail "a lone run peaked at $lone live ShellCheck processes, expected its two workers"
  : > "$tmp/peak"
  baseline=$(FM_LINT_SLOT_DIR=off fm_lint_concurrent_runs 6 "$tmp" "$tmp/bin" 12)
  [ "$baseline" -eq 12 ] || fail "six ungated runs peaked at $baseline live ShellCheck processes, expected 12"
  : > "$tmp/peak"
  # Six runs would start twelve ShellCheck processes if each bounded only itself.
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=3 FM_TEST_SEAM=1 FM_LINT_SLOT_LOAD=0 \
    fm_lint_concurrent_runs 6 "$tmp" "$tmp/bin" 3)
  [ "$peak" -le 3 ] || fail "six concurrent runs reached $peak live ShellCheck processes, expected at most 3 host-wide"
  [ "$peak" -ge 3 ] || fail "six concurrent runs peaked at $peak, so the slots were not used in parallel"
  pass "six concurrent runs peak at $baseline ShellCheck processes ungated and $peak with a three-slot pool"
}

test_host_load_shrinks_slots_to_the_floor() {
  local tmp peak
  tmp=$(fm_lint_slot_fixture fm-lint-slots-load)
  # Load far past two times the cores leaves only the two-slot floor, so the
  # runs queue instead of failing or timing out.
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=6 FM_TEST_SEAM=1 FM_LINT_SLOT_LOAD=100000 \
    fm_lint_concurrent_runs 4 "$tmp" "$tmp/bin" 2)
  [ "$peak" -le 2 ] || fail "under heavy load four runs reached $peak live ShellCheck processes, expected at most 2"
  : > "$tmp/peak"
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=6 FM_TEST_SEAM=1 FM_LINT_SLOT_LOAD=0 \
    fm_lint_concurrent_runs 4 "$tmp" "$tmp/bin" 6)
  [ "$peak" -gt 2 ] || fail "with an idle host four runs peaked at $peak, so the load never widened the slots"
  pass "host load shrinks the shared ShellCheck slots to a two-slot floor and idle hosts use all of them"
}

test_host_load_preserves_the_cap_until_the_threshold() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slots-threshold)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "host load boundary regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
my $command = q{
    use Time::HiRes qw(time sleep);
    my ($started, $release) = @ARGV;
    open(my $fh, '>', $started) or die "$!";
    close $fh;
    my $deadline = time() + 15;
    until (-e $release) { exit 1 if time() > $deadline; sleep 0.01; }
};
for my $cap ('', 6) {
    local $ENV{FM_LINT_HOST_SLOTS} = $cap;
    for my $load (30, 36, 37) {
        local $ENV{FM_TEST_SEAM} = 1;
        local $ENV{FM_LINT_SLOT_LOAD} = $load;
        my $full = $cap || 9;
        my $expected = $load == 37 ? $full - 1 : $full;
        my $dir = "$tmp/$full.$load";
        make_path($dir);
        my @pids;
        for my $index (0 .. $full) {
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if (!$pid) {
                exec $^X, $gate, 'gate', "$dir/slots", 18, "$dir/wait.$index",
                    '--', $^X, '-e', $command, "$dir/started.$index", "$dir/release";
                die "exec: $!";
            }
            push @pids, $pid;
        }
        my $error;
        eval {
            my $deadline = time() + 10;
            while (1) {
                my @started = glob "$dir/started.*";
                last if @started >= $expected;
                die "admission deadline exceeded\n" if time() > $deadline;
                sleep 0.01;
            }
            sleep 0.25;
            my @started = glob "$dir/started.*";
            die "admitted @started; expected $expected commands\n" unless @started == $expected;
        };
        $error = $@;
        open(my $release, '>', "$dir/release") or die "release: $!";
        close $release;
        for my $pid (@pids) {
            waitpid($pid, 0);
            $error ||= "gated command exited with status $?\n" if $?;
        }
        die "cap $full, load $load: $error" if $error;
    }
}
for my $path (qw(scan wake)) {
    my $dir = "$tmp/occupancy.$path";
    make_path("$dir/slots");
    my @holders;
    for my $index ($path eq 'wake' ? (0 .. 8) : (1 .. 8)) {
        open($holders[$index], '>>', "$dir/slots/slot.$index") or die "$!";
        flock($holders[$index], LOCK_EX) or die "$!";
    }
    local $ENV{FM_LINT_HOST_SLOTS} = 9;
    local $ENV{FM_TEST_SEAM} = 1;
    local $ENV{FM_LINT_SLOT_LOAD} = 43;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $_ for grep { defined } @holders;
        exec $^X, $gate, 'gate', "$dir/slots", 18, "$dir/wait",
            '--', $^X, '-e', 'open(my $fh, ">", $ARGV[0]) or die "$!"', "$dir/started";
        die "exec: $!";
    }
    my $error;
    eval {
        sleep 0.25;
        close $holders[0] if $path eq 'wake';
        sleep 2;
        die "admitted with eight occupied slots and an allowance of two\n" if -e "$dir/started";
        close $holders[$_] for 1 .. 7;
        my $deadline = time() + 5;
        until (-e "$dir/started") {
            die "did not admit below the occupancy allowance\n" if time() > $deadline;
            sleep 0.01;
        }
    };
    $error = $@;
    close $holders[8];
    if ($error) { kill 'KILL', $pid; }
    waitpid($pid, 0);
    $error ||= "gated command failed: $?\n" if $?;
    die "$path: $error" if $error;
}
PL
  pass "host caps follow the load threshold and both acquisition paths respect total occupancy"
}

test_slot_pool_can_be_disabled_or_misconfigured() {
  local tmp rc out
  tmp=$(fm_lint_slot_fixture fm-lint-slots-off)
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR=off "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a run with the slot pool off failed"$'\n'"$out"
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=zero "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric FM_LINT_HOST_SLOTS exited $rc, expected 2"
  assert_contains "$out" "FM_LINT_HOST_SLOTS" "the refusal did not name the setting"
  [ ! -d "$tmp/slots" ] || fail "a refused run still created the slot directory"
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/a.sh/blocked" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unusable slot directory must not fail lint"$'\n'"$out"
  assert_contains "$out" "running without the host-wide ShellCheck bound" "an unusable slot directory was not reported"
  pass "the slot pool can be disabled, rejects bad settings, and never fails lint when unusable"
}

test_slot_file_failures_run_ungated() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-errors)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "slot I/O fallback regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
open(my $module, '>', "$tmp/FailLock.pm") or die "$!";
print {$module} <<'MODULE';
package FailLock;
use Errno qw(EIO EWOULDBLOCK);
use Fcntl qw(LOCK_NB);
BEGIN {
    *CORE::GLOBAL::flock = sub {
        $! = $ENV{FAIL_LOCK} eq 'wait' && ($_[1] & LOCK_NB) ? EWOULDBLOCK : EIO;
        return 0;
    };
}
1;
MODULE
close $module;
for my $failure (qw(open scan wait)) {
    my $dir = "$tmp/$failure";
    make_path("$dir/slots");
    make_path("$dir/slots/slot.0") if $failure eq 'open';
    local $ENV{FM_LINT_HOST_SLOTS} = 1;
    local $ENV{FM_TEST_SEAM} = 1;
    local $ENV{FM_LINT_SLOT_LOAD} = 0;
    local $ENV{FAIL_LOCK} = $failure;
    my @inject = $failure eq 'open' ? () : ("-I$tmp", '-MFailLock');
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>', "$dir/err" or die "$!";
        exec $^X, @inject, $gate, 'gate', "$dir/slots", 18, "$dir/wait",
            '--', $^X, '-e', 'print "analysis ran\n"; exit 23';
        die "exec: $!";
    }
    my $deadline = time() + 30;
    while (waitpid($pid, WNOHANG) == 0) {
        if (time() > $deadline) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
            die "$failure failure queued instead of running ungated\n";
        }
        sleep 0.01;
    }
    die "$failure fallback lost the command exit status: $?\n" unless $? == (23 << 8);
    open(my $err, '<', "$dir/err") or die "$!";
    local $/;
    my $warning = <$err>;
    die "$failure fallback omitted the warning\n"
        unless $warning =~ /running without the host-wide ShellCheck bound/;
}
PL
  pass "slot open and non-contention scan/wait lock failures warn and run ungated"
}

test_slot_survives_gate_death() {
  local tmp bounded=none
  if fm_lint_bounds_supported; then bounded=perl; fi
  tmp=$(fm_test_tmproot fm-lint-slot-inheritance)
  perl - "$LINT" "$ROOT/bin/fm-lint-cache.pl" "$tmp" "$bounded" <<'PL' || fail "slot lifetime regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $gate_script, $tmp, $bound_mechanism) = @ARGV;
open(my $stub, '>', "$tmp/shellcheck") or die "$!";
print {$stub} "#!/usr/bin/env perl\n", <<'STUB';
use Time::HiRes qw(time sleep);
$SIG{TERM} = $SIG{HUP} = $SIG{INT} = 'IGNORE';
my $child = fork();
die "fork: $!" unless defined $child;
if (!$child) {
    my $deadline = time() + 15;
    until (-e "$ENV{CASE_DIR}/release") { last if time() > $deadline; sleep 0.01; }
    exit 0;
}
open(my $fh, '>', "$ENV{CASE_DIR}/started") or die "$!";
print {$fh} "$$ $child\n";
close $fh;
waitpid($child, 0);
STUB
close $stub;
chmod 0755, "$tmp/shellcheck";
for my $bounded ('none', $bound_mechanism eq 'perl' ? ('perl') : ()) {
    my $dir = "$tmp/$bounded";
    make_path("$dir/out");
    open(my $root, '>', "$dir/root.sh") or die "$!";
    print {$root} "#!/bin/bash\nexit 0\n";
    close $root;
    open(my $manifest, '>', "$dir/manifest") or die "$!";
    print {$manifest} "0\t$dir/root.sh\n";
    close $manifest;
    local %ENV = (%ENV, FM_LINT_INTERNAL => 1, FM_LINT_INTERNAL_CACHE => 'off',
        FM_LINT_INTERNAL_SLOT_DIR => "$dir/slots", FM_LINT_INTERNAL_NCPU => 18,
        FM_LINT_HOST_SLOTS => 1, FM_TEST_SEAM => 1, FM_LINT_SLOT_LOAD => 0,
        FM_LINT_INTERNAL_BOUNDED => $bounded, FM_LINT_INTERNAL_MEMORY_KIB => 2097152,
        FM_LINT_INTERNAL_ROOT_SECS => 10, FM_LINT_INTERNAL_GRACE => 1,
        FM_LINT_SHELLCHECK => "$tmp/shellcheck", CASE_DIR => $dir);
    my $worker = fork();
    die "fork: $!" unless defined $worker;
    if (!$worker) {
        open STDOUT, '>', "$dir/output" or die "$!";
        open STDERR, '>&', \*STDOUT or die "$!";
        exec '/bin/bash', $lint, '--internal-worker', "$dir/manifest", "$dir/out", 0;
        die "exec: $!";
    }
    my ($command, $descendant, $gate, $queued, $error);
    eval {
        my $deadline = time() + 5;
        until (-s "$dir/started") { die "command never started\n" if time() > $deadline; sleep 0.01; }
        open(my $started, '<', "$dir/started") or die "$!";
        ($command, $descendant) = split / /, <$started>;
        open(my $ps, '-|', 'ps', '-axo', 'pid=,ppid=,args=') or die "$!";
        my (%parent, %args);
        while (<$ps>) {
            next unless /^\s*(\d+)\s+(\d+)\s+(.*)$/;
            $parent{$1} = $2; $args{$1} = $3;
        }
        close $ps;
        my $ancestor = $command;
        while ($ancestor && $ancestor != $worker) {
            if (($args{$ancestor} // '') =~ /\Q$dir\/slots\E/) { $gate = $ancestor; last; }
            $ancestor = $parent{$ancestor};
        }
        die "gate not found in command ancestry\n" unless $gate;
        $queued = fork();
        die "fork: $!" unless defined $queued;
        if (!$queued) {
            exec $^X, $gate_script, 'gate', "$dir/slots", 18, "$dir/queued.wait",
                '--', $^X, '-e', q{
                    my ($admitted, $bounded, @protected) = @ARGV;
                    if ($bounded ne 'none') {
                        open(my $ps, '-|', 'ps', '-o', 'stat=', '-p', join(',', @protected)) or die "$!";
                        my @live = grep { !/^\s*Z/ } <$ps>;
                        close $ps;
                        die "admission overlapped a live protected tree\n" if @live;
                    }
                    open(my $fh, '>', $admitted) or die "$!";
                }, "$dir/admitted", $bounded, $command, $descendant;
            die "exec: $!";
        }
        kill 'KILL', $gate;
        if ($bounded eq 'none') {
            sleep 0.2;
            die "queued command started while protected tree survived\n" if -e "$dir/admitted";
            kill 'KILL', $command;
            sleep 0.2;
            die "queued command started while protected descendant survived\n" if -e "$dir/admitted";
            die "protected descendant exited before release\n" unless kill 0, $descendant;
        } else {
            my $deadline = time() + 5;
            until (-e "$dir/admitted") {
                die "watchdog cleanup did not release the slot\n" if time() > $deadline;
                sleep 0.01;
            }
        }
    };
    $error = $@;
    open(my $release, '>', "$dir/release") or die "$!";
    close $release;
    my $deadline = time() + 5;
    if ($queued) {
        while (waitpid($queued, WNOHANG) == 0) {
            if (time() > $deadline) { kill 'KILL', $queued; waitpid($queued, 0); $error ||= "slot never released\n"; last; }
            sleep 0.01;
        }
        $error ||= "queued command failed: $?\n" if $?;
        $error ||= "queued command never admitted\n" unless -e "$dir/admitted";
    }
    kill 'KILL', $command if $command;
    kill 'KILL', $descendant if $descendant;
    kill 'TERM', $worker;
    waitpid($worker, 0);
    if ($error) {
        open(my $output, '<', "$dir/output") or die "$!";
        open(my $analysis, '<', "$dir/out/shard.0.out") or die "$!";
        local $/;
        die "$bounded: $error", <$output>, <$analysis>;
    }
}
PL
  pass "inherited slots prevent overlap after gate death and allow admission after watchdog cleanup"
}

test_queued_roots_use_high_resolution_timings() {
  local tmp bounded=none
  if fm_lint_bounds_supported; then bounded=perl; fi
  tmp=$(fm_test_tmproot fm-lint-slot-clock)
  perl - "$LINT" "$tmp" "$bounded" <<'PL' || fail "queued root clock regression failed"
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $tmp, $bounded) = @ARGV;
open(my $env, '>', "$tmp/bash-env") or die "$!";
print {$env} "unset EPOCHREALTIME\n";
close $env;
open(my $stub, '>', "$tmp/shellcheck") or die "$!";
print {$stub} "#!/usr/bin/env perl\n", <<'STUB';
use Time::HiRes qw(sleep);
sleep 0.08;
if ($ENV{RETRY} && grep { $_ eq '--external-sources' } @ARGV) {
    print STDERR "shellcheck: Heap exhausted;\n";
    exit 251;
}
exit 0;
STUB
close $stub;
chmod 0755, "$tmp/shellcheck";
for my $retry (0, 1) {
    my $dir = "$tmp/$retry";
    make_path("$dir/out", "$dir/slots");
    open(my $slot, '>>', "$dir/slots/slot.0") or die "$!";
    flock($slot, LOCK_EX) or die "$!";
    open(my $manifest, '>', "$dir/manifest") or die "$!";
    print {$manifest} "0\t$dir/root.sh\n";
    close $manifest;
    open(my $root, '>', "$dir/root.sh") or die "$!";
    print {$root} "#!/bin/bash\nexit 0\n";
    close $root;
    local %ENV = (%ENV, BASH_ENV => "$tmp/bash-env", RETRY => $retry,
        FM_LINT_INTERNAL => 1, FM_LINT_INTERNAL_CACHE => 'off',
        FM_LINT_INTERNAL_SLOT_DIR => "$dir/slots", FM_LINT_INTERNAL_NCPU => 18,
        FM_LINT_HOST_SLOTS => 1, FM_TEST_SEAM => 1, FM_LINT_SLOT_LOAD => 0,
        FM_LINT_INTERNAL_BOUNDED => $bounded, FM_LINT_INTERNAL_MEMORY_KIB => 2097152,
        FM_LINT_INTERNAL_ROOT_SECS => 3, FM_LINT_INTERNAL_GRACE => 1,
        FM_LINT_INTERNAL_ROOTS_LOG => "$dir/roots.tsv", FM_LINT_SHELLCHECK => "$tmp/shellcheck");
    my $launched = time();
    my $worker = fork();
    die "fork: $!" unless defined $worker;
    if (!$worker) {
        close $slot;
        open STDOUT, '>', "$dir/output" or die "$!";
        open STDERR, '>&', \*STDOUT or die "$!";
        exec '/bin/bash', $lint, '--internal-worker', "$dir/manifest", "$dir/out", 0;
        die "exec: $!";
    }
    my $error;
    eval {
        # Controller waits cover host scheduling and worker bookkeeping; the
        # protected root still has its independently enforced three-second bound.
        my $deadline = time() + 30;
        until (-s "$dir/roots.tsv") { die "root never began\n" if time() > $deadline; sleep 0.01; }
        my $began = time();
        sleep 1.5;
        close $slot;
        $deadline = time() + 30;
        while (waitpid($worker, WNOHANG) == 0) {
            die "queued root timed out\n" if time() > $deadline;
            sleep 0.01;
        }
        die "queued root failed: $?\n" if $?;
        my $finished = time();
        my $queued_ms = 0;
        for my $file (glob "$dir/out/*.rss.wait") {
            open(my $wait, '<', $file) or die "$!";
            $queued_ms += <$wait>;
        }
        my $elapsed = ($finished - $launched) * 1000 - $queued_ms;
        open(my $log, '<', "$dir/roots.tsv") or die "$!";
        my @end;
        while (<$log>) { @end = split /\t/ if /^end\t/; }
        die "missing root result\n" unless @end;
        my $expected = $retry ? 'memory-fallback' : 'ok';
        die "wrong root outcome: $end[9]\n" unless $end[9] eq $expected;
        die "root timestamps fall outside the observed lifecycle\n"
            unless $end[5] >= $launched * 1000 - 1 && $end[5] <= $began * 1000 + 1
                && $end[6] >= ($began + 1.5) * 1000 - 1 && $end[6] <= $finished * 1000 + 1;
        die "duration $end[7]ms exceeds $elapsed ms available for analysis\n"
            unless $end[7] >= 70 && $end[7] <= $elapsed + 2;
        die "root wall time omitted the queue\n" unless $end[6] - $end[5] >= 1500;
    };
    $error = $@;
    close $slot if defined fileno($slot);
    kill 'KILL', $worker;
    waitpid($worker, 0);
    die "retry=$retry: $error" if $error;
}
PL
  pass "queued roots and memory retries record precise analysis durations without EPOCHREALTIME"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_root_deadline_names_the_root_and_reaps_the_tree() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): root deadline kill check"
    return
  fi
  local tmp fakebin stub_log telemetry roots_log out rc
  local blocker ok sentinel_pid child_pid_file stub_pid_file child_pid stub_pid
  tmp=$(fm_test_tmproot fm-lint-bound-deadline)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  child_pid_file="$tmp/child.pid"
  stub_pid_file="$tmp/stub.pid"
  blocker="$tmp/blocker.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$blocker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 \
    FM_LINT_ROOT_SECONDS=1 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_STUB_LOG="$stub_log" FM_TEST_CHILD_PID="$child_pid_file" \
    FM_TEST_STUB_PID="$stub_pid_file" FM_TEST_BLOCK_SECS=300 \
    "$LINT" --telemetry "$telemetry" "$ok" "$blocker" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root pinned at the wall deadline unexpectedly passed"
  assert_contains "$out" "blocker.sh" "the timed-out root was not named"
  assert_contains "$out" "reason=timeout" "the timed-out root was not reported as a timeout"
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the lint deadline killed an unrelated sentinel process"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  if [ -s "$child_pid_file" ]; then
    child_pid=$(cat "$child_pid_file")
    kill -0 "$child_pid" 2>/dev/null \
      && fail "the blocked root's child survived the deadline kill"
  else
    fail "the blocked root never recorded its child pid"
  fi
  if [ -s "$stub_pid_file" ]; then
    stub_pid=$(cat "$stub_pid_file")
    kill -0 "$stub_pid" 2>/dev/null \
      && fail "the blocked root's ShellCheck process survived the deadline kill"
  else
    fail "the blocked root never recorded its ShellCheck pid"
  fi
  [ -f "$roots_log" ] || fail "the run kept no retained per-root sidecar"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the completed root's ok record"
  awk -F '\t' '$1 == "end" && $3 ~ /blocker\.sh$/ && $10 == "timeout" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the timed-out root by name"
  pass "a root pinned at the wall deadline fails by name, reaps its tree, and leaves the sentinel alive"
}

test_root_memory_limit_reports_a_named_death() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): memory-limit death check"
    return
  fi
  local tmp fakebin stub_log telemetry roots_log out rc hoarder ok
  local sentinel_pid
  tmp=$(fm_test_tmproot fm-lint-bound-memory)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  hoarder="$tmp/hoarder.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hoarder"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  # Control: with no memory limit the same allocator succeeds, so a memory
  # death below can only come from the enforced cap.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$tmp/control.tsv" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the allocator failed without any memory limit"$'\n'"$out"
  grep -q $'^meta\tbounds_enforced\t0$' "$tmp/control.roots.tsv" \
    || fail "the control run was not unbounded"
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$tmp/control.roots.tsv" || fail "the uncapped allocator root did not complete ok"

  # The hoarder stub allocates 512 MiB; under a 256 MiB address-space limit
  # the allocator is refused and the run must name the root, not survive.
  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=262144 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$telemetry" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root killed by its memory limit unexpectedly passed"
  assert_contains "$out" "hoarder.sh" "the memory-limited root was not named"
  assert_contains "$out" "reason=memory" "the memory-limit death was not classified as memory"
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the memory-limit kill took an unrelated sentinel process with it"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "memory" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the memory-limited root by name"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the clean root's record"
  pass "a root refused by its enforced memory limit fails by name with a memory reason"
}

test_memory_failure_retries_without_external_sources() {
  local tmp fakebin fixture out rc log rss_kib require_bounds=0 mode
  local -a modes=(0)
  if fm_lint_bounds_supported; then
    require_bounds=1
    modes=(1 0)
  fi
  tmp=$(fm_test_tmproot fm-lint-memory-fallback)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/teardown.sh"
  log="$tmp/flags.log"
  printf '#!/usr/bin/env bash\n# shellcheck source=lib.sh\nexit 0\n' > "$fixture"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
follow=no
exclude=none
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    --external-sources) follow=yes ;;
    --exclude=*) exclude=${1#--exclude=} ;;
  esac
  shift
done
shift
printf '%s\t%s\n' "$follow" "$exclude" >> "$FM_TEST_FALLBACK_LOG"
if [ "$follow" = yes ]; then
  printf 'shellcheck: Heap exhausted;\n' >&2
  exit 251
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  for mode in "${modes[@]}"; do
    : > "$log"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$mode" \
      FM_TEST_FALLBACK_LOG="$log" "$LINT" --telemetry "$tmp/pass.$mode.tsv" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "a clean no-source fallback did not pass (bounded=$mode)"$'\n'"$out"
    assert_grep $'source_directives\t1' "$tmp/pass.$mode.tsv" "telemetry lost the root's source directive"
    assert_grep $'source_followed_directives\t0' "$tmp/pass.$mode.tsv" \
      "telemetry counted a source directive that the passing fallback did not follow"
    [ "$(cat "$log")" = "$(printf 'yes\tnone\nno\tSC1091,SC2034,SC2153,SC2329')" ] \
      || fail "the memory failure did not retry without external sources and exclude only cross-file codes"$'\n'"$(cat "$log")"
    assert_contains "$out" "hit the memory ceiling with --external-sources (reason=memory rc=251)" \
      "the fallback was not identified in the output"
    assert_contains "$out" "fallback passed with cross-file codes excluded (SC1091,SC2034,SC2153,SC2329)" \
      "the narrower fallback result was not disclosed"
    awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 0 && $10 == "memory-fallback" { found=1 } END { exit !found }' \
      "$tmp/pass.$mode.roots.tsv" || fail "the clean fallback was not recorded distinctly"
    rss_kib=$(awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ { print $11 }' "$tmp/pass.$mode.roots.tsv")
    if [ "$mode" -eq 1 ]; then
      assert_grep $'meta\tbounds_enforced\t1' "$tmp/pass.$mode.roots.tsv" \
        "the bounded fallback did not enforce bounds"
      case "$rss_kib" in ''|*[!0-9]*) fail "the fallback attempts lost per-root RSS reporting: $rss_kib" ;; esac
    else
      assert_grep $'meta\tbounds_enforced\t0' "$tmp/pass.$mode.roots.tsv" \
        "the unbounded fallback unexpectedly enforced bounds"
      # Unbounded roots read RSS from /usr/bin/time when the host has it, so the
      # figure is either that reading or the explicit unavailable marker.
      case "$rss_kib" in
        unavailable) ;;
        ''|*[!0-9]*) fail "the unbounded fallback reported a malformed RSS: $rss_kib" ;;
      esac
    fi
  done

  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): real fallback finding check"
    return
  fi
  local real_shellcheck
  real_shellcheck=$(command -v shellcheck)
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  exec "$FM_REAL_SHELLCHECK" "$@"
fi
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
exec "$FM_REAL_SHELLCHECK" "$@"
SH
  chmod +x "$fakebin/shellcheck"
  # shellcheck disable=SC2016 # The fixture intentionally contains an unexpanded parameter.
  printf '#!/usr/bin/env bash\nx=$1\nprintf "%%s\\n" $x\n' > "$fixture"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_REAL_SHELLCHECK="$real_shellcheck" \
    FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$require_bounds" \
    "$LINT" --telemetry "$tmp/finding.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a real ShellCheck finding in the fallback did not fail lint (exit $rc)"$'\n'"$out"
  assert_contains "$out" "fallback reason=findings rc=1" \
    "the fallback finding was not identified"
  assert_contains "$out" "SC2086" "the real fallback finding was not reported"
  awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 1 && $10 == "findings" { found=1 } END { exit !found }' \
    "$tmp/finding.roots.tsv" || fail "the fallback finding was not recorded as a failure"
  pass "memory failures retry without source following, exclude cross-file codes, and preserve a real fallback finding"
}

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

fm_lint_small_repo() {  # <directory>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/bin/backends" "$dir/tests"
  cp "$LINT" "$ROOT/bin/fm-lint-cache.pl" "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-lint-workflows.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/fm-lint-workflows.sh"
  cat > "$dir/bin/library.sh" <<'SH'
#!/usr/bin/env bash
export SHARED_VALUE=ok
case "${1:-}" in ''|.|..|-*|*.git|*[!A-Za-z0-9._-]*) : ;; esac
SH
  cat > "$dir/bin/consumer.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=bin/library.sh
. "$(dirname "${BASH_SOURCE[0]}")/library.sh"
printf '%s\n' "$SHARED_VALUE"
SH
  cat > "$dir/bin/caller.sh" <<'SH'
#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/consumer.sh
. "$HERE/consumer.sh"
SH
}

fm_lint_production_repo() {
  local dir=$1 source
  fm_lint_small_repo "$dir"
  for source in "$ROOT"/bin/*.sh; do
    [ "${source##*/}" = fm-lint-workflows.sh ] || cp "$source" "$dir/bin/"
  done
  cp "$ROOT"/bin/backends/*.sh "$dir/bin/backends/"
}

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
test_jobs_are_deterministic_and_complete
test_host_slots_bound_concurrent_runs
test_host_load_shrinks_slots_to_the_floor
test_host_load_preserves_the_cap_until_the_threshold
test_slot_pool_can_be_disabled_or_misconfigured
test_slot_file_failures_run_ungated
test_slot_survives_gate_death
test_queued_roots_use_high_resolution_timings
test_worker_trees_stop_on_signal
test_root_deadline_names_the_root_and_reaps_the_tree
test_root_memory_limit_reports_a_named_death
test_memory_failure_retries_without_external_sources
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
test_zero_changed_files_exits_clean
test_ci_keeps_external_sources_without_local_exclusions
test_main_branch_keeps_external_sources
test_merge_base_less_keeps_external_sources
test_explicit_path_keeps_external_sources
