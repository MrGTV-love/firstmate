#!/usr/bin/env bash
# fm-merge-prune-lib.sh - the provable-scratch proofs behind bin/fm-merge-prune.sh.
#
# bin/fm-teardown.sh stays the authority. This library is used only when
# teardown refused a merged task's pool copy for a reason that may not be real
# unlanded work (a squash-merged copy that teardown calls not landed, or a
# closeout driver's exact-tree refusal; bin/fm-merge-prune.sh names the only
# refusals that reach it). It follows the criteria of the owner's
# treehouse-reap-clean reaper and proves, read live, that the copy holds nothing
# worth keeping. It never forces, discards or hides anything: any proof it
# cannot make keeps the copy. A read that fails (the ignored-file listing, the
# stash listing, the search for nested copies, the listing of a .claude or .tac
# directory) never counts as finding nothing: it keeps the copy, except that a
# failed stash listing is retried later.
#
# A copy passes only when ALL of these hold, for the task's own copy AND for
# every nested copy found inside it, each checked one by one:
#   - the task's own copy is a Treehouse pool slot of the task's project, by the
#     repo's one test (fm_treehouse_pool_slot in bin/fm-wake-lib.sh, which
#     bin/fm-merge-prune.sh runs before it calls these proofs): the pool's
#     treehouse-state.json sits beside the slot and the slot shares the
#     project's git directory;
#   - git reports no changed or untracked file (every untracked file and every
#     changed submodule counts, whatever status.showUntrackedFiles or
#     diff.ignoreSubmodules says) and the copy holds no stash entry of its own
#     work: for a linked worktree of the project, a stash made on
#     another branch of the project is another task's (a linked worktree shares
#     the project's stash list), while a stash made on the copy's branch, or any
#     stash of a detached copy, counts; a nested copy that is an independent
#     clone (its own git directory) shares nothing, so every stash it holds
#     counts;
#   - no commit reachable from the copy's HEAD, which is its own checked-out
#     branch, is missing from every remote (after a fetch); for a linked
#     worktree, other branches of the project are other work, but for an
#     independent clone every local branch is read too, because removing the
#     clone destroys them. The task's own copy may also rely on the merged pull
#     request's head: a commit that is an ancestor of refs/pull/<n>/head landed;
#   - the task's own copy also holds nothing the merged pull request leaves out
#     (fm_mp_prove_landed): its HEAD is in the pull request's head, or the
#     default branch already carries its content. A commit that is only pushed,
#     such as a follow-up after the merge, is not landed;
#   - every ignored file is scratch (list below), a preserved record, or a
#     symlink; anything else is unique and keeps the copy;
#   - no process has its working directory or an open file inside it, except a
#     system search indexer and the one idle shell of the task's own terminal
#     pane (fm_mp_pane_shell), which is ended with SIGHUP just before the copy is
#     destroyed (fm_mp_end_pane_shell) because treehouse refuses a copy that has
#     a process working inside it.
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
# Requires bin/fm-timeout-lib.sh, bin/fm-backend.sh and bin/fm-task-copy-lib.sh to be
# sourced first.
# Regression coverage: tests/fm-merge-prune.test.sh.

FM_MP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_MP_LIB_DIR/fm-agent-process-lib.sh"
# shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
FM_MP_VERDICT=
# shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
FM_MP_REASON=
# shellcheck disable=SC2034 # Output global, read by bin/fm-merge-prune.sh.
FM_MP_PANE_SHELL=
# shellcheck disable=SC2034 # State between passes of fm_mp_prove_git, set by its fetching mode.
FM_MP_PR_HEAD=
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

fm_mp_real() {  # <path> -> physical path on stdout
  (cd "$1" 2>/dev/null && pwd -P)
}

# Paths of copies nested strictly inside <copy>: any directory below it that
# holds its own .git, other than a tracked submodule. Dependency and
# environment trees are searched too: a clone there holds work like any other.
fm_mp_find_nested() {  # <real-copy>; fills FM_MP_NESTED; 1 when a read failed
  local copy=$1 gitpath dir sub gitlinks found
  FM_MP_NESTED=()
  if ! gitlinks=$(set -o pipefail; git -C "$copy" ls-files -s 2>/dev/null | sed -n 's/^160000 [0-9a-f]* [0-9]\t//p'); then
    fm_mp_verdict keep "cannot list the tracked files of $copy"
    return 1
  fi
  if ! found=$(set -o pipefail; find "$copy" \
    -path "$copy/.git" -prune -o \
    -name .git -prune -print0 2>/dev/null | tr '\0' '\n'); then
    fm_mp_verdict keep "cannot search $copy for nested copies"
    return 1
  fi
  while IFS= read -r gitpath; do
    [ -n "$gitpath" ] || continue
    dir=${gitpath%/.git}
    sub=${dir#"$copy"/}
    if [ -n "$gitlinks" ] && printf '%s\n' "$gitlinks" | grep -Fxq -- "$sub"; then
      continue
    fi
    FM_MP_NESTED+=("$dir")
  done <<EOF
$found
EOF
}

fm_mp_verdict() {  # <ok|keep|transient> <reason>
  # shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
  FM_MP_VERDICT=$1
  # shellcheck disable=SC2034 # Output globals, read by bin/fm-merge-prune.sh.
  FM_MP_REASON=$2
}

# The stash entries made on this copy's work, counted on stdout. Git names the
# branch a stash was made on in its message ("WIP on <branch>: ..." or "On
# <branch>: ..."), and a linked worktree shares its stash list with the project,
# so in the own scope a stash that names another branch is not this copy's. A
# detached copy, a stash made with no branch, and a message that names no branch
# all count. In the all scope (an independent clone, which shares nothing with
# the project) every entry counts. Returns 1 when git cannot list the stash
# entries.
fm_mp_own_stashes() {  # <real-copy> [<own|all>]
  local copy=$1 scope=${2:-all} branch subject name n=0 listing
  branch=$(git -C "$copy" symbolic-ref -q --short HEAD 2>/dev/null) || branch=
  listing=$(git -C "$copy" stash list --format=%gs 2>/dev/null) || return 1
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    if [ "$scope" = all ]; then n=$((n + 1)); continue; fi
    name=
    case "$subject" in
      "WIP on "*) name=${subject#"WIP on "} ;;
      "On "*) name=${subject#"On "} ;;
    esac
    name=${name%%:*}
    if [ -z "$branch" ] || [ -z "$name" ] || [ "$name" = "(no branch)" ] || [ "$name" = "$branch" ]; then
      n=$((n + 1))
    fi
  done <<EOF
$listing
EOF
  printf '%s' "$n"
}

# Status, stash and unpushed-commit proofs for one copy.
# <pr-number> is empty for a nested copy; the task's own copy passes it so a
# squash-merged pull request's head counts as the remote proof. The default mode
# fetches the remotes (and the pull request's head) first and leaves that head in
# FM_MP_PR_HEAD. The nofetch mode makes no network call: it reuses the remote
# refs and the pull request head that an earlier fetching pass left, so a pass
# made while the project lock is held can never wait on a hung remote. The own
# scope reads only this copy's work (its HEAD and its own branch's stashes) and
# is for a linked worktree of the project; the all scope, the default, also
# reads every local branch and every stash, and is for an independent clone.
fm_mp_prove_git() {  # <real-copy> [<pr-number>] [nofetch] [<own|all>]
  local copy=$1 prn=${2:-} mode=${3:-fetch} scope=${4:-all} top dirty stashes unpushed prsha='' extra=() refs=(HEAD)
  if ! top=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) || [ "$(fm_mp_real "$top")" != "$copy" ]; then
    fm_mp_verdict keep "$copy is not a git work tree root"
    return 1
  fi
  if ! dirty=$(git -C "$copy" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null); then
    fm_mp_verdict transient "git status failed in $copy"
    return 1
  fi
  if [ -n "$dirty" ]; then
    fm_mp_verdict keep "$copy has changed or untracked files ($(printf '%s\n' "$dirty" | wc -l | tr -d ' ') entries, first: $(printf '%s\n' "$dirty" | sed -n 1p))"
    return 1
  fi
  if ! stashes=$(fm_mp_own_stashes "$copy" "$scope"); then
    fm_mp_verdict transient "git stash list failed in $copy"
    return 1
  fi
  if [ "$stashes" != 0 ]; then
    fm_mp_verdict keep "$copy holds $stashes stash entries of its own work"
    return 1
  fi
  if [ "$mode" = nofetch ]; then
    [ -z "$prn" ] || prsha=$FM_MP_PR_HEAD
  else
    fm_run_timed "$(fm_mp_limit merge-prune.fetch 120)" git -C "$copy" fetch -q --all </dev/null >/dev/null 2>&1 || true
    if [ -n "$prn" ]; then
      FM_MP_PR_HEAD=
      if fm_run_timed "$(fm_mp_limit merge-prune.fetch 120)" git -C "$copy" fetch -q origin "refs/pull/$prn/head" </dev/null >/dev/null 2>&1; then
        prsha=$(git -C "$copy" rev-parse -q --verify FETCH_HEAD 2>/dev/null) || prsha=
        FM_MP_PR_HEAD=$prsha
      fi
    fi
  fi
  [ -z "$prsha" ] || extra=("$prsha")
  [ "$scope" != all ] || refs+=(--branches)
  if ! unpushed=$(git -C "$copy" rev-list --count "${refs[@]}" --not --remotes ${extra[@]+"${extra[@]}"} 2>/dev/null); then
    fm_mp_verdict keep "cannot compare $copy with its remotes"
    return 1
  fi
  if [ "$unpushed" != 0 ]; then
    fm_mp_verdict keep "$copy has $unpushed commit(s) on no remote"
    return 1
  fi
  [ -z "$prn" ] || fm_mp_prove_landed "$copy" "$prsha" || return 1
  return 0
}

# The task's own copy must also hold nothing the merged pull request leaves out.
# Work that is only pushed, such as a follow-up commit after the merge, is not
# landed. It must be proved here, before anything is stopped: the pane's idle
# `treehouse get` subshell returns the slot to the pool when it ends, which
# resets the slot and so hides that commit from `treehouse destroy`. The copy's
# HEAD must be in the merged pull request's head, or the default branch, as
# fetched (no network call is made here), must already carry its content, which
# is what a squash merge leaves. A read that fails proves nothing and keeps the copy.
fm_mp_prove_landed() {  # <real-copy> <merged-pr-head-or-empty>
  local copy=$1 prsha=${2:-} head name tree merged
  if ! head=$(git -C "$copy" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null); then
    fm_mp_verdict keep "cannot read the HEAD of $copy"
    return 1
  fi
  if [ -n "$prsha" ] && git -C "$copy" merge-base --is-ancestor "$head" "$prsha" 2>/dev/null; then
    return 0
  fi
  if name=$(fm_task_copy_default_branch "$copy") \
    && tree=$(git -C "$copy" rev-parse -q --verify "refs/remotes/origin/$name^{tree}" 2>/dev/null) \
    && merged=$(git -C "$copy" merge-tree --write-tree "refs/remotes/origin/$name" "$head" 2>/dev/null) \
    && [ "${merged%%$'\n'*}" = "$tree" ]; then
    return 0
  fi
  fm_mp_verdict keep "$copy has commits that are not in the merged pull request: its HEAD ${head:0:12} is not in the pull request's head and the default branch does not carry its content"
  return 1
}

# Classify every ignored entry of one copy. Fills FM_MP_PRESERVE with the
# copy-relative preserve-list paths; keeps the copy on the first unique entry.
fm_mp_prove_ignored() {  # <real-copy>
  local copy=$1 entry rel listing
  FM_MP_PRESERVE=()
  if ! listing=$(set -o pipefail; git -C "$copy" ls-files -o -i --exclude-standard --directory -z 2>/dev/null | tr '\0' '\n'); then
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
  local copy=$1 rel=$2 name child n children
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
    .claude|.opencode|.claude/worktrees|.opencode/plugins|.tac)
      if [ -d "$copy/$rel" ]; then
        if ! children=$(ls -A "$copy/$rel" 2>/dev/null); then
          fm_mp_verdict keep "cannot list $rel in $copy"
          return 1
        fi
        while IFS= read -r child; do
          [ -n "$child" ] || continue
          fm_mp_classify_entry "$copy" "$rel/$child" || return 1
        done <<EOF
$children
EOF
        return 0
      fi
      ;;
    .tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) return 0 ;;
    # Firstmate's own hook files, and a clone under .claude/worktrees, which the
    # search for nested copies proves on its own.
    .claude/settings.local.json|.opencode/plugins/fm-busy-state.js) return 0 ;;
    .claude/worktrees/*)
      if [ -e "$copy/$rel/.git" ]; then
        return 0
      fi
      ;;
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
# The one idle pane shell that passes is left in FM_MP_PANE_SHELL for the caller
# to end; a second one keeps the copy.
fm_mp_prove_unused() {  # <real-copy> [<pane-pid>]
  local copy=$1 pane=${2:-} out rc=0 kept pid errfile err
  FM_MP_PANE_SHELL=
  if ! command -v lsof >/dev/null 2>&1; then
    fm_mp_verdict keep "cannot prove no process uses $copy: lsof is not installed"
    return 1
  fi
  if ! errfile=$(mktemp "${TMPDIR:-/tmp}/fm-mp-lsof.XXXXXX" 2>/dev/null); then
    fm_mp_verdict transient "process check of $copy could not record its messages"
    return 1
  fi
  out=$(fm_run_timed "$(fm_mp_limit merge-prune.lsof 90)" lsof +D "$copy" -t 2>"$errfile" </dev/null) || rc=$?
  err=$(sed -n 1p "$errfile" 2>/dev/null | tr -d '\r' | cut -c1-120)
  rm -f "$errfile"
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    fm_mp_verdict transient "process check of $copy timed out"
    return 1
  fi
  # lsof exits 1 with no output and no message when nothing is open (it also
  # does so when something is, so the exit status alone proves nothing). An
  # error exit or a message with no pid listed is a probe that failed, which
  # cannot show that no process holds the copy.
  if [ -z "$out" ] && { [ "$rc" -gt 1 ] || [ -n "$err" ]; }; then
    fm_mp_verdict transient "process check of $copy failed (exit $rc${err:+: $err})"
    return 1
  fi
  out=$(printf '%s\n' "$out" | sort -u | tr '\n' ' ')
  out=${out% }
  kept=
  for pid in $out; do
    if fm_mp_indexer_pid "$pid"; then
      :
    elif [ -z "$FM_MP_PANE_SHELL" ] && fm_mp_pane_shell "$pid" "$pane" "$copy"; then
      FM_MP_PANE_SHELL=$pid
    else
      kept="${kept:+$kept }$pid"
    fi
  done
  if [ -n "$kept" ]; then
    FM_MP_PANE_SHELL=
    fm_mp_verdict keep "process(es) inside $copy: $kept"
    return 1
  fi
  return 0
}

# A system search indexer (macOS Spotlight) holds a recently written tree open
# for as long as a minute while it reads it. It only reads, deleting the tree
# under it harms nothing, and counting it would keep nearly every fresh copy on a
# Mac. It and the task's own pane shell (fm_mp_pane_shell, which is ended before
# the destroy) are the deliberate exceptions to "no process inside" (named in
# docs/configuration.md); any other process, whatever it does, keeps the copy.
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
      pid=$(fm_run_timed "$(fm_mp_limit merge-prune.pane-pid 15)" tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null </dev/null) || pid=
      ;;
    herdr)
      # shellcheck disable=SC2016 # The single-quoted bash -c program expands its own positional arguments.
      out=$(fm_run_timed "$(fm_mp_limit merge-prune.pane-process-info 30)" bash -c '. "$1/fm-backend.sh" && fm_backend_source herdr && fm_backend_herdr_cli "$2" pane process-info --pane "$3"' \
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
# `treehouse get` subshell). Only a recognized shell whose working directory is
# inside <real-copy>, with no child process, that is a strict descendant of the
# pane's shell (<pane-pid>) qualifies. The pane's own shell never does, because
# ending it would close the pane. A build, an editor, a test, or a shell running
# one is not it.
fm_mp_pane_shell() {  # <pid> <pane-pid> <real-copy>
  local pid=$1 pane=${2:-} copy=$3 comm cwd
  [ -n "$pane" ] || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  comm=$(printf '%s' "$comm" | tr -d '[:space:]')
  [ "$(fm_agent_process_classify_name "$comm")" = shell ] || return 1
  cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null </dev/null | sed -n 's/^n//p' | sed -n 1p)
  case "$cwd" in "$copy"|"$copy"/*) ;; *) return 1 ;; esac
  ps -axo pid=,ppid= 2>/dev/null | awk -v p="$pid" -v pane="$pane" '
    { parent[$1] = $2; if ($2 == p) child = 1 }
    END {
      if (child) exit 1
      p = parent[p]
      for (n = 0; p > 1 && n < 64; n++) {
        if (p == pane) exit 0
        p = parent[p]
      }
      exit 1
    }'
}

# End the pane's idle shell with SIGHUP, the way closing its terminal would, and
# wait up to <seconds> for it to go. It is proved again right before the signal;
# a process that is not that shell any more, or a shell that does not go, returns
# 1 and nothing stronger than SIGHUP is ever sent. The pane itself stays open on
# its outer shell. The caller has stopped the agent first.
fm_mp_end_pane_shell() {  # <pid> <pane-pid> <real-copy> <seconds>
  local pid=$1 waited=0
  kill -0 "$pid" 2>/dev/null || return 0
  fm_mp_pane_shell "$1" "$2" "$3" || return 1
  kill -HUP "$pid" 2>/dev/null || return 1
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -lt "$4" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
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
