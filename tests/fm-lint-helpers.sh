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
  FM_TEST_REAL_GIT_BIN=$(command -v git)
  export FM_TEST_REAL_GIT_BIN
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
# Literal-baseline reads are real repository reads, not selection fixtures.
[ "${1:-}" != -C ] || exec "$FM_TEST_REAL_GIT_BIN" "$@"
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


# Validate one group's registered selection and run it in registration order.
fm_lint_run() {
  local requested_case test_case registered_case
  for requested_case in "$@"; do
    registered_case=false
    for test_case in "${fm_lint_test_cases[@]}"; do
      if [ "$requested_case" = "$test_case" ]; then registered_case=true; break; fi
    done
    if [ "$registered_case" = false ]; then
      printf 'Unknown test case: %s\n' "$requested_case" >&2
      printf 'Usage: bash %s [test_function_name ...]\n' "${BASH_SOURCE[1]##*/}" >&2
      exit 2
    fi
  done
  for test_case in "${fm_lint_test_cases[@]}"; do
    if [ "$#" -eq 0 ]; then "$test_case"; continue; fi
    for requested_case in "$@"; do
      if [ "$requested_case" = "$test_case" ]; then "$test_case"; break; fi
    done
  done
}
