#!/usr/bin/env bash
# fm-merge-prune-lib.sh - the provable-scratch proofs behind bin/fm-merge-prune.sh.
#
# bin/fm-teardown.sh stays the authority. This library is used only when
# teardown refused a merged task's pool copy for a reason that may not be real
# unlanded work (a false-positive landing refusal, an orphan nested copy with no
# task record, ignored scratch files). It follows the criteria of the owner's
# treehouse-reap-clean reaper and proves, read live, that the copy holds nothing
# worth keeping. It never forces, discards or hides anything: any proof it
# cannot make keeps the copy.
#
# A copy passes only when ALL of these hold, for the task's own copy AND for
# every nested copy found inside it, each checked one by one:
#   - the path is a pool copy: <pool root>/<pool>/<slot>/<repo> (the pool root is
#     $TREEHOUSE_ROOT, default $HOME/.treehouse);
#   - git reports no changed or untracked file and the copy holds no stash entry;
#   - no commit on HEAD or any local branch is missing from every remote (after a
#     fetch), except that the task's own copy may also rely on the merged pull
#     request's head: a commit that is an ancestor of refs/pull/<n>/head landed;
#   - every ignored file is scratch (list below), a preserved record, or a
#     symlink; anything else is unique and keeps the copy;
#   - no process has its working directory or an open file inside it, except a
#     system search indexer and the idle shell of the task's own terminal pane
#     (fm_mp_pane_shell).
# Ignored scratch: virtual environments, node_modules, tool and build caches
# (.venv, venv, node_modules, __pycache__, .pytest_cache, .ruff_cache,
# .mypy_cache, .next, graphify-out, .import_linter_cache, *.tsbuildinfo,
# .tac/tmp, .tac/uv-cache), .DS_Store, Firstmate's turn-end hook files, and
# anything ignored under .claude or .opencode. The preserve list is exempt from
# that last rule: .claude/bug-evidence (slot-specific closeout records) and
# .claude/channel-outbox (rate files). Before removal those are copied to the
# task's data folder with SHA-256 checksums and verified there.
#
# Each proof sets FM_MP_VERDICT (ok | keep | transient) and FM_MP_REASON. A
# transient verdict (a timed-out process or git read) is retried later; keep is
# a real reason that raises one wake. PR 166 (teardown keeps unique ignored
# files) preserves other ignored files inside teardown's own nested-copy path;
# this fallback is stricter by design and writes to its own preserve directory.
#
# Requires bin/fm-timeout-lib.sh and bin/fm-backend.sh to be sourced first.
# Regression coverage: tests/fm-merge-prune.test.sh.

FM_MP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_MP_LIB_DIR/fm-agent-process-lib.sh"
# shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
FM_MP_VERDICT=
# shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
FM_MP_REASON=
FM_MP_PRESERVE=()
FM_MP_NESTED=()

# A bound for one external call. Calibrated by bin/fm-duration.py limit when the
# host has samples for the key; otherwise the fallback, in seconds.
fm_mp_limit() {  # <key> <fallback-seconds>
  python3 "$FM_MP_LIB_DIR/fm-duration.py" limit "$1" --fallback "$2" --percentile 99 --margin 3 2>/dev/null \
    || printf '%s' "$2"
}

# Names that are scratch wherever they appear as an ignored entry.
fm_mp_scratch_name() {  # <basename>
  case "$1" in
    .venv|venv|node_modules|__pycache__|.pytest_cache|.ruff_cache|.mypy_cache) return 0 ;;
    .DS_Store|.fm-grok-turnend|.fm-kimi-turnend) return 0 ;;
    .next|graphify-out|.import_linter_cache|*.tsbuildinfo) return 0 ;;
  esac
  return 1
}

fm_mp_pool_root() {  # -> real pool root on stdout
  local root=${TREEHOUSE_ROOT:-${HOME:-}/.treehouse}
  case "$root" in /*) ;; *) return 1 ;; esac
  [ -d "$root" ] || return 1
  (cd "$root" 2>/dev/null && pwd -P)
}

fm_mp_real() {  # <path> -> physical path on stdout
  (cd "$1" 2>/dev/null && pwd -P)
}

# 0 when <real-path> is <root>/<pool>/<slot>/<repo> or inside one.
fm_mp_in_pool() {  # <real-path>
  local root
  root=$(fm_mp_pool_root) || return 1
  case "$1" in
    "$root"/*/*/*) return 0 ;;
  esac
  return 1
}

# Paths of copies nested strictly inside <copy>: any directory below it that
# holds its own .git, other than a tracked submodule. Dependency and
# environment trees are not searched.
fm_mp_find_nested() {  # <real-copy>; fills FM_MP_NESTED
  local copy=$1 gitpath dir sub gitlinks
  FM_MP_NESTED=()
  gitlinks=$(git -C "$copy" ls-files -s 2>/dev/null | sed -n 's/^160000 [0-9a-f]* [0-9]\t//p')
  while IFS= read -r -d '' gitpath; do
    dir=${gitpath%/.git}
    sub=${dir#"$copy"/}
    if [ -n "$gitlinks" ] && printf '%s\n' "$gitlinks" | grep -Fxq -- "$sub"; then
      continue
    fi
    FM_MP_NESTED+=("$dir")
  done < <(find "$copy" \
    \( -path "$copy/.git" -o -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
    -name .git -prune -print0 2>/dev/null)
}

fm_mp_verdict() {  # <ok|keep|transient> <reason>
  # shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
  FM_MP_VERDICT=$1
  # shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
  FM_MP_REASON=$2
}

# Status, stash and unpushed-commit proofs for one copy.
# <pr-number> is empty for a nested copy; the task's own copy passes it so a
# squash-merged pull request's head counts as the remote proof.
fm_mp_prove_git() {  # <real-copy> [<pr-number>]
  local copy=$1 prn=${2:-} top dirty stashes unpushed prsha='' extra=()
  if ! top=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) || [ "$(fm_mp_real "$top")" != "$copy" ]; then
    fm_mp_verdict keep "$copy is not a git work tree root"
    return 1
  fi
  if ! dirty=$(git -C "$copy" status --porcelain 2>/dev/null); then
    fm_mp_verdict transient "git status failed in $copy"
    return 1
  fi
  if [ -n "$dirty" ]; then
    fm_mp_verdict keep "$copy has changed or untracked files ($(printf '%s\n' "$dirty" | wc -l | tr -d ' ') entries, first: $(printf '%s\n' "$dirty" | sed -n 1p))"
    return 1
  fi
  stashes=$(git -C "$copy" stash list 2>/dev/null | wc -l | tr -d ' ')
  if [ "$stashes" != 0 ]; then
    fm_mp_verdict keep "$copy holds $stashes stash entries"
    return 1
  fi
  fm_run_timed "$(fm_mp_limit merge-prune.fetch 120)" git -C "$copy" fetch -q --all </dev/null >/dev/null 2>&1 || true
  if [ -n "$prn" ]; then
    if fm_run_timed "$(fm_mp_limit merge-prune.fetch 120)" git -C "$copy" fetch -q origin "refs/pull/$prn/head" </dev/null >/dev/null 2>&1; then
      prsha=$(git -C "$copy" rev-parse -q --verify FETCH_HEAD 2>/dev/null) || prsha=
    fi
  fi
  [ -z "$prsha" ] || extra=("$prsha")
  if ! unpushed=$(git -C "$copy" rev-list --count HEAD --branches --not --remotes ${extra[@]+"${extra[@]}"} 2>/dev/null); then
    fm_mp_verdict keep "cannot compare $copy with its remotes"
    return 1
  fi
  if [ "$unpushed" != 0 ]; then
    fm_mp_verdict keep "$copy has $unpushed commit(s) on no remote"
    return 1
  fi
  return 0
}

# Classify every ignored entry of one copy. Fills FM_MP_PRESERVE with the
# copy-relative preserve-list paths; keeps the copy on the first unique entry.
fm_mp_prove_ignored() {  # <real-copy>
  local copy=$1 entry rel listing
  FM_MP_PRESERVE=()
  if ! listing=$(git -C "$copy" ls-files -o -i --exclude-standard --directory -z 2>/dev/null | tr '\0' '\n'); then
    fm_mp_verdict keep "cannot list ignored files in $copy"
    return 1
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel=${entry%/}
    fm_mp_classify_entry "$copy" "$rel" || return 1
  done <<EOF
$listing
EOF
  return 0
}

# One ignored entry: scratch (return 0), preserved (recorded, return 0), or
# unique (keep verdict, return 1). Directories that may hold both kinds are
# opened one level at a time.
fm_mp_classify_entry() {  # <real-copy> <relative-path>
  local copy=$1 rel=$2 name child n
  name=${rel##*/}
  if [ -L "$copy/$rel" ]; then
    return 0
  fi
  case "$rel" in
    .claude/bug-evidence|.claude/bug-evidence/*|.claude/channel-outbox|.claude/channel-outbox/*)
      case "$rel" in
        .claude/bug-evidence|.claude/channel-outbox) FM_MP_PRESERVE+=("$rel") ;;
        *)
          # A file inside a preserved directory is covered by the directory.
          n=${rel#.claude/}
          n=${n%%/*}
          case " ${FM_MP_PRESERVE[*]-} " in
            *" .claude/$n "*) ;;
            *) FM_MP_PRESERVE+=(".claude/$n") ;;
          esac
          ;;
      esac
      return 0
      ;;
    .claude|.tac)
      if [ -d "$copy/$rel" ]; then
        while IFS= read -r child; do
          [ -n "$child" ] || continue
          fm_mp_classify_entry "$copy" "$rel/$child" || return 1
        done < <(ls -A "$copy/$rel" 2>/dev/null)
        return 0
      fi
      ;;
    .tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) return 0 ;;
    .claude/*|.opencode|.opencode/*) return 0 ;;
  esac
  if fm_mp_scratch_name "$name"; then
    return 0
  fi
  fm_mp_verdict keep "$copy holds an ignored file that is neither scratch nor on the preserve list: $rel"
  return 1
}

# A process with a working directory or an open file under <real-copy> keeps it.
# lsof is the same probe treehouse-reap-clean uses (minus system search
# indexers and the task's own idle pane shell, below); a missing probe cannot
# prove absence and keeps the copy, a probe that times out is retried later.
fm_mp_prove_unused() {  # <real-copy> [<pane-pid>]
  local copy=$1 pane=${2:-} out rc=0 kept pid
  if ! command -v lsof >/dev/null 2>&1; then
    fm_mp_verdict keep "cannot prove no process uses $copy: lsof is not installed"
    return 1
  fi
  out=$(fm_run_timed "$(fm_mp_limit merge-prune.lsof 90)" lsof +D "$copy" -t 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    fm_mp_verdict transient "process check of $copy timed out"
    return 1
  fi
  out=$(printf '%s\n' "$out" | sort -u | tr '\n' ' ')
  out=${out% }
  kept=
  for pid in $out; do
    fm_mp_indexer_pid "$pid" || fm_mp_pane_shell "$pid" "$pane" || kept="${kept:+$kept }$pid"
  done
  if [ -n "$kept" ]; then
    fm_mp_verdict keep "process(es) inside $copy: $kept"
    return 1
  fi
  return 0
}

# A system search indexer (macOS Spotlight) holds a recently written tree open
# for as long as a minute while it reads it. It only reads, deleting the tree
# under it harms nothing, and counting it would keep nearly every fresh copy on a
# Mac. It and the task's own pane shell (fm_mp_pane_shell) are the deliberate
# exceptions to "no process inside" (named in docs/configuration.md); any other
# process, whatever it does, keeps the copy.
fm_mp_indexer_pid() {  # <pid>
  local comm
  comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  comm=${comm##*/}
  case "$comm" in
    mdworker|mdworker_shared|mds|mds_stores|mdsync) return 0 ;;
  esac
  return 1
}

# The pid of the shell that the task's terminal pane was started with, for the
# backends that report it (tmux, herdr); nothing for any other backend or when
# the pane cannot be read, which exempts nothing.
fm_mp_pane_pid() {  # <meta-file>
  local meta=$1 target out pid=
  target=$(fm_backend_target_of_meta "$meta") || return 0
  case "$(fm_backend_of_meta "$meta")" in
    tmux)
      pid=$(fm_run_timed 15 tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null </dev/null) || pid=
      ;;
    herdr)
      out=$(fm_run_timed 30 bash -c '. "$1/fm-backend.sh" && fm_backend_source herdr && fm_backend_herdr_cli "$2" pane process-info --pane "$3"' \
        _ "$FM_MP_LIB_DIR" "${target%%:*}" "${target#*:}" 2>/dev/null </dev/null) || out=
      pid=$(printf '%s' "$out" | jq -r --arg pane "${target#*:}" \
        'select(.result.process_info.pane_id == $pane) | .result.process_info.shell_pid // empty' 2>/dev/null) || pid=
      ;;
  esac
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 1 ] || return 0
  printf '%s' "$pid"
}

# Whether <pid> is the task's own pane shell: the idle shell that the pane keeps
# in the copy after its agent exits (the pane entered the copy with a
# `treehouse get` subshell). Only a recognized shell with no child process that
# is the pane's shell (<pane-pid>) or descends from it qualifies. A build, an
# editor, a test, or a shell running one is not it.
fm_mp_pane_shell() {  # <pid> <pane-pid>
  local pid=$1 pane=${2:-} comm
  [ -n "$pane" ] || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  comm=$(printf '%s' "$comm" | tr -d '[:space:]')
  [ "$(fm_agent_process_classify_name "$comm")" = shell ] || return 1
  ps -axo pid=,ppid= 2>/dev/null | awk -v p="$pid" -v pane="$pane" '
    { parent[$1] = $2; if ($2 == p) child = 1 }
    END {
      if (child) exit 1
      for (n = 0; p > 1 && n < 64; n++) {
        if (p == pane) exit 0
        p = parent[p]
      }
      exit 1
    }'
}

# Copy one preserve-list path with checksums. <dest-dir> receives the tree under
# its copy-relative path plus SHA256SUMS; the copy is verified before returning.
# A path with no regular file has nothing to checksum and nothing to verify.
fm_mp_preserve_one() {  # <real-copy> <relative-path> <dest-dir>
  local copy=$1 rel=$2 dest=$3 file
  mkdir -p "$dest/$(dirname "$rel")" || return 1
  cp -Rp "$copy/$rel" "$dest/$rel" || return 1
  (
    cd "$copy" || exit 1
    while IFS= read -r -d '' file; do
      shasum -a 256 -- "$file" || exit 1
    done < <(find "$rel" -type f -print0 | LC_ALL=C sort -z)
  ) >> "$dest/SHA256SUMS" || return 1
  [ ! -s "$dest/SHA256SUMS" ] || (cd "$dest" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || return 1
}
