#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs ShellCheck's default severity and extended, source-aware analysis with
# ambient configuration disabled and one exact ShellCheck version.
# CI selects the complete canonical set; local branches select changed files,
# known transitive sourcing callers, and possible callers of unresolved imports.
# Every mode attempts --norc --external-sources and the same diagnostic rules.
# A root that hits the memory ceiling while following sources is retried once
# without --external-sources and with SC1091, SC2034, SC2153, and SC2329
# excluded (see the memory fallback in fm_lint_run_root); the roots log marks
# the retry, and CI still checks those codes on every source-following attempt.
# --fast remains an explicit local-only opt-out from extended dataflow.
# Selection and cache reuse retain the roots' source directives and call-site
# context; checking a library separately cannot replace joint source analysis.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow first. CI coverage never depends
#     on a local diff; memory failures may take the narrower retry below.
#   - Otherwise it selects canonical roots whose transitive source closure
#     contains a path changed since the merge-base, including staged, unstaged,
#     untracked, deleted and renamed paths. An unchanged imported library is not
#     a separate root; its callers analyze it through their sources. Runtime
#     backend imports participate in selection and cache invalidation even when
#     their static source annotations intentionally isolate adapter analysis.
#     Unresolved runtime imports select possible callers on changed/deleted shell
#     or known source inputs and disable cache reuse, regardless of annotations.
#     Discovery recognizes source/. command words, balanced substitutions, and
#     executable bash/sh -c and program-stdin heredocs. Source annotations remain
#     inputs; ordinary comments, inert quoted programs, and heredoc data do not.
#     Quoted child positional arguments are resolved; <<- strips leading tabs.
#     Changes to bin/fm-lint.sh or bin/fm-lint-cache.pl select all. An empty
#     set skips ShellCheck but still checks backend purity and workflows. A
#     changed widely sourced library still costs a cold source-aware analysis
#     of every caller; the cache only reuses identical inputs.
# Explicit paths bypass changed-file selection and are linted as given, without
# the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
# Successful source-aware checks are shared across worktrees via content hashes
# of the root, its source closure, the analysis arguments, owner, helper, platform,
# and ShellCheck binary. Identical concurrent misses share one check through flock.
# Only successful, input-stable results are retained; findings always run again.
# FM_LINT_CACHE_DIR overrides ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/lint;
# "off" disables reuse. CI always disables reuse so every canonical root is checked.
# Nothing prunes that directory; each key leaves small files until removed by hand.
# A missing, unwritable or unresolvable cache falls back to real analysis.
#
# Dependency selection and caching are private Perl helpers using the Perl
# runtime already required for worker cleanup; no extra tool is installed.
# Lint defaults to two concurrency-limited workers over two stable logical
# shards, and each worker runs ONE canonical root per ShellCheck process, so a
# run holds at most JOBS concurrent ShellCheck processes. Diagnostics replay
# in stable shard/root order. FM_LINT_JOBS=1 changes concurrency, not diagnostics
# or exit selection.
# That bound is per run; only cold checks enter the host-wide pool, after cache
# lookup and identical-miss serialization, so hits and duplicate waiters consume
# no host slots. Cold roots share the pool per lint run, not per worker: a free
# slot goes to the waiting run holding the fewest slots, then the run served
# least recently, so a two-worker run cannot take two turns for each turn of a
# one-worker run. Within a run, roots stay FIFO and newer roots cannot bypass an
# older one. Killed waiters, and waiters stopped for a second while a slot sits
# free, are skipped automatically. Admission needs only a free slot among the
# cap; fairness does not increase host concurrency. After an update to this
# gate merges, restart in-flight lints that still run the older code.
# FM_LINT_SLOT_DIR defaults to ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/lint-slots;
# "off" disables the pool. Host load average never changes admission, so
# unrelated machine load cannot starve lint.
# Runs share a pool only when they use the same slot directory, so different
# homes or overrides must select the same directory to share the host bound.
# FM_LINT_HOST_SLOTS sets the cap; unset or empty uses max(2, floor(ncpu/2)).
# A nonempty value must be a positive decimal integer without leading zeros,
# or lint exits 2, even with the pool off. The cap is the only host-wide bound:
# a lone default two-worker run keeps both workers unless an explicit cap of one
# is selected. The CPU-derived default keeps the memory protection of the
# original pool (some ShellChecks reach several GB); the per-root memory limit
# is enforced only where ulimit -v works, and native macOS cannot enforce it.
# Waiting roots queue rather than fail; both cache-key and host-slot queue time
# consume neither the root deadline nor its retry budget.
# Slot directory, file, or locking failures warn and run ungated rather than failing lint.
# The private gate's locking and process-lifetime invariants live in bin/fm-lint-cache.pl.
# --partition 1of3/2of3/3of3 splits the entire canonical inventory across
# three CI runners, each with those same concurrency-limited workers.
# Partitions are complete, disjoint, and measured-duration balanced; --list-files
# exposes their actual roots. A root without a measured hint gets 6000 ms,
# rounded above the observed 5352 ms per-root mean; it is never omitted.
# Partition mode starts with full source-aware analysis, never changed-only
# or --fast, and does not accept explicit paths. Each partition also runs
# workflow lint and backend-purity checks, keeping either invocation
# independently useful.
#
# With FM_LINT_REQUIRE_BOUNDS=1, which CI sets, every per-root ShellCheck
# process runs under an enforced envelope: a wall deadline
# (FM_LINT_ROOT_SECONDS, default 1200, which fm-duration.py may only raise to
# a measured p99 x 3 once calibrated), a terminate-then-kill cleanup grace
# (FM_LINT_ROOT_GRACE, default 5), and a per-process address-space limit
# (FM_LINT_ROOT_MEMORY_KIB, default 12582912 = 12 GiB of virtual address
# space per analysis process). The sizing rationale and RSS reduction threshold
# live beside ROOT_MEMORY_KIB below. This is not a resident-memory ceiling;
# check aggregate runner RSS in CI. The watchdog uses the shared
# bin/fm-timeout-lib.sh group-kill pattern, so a deadline or an interrupt
# removes the owned process group. Bounds mode proves the watchdog can
# actually bound a probe command and that the host accepts the memory limit
# BEFORE any root starts; when either check fails the run refuses with a
# named error, so a required-bounds run never lints uncapped. Without
# FM_LINT_REQUIRE_BOUNDS (a local developer lint, where hosts like macOS
# cannot apply the address-space limit at all) each root still runs in its
# own ShellCheck process with identical diagnostics and no deadline or memory
# limit; the host-wide concurrency pool remains enabled unless disabled above.
#
# If a source-following root exits with a memory failure, it is retried once
# without --external-sources under the same memory limit and only the time
# left in that root's original deadline; with under a second left, the
# memory failure stands without a retry. A clean retry passes
# with an explicit memory-fallback reason and warning; only the
# cross-file-dependent codes listed above are excluded.
# Other findings and failed retries still fail lint. The retry's diagnostics
# replace the failed attempt's output; peak RSS is the maximum of both attempts.
#
# Root timestamps use Perl's high-resolution clock even on stock macOS Bash.
# Start/end span the queue wait; recorded duration subtracts waits from both
# the initial attempt and any retry.
# Per-root evidence is incremental: workers append begin/end records (root,
# mode, shard, start, end, duration, final exit status, reason, peak RSS when
# measured, whether the final attempt followed sources, calibration eligibility,
# and the 1-minute load at root start and end) to a roots log
# as each root completes, so a mid-run kill still leaves the completed record
# and names the root in flight as begun-but-unfinished. With --telemetry the
# log is retained at
# <telemetry-without-.tsv>.roots.tsv (or <telemetry>.roots.tsv if there is no
# .tsv suffix); otherwise it lives only in the
# run's scratch dir. Reason values are ok, findings, memory-fallback,
# timeout, memory, signal:<sig>, limit-unavailable, or error:<rc>.
# Memory requires process-level evidence (a GHC exhaustion status or runtime
# error on stderr), not an echoed source excerpt or an OOM phrase in a
# filename. In partition mode begin/end
# lines also stream to stderr, and an abnormal root end is always reported
# there.
# Duration observations are appended through fm-duration.py in one batch from
# the roots log when lint exits; cache-hit, partial selection and
# memory-fallback successes are not cold calibration evidence.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
# source_followed_directives counts directives only for roots whose final
# attempt followed sources, not roots that passed or failed a no-source retry.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override concurrent worker count
#   fm-lint.sh --partition <1of3|2of3|3of3> lint one canonical CI partition (see fallback above)
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. No-source checks (the
# memory fallback) cannot judge them.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# The sibling timeout library supplies the shared group-kill watchdog that
# bounds each root when FM_LINT_REQUIRE_BOUNDS=1 requires it; without the
# library a required-bounds run refuses in preflight rather than lint uncapped.
if [ -r "$SELF_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SELF_DIR/fm-timeout-lib.sh"
fi

if [ -r "$SELF_DIR/fm-duration-lib.sh" ]; then
  # shellcheck source=bin/fm-duration-lib.sh
  . "$SELF_DIR/fm-duration-lib.sh"
fi

FM_LINT_WORKER_RUN_PID=
FM_LINT_WORKER_ARGS=()
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_RUN_PID" ] || return 0
  kill "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  FM_LINT_WORKER_RUN_PID=
}

fm_lint_now_ms() {
  "${FM_LINT_PERL_BIN:-perl}" -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

# Names are listed only for signal numbers that agree on Linux and macOS; any
# other number reports itself.
fm_lint_signal_name() {  # <signal-number>
  case "$1" in
    1) printf 'HUP\n' ;; 2) printf 'INT\n' ;; 3) printf 'QUIT\n' ;;
    6) printf 'ABRT\n' ;; 8) printf 'FPE\n' ;; 9) printf 'KILL\n' ;;
    11) printf 'SEGV\n' ;; 13) printf 'PIPE\n' ;; 14) printf 'ALRM\n' ;;
    15) printf 'TERM\n' ;; 24) printf 'XCPU\n' ;; 25) printf 'XFSZ\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Peak RSS of a finished root process: GNU time writes max_rss_kib=<KiB> while
# BSD time -l writes "maximum resident set size" in bytes.
fm_lint_root_rss() {  # <rss-file>
  local file=$1 kib
  kib=$(awk '
    /^max_rss_kib=/ { value = substr($0, 13) + 0; found = 1 }
    /maximum resident set size/ { value = int($1 / 1024); found = 1 }
    END { if (found) print value }
  ' "$file" 2>/dev/null)
  printf '%s\n' "${kib:-unavailable}"
}

fm_lint_max_root_rss() {  # <rss-kib> <rss-kib>
  local first=$1 second=$2
  case "$first" in ''|unavailable|*[!0-9]*) printf '%s\n' "$second"; return ;; esac
  case "$second" in ''|unavailable|*[!0-9]*) printf '%s\n' "$first"; return ;; esac
  if [ "$first" -gt "$second" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# Map a root's exit status onto the reported reason vocabulary without
# pretending every signal or nonzero exit is a memory kill: only process-level
# memory-failure evidence earns the memory reason - GHC's heap-exhaustion
# status 251, or a complete runtime memory-error line on the root's stderr,
# including the cache wrapper's Perl "Out of memory!" exit 1 - and that
# evidence is checked before a generic findings or signal reason.
# Diagnostics and their echoed source excerpts are on stdout and never count,
# and each stderr form is matched whole to its line end, so a root path that
# merely contains OOM words inside a file error never counts either.
fm_lint_classify_root() {  # <rc> <root-stderr-file>
  local rc=$1 err=$2
  case "$rc" in
    0) printf 'ok\n'; return 0 ;;
    97) printf 'limit-unavailable\n'; return 0 ;;
    251) printf 'memory\n'; return 0 ;;
  esac
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && [ "$rc" = 124 ]; then
    printf 'timeout\n'; return 0
  fi
  if grep -qE '^[^[:space:]:]+: (out of memory \(requested [0-9]+ bytes\)|Heap exhausted;)$|: resource exhausted \((Cannot allocate memory|out of memory)\)$|^Out of memory!$' "$err" 2>/dev/null; then
    printf 'memory\n'; return 0
  fi
  if [ "$rc" = 1 ]; then
    printf 'findings\n'; return 0
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    case "$rc" in
      137)
        # The perl watchdog exits 124 on its own bound, so a bare 137 is a real
        # SIGKILL of the child; GNU/BSD timeout instead report 137 when their
        # configured kill had to fire at the bound.
        if [ "${FM_LINT_INTERNAL_BOUNDED:-}" = perl ]; then
          printf 'signal:KILL\n'; return 0
        fi
        printf 'timeout\n'; return 0
        ;;
    esac
  fi
  case "$rc" in
    ''|*[!0-9]*) printf 'error\n' ;;
    *)
      if [ "$rc" -gt 128 ]; then
        printf 'signal:%s\n' "$(fm_lint_signal_name "$((rc - 128))")"
      else
        printf 'error:%s\n' "$rc"
      fi
      ;;
  esac
}

# Run one ShellCheck invocation under the given deadline and the per-root
# address-space limit, returning its exit status in FM_LINT_LAST_RC.
fm_lint_exec_root() {  # <path> <stdout-file> <stderr-file> <rss-file> <seconds> <args...>
  local path=$1 root_out=$2 root_err=$3 rss_file=$4 seconds=$5 invocation_rc=0 wait_file waited
  local -a analysis_command gate_command cold_command check_command
  shift 5
  analysis_command=("$FM_LINT_SHELLCHECK" "$@" -- "$path")
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" = none ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      analysis_command=(/usr/bin/time -lp -o "$rss_file" "${analysis_command[@]}")
    else
      analysis_command=(/usr/bin/time -f 'max_rss_kib=%M' -o "$rss_file" "${analysis_command[@]}")
    fi
  fi
  # The host-wide slot gate sits outside the watchdog and /usr/bin/time, so
  # queue time counts toward neither the root deadline nor its peak RSS.
  gate_command=()
  wait_file="$rss_file.wait"
  rm -f "$wait_file" "$rss_file.cache" "$rss_file.cache.wait"
  if [ "${FM_LINT_INTERNAL_SLOT_DIR:-off}" != off ]; then
    gate_command=("${FM_LINT_PERL_BIN:-perl}" "$SELF_DIR/fm-lint-cache.pl" gate \
      "$FM_LINT_INTERNAL_SLOT_DIR" "$FM_LINT_INTERNAL_NCPU" "$FM_LINT_INTERNAL_RUN_ID" "$wait_file" --)
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    # The watchdog runs in a process group of its own (the same setpgrp hop the
    # workers use), so the owner's TERM-then-KILL group sweep cannot kill it
    # before it has forwarded the signal to the root's own group. If the worker
    # dies before its trap can signal the watchdog, the watchdog's parent-death
    # check still starts the same terminate-then-kill escalation; the worker
    # names itself as that owner before the launch, so a worker that dies while
    # the watchdog is still starting is detected too.
    cold_command=(${gate_command[@]+"${gate_command[@]}"} "${FM_LINT_PERL_BIN:-perl}" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        "${BASH:-bash}" "$SELF" --internal-timed \
        "$seconds" "$FM_LINT_INTERNAL_GRACE" \
        "${BASH:-bash}" "$SELF" --internal-root "$rss_file" "$FM_LINT_INTERNAL_MEMORY_KIB" \
        "${analysis_command[@]}")
  else
    cold_command=(${gate_command[@]+"${gate_command[@]}"} "${analysis_command[@]}")
  fi
  # Hits and identical concurrent misses need no host slot. Only the cache's
  # cold execution enters the gate, with the watchdog still inside admission.
  check_command=(env "FM_LINT_CACHE_RESULT_FILE=$rss_file.cache" \
    "${FM_LINT_PERL_BIN:-perl}" "$SELF_DIR/fm-lint-cache.pl" check \
    "${FM_LINT_INTERNAL_CACHE:-off}" "$ROOT" "$FM_LINT_SHELLCHECK" \
    "$@" -- "$path" --execute "${cold_command[@]}")
  ( FM_EXEC_TIMED_OWNER_PID=$$ exec "${check_command[@]}" ) > "$root_out" 2> "$root_err" &
  FM_LINT_WORKER_RUN_PID=$!
  wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
  FM_LINT_WORKER_RUN_PID=
  FM_LINT_LAST_RC=$invocation_rc
  FM_LINT_LAST_WAIT_MS=0
  for wait_file in "$rss_file.wait" "$rss_file.cache.wait"; do
    if [ -r "$wait_file" ]; then
      waited=$(tr -d '[:space:]' < "$wait_file" 2>/dev/null)
      case "$waited" in
        ''|*[!0-9]*) ;;
        *) FM_LINT_LAST_WAIT_MS=$((FM_LINT_LAST_WAIT_MS + waited)) ;;
      esac
    fi
  done
}

# Run one selected root, retry memory failures without source following, record
# its lifecycle in the roots log, and append the final diagnostics.
fm_lint_run_root() {  # <index> <path> <output-dir> <shard-index>
  local index=$1 path=$2 output_dir=$3 shard_index=$4
  local root_out="$output_dir/root.$shard_index.$index.out"
  local root_err="$output_dir/root.$shard_index.$index.err"
  local rss_file="$output_dir/root.$shard_index.$index.rss"
  local fallback_out="$output_dir/root.$shard_index.$index.fallback.out"
  local fallback_err="$output_dir/root.$shard_index.$index.fallback.err"
  local fallback_rss="$output_dir/root.$shard_index.$index.fallback.rss"
  local start_ms end_ms duration_ms invocation_rc=0 reason rss_kib initial_rc initial_reason
  local calibration=0 cache_outcome load_start='' load_end=''
  local fallback_secs queued_ms=0 root_seconds=$FM_LINT_INTERNAL_ROOT_SECS
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && declare -F fm_duration_limit >/dev/null 2>&1; then
    root_seconds=$(fm_duration_limit "lint-root.${FM_LINT_INTERNAL_MODE:-full}.$path" "$root_seconds" 99) || return $?
  fi
  local final_follow_sources=${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}
  local -a fallback_args
  if declare -F fm_duration_load >/dev/null 2>&1; then
    load_start=$(fm_duration_load)
  fi
  start_ms=$(fm_lint_now_ms)
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'begin\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" "$start_ms" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ]; then
    printf 'fm-lint: begin %s (shard %s, %s mode)\n' \
      "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-unknown}" >&2
  fi
  fm_lint_exec_root "$path" "$root_out" "$root_err" "$rss_file" \
    "$root_seconds" "${FM_LINT_WORKER_ARGS[@]}"
  invocation_rc=$FM_LINT_LAST_RC
  queued_ms=$FM_LINT_LAST_WAIT_MS
  reason=$(fm_lint_classify_root "$invocation_rc" "$root_err")
  initial_rc=$invocation_rc
  initial_reason=$reason
  # The retry spends what is left of this root's one deadline rather than a
  # fresh one, so both attempts together still fit the budget CI sized its job
  # timeout around.
  fallback_secs=$(( (start_ms + queued_ms + root_seconds * 1000 - $(fm_lint_now_ms)) / 1000 ))
  if [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
    && [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] \
    && [ "$fallback_secs" -lt 1 ]; then
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); no time left in its %ss deadline to retry without it\n' \
      "$path" "$initial_reason" "$initial_rc" "$root_seconds" >> "$output_dir/shard.$shard_index.out"
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  elif [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
    fallback_args=()
    for arg in "${FM_LINT_WORKER_ARGS[@]}"; do
      [ "$arg" = --external-sources ] || fallback_args+=("$arg")
    done
    [ -z "$LOCAL_NOX_EXCLUDE" ] || fallback_args+=("--exclude=$LOCAL_NOX_EXCLUDE")
    fm_lint_exec_root "$path" "$fallback_out" "$fallback_err" "$fallback_rss" \
      "$fallback_secs" "${fallback_args[@]}"
    final_follow_sources=0
    invocation_rc=$FM_LINT_LAST_RC
    queued_ms=$((queued_ms + FM_LINT_LAST_WAIT_MS))
    reason=$(fm_lint_classify_root "$invocation_rc" "$fallback_err")
    rss_kib=$(fm_lint_max_root_rss \
      "$(fm_lint_root_rss "$rss_file")" "$(fm_lint_root_rss "$fallback_rss")")
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); retried without it' \
      "$path" "$initial_reason" "$initial_rc" >> "$output_dir/shard.$shard_index.out"
    if [ "$reason" = ok ]; then
      reason=memory-fallback
      invocation_rc=0
      printf '; fallback passed with cross-file codes excluded (%s)\n' "$LOCAL_NOX_EXCLUDE" \
        >> "$output_dir/shard.$shard_index.out"
    else
      printf '; fallback reason=%s rc=%s\n' "$reason" "$invocation_rc" \
        >> "$output_dir/shard.$shard_index.out"
    fi
    cat "$fallback_out" "$fallback_err" >> "$output_dir/shard.$shard_index.out"
  else
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  fi
  end_ms=$(fm_lint_now_ms)
  if declare -F fm_duration_load >/dev/null 2>&1; then
    load_end=$(fm_duration_load)
  fi
  duration_ms=$((end_ms - start_ms - queued_ms))
  cache_outcome=$(cat "$rss_file.cache" 2>/dev/null || true)
  if [ "$cache_outcome" = analyzed ] && [ "$reason" != memory-fallback ]; then
    calibration=1
  fi
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" \
      "$start_ms" "$end_ms" "$duration_ms" "$invocation_rc" "$reason" "$rss_kib" "$final_follow_sources" "$calibration" \
      "$load_start" "$load_end" >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ] || { [ "$reason" != ok ] && [ "$reason" != findings ] && [ "$reason" != memory-fallback ]; }; then
    printf 'fm-lint: end %s reason=%s rc=%s duration_ms=%s rss_kib=%s\n' \
      "$path" "$reason" "$invocation_rc" "$duration_ms" "$rss_kib" >&2
  fi
  return "$invocation_rc"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab entry index path output invocation_rc rc=0
  local -a root_entries
  root_entries=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    root_entries+=("$index	$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#root_entries[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    FM_LINT_WORKER_ARGS=(--norc --external-sources)
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      FM_LINT_WORKER_ARGS+=(--extended-analysis=false)
    fi
    : > "$output.out"
    for entry in "${root_entries[@]}"; do
      index=${entry%%"$tab"*}
      path=${entry#*"$tab"}
      invocation_rc=0
      fm_lint_run_root "$index" "$path" "$output_dir" "$shard_index" || invocation_rc=$?
      if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
        rc=$invocation_rc
      fi
    done
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

# Private per-root payload mode used only by the bounded runner above: apply
# the per-process address-space limit (a positive KiB count), then exec
# /usr/bin/time for the per-root peak-RSS record when it is available, else the
# tool itself. A limit the host cannot apply exits 97 so the parent reports
# limit-unavailable instead of running uncapped.
if [ "${1:-}" = "--internal-root" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-root is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  internal_rss_file=$2
  internal_memory_kib=$3
  shift 3
  case "$internal_memory_kib" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: --internal-root memory limit must be a positive KiB count, got %s\n' \
        "$internal_memory_kib" >&2
      exit 2
      ;;
  esac
  ulimit -v "$internal_memory_kib" 2>/dev/null || {
    printf 'fm-lint.sh: per-root memory limit %s KiB is not enforceable on this host\n' \
      "$internal_memory_kib" >&2
    exit 97
  }
  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec /usr/bin/time -l -o "$internal_rss_file" "$@"
    fi
    exec /usr/bin/time -f 'max_rss_kib=%M' -o "$internal_rss_file" "$@"
  fi
  exec "$@"
fi

# Private bounded-run mode used only by the per-root runner above: the caller
# has already moved this process into its own group, so re-enter through SELF
# keeps the watchdog out of the worker's killable group while resolving the
# shared fm_exec_timed implementation through the same source path.
if [ "${1:-}" = "--internal-timed" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-timed is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  declare -F fm_exec_timed >/dev/null 2>&1 || {
    printf 'fm-lint.sh: fm-timeout-lib.sh is required for bounded runs.\n' >&2
    exit 127
  }
  fm_exec_timed "$2" "$3" "${@:4}"
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  if [ -r "$SELF_DIR/fm-duration.py" ]; then
    python3 "$SELF_DIR/fm-duration.py" check-literals || return $?
  fi
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
PARTITION=
PARTITION_REQUESTED=0
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --partition)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --partition requires 1of3, 2of3 or 3of3.\n' >&2; exit 2; }
      PARTITION=$2
      PARTITION_REQUESTED=1
      shift 2
      ;;
    --partition=*)
      PARTITION=${1#*=}
      PARTITION_REQUESTED=1
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

case "$PARTITION" in
  '')
    if [ "$PARTITION_REQUESTED" -eq 1 ]; then
      printf 'fm-lint.sh: --partition requires 1of3, 2of3 or 3of3.\n' >&2
      exit 2
    fi
    ;;
  1of3|2of3|3of3)
    if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ]; then
      printf 'fm-lint.sh: --partition requires full canonical lint; omit --fast and explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) printf 'fm-lint.sh: --partition must be 1of3, 2of3 or 3of3, got %s.\n' "$PARTITION" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}


CHANGED_MODE=0
EXPLICIT_PATHS=0
# Until a complete cold run proves otherwise, this invocation is not evidence
# for the canonical cold ceiling (including a zero-target changed selection).
if [ -n "${FM_DURATION_CALIBRATION_FILE:-}" ] && [ "${FM_DURATION_MANAGED_KEY:-}" = "lint.$ANALYSIS_MODE.${PARTITION:-whole}" ]; then
  printf '0\n' > "$FM_DURATION_CALIBRATION_FILE"
fi
if [ "$LIST_FILES" -eq 0 ] && ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for source selection, caching and worker cleanup.\n' >&2
  exit 127
fi
[ -r "$SELF_DIR/fm-lint-cache.pl" ] || {
  printf 'fm-lint.sh: bin/fm-lint-cache.pl is required for source-aware lint.\n' >&2
  exit 2
}
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ -z "$PARTITION" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    changed_list=$(mktemp "${TMPDIR:-/tmp}/fm-lint-changes.XXXXXX") || exit 1
    selected_list=$(mktemp "${TMPDIR:-/tmp}/fm-lint-selection.XXXXXX") || { rm -f "$changed_list"; exit 1; }
    if ! git diff --name-only --no-renames -z "$merge_base" -- > "$changed_list" \
      || ! git ls-files --others --exclude-standard -z >> "$changed_list" \
      || ! perl "$SELF_DIR/fm-lint-cache.pl" select "$ROOT" < "$changed_list" > "$selected_list"; then
      rm -f "$changed_list" "$selected_list"
      printf 'fm-lint.sh: could not select changed roots and source dependencies.\n' >&2
      exit 2
    fi
    while IFS= read -r -d '' changed_path; do
      ROOTS+=("$changed_path")
    done < "$selected_list"
    rm -f "$changed_list" "$selected_list"
  fi
fi
# Stable largest-first packing uses measured durations across CI runners and
# direct bytes across the two local workers. Neither weight is a skip rule.
TAB=$(printf '\t')
# Slowest successful per-root duration_ms from three Ubuntu main runs.
# docs/fm-test-portable-shards.md owns measurement provenance and refresh.
# Hints affect assignment only, never source analysis or canonical coverage.
fm_lint_partition_weight_hints() {
  cat <<'EOF'
bin/backends/cmux.sh	3524
bin/backends/herdr.sh	15753
bin/backends/orca.sh	3322
bin/backends/tmux.sh	5429
bin/backends/zellij.sh	3623
bin/fm-afk-contract.sh	583
bin/fm-afk-launch.sh	11442
bin/fm-afk-return.sh	22823
bin/fm-afk-start.sh	7882
bin/fm-agent-process-lib.sh	565
bin/fm-agy-trust.sh	216
bin/fm-api-key-guard-lib.sh	165
bin/fm-arm-pretool-check.sh	217
bin/fm-backend-hometag-lib.sh	167
bin/fm-backend.sh	767
bin/fm-backlog-handoff.sh	54793
bin/fm-backlog-receive.sh	7935
bin/fm-backlog-transition-lib.sh	3425
bin/fm-bearings-board.sh	365
bin/fm-bearings-snapshot.sh	618
bin/fm-bootstrap.sh	34845
bin/fm-branch-outcome.sh	16653
bin/fm-branch-prompt.sh	114
bin/fm-branch-report.sh	8034
bin/fm-brief-heading-lib.sh	117
bin/fm-brief.sh	21315
bin/fm-busy-event.sh	918
bin/fm-busy-lib.sh	668
bin/fm-captain-hold.sh	24125
bin/fm-cd-pretool-check.sh	215
bin/fm-check-lib.sh	217
bin/fm-check-register.sh	2121
bin/fm-check-unregister.sh	2020
bin/fm-classify-lib.sh	7084
bin/fm-claude-launcher-lib.sh	165
bin/fm-claude-memory-lib.sh	167
bin/fm-claude-stop-autoarm.sh	8586
bin/fm-claude-trust.sh	467
bin/fm-compact-adviser-lib.sh	115
bin/fm-composer-lib.sh	2823
bin/fm-config-inherit-lib.sh	1820
bin/fm-config-push.sh	12094
bin/fm-contributions.sh	11089
bin/fm-control-lib.sh	365
bin/fm-control-worktree-lib.sh	417
bin/fm-control.sh	39808
bin/fm-cpu-pass.sh	167
bin/fm-crew-state.sh	30829
bin/fm-cursor-lib.sh	215
bin/fm-decision-hold.sh	315
bin/fm-devin-config.sh	165
bin/fm-dispatch-capacity-lib.sh	2874
bin/fm-dispatch-capacity.sh	3073
bin/fm-dispatch-resolve.sh	4828
bin/fm-doc-audience-check.sh	114
bin/fm-dod-lib.sh	10742
bin/fm-ensure-agents-md.sh	214
bin/fm-env-lib.sh	116
bin/fm-exclude-tools-lib.sh	165
bin/fm-extension.sh	117
bin/fm-ff-lib.sh	867
bin/fm-fleet-ledger.sh	16052
bin/fm-fleet-snapshot.sh	15453
bin/fm-fleet-sync.sh	568
bin/fm-fleet-view.sh	115
bin/fm-forge-detect.sh	116
bin/fm-gate-refuse-lib.sh	167
bin/fm-gemini-lib.sh	165
bin/fm-gh-rest.sh	7983
bin/fm-git-strip-ai-trailers.sh	217
bin/fm-guard.sh	7732
bin/fm-harness.sh	616
bin/fm-herdr-ci-cleanup.sh	168
bin/fm-herdr-lab.sh	570
bin/fm-herdr-session-cleanup.sh	11494
bin/fm-hold-reason-lib.sh	116
bin/fm-home-seed.sh	11088
bin/fm-home-summary-refresh.sh	7933
bin/fm-hook-host-lib.sh	116
bin/fm-host-mirror.sh	7982
bin/fm-idle-reap-lib.sh	20114
bin/fm-idle-session-reap.sh	23416
bin/fm-inactive-reconcile.sh	31391
bin/fm-inbox.sh	9488
bin/fm-install-actionlint.sh	167
bin/fm-install-herdr.sh	166
bin/fm-install-shellcheck.sh	166
bin/fm-install-treehouse.sh	166
bin/fm-jev-belay-hook.sh	617
bin/fm-jev-guard-hook.sh	116
bin/fm-kimi-turnend-hook.sh	165
bin/fm-lab-home.sh	8234
bin/fm-landed-lib.sh	120
bin/fm-launch-proof-lib.sh	867
bin/fm-lease-lib.sh	518
bin/fm-lease.sh	8133
bin/fm-line-cap-lib.sh	117
bin/fm-lint-workflows.sh	167
bin/fm-lint.sh	1418
bin/fm-live-lab.sh	8934
bin/fm-load-report.sh	114
bin/fm-lock-lib.sh	167
bin/fm-lock.sh	8184
bin/fm-mail-check.sh	2623
bin/fm-mail.sh	18559
bin/fm-marker-lib.sh	417
bin/fm-mem-guard.sh	115
bin/fm-merge-authority-lib.sh	2823
bin/fm-merge-local.sh	15548
bin/fm-merge-outcome-lib.sh	10238
bin/fm-model-catalog-lib.sh	467
bin/fm-model-freshness.sh	617
bin/fm-model-index.sh	717
bin/fm-nm-run-lib.sh	566
bin/fm-on.sh	468
bin/fm-open-loops.sh	114
bin/fm-operational-input.sh	368
bin/fm-parent-channel-lib.sh	316
bin/fm-path-lib.sh	115
bin/fm-peek.sh	868
bin/fm-pending-reply-lib.sh	20007
bin/fm-pipeline-spend.sh	2720
bin/fm-pr-check.sh	23619
bin/fm-pr-lib.sh	1718
bin/fm-pr-merge.sh	32592
bin/fm-pr-poll.sh	216
bin/fm-pr-reviewers.sh	1919
bin/fm-pr-state.sh	1969
bin/fm-primary-scope-lib.sh	166
bin/fm-proc-budget.sh	166
bin/fm-proc-guard.sh	116
bin/fm-procevent-lavish.sh	12645
bin/fm-procevent-lib.sh	1369
bin/fm-procevent-posttool-check.sh	1969
bin/fm-procevent-proc.sh	1670
bin/fm-procevent-quota.sh	11944
bin/fm-procevent-remote-reply.sh	33344
bin/fm-procevent-when.sh	12845
bin/fm-procevent.sh	17508
bin/fm-project-capacity-lib.sh	214
bin/fm-project-mode.sh	165
bin/fm-project-origin-lib.sh	166
bin/fm-promote.sh	47477
bin/fm-public-followup-collect.sh	15951
bin/fm-public-followup-emit.sh	16455
bin/fm-public-followup-lib.sh	14448
bin/fm-public-followup.sh	19310
bin/fm-push-transition-lib.sh	17257
bin/fm-quota-axi-lib.sh	167
bin/fm-quota-choose.sh	3773
bin/fm-reboot-recover.sh	1920
bin/fm-remote-delta-read.sh	315
bin/fm-remote-doctor.sh	4025
bin/fm-remote-entrypoint.sh	2019
bin/fm-remote-file.sh	7735
bin/fm-remote-herdr-guard.sh	265
bin/fm-remote-herdr-owner-lib.sh	218
bin/fm-remote-home-provision.sh	7933
bin/fm-remote-home-seed.sh	8386
bin/fm-remote-inherit-push.sh	2320
bin/fm-remote-inherit.sh	10190
bin/fm-remote-job-lib.sh	1620
bin/fm-remote-job-reap-orphans.sh	1920
bin/fm-remote-job-worker.sh	3425
bin/fm-remote-readiness-lib.sh	114
bin/fm-remote-secondmate-control.sh	27027
bin/fm-remote-secondmate-relaunch.sh	11495
bin/fm-review-diff.sh	265
bin/fm-secondmate-charter-lib.sh	115
bin/fm-secondmate-liveness-lib.sh	12245
bin/fm-secondmate-nudge-lib.sh	164
bin/fm-secondmate-parent-lib.sh	167
bin/fm-secondmate-reconcile.sh	8034
bin/fm-secondmate-registry-lib.sh	317
bin/fm-secondmate-report.sh	21417
bin/fm-secondmate-restart-lib.sh	1218
bin/fm-secondmate-restart.sh	21063
bin/fm-send.sh	44872
bin/fm-session-end-relaunch-lib.sh	22518
bin/fm-session-launch-policy-lib.sh	2171
bin/fm-session-lock-lib.sh	415
bin/fm-session-start.sh	26077
bin/fm-sessionstart-cursor.sh	115
bin/fm-sessionstart-nudge.sh	566
bin/fm-sessionstart-run.sh	668
bin/fm-skill-pick.sh	517
bin/fm-spawn.sh	59208
bin/fm-startup-growth-check.sh	2623
bin/fm-startup-memory-budget-lib.sh	215
bin/fm-startup-memory-budget.sh	268
bin/fm-startup-network.sh	8736
bin/fm-status-decision-lib.sh	1117
bin/fm-status-event-lib.sh	1571
bin/fm-status-io-lib.sh	566
bin/fm-status-record-lib.sh	165
bin/fm-status-wake-lib.sh	3074
bin/fm-stow-cascade.sh	2119
bin/fm-supervise-daemon.sh	26627
bin/fm-supervision-engine-lib.sh	367
bin/fm-supervision-host.sh	10989
bin/fm-supervision-instructions.sh	568
bin/fm-supervision-lib.sh	165
bin/fm-supervisor-target-lib.sh	116
bin/fm-tangle-lib.sh	165
bin/fm-task-copy-lib.sh	867
bin/fm-task-docker-lib.sh	616
bin/fm-task-inbox-lib.sh	467
bin/fm-tasks-axi-lib.sh	215
bin/fm-tasks-axi.sh	13147
bin/fm-teamclaude-launch.sh	317
bin/fm-teardown.sh	85068
bin/fm-test-isolation-proof.sh	415
bin/fm-test-reap-orphans.sh	7735
bin/fm-test-run.sh	1871
bin/fm-timeout-lib.sh	265
bin/fm-timing-lib.sh	171
bin/fm-tmux-lib.sh	3575
bin/fm-tool-update-check.sh	3074
bin/fm-trace-context-lib.sh	217
bin/fm-transition-lib.sh	165
bin/fm-turnend-guard-cursor.sh	9138
bin/fm-turnend-guard-grok.sh	465
bin/fm-turnend-guard.sh	8136
bin/fm-typesafe-health.sh	1500
bin/fm-typesafe-lib.sh	417
bin/fm-update.sh	2520
bin/fm-utc-lib.sh	116
bin/fm-vendor-auth-probe.sh	317
bin/fm-wake-drain.sh	19360
bin/fm-wake-grant.sh	7082
bin/fm-wake-lib.sh	6933
bin/fm-watch-arm.sh	7986
bin/fm-watch-checkpoint.sh	517
bin/fm-watch.sh	53828
bin/fm-watchdog-check.sh	43468
bin/fm-watchdog-install.sh	216
bin/fm-worker-account-lib.sh	417
bin/fm-x-dismiss.sh	5580
bin/fm-x-followup.sh	13198
bin/fm-x-lib.sh	5079
bin/fm-x-link.sh	16304
bin/fm-x-poll.sh	15852
bin/fm-x-reply.sh	6178
tests/cmux-test-safety.sh	166
tests/fixtures.sh	768
tests/fm-afk-contract.test.sh	1370
tests/fm-afk-inject-e2e.test.sh	265
tests/fm-afk-inject-herdr-e2e.test.sh	415
tests/fm-afk-launch.test.sh	19156
tests/fm-afk-pi-herdr-return-e2e.test.sh	1017
tests/fm-afk-return.test.sh	4326
tests/fm-agy-composer-live-e2e.test.sh	916
tests/fm-agy-harness.test.sh	1621
tests/fm-agy-signals-live-e2e.test.sh	866
tests/fm-arm-pretool-check.test.sh	1170
tests/fm-ask-user-authority.test.sh	718
tests/fm-backend-autodetect-smoke.test.sh	267
tests/fm-backend-cmux-smoke.test.sh	266
tests/fm-backend-cmux.test.sh	9639
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh	917
tests/fm-backend-herdr-eventwait-smoke.test.sh	216
tests/fm-backend-herdr-focus-flash-e2e.test.sh	417
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh	568
tests/fm-backend-herdr-presentation-e2e.test.sh	3674
tests/fm-backend-herdr-prune-safety-e2e.test.sh	264
tests/fm-backend-herdr-recovery-lock-e2e.test.sh	14550
tests/fm-backend-herdr-respawn-idem-e2e.test.sh	217
tests/fm-backend-herdr-smoke.test.sh	468
tests/fm-backend-herdr-stale-active-tab-e2e.test.sh	165
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh	365
tests/fm-backend-herdr.test.sh	52691
tests/fm-backend-orca.test.sh	2270
tests/fm-backend-tmux-smoke.test.sh	216
tests/fm-backend-zellij-smoke.test.sh	266
tests/fm-backend-zellij.test.sh	10140
tests/fm-backend.test.sh	1768
tests/fm-backlog-atomicity.test.sh	40860
tests/fm-backlog-handoff.test.sh	1869
tests/fm-backlog-read-bound.test.sh	1067
tests/fm-bearings-board-lavish-live-e2e.test.sh	817
tests/fm-bearings-board-render.test.sh	868
tests/fm-bearings-board.test.sh	1570
tests/fm-bearings-snapshot.test.sh	3926
tests/fm-bootstrap-network-parallel.test.sh	918
tests/fm-bootstrap.test.sh	2319
tests/fm-branch-supervision.test.sh	2472
tests/fm-brief.test.sh	14800
tests/fm-busy-adapter-wiring.test.sh	1519
tests/fm-busy-state.test.sh	1317
tests/fm-calm-claude-mod-live-e2e.test.sh	1117
tests/fm-calm-claude-mod-plugin.test.sh	716
tests/fm-calm-claude-mod.test.sh	969
tests/fm-calm-pi-extension.test.sh	3072
tests/fm-calm-pi-queue-retention-live-e2e.test.sh	718
tests/fm-captain-hold-archive.test.sh	1324
tests/fm-captain-hold-cleanup.test.sh	2765
tests/fm-captain-hold-keyed-answers.test.sh	1806
tests/fm-captain-hold-lifecycle-helpers.sh	438
tests/fm-captain-hold-lifecycle.test.sh	2388
tests/fm-captain-hold-reconcile.test.sh	2543
tests/fm-captain-hold-sweep.test.sh	1481
tests/fm-cd-pretool-check.test.sh	1067
tests/fm-check-unregister.test.sh	868
tests/fm-ci-workflow.test.sh	867
tests/fm-classify-corr-token.test.sh	10038
tests/fm-classify-decision-key.test.sh	9639
tests/fm-claude-nested-home-live-e2e.test.sh	1670
tests/fm-claude-stop-autoarm-live-e2e.test.sh	967
tests/fm-claude-stop-autoarm.test.sh	3021
tests/fm-claude-titled-composer-live-e2e.test.sh	1268
tests/fm-claude-trust.test.sh	1718
tests/fm-cmux-claude-composer-live-e2e.test.sh	1671
tests/fm-codex-continuity-live-e2e.test.sh	718
tests/fm-codex-hook-layer-live-e2e.test.sh	919
tests/fm-composer-codex-idle-live-e2e.test.sh	818
tests/fm-composer-ghost.test.sh	1220
tests/fm-composer-lib.test.sh	3625
tests/fm-composer-matrix-live-e2e.test.sh	967
tests/fm-composer-native-band.test.sh	1370
tests/fm-composer-native-continuation.test.sh	1067
tests/fm-composer-native-idle-hint.test.sh	4024
tests/fm-contributions-read-saved.test.sh	768
tests/fm-contributions.test.sh	2221
tests/fm-control-herdr-smoke.test.sh	1069
tests/fm-control-reassociate.test.sh	3073
tests/fm-control-relaunch.test.sh	9888
tests/fm-control.test.sh	9788
tests/fm-cpu-pass.test.sh	1370
tests/fm-crew-state.test.sh	6482
tests/fm-cursor-harness.test.sh	7933
tests/fm-cursor-primary-live-e2e.test.sh	866
tests/fm-cursor-primary.test.sh	1518
tests/fm-daemon.test.sh	41764
tests/fm-devin-harness.test.sh	6330
tests/fm-devin-signals-live-e2e.test.sh	7082
tests/fm-dispatch-capacity.test.sh	4427
tests/fm-dispatch-resolve.test.sh	2923
tests/fm-documentation-audiences.test.sh	767
tests/fm-dod-lib.test.sh	13247
tests/fm-ensure-agents-md.test.sh	1069
tests/fm-extension-binding.test.sh	6682
tests/fm-fleet-ledger.test.sh	13697
tests/fm-fleet-snapshot-contribution-cleanup.test.sh	767
tests/fm-fleet-snapshot-fleet-cost.test.sh	769
tests/fm-fleet-snapshot-rolling-window.test.sh	766
tests/fm-fleet-snapshot-tmp-leak.test.sh	766
tests/fm-fleet-snapshot-view.test.sh	9835
tests/fm-fleet-sync.test.sh	1318
tests/fm-forge-detect.test.sh	768
tests/fm-fork-free-helpers.test.sh	817
tests/fm-gate-refuse.test.sh	1419
tests/fm-gemini-harness.test.sh	1119
tests/fm-gh-rest.test.sh	1267
tests/fm-git-strip-ai-trailers.test.sh	3174
tests/fm-gitignore-config.test.sh	167
tests/fm-gotmp.test.sh	217
tests/fm-grok-continuity-live-e2e.test.sh	816
tests/fm-grok-harness.test.sh	968
tests/fm-grok-stop-live-e2e.test.sh	967
tests/fm-guard-stale-banner.test.sh	1568
tests/fm-harness-adapter-instructions-live-e2e.test.sh	917
tests/fm-harness-adapter-references.test.sh	668
tests/fm-harness-liveness-drift-live-e2e.test.sh	868
tests/fm-harness-precedence.test.sh	1270
tests/fm-herdr-attached-viewer-live-e2e.test.sh	917
tests/fm-herdr-lab.test.sh	1418
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh	869
tests/fm-herdr-session-cleanup-e2e.test.sh	215
tests/fm-herdr-session-cleanup.test.sh	1068
tests/fm-herdr-submit-confirm-live-e2e.test.sh	1470
tests/fm-herdr-version-floor-live-e2e.test.sh	819
tests/fm-home-summary-refresh-ownership.test.sh	668
tests/fm-home-summary-refresh.test.sh	2672
tests/fm-host-mirror-live-e2e.test.sh	5979
tests/fm-host-mirror.test.sh	1069
tests/fm-idle-session-reap.test.sh	34944
tests/fm-inactive-reconcile.test.sh	1771
tests/fm-inbox.test.sh	1420
tests/fm-jev-guard.test.sh	1018
tests/fm-keep-ai-trailers-home-local.test.sh	1620
tests/fm-kimi-harness.test.sh	1819
tests/fm-launch-prompt-signals-live-e2e.test.sh	56051
tests/fm-launch-proof.test.sh	15948
tests/fm-lint-workflows.test.sh	1069
tests/fm-lint.test.sh	3523
tests/fm-live-gate.test.sh	1119
tests/fm-live-lab-up-mate.test.sh	967
tests/fm-live-lab.test.sh	2070
tests/fm-load-report.test.sh	968
tests/fm-mail-check.test.sh	1118
tests/fm-mail.test.sh	2473
tests/fm-mem-guard.test.sh	117
tests/fm-model-freshness.test.sh	1318
tests/fm-model-index-live-e2e.test.sh	1217
tests/fm-model-index.test.sh	5728
tests/fm-model-picker.test.sh	900
tests/fm-muse-harness.test.sh	4074
tests/fm-muse-signals-live-e2e.test.sh	6831
tests/fm-nm-test-contract.test.sh	667
tests/fm-no-mistakes-required.test.sh	719
tests/fm-omp-composer-box-live-e2e.test.sh	2019
tests/fm-omp-fallback-chain-live-e2e.test.sh	1067
tests/fm-omp-harness.test.sh	11440
tests/fm-omp-primary-live-e2e.test.sh	969
tests/fm-omp-reboot-live-e2e.test.sh	2924
tests/fm-omp-stale-wake-live-e2e.test.sh	766
tests/fm-omp-task-session-live-e2e.test.sh	668
tests/fm-omp-wake-restore-live-e2e.test.sh	2671
tests/fm-omp-wake-turns.test.sh	114
tests/fm-on.test.sh	3322
tests/fm-open-loops.test.sh	818
tests/fm-opencode-primary-live-e2e.test.sh	1019
tests/fm-operational-input.test.sh	916
tests/fm-orphan-safety.test.sh	868
tests/fm-parent-channel-scan-exclusion.test.sh	968
tests/fm-peek-remote.test.sh	719
tests/fm-pending-reply.test.sh	43161
tests/fm-pi-branch-extension.test.sh	1921
tests/fm-pi-branch-live-e2e.test.sh	867
tests/fm-pi-branch-responsiveness-live-e2e.test.sh	867
tests/fm-pi-codex-native.test.sh	716
tests/fm-pi-primary-live-e2e.test.sh	1069
tests/fm-pi-primary-types.test.sh	165
tests/fm-pi-seeded-home-trust-live-e2e.test.sh	818
tests/fm-pi-watch-extension.test.sh	2420
tests/fm-pi-watch-loader-live.test.sh	717
tests/fm-pi-windows-shell-invocation.test.sh	716
tests/fm-pipeline-spend.test.sh	968
tests/fm-pr-check-security.test.sh	13798
tests/fm-pr-merge.test.sh	3825
tests/fm-pr-reviewers.test.sh	767
tests/fm-pr-state-live-e2e.test.sh	716
tests/fm-pr-state.test.sh	869
tests/fm-proc-budget.test.sh	1067
tests/fm-proc-guard.test.sh	1018
tests/fm-procevent-proc.test.sh	969
tests/fm-procevent-quota.test.sh	416
tests/fm-procevent-runner-backlog.test.sh	1067
tests/fm-procevent-runner-custody.test.sh	969
tests/fm-procevent-when.test.sh	3472
tests/fm-procevent.test.sh	58841
tests/fm-project-capacity.test.sh	1318
tests/fm-project-origin.test.sh	816
tests/fm-public-followup.test.sh	22319
tests/fm-quota-array-dispatch-live-e2e.test.sh	768
tests/fm-quota-choose.test.sh	515
tests/fm-remote-backlog-handoff.test.sh	1518
tests/fm-remote-delta-read.test.sh	916
tests/fm-remote-doctor.test.sh	1819
tests/fm-remote-entrypoint.test.sh	767
tests/fm-remote-herdr-guard.test.sh	1370
tests/fm-remote-job-claim-reap.test.sh	4826
tests/fm-remote-job-claim-retention.test.sh	2620
tests/fm-remote-job-launchagent.test.sh	3123
tests/fm-remote-job-orphan-reap.test.sh	869
tests/fm-remote-job.test.sh	11845
tests/fm-remote-reply.test.sh	36703
tests/fm-remote-secondmate-lifecycle-e2e.test.sh	5327
tests/fm-remote-secondmate-parent-binding.test.sh	3073
tests/fm-remote-secondmate-relaunch.test.sh	3673
tests/fm-remote-secondmate-trace-context.test.sh	968
tests/fm-remote-transport-lanes.test.sh	3472
tests/fm-review-diff.test.sh	869
tests/fm-rovo-harness.test.sh	9038
tests/fm-rovo-signals-live-e2e.test.sh	1520
tests/fm-secondmate-harness.test.sh	3473
tests/fm-secondmate-lifecycle-e2e.test.sh	1068
tests/fm-secondmate-liveness.test.sh	1568
tests/fm-secondmate-reconcile.test.sh	1819
tests/fm-secondmate-restart.test.sh	2420
tests/fm-secondmate-safety.test.sh	13245
tests/fm-secondmate-sync.test.sh	3024
tests/fm-send-agy-confirm.test.sh	768
tests/fm-send-inbox-doorbell-live-e2e.test.sh	917
tests/fm-send-inbox.test.sh	1217
tests/fm-send-popup-settle.test.sh	766
tests/fm-send-remote-delivery.test.sh	24769
tests/fm-send-resolve-key.test.sh	1670
tests/fm-send-secondmate-marker-herdr-e2e.test.sh	818
tests/fm-send-secondmate-marker.test.sh	919
tests/fm-send-settle.test.sh	817
tests/fm-send-strict.test.sh	917
tests/fm-session-end-relaunch.test.sh	2070
tests/fm-session-launch-policy-inherit.test.sh	3073
tests/fm-session-launch-policy-receipt.test.sh	11692
tests/fm-session-launch-policy.test.sh	2471
tests/fm-session-lock-ancestry.test.sh	1468
tests/fm-session-start.test.sh	4278
tests/fm-sessionstart-hook-live-e2e.test.sh	1119
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh	869
tests/fm-sessionstart-nudge.test.sh	1270
tests/fm-shared-captain-inheritance.test.sh	1269
tests/fm-skill-pick.test.sh	2724
tests/fm-spawn-acquisition-cleanup.test.sh	71683
tests/fm-spawn-acquisition-herdr-e2e.test.sh	114
tests/fm-spawn-batch.test.sh	818
tests/fm-spawn-claude-api-key-guard.test.sh	1370
tests/fm-spawn-claude-start-confirm.test.sh	1067
tests/fm-spawn-compact-adviser-disable-remote.test.sh	917
tests/fm-spawn-compact-adviser-disable.test.sh	1571
tests/fm-spawn-dispatch-profile.test.sh	3923
tests/fm-spawn-herdr-launch-shell.test.sh	1068
tests/fm-spawn-orca-worktree.test.sh	969
tests/fm-spawn-pool-base-freshen.test.sh	1818
tests/fm-spawn-retained-copy.test.sh	17409
tests/fm-spawn-worktree-settle.test.sh	1017
tests/fm-startup-growth-check.test.sh	3375
tests/fm-startup-memory-budget.test.sh	969
tests/fm-startup-network.test.sh	1720
tests/fm-stat-shadowing.test.sh	68234
tests/fm-stow-cascade.test.sh	1019
tests/fm-supervision-events.test.sh	1217
tests/fm-supervision-fork-budget.test.sh	867
tests/fm-supervision-host-attended-live-e2e.test.sh	6430
tests/fm-supervision-host-helpers.sh	1068
tests/fm-supervision-host-hook.test.sh	1720
tests/fm-supervision-host-live-e2e.test.sh	867
tests/fm-supervision-host.test.sh	3825
tests/fm-supervision-instructions.test.sh	1067
tests/fm-tangle-guard.test.sh	1118
tests/fm-task-delivery.test.sh	2372
tests/fm-task-docker-live-e2e.test.sh	1570
tests/fm-task-inbox.test.sh	2322
tests/fm-tasks-axi.test.sh	2121
tests/fm-teamclaude-launch-live-e2e.test.sh	718
tests/fm-teamclaude-launch.test.sh	1119
tests/fm-teardown-endpoint-safety.test.sh	2321
tests/fm-teardown.test.sh	10286
tests/fm-test-fixture-cleanup.test.sh	819
tests/fm-test-fixtures.test.sh	1270
tests/fm-test-isolation-proof.test.sh	917
tests/fm-test-reap-orphans.test.sh	1569
tests/fm-test-run.test.sh	3424
tests/fm-timeout-lib.test.sh	4425
tests/fm-tmux-agent-liveness.test.sh	6178
tests/fm-tmux-submit-busy.test.sh	9088
tests/fm-tool-update-check.test.sh	1669
tests/fm-trace-context-lib.test.sh	916
tests/fm-trace-context-spawn.test.sh	1270
tests/fm-transition-lib.test.sh	716
tests/fm-turnend-foreign-owner-arm-fix.test.sh	116
tests/fm-turnend-guard.test.sh	3224
tests/fm-typesafe-health.test.sh	1500
tests/fm-typesafe-key-source.test.sh	1068
tests/fm-update.test.sh	1119
tests/fm-vendor-auth-probe.test.sh	967
tests/fm-voice-relay.test.sh	1820
tests/fm-wake-daemon-lifecycle-e2e.test.sh	1019
tests/fm-wake-drain-open-decisions-cursor.test.sh	1620
tests/fm-wake-drain-open-decisions.test.sh	1019
tests/fm-wake-drain-outcome-backstop.test.sh	1369
tests/fm-wake-drain-unread-status.test.sh	19612
tests/fm-wake-queue.test.sh	5478
tests/fm-watch-arm.test.sh	2822
tests/fm-watch-checkpoint.test.sh	1017
tests/fm-watch-idle-reap.test.sh	1269
tests/fm-watch-open-loops.test.sh	1969
tests/fm-watch-recovery-loop.test.sh	1067
tests/fm-watch-triage.test.sh	11895
tests/fm-watch-typesafe-health.test.sh	1200
tests/fm-watchdog-check.test.sh	1217
tests/fm-watcher-lock.test.sh	2773
tests/fm-worker-account-live-e2e.test.sh	1220
tests/fm-worker-account.test.sh	1668
tests/fm-x-mode.test.sh	4825
tests/git-config-helpers.sh	117
tests/herdr-client-pair-fixture.sh	114
tests/herdr-test-safety.sh	116
tests/lib.sh	618
tests/remote-herdr-fixture.sh	114
tests/secondmate-helpers.sh	716
tests/wake-helpers.sh	817
tests/zellij-test-safety.sh	113
EOF
}

fm_lint_root_weights() {
  local index=1 path weight
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ]; then
  PARTITION_ROOTS=()
  partition_weights=$(set -o pipefail; fm_lint_root_weights | awk -F '\t' '
    NR == FNR { hint[$1]=$2; next }
    { printf "%s\t%s\t%s\n", (($3 in hint) ? hint[$3] : 6000), $2, $3 }
  ' <(fm_lint_partition_weight_hints) -) || exit $?
  while IFS="$TAB" read -r index path; do
    PARTITION_ROOTS+=("$path")
  done < <(printf '%s\n' "$partition_weights" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n | awk -F '\t' -v want="${PARTITION%%of*}" '
    {
      shard=1
      for (candidate=2; candidate<=3; candidate++)
        if (load[candidate] < load[shard]) shard=candidate
      load[shard]+=$1
      if (shard == want) print $2 "\t" $3
    }
  ' | LC_ALL=C sort -t "$TAB" -k1,1n)
  ROOTS=("${PARTITION_ROOTS[@]}")
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
CACHE_DIR=${FM_LINT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/lint}
if [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; then
  CACHE_DIR=off
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

# Per-root bounded-execution envelope. Under FM_LINT_REQUIRE_BOUNDS=1 the
# watchdog is probed and the host's acceptance of ulimit -v is checked before
# any root starts; failed checks refuse with a named error. A required-bounds run
# never lints uncapped. Without it each root still runs alone in its own
# ShellCheck process, unbounded, for local developer lint.
ROOT_SECONDS=${FM_LINT_ROOT_SECONDS:-1200}
ROOT_GRACE=${FM_LINT_ROOT_GRACE:-5}
# 12 GiB of virtual address space per analysis process. ulimit -v caps
# address space, not resident memory; ShellCheck's GHC runtime reserves about
# a third of that space, leaving ~8 GiB usable heap per root. Measured x86_64
# demand for the heaviest roots is near 5.5-6 GiB: the 8 GiB address-space
# cap's ~5.33 GiB wall caught bin/fm-spawn.sh, bin/fm-teardown.sh,
# tests/fm-pending-reply.test.sh, and
# tests/fm-launch-prompt-signals-live-e2e.test.sh. CI runs one root per
# lint job, so worst-case resident demand is ~8 GiB plus runner overhead,
# inside the 16 GiB runner. Local lint defaults to two workers; two such
# caps allow ~16 GiB resident plus host overhead, so use FM_LINT_JOBS=1 on
# smaller local machines. A root that exceeds its cap fails by name.
# Never drop diagnostic rules or leave a source owner unchecked to fit a root
# under its cap. The roots sidecar records peak RSS even without bounds; roots
# peaking above about 3 GiB resident remain source-graph reduction candidates.
ROOT_MEMORY_KIB=${FM_LINT_ROOT_MEMORY_KIB:-12582912}
for bound_pair in \
  "FM_LINT_ROOT_SECONDS=$ROOT_SECONDS" \
  "FM_LINT_ROOT_GRACE=$ROOT_GRACE" \
  "FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB"; do
  case "${bound_pair#*=}" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: %s must be a positive integer, got %s.\n' \
        "${bound_pair%%=*}" "${bound_pair#*=}" >&2
      exit 2
      ;;
  esac
done

BOUND_MECH=none
if [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
  bounds_problems=()
  if declare -F fm_exec_timed >/dev/null 2>&1; then
    # perl is mandatory above, so fm_exec_timed always takes its perl watchdog.
    BOUND_MECH=perl
  else
    bounds_problems+=('bin/fm-timeout-lib.sh is missing beside fm-lint.sh, so no watchdog is available')
  fi
  if [ "$BOUND_MECH" != none ]; then
    # Exercise the real bound end to end before any root starts: a clean probe
    # must exit 0 and an over-deadline probe must come back as a timeout, so a
    # watchdog that cannot actually bound a command (a perl without
    # Time::HiRes, say) refuses the run here instead of failing every root at
    # run time.
    probe_rc=0
    ( fm_exec_timed 30 1 true ) >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      bounds_problems+=("the timeout watchdog could not run a probe command (rc=$probe_rc)")
    else
      probe_rc=0
      ( fm_exec_timed 2 1 sleep 30 ) >/dev/null 2>&1 || probe_rc=$?
      case "$probe_rc" in
        124|137) : ;;
        *) bounds_problems+=("the timeout watchdog did not bound an over-deadline probe (rc=$probe_rc)") ;;
      esac
    fi
  fi
  ( ulimit -v "$ROOT_MEMORY_KIB" ) 2>/dev/null \
    || bounds_problems+=("per-root memory limit FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB KiB is not enforceable on this host (ulimit -v)")
  if [ "${#bounds_problems[@]}" -gt 0 ]; then
    for problem in "${bounds_problems[@]}"; do
      printf 'fm-lint.sh: bounds required but %s.\n' "$problem" >&2
    done
    printf 'fm-lint.sh: refusing to lint uncapped under FM_LINT_REQUIRE_BOUNDS=1.\n' >&2
    exit 2
  fi
fi

# Host-wide pool configuration; the header owns its public controls.
SLOT_DIR=${FM_LINT_SLOT_DIR:-${XDG_CACHE_HOME:-${HOME:-${TMPDIR:-/tmp}}/.cache}/firstmate/lint-slots}
case "${FM_LINT_HOST_SLOTS:-1}" in
  ''|0*|*[!0-9]*)
    printf 'fm-lint.sh: FM_LINT_HOST_SLOTS must be a positive integer, got %s.\n' \
      "${FM_LINT_HOST_SLOTS:-}" >&2
    exit 2
    ;;
esac
NCPU=
if [ "$SLOT_DIR" != off ]; then
  NCPU=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null) || NCPU=
  case "$NCPU" in ''|0*|*[!0-9]*) NCPU=1 ;; esac
fi

PROGRESS=0
if [ -n "$PARTITION" ]; then
  PROGRESS=1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_stop_workers() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  ACTIVE_PIDS=()
}
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  fm_lint_stop_workers
  rm -rf "$TMP_ROOT"
}
FM_LINT_DURATION_LOAD=
if declare -F fm_duration_load >/dev/null 2>&1; then
  FM_LINT_DURATION_LOAD=$(fm_duration_load)
fi
FM_LINT_DURATION_START=$(fm_lint_now_ms)
# shellcheck disable=SC2329 # Invoked by EXIT trap.
fm_lint_finish() {
  local result=$? calibration=0
  fm_lint_stop_workers
  if [ "$EXPLICIT_PATHS" -eq 0 ] && [ "$CHANGED_MODE" -eq 0 ] && [ -s "${ROOTS_LOG:-}" ]; then
    calibration=$(awk -F '\t' '$1 == "end" { count++; if ($13 != 1) ineligible++ } END { print (count > 0 && !ineligible) ? 1 : 0 }' "$ROOTS_LOG")
  fi
  if [ -n "${FM_DURATION_CALIBRATION_FILE:-}" ] && [ "${FM_DURATION_MANAGED_KEY:-}" = "lint.$ANALYSIS_MODE.${PARTITION:-whole}" ]; then
    printf '%s\n' "$calibration" > "$FM_DURATION_CALIBRATION_FILE"
  fi
  if declare -F fm_duration_record_batch >/dev/null 2>&1; then
    {
      if [ -s "${ROOTS_LOG:-}" ]; then
        awk -F '\t' -v OFS='\t' '$1 == "end" { print "lint-root." ($5 == "" ? "full" : $5) "." $3, $8, $9, $13, $14, $15, ($10 == "timeout" ? 1 : 0) }' "$ROOTS_LOG"
      fi
      printf 'lint.%s.%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$ANALYSIS_MODE" "${PARTITION:-whole}" \
        "$(( $(fm_lint_now_ms) - FM_LINT_DURATION_START ))" "$result" "$calibration" \
        "$FM_LINT_DURATION_LOAD" "$(fm_duration_load)"
    } | fm_duration_record_batch
  fi
  fm_lint_cleanup
}
trap fm_lint_finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"

# The roots log is the retained per-root lifecycle sidecar; beside --telemetry
# it survives as ${TELEMETRY%.tsv}.roots.tsv even when a run is killed
# mid-flight.
if [ -n "$TELEMETRY" ]; then
  ROOTS_LOG=${TELEMETRY%.tsv}.roots.tsv
else
  ROOTS_LOG=$TMP_ROOT/roots.tsv
fi
: > "$ROOTS_LOG"
if [ "$BOUND_MECH" != none ]; then
  bounds_applied=1
  root_deadline_meta=$ROOT_SECONDS
  root_grace_meta=$ROOT_GRACE
  root_memory_meta=$ROOT_MEMORY_KIB
else
  bounds_applied=0
  root_deadline_meta=unbounded
  root_grace_meta=unbounded
  root_memory_meta=unbounded
fi
{
  printf 'format\t%s\n' 'fm-lint-roots-v1'
  printf 'meta\t%s\t%s\n' 'shellcheck_version' "$resolved"
  printf 'meta\t%s\t%s\n' 'platform' "$(uname -s) $(uname -m)"
  printf 'meta\t%s\t%s\n' 'image_os' "${ImageOS:-unknown}"
  printf 'meta\t%s\t%s\n' 'image_version' "${ImageVersion:-unknown}"
  printf 'meta\t%s\t%s\n' 'mode' "$ANALYSIS_MODE"
  printf 'meta\t%s\t%s\n' 'partition' "${PARTITION:-all}"
  printf 'meta\t%s\t%s\n' 'jobs' "$JOBS"
  printf 'meta\t%s\t%s\n' 'bounds_enforced' "$bounds_applied"
  printf 'meta\t%s\t%s\n' 'root_deadline_seconds' "$root_deadline_meta"
  printf 'meta\t%s\t%s\n' 'root_kill_grace_seconds' "$root_grace_meta"
  printf 'meta\t%s\t%s\n' 'root_memory_limit_kib' "$root_memory_meta"
  printf 'meta\t%s\t%s\n' 'timing_mechanism' "$BOUND_MECH"
} >> "$ROOTS_LOG"

SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_root_weights > "$WEIGHTS" || exit $?

# Largest-first deterministic greedy assignment balances the two worker
# queues without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  local -a worker_env
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  worker_env=(
    FM_LINT_INTERNAL=1
    FM_LINT_INTERNAL_FAST="$FAST"
    FM_LINT_INTERNAL_BOUNDED="$BOUND_MECH"
    FM_LINT_INTERNAL_MEMORY_KIB="$ROOT_MEMORY_KIB"
    FM_LINT_INTERNAL_ROOT_SECS="$ROOT_SECONDS"
    FM_LINT_INTERNAL_GRACE="$ROOT_GRACE"
    FM_LINT_INTERNAL_ROOTS_LOG="$ROOTS_LOG"
    FM_LINT_INTERNAL_MODE="$ANALYSIS_MODE"
    FM_LINT_INTERNAL_PROGRESS="$PROGRESS"
    FM_LINT_SHELLCHECK="$SHELLCHECK_BIN"
    FM_LINT_PERL_BIN="$PERL_BIN"
  )
  worker_env+=(FM_LINT_INTERNAL_CACHE="$CACHE_DIR" FM_LINT_INTERNAL_SLOT_DIR="$SLOT_DIR" FM_LINT_INTERNAL_NCPU="$NCPU")
  worker_env+=(FM_LINT_INTERNAL_RUN_ID="$$")
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env "${worker_env[@]}" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

# Close the roots log with completion counts so a mid-run kill leaves
# begun-but-unfinished roots attributable by name. result_exit is appended
# after the purity and workflow checks so it records the run's final status.
if [ -s "$ROOTS_LOG" ]; then
  read -r roots_completed roots_unfinished roots_begun <<EOF
$(awk -F '\t' '
  $1 == "begin" { begun[$2 FS $3] = 1; total++ }
  $1 == "end" { ended[$2 FS $3] = 1; done_count++ }
  END { unfinished = 0; for (key in begun) if (!(key in ended)) unfinished++
        printf "%d %d %d\n", done_count + 0, unfinished, total + 0 }
' "$ROOTS_LOG")
EOF
  {
    printf 'meta\t%s\t%s\n' 'roots_begun' "$roots_begun"
    printf 'meta\t%s\t%s\n' 'roots_completed' "$roots_completed"
    printf 'meta\t%s\t%s\n' 'roots_unfinished' "$roots_unfinished"
  } >> "$ROOTS_LOG"
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  source_followed=0
  awk -F '\t' '$1 == "end" && $12 == 0 { print $2 }' "$ROOTS_LOG" > "$TMP_ROOT/no-source-indices"
  root_index=0
  for path in "${ROOTS[@]}"; do
    root_index=$((root_index + 1))
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" > "$TMP_ROOT/root-source-targets"
      cat "$TMP_ROOT/root-source-targets" >> "$TMP_ROOT/source-targets"
      if ! grep -qx "$root_index" "$TMP_ROOT/no-source-indices"; then
        followed_here=$(grep -cv '^/dev/null$' "$TMP_ROOT/root-source-targets" || true)
        source_followed=$((source_followed + followed_here))
      fi
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'partition\t%s\n' "${PARTITION:-all}"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_bounds_enforced\t%s\n' "$bounds_applied"
    printf 'root_deadline_seconds\t%s\n' "$root_deadline_meta"
    printf 'root_kill_grace_seconds\t%s\n' "$root_grace_meta"
    printf 'root_memory_limit_kib\t%s\n' "$root_memory_meta"
    printf 'root_timing_mechanism\t%s\n' "$BOUND_MECH"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ -s "$ROOTS_LOG" ]; then
  printf 'meta\t%s\t%s\n' 'result_exit' "$overall_rc" >> "$ROOTS_LOG"
fi

exit "$overall_rc"
