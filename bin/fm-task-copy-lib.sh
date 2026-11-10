#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_TASK_COPY_* are output globals for sourcing callers.
# Which local copy a task record may name.
#
# A task record's worktree= names the local copy its work lives in. Four
# callers must agree on what may be named there, so the rules live here once:
#   - bin/fm-spawn.sh admits only an isolated worktree of the project as a new
#     task's copy (fm_task_copy_isolated);
#   - bin/fm-teardown.sh refuses to return a pool slot that another task record
#     still names (fm_task_copy_other_record);
#   - bin/fm-spawn.sh and bin/fm-home-seed.sh refuse a Treehouse allocation
#     while a pool slot that Treehouse's state does not durably hold contains a
#     task record's current copy (fm_task_copy_pool_slots_hold_no_current_copy);
#   - bin/fm-control.sh reassociate re-points a record at a replacement copy only
#     when both hold for that copy and it shares the project's repository
#     (fm_task_copy_same_repository).
# A record's prior_worktree= lines name copies the task worked in before a
# reassociation that stay its preserved custody, so the record scan counts them
# exactly like worktree= and home=. A pool slot the task left entirely is
# released to the pool instead (its HEAD is anchored), so it is never one.
#
# Requires bin/fm-backend.sh (fm_meta_get), bin/fm-secondmate-parent-lib.sh
# (fm_firstmate_root_home), and bin/fm-wake-lib.sh to be sourced first;
# sources bin/fm-secondmate-registry-lib.sh itself when the caller has not.

FM_TASK_COPY_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
if ! declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$FM_TASK_COPY_LIB_DIR/fm-secondmate-registry-lib.sh"
fi

# Process observations are tri-state: 0 live, 1 absent, 2 unreadable. A confined
# worker cannot execute setuid ps (126); reuse the test reaper's sysctl helper.
# Only a complete, readable PID table proves absence there. No age or ancestry
# exception releases a lock naming a live PID, including a recycled PID.
fm_task_copy_confined_launcher_state() {  # <pid>
  local pid=$1 table observed found=1
  table=$(python3 "$FM_TASK_COPY_LIB_DIR/fm-proc-info.py" table pid 2>/dev/null) || return 2
  [ -n "$table" ] || return 2
  while IFS= read -r observed; do
    case "$observed" in ''|*[!0-9]*) return 2 ;; esac
    [ "$observed" != "$pid" ] || found=0
  done <<< "$table"
  return "$found"
}

# Interpret one completed ps observation without executing a process probe.
# Exit 1 proves absence only with empty stdout and either empty stderr or exactly
# macOS's not-found line for this PID; any other diagnostic makes that failed read
# unknown. The acquisition owner handles exit 126.
fm_task_copy_ps_observation_state() {  # <pid> <status> <stdout> <stderr>
  local pid=$1 rc=$2 observed=$3 diagnostic=$4
  case "$rc" in
    0)
      observed=${observed//[[:space:]]/}
      [ "$observed" = "$pid" ] || return 2
      return 0
      ;;
    1)
      [ -z "$observed" ] || return 2
      [ -z "$diagnostic" ] || [ "$diagnostic" = "ps: process id too large: $pid"$'\n' ] || return 2
      return 1
      ;;
    *) return 2 ;;
  esac
}

fm_task_copy_launcher_state() {  # <pid>
  local pid=$1 observed diagnostic diagnostic_file rc=0
  diagnostic_file=$(mktemp "${TMPDIR:-/tmp}/fm-copy-ps.XXXXXX") || return 2
  observed=$(ps -p "$pid" -o pid= 2>"$diagnostic_file") || rc=$?
  if [ "$rc" = 126 ]; then
    rm -f -- "$diagnostic_file"
    fm_task_copy_confined_launcher_state "$pid"
    return $?
  fi
  # Retain even a whitespace-only diagnostic; failed reads are not absence.
  diagnostic=$(cat "$diagnostic_file" && printf '.') || {
    rm -f -- "$diagnostic_file"
    return 2
  }
  diagnostic=${diagnostic%.}
  rm -f -- "$diagnostic_file"
  fm_task_copy_ps_observation_state "$pid" "$rc" "$observed" "$diagnostic"
}

# The physical path of an existing directory, or a failure.
fm_task_copy_canonical_dir() {  # <path>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

fm_task_copy_paths_overlap() {  # <canonical-a> <canonical-b>
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"/*) return 0 ;; esac
  case "$b" in "$a"/*) return 0 ;; esac
  [ "$a" = / ] || [ "$b" = / ]
}

fm_task_copy_default_branch() {
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$project" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# A failed content check is no verdict on the work while FM_TASK_COPY_UNASKED
# names why: it is cleared only once the check compared the two trees, and a
# merge conflict is that comparison's answer. With no-fetch the same rule reads
# the refs already here: merge-tree adds objects only, and no ref or worktree moves.
FM_TASK_COPY_UNASKED=
fm_task_copy_content_in_default() {  # <worktree> <project> [<default-branch>] [<head-ref>] [no-fetch] [<anchor>]
  local worktree=$1 project=$2 name=${3:-} head=${4:-HEAD} fetch=${5:-} anchor=${6:-} ref default_tree merged_tree
  FM_TASK_COPY_UNASKED='the content check could not compare with the default branch'
  [ -d "$worktree" ] || return 1
  [ -n "$name" ] || name=$(fm_task_copy_default_branch "$project") || return 1
  if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
    [ "$fetch" = no-fetch ] || git -C "$worktree" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || {
      FM_TASK_COPY_UNASKED="origin/$name could not be fetched"
      return 1
    }
    ref="refs/remotes/origin/$name"
  elif git -C "$worktree" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$worktree" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$worktree" merge-tree --write-tree "$ref" "$head" 2>/dev/null) || {
    [ "$?" != 1 ] || FM_TASK_COPY_UNASKED=
    return 1
  }
  FM_TASK_COPY_UNASKED=
  merged_tree=${merged_tree%%$'\n'*}
  [ "$merged_tree" = "$default_tree" ] || return 1
  # The merge above takes the merge base of the two as the copy's own base, and a merge
  # that dropped a side's change (an `ours` merge, or either parent order) can make a
  # commit of the copy the base without its change. The change is measured again from a
  # base that is not computed from the graph where one is recorded.
  fm_task_copy_default_holds_change "$worktree" "$head" "$ref" "$anchor"
}

# Is the change a copy holds delivered to the default branch? Reachability is not delivery:
# a merge can make a commit reachable without its change (an `ours` merge, or a merge whose
# tree is one side's, whichever parent comes first). The copy's own change is measured from a
# base, and a base that comes from parent pointers can be faked by exactly such a merge. So the
# base is taken from a RECORD whenever one exists: the member PR's base oid, which the forge
# attests (gh pr view --json baseRefOid), passed in by the caller as <anchor>. Without a recorded
# PR no anchor exists, and the base is the newest commit of the default branch's first-parent
# line that the copy holds, a position that refuses the conventional `ours` merge but cannot
# refuse a crafted parent-order merge (a known limit). A git read that
# fails or ends early is never an answer: every helper below keeps a git read's output in a
# file, checks the read's status, and reports "unread" (FM_TASK_COPY_UNASKED set) before it
# ever reports "not present".
FM_TASK_COPY_WHY=
FM_TASK_COPY_BASE=
FM_TASK_COPY_LANDING=

# fm_task_copy_read <dir> <out> <git args...>: run a git read with its output in <out>,
# returning git's own status, so a caller never takes the output of a failed read for an answer.
fm_task_copy_read() {
  local dir=$1 out=$2
  shift 2
  git -C "$dir" "$@" > "$out" 2>/dev/null
}

# Is <a> an ancestor of <b>? 0 yes, 1 no, 2 the answer could not be read.
fm_task_copy_ancestor() {  # <dir> <a> <b>
  local rc=0
  git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null || rc=$?
  case "$rc" in 0 | 1) return "$rc" ;; *) return 2 ;; esac
}

# Is the net change <base> to <ref> present in <target>'s final tree? 0 when every path the
# change touches holds the same content there, or the reverse of the change applies cleanly
# to that tree (which also covers a target that built further on the same paths). 1 when it
# is not present. 2 when the net change is empty: nothing to lose, which a caller decides for
# itself. 3 when a read failed or ended early. History alone is not enough: a commit can be
# reachable, or its patch replayed, and then reverted before it lands.
fm_task_copy_net_change_present() {  # <dir> <ref> <target> <base>
  local scratch rc
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-copy.XXXXXX") || return 3
  fm_task_copy_net_change_present_in "$scratch" "$@"
  rc=$?
  rm -rf "$scratch"
  return "$rc"
}

fm_task_copy_net_change_present_in() {  # <scratch> <dir> <ref> <target> <base>
  local scratch=$1 dir=$2 ref=$3 target=$4 base=$5 path hdr om nm rest rc=0 i entry
  local -a paths=() newmodes=() oldmodes=()
  fm_task_copy_read "$dir" "$scratch/raw" diff --raw -z --no-renames --no-abbrev "$base" "$ref" -- || return 3
  [ -s "$scratch/raw" ] || return 2
  while IFS= read -r -d '' hdr; do
    IFS= read -r -d '' path || return 3
    hdr=${hdr#:}
    read -r om nm rest <<< "$hdr"
    paths+=("$path")
    oldmodes+=("$om")
    newmodes+=("$nm")
  done < "$scratch/raw"
  [ "${#paths[@]}" -gt 0 ] || return 3
  GIT_LITERAL_PATHSPECS=1 git -C "$dir" diff --quiet --no-renames "$ref" "$target" -- "${paths[@]}" 2>/dev/null || rc=$?
  case "$rc" in 0) return 0 ;; 1) ;; *) return 3 ;; esac
  # git apply only warns when a file's mode or type is not what the patch expects, so the
  # entry type and mode of every path whose mode the change set are compared first.
  for ((i = 0; i < ${#paths[@]}; i++)); do
    [ "${oldmodes[$i]}" != "${newmodes[$i]}" ] || continue
    [ "${newmodes[$i]}" != 000000 ] || continue
    GIT_LITERAL_PATHSPECS=1 git -C "$dir" ls-tree -z "$target" -- "${paths[$i]}" > "$scratch/entry" 2>/dev/null || return 3
    entry=
    IFS= read -r -d '' entry < "$scratch/entry" || :
    [ "${entry%% *}" = "${newmodes[$i]}" ] || return 1
  done
  GIT_INDEX_FILE=$scratch/index git -C "$dir" read-tree "$target" 2>/dev/null || return 3
  fm_task_copy_read "$dir" "$scratch/patch" diff --binary --full-index --no-renames "$base" "$ref" -- || return 3
  [ -s "$scratch/patch" ] || return 3
  rc=0
  GIT_INDEX_FILE=$scratch/index git -C "$dir" apply --cached -R --check < "$scratch/patch" 2>/dev/null || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 3 ;; esac
}

# Is every merge between <base> and <tip> EXACTLY what git itself makes of its two parents?
# A merge that dropped a side's change (an `ours` merge, a merge that took one side's tree
# whichever parent comes first, or a conflict resolved to either side or to a third version)
# makes the commits it merged reachable without their content, so a copy that stands on such a
# commit cannot be measured from it. The rule has no escape: a merge counts only when
# `git merge-tree --write-tree p1 p2` is clean and its tree IS the merge's tree; a conflict, an
# octopus merge or any other tree refuses. Ancestry is never read as content. 0 when every merge
# is exact (or there is none). 1 with the fact in FM_TASK_COPY_WHY. 2 when a read failed, with
# the fact in FM_TASK_COPY_UNASKED. No count limit: a long path is slow, not refused.
fm_task_copy_merges_exact() {  # <dir> <base> <tip>
  local scratch rc
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-copy.XXXXXX") || {
    FM_TASK_COPY_UNASKED='a scratch directory for the merge check could not be made'
    return 2
  }
  fm_task_copy_merges_exact_in "$scratch" "$@"
  rc=$?
  rm -rf "$scratch"
  return "$rc"
}

fm_task_copy_merges_exact_in() {  # <scratch> <dir> <base> <tip>
  local scratch=$1 dir=$2 base=$3 tip=$4 commit p1 p2 rest merged merge_rc tree
  FM_TASK_COPY_WHY=
  fm_task_copy_read "$dir" "$scratch/merges" rev-list --merges --ancestry-path --parents "$base..$tip" -- || {
    FM_TASK_COPY_UNASKED="the merges between ${base:0:12} and ${tip:0:12} could not be listed"
    return 2
  }
  [ -s "$scratch/merges" ] || return 0
  while IFS=' ' read -r commit p1 p2 rest; do
    [ -n "$commit" ] || continue
    if [ -z "$p2" ] || [ -n "$rest" ]; then
      FM_TASK_COPY_WHY="the merge ${commit:0:12} is an octopus merge (or has no second parent), which is not read"
      return 1
    fi
    merge_rc=0
    merged=$(git -C "$dir" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) || merge_rc=$?
    case "$merge_rc" in
      0) ;;
      1)
        FM_TASK_COPY_WHY="the merge ${commit:0:12} resolved a conflict, so a side's change may have been dropped"
        return 1
        ;;
      *)
        FM_TASK_COPY_UNASKED="git could not merge the parents of ${commit:0:12}"
        return 2
        ;;
    esac
    tree=$(git -C "$dir" rev-parse --verify --quiet "$commit^{tree}" 2>/dev/null) || {
      FM_TASK_COPY_UNASKED="the tree of ${commit:0:12} could not be read"
      return 2
    }
    if [ "${merged%%$'\n'*}" != "$tree" ]; then
      FM_TASK_COPY_WHY="the merge ${commit:0:12} is not what git makes of its parents (a side's change was dropped, or the merge added an edit of its own)"
      return 1
    fi
  done < "$scratch/merges"
  return 0
}

# The fork point of <ref> against a recorded base that <ref> may not contain. The forge records
# a PR's base as the base branch's tip, which can be ahead of where the branch forked, and a
# pre-rebase copy never held the recorded base at all. The fork point is the single merge base
# X of the two, and X is trusted only after every merge between X and the recorded base is
# shown exact (fm_task_copy_merges_exact): a merge that dropped a side's change would make X a
# commit the default branch reached without its content. A <ref> that contains the recorded
# base forks there. Sets FM_TASK_COPY_BASE. 0 with it set. 1 with the refusal in
# FM_TASK_COPY_WHY (no common history, more than one merge base, an inexact merge). 2 with the
# unread fact in FM_TASK_COPY_UNASKED.
fm_task_copy_fork_base() {  # <dir> <ref> <recorded-base>
  local dir=$1 ref=$2 recorded=$3 rc=0 bases
  FM_TASK_COPY_BASE=
  FM_TASK_COPY_WHY=
  fm_task_copy_ancestor "$dir" "$recorded" "$ref" || rc=$?
  case "$rc" in
    0)
      FM_TASK_COPY_BASE=$recorded
      return 0
      ;;
    1) ;;
    *)
      FM_TASK_COPY_UNASKED="whether ${ref:0:12} contains the recorded base ${recorded:0:12} could not be read"
      return 2
      ;;
  esac
  rc=0
  bases=$(git -C "$dir" merge-base --all "$recorded" "$ref" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    1)
      FM_TASK_COPY_WHY="has no common history with the member PR's recorded base, so its own work has no base to be measured from"
      return 1
      ;;
    *)
      FM_TASK_COPY_UNASKED="the merge base of ${ref:0:12} and the member PR's recorded base could not be read"
      return 2
      ;;
  esac
  case "$bases" in
    *$'\n'*)
      FM_TASK_COPY_WHY="has more than one merge base with the member PR's recorded base, so its own work has no single base to be measured from"
      return 1
      ;;
  esac
  rc=0
  fm_task_copy_merges_exact "$dir" "$bases" "$recorded" || rc=$?
  case "$rc" in
    0) ;;
    1)
      FM_TASK_COPY_WHY="stands on a commit that the default branch reached through a merge that is not what git makes of its parents ($FM_TASK_COPY_WHY), so its own work cannot be measured from there"
      return 1
      ;;
    *) return 2 ;;
  esac
  FM_TASK_COPY_BASE=$bases
}

# Is <ref>'s own change, measured from a recorded base, present in <target>'s final tree
# (fm_task_copy_net_change_present)? The change is measured from the recorded base itself
# first. When that is not present and <ref> does not contain the recorded base, that diff also
# held the reverse of the base branch's own commits past the fork point, so the change is
# measured again from the fork point (fm_task_copy_fork_base). With fork-only the recorded
# base is never the measure unless <ref> contains it. 0 present. 1 not present, with a fork
# point's refusal in FM_TASK_COPY_WHY. 2 the measured change is empty. 3 a read failed, with
# the fact in FM_TASK_COPY_UNASKED when the fork point could not be read.
fm_task_copy_recorded_change_present() {  # <dir> <ref> <target> <recorded-base> [fork-only]
  local rc=0
  FM_TASK_COPY_UNASKED=
  FM_TASK_COPY_WHY=
  if [ "${5:-}" != fork-only ]; then
    fm_task_copy_net_change_present "$1" "$2" "$3" "$4" || rc=$?
    [ "$rc" = 1 ] || return "$rc"
    rc=0
  fi
  fm_task_copy_fork_base "$1" "$2" "$4" || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) return 3 ;;
  esac
  [ "${5:-}" = fork-only ] || [ "$FM_TASK_COPY_BASE" != "$4" ] || return 1
  fm_task_copy_net_change_present "$1" "$2" "$3" "$FM_TASK_COPY_BASE"
}

# The first-parent line of <default-ref>, newest first, one commit per line in <out>.
fm_task_copy_line() {  # <dir> <default-ref> <out>
  fm_task_copy_read "$1" "$3" rev-list --first-parent "$2" -- && [ -s "$3" ]
}

# The base of <ref>'s own change: the newest commit on <default-ref>'s FIRST-PARENT line that
# <ref> holds. The line is what was directly integrated into the default branch (a squash, a
# fast-forward, or the first parent of a merge). A commit that reached the default branch only
# as the second parent of a merge is not on it, so an `ours` merge cannot move the base past
# that commit. The base is a position, not content: a merge can put a commit on the line
# without its change, so the base only chooses the change to measure, and
# fm_task_copy_content_delivered must hold as well. Holding a commit is monotone along the
# line, so the search is a binary search. Sets FM_TASK_COPY_BASE. 0 with the base set. 1 with
# the refusal in FM_TASK_COPY_WHY (the copy holds no commit of the line). 2 with the unread
# fact in FM_TASK_COPY_UNASKED.
fm_task_copy_first_parent_base() {  # <dir> <ref> <default-ref>
  local dir=$1 ref default_ref=$3 scratch line n=0 lo hi mid rc=0
  local -a line_commits=()
  FM_TASK_COPY_BASE=
  FM_TASK_COPY_WHY=
  FM_TASK_COPY_UNASKED=
  ref=$(git -C "$dir" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || {
    FM_TASK_COPY_UNASKED="$2 could not be read"
    return 2
  }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-copy.XXXXXX") || {
    FM_TASK_COPY_UNASKED='a scratch directory for the base search could not be made'
    return 2
  }
  if ! fm_task_copy_line "$dir" "$default_ref" "$scratch/line"; then
    rm -rf "$scratch"
    FM_TASK_COPY_UNASKED="the first-parent line of $default_ref could not be read"
    return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line_commits[n]=$line
    n=$((n + 1))
  done < "$scratch/line"
  rm -rf "$scratch"
  fm_task_copy_ancestor "$dir" "${line_commits[$((n - 1))]}" "$ref" || rc=$?
  case "$rc" in
    0) ;;
    1)
      FM_TASK_COPY_WHY="the copy holds no commit of the default branch's first-parent line"
      return 1
      ;;
    *)
      FM_TASK_COPY_UNASKED="whether the copy holds the root of $default_ref could not be read"
      return 2
      ;;
  esac
  lo=0
  hi=$((n - 1))
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2))
    rc=0
    fm_task_copy_ancestor "$dir" "${line_commits[$mid]}" "$ref" || rc=$?
    case "$rc" in
      0) hi=$mid ;;
      1) lo=$((mid + 1)) ;;
      *)
        FM_TASK_COPY_UNASKED="whether the copy holds ${line_commits[$mid]:0:12} could not be read"
        return 2
        ;;
    esac
  done
  FM_TASK_COPY_BASE=${line_commits[$lo]}
}

# The OLDEST commit on <default-ref>'s first-parent line that holds <ref>: the commit that
# integrated it. A commit reachable only through a second parent is held by the merge that
# took that parent in, so that merge is where its change must be read. Sets
# FM_TASK_COPY_LANDING. 0 with it set. 1 when <ref> is not reachable from the line. 2 when a
# read failed.
fm_task_copy_first_parent_landing() {  # <dir> <ref> <default-ref>
  local dir=$1 ref default_ref=$3 scratch line n=0 lo hi mid rc=0
  local -a line_commits=()
  FM_TASK_COPY_LANDING=
  ref=$(git -C "$dir" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || {
    FM_TASK_COPY_UNASKED="$2 could not be read"
    return 2
  }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-copy.XXXXXX") || {
    FM_TASK_COPY_UNASKED='a scratch directory for the landing search could not be made'
    return 2
  }
  if ! fm_task_copy_line "$dir" "$default_ref" "$scratch/line"; then
    rm -rf "$scratch"
    FM_TASK_COPY_UNASKED="the first-parent line of $default_ref could not be read"
    return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line_commits[n]=$line
    n=$((n + 1))
  done < "$scratch/line"
  rm -rf "$scratch"
  fm_task_copy_ancestor "$dir" "$ref" "${line_commits[0]}" || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *)
      FM_TASK_COPY_UNASKED="whether the copy is reachable from $default_ref could not be read"
      return 2
      ;;
  esac
  lo=0
  hi=$((n - 1))
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi + 1) / 2))
    rc=0
    fm_task_copy_ancestor "$dir" "$ref" "${line_commits[$mid]}" || rc=$?
    case "$rc" in
      0) lo=$mid ;;
      1) hi=$((mid - 1)) ;;
      *)
        FM_TASK_COPY_UNASKED="whether the copy is reachable from ${line_commits[$mid]:0:12} could not be read"
        return 2
        ;;
    esac
  done
  FM_TASK_COPY_LANDING=${line_commits[$lo]}
}

# Does <default-ref> really hold <ref>'s own work? With an <anchor> (the member PR's base oid
# from the forge) the answer is one test: the net change anchor to <ref> must be present in the
# default branch's tree (fm_task_copy_net_change_present: every changed path equal there, or the
# reverse of the change applies cleanly, which covers a later edit of other lines, and checks
# type and mode). A <ref> that does not contain the anchor (the forge's base is ahead of the
# fork point) is measured from its fork point once the merges up to the anchor are shown exact
# (fm_task_copy_recorded_change_present). No other graph position is trusted. A
# copy that leaves no net change has nothing to lose. Without an anchor, the position-based proof
# runs: measured from the first-parent base, a copy on the first-parent line itself has nothing
# to measure; a copy reachable only through a merge is held by the commit that took it in
# (fm_task_copy_first_parent_landing), whose own tree must hold the net change; a copy not
# reachable at all (squashed or rebased in) must merge into <default-ref> from that base with no
# change of the default tree. Any failure to read is no answer: it leaves FM_TASK_COPY_UNASKED set.
fm_task_copy_default_holds_change() {  # <dir> <ref> <default-ref> [<anchor>]
  local dir=$1 ref=$2 default_ref=$3 anchor=${4:-} base rc=0 default_tree merged merge_rc=0
  FM_TASK_COPY_UNASKED=
  ref=$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || {
    FM_TASK_COPY_UNASKED="$2 could not be read"
    return 1
  }
  if [ -n "$anchor" ]; then
    git -C "$dir" cat-file -e "$anchor^{commit}" 2>/dev/null || {
      FM_TASK_COPY_UNASKED="the recorded base ${anchor:0:12} of the member PR is not in this clone"
      return 1
    }
    fm_task_copy_recorded_change_present "$dir" "$ref" "$default_ref" "$anchor" || rc=$?
    case "$rc" in
      0 | 2) return 0 ;;
      1) return 1 ;;
      *)
        [ -n "$FM_TASK_COPY_UNASKED" ] || FM_TASK_COPY_UNASKED='the net change of the copy could not be read against the default branch'
        return 1
        ;;
    esac
  fi
  fm_task_copy_first_parent_base "$dir" "$ref" "$default_ref" || return 1
  base=$FM_TASK_COPY_BASE
  [ "$base" != "$ref" ] || return 0
  fm_task_copy_ancestor "$dir" "$ref" "$default_ref" || rc=$?
  case "$rc" in
    0)
      fm_task_copy_first_parent_landing "$dir" "$ref" "$default_ref" || {
        [ "$?" != 2 ] || return 1
        FM_TASK_COPY_UNASKED='the commit that took the copy in could not be found'
        return 1
      }
      rc=0
      fm_task_copy_net_change_present "$dir" "$ref" "$FM_TASK_COPY_LANDING" "$base" || rc=$?
      case "$rc" in
        0 | 2) return 0 ;;
        1) return 1 ;;
        *)
          FM_TASK_COPY_UNASKED='the net change of the copy could not be read against the commit that took it in'
          return 1
          ;;
      esac
      ;;
    1) ;;
    *)
      FM_TASK_COPY_UNASKED='the copy could not be placed against the default branch'
      return 1
      ;;
  esac
  default_tree=$(git -C "$dir" rev-parse --quiet --verify "$default_ref^{tree}" 2>/dev/null) || {
    FM_TASK_COPY_UNASKED='the default branch tree could not be read'
    return 1
  }
  merged=$(git -C "$dir" merge-tree --write-tree --merge-base="$base" "$default_ref" "$ref" 2>/dev/null) || merge_rc=$?
  if [ "$merge_rc" -gt 1 ]; then
    FM_TASK_COPY_UNASKED='the content check could not merge the copy from its base'
    return 1
  fi
  [ "$merge_rc" = 0 ] && [ "${merged%%$'\n'*}" = "$default_tree" ]
}

# The porcelain status lines of <copy> that are its own uncommitted work:
# Firstmate's hook files do not count, and neither does the untracked entry of
# each of the task's own <nested-copy> paths inside <copy>, since each of those
# is preserved or proved on its own.
fm_task_copy_dirty_status() {  # <porcelain-status> [<copy> <nested-copy>...]
  local status=$1 copy=${2:-} line nested
  shift
  [ "$#" -eq 0 ] || shift
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'?? .claude/'*|'?? .fm-grok-turnend'|'?? .fm-kimi-turnend') continue ;;
    esac
    for nested in "$@"; do
      case "$nested" in
        "$copy"/*) [ "$line" != "?? ${nested#"$copy"/}/" ] || continue 2 ;;
      esac
    done
    printf '%s\n' "$line"
  done <<< "$status"
}

# The canonical paths of the task's own prior_worktree= copies that lie strictly
# inside <slot>: the copies a reset or release of that slot would sweep away.
# Shared by bin/fm-control.sh reassociate and bin/fm-teardown.sh.
fm_task_copy_priors_inside() {  # <meta> <slot>
  local meta=$1 slot=$2 line prior_real
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*) ;; *) continue ;; esac
    prior_real=$(fm_task_copy_canonical_dir "${line#prior_worktree=}") || continue
    case "$prior_real" in "$slot"/*) printf '%s\n' "$prior_real" ;; esac
  done < "$meta"
}

# The one rule for a task's own copy that a pool slot reset or release may
# sweep away, shared by bin/fm-control.sh reassociate and bin/fm-teardown.sh:
# <copy> must be a clean Git worktree root (fm_task_copy_dirty_status, with the
# task's own <nested-copy> paths) whose HEAD a refs/fm/anchor/<task>-<sha>
# preservation anchor in <project> holds. With <write> 1 a missing anchor is
# written and verified; with 0 nothing is written and a missing anchor returns
# 2. FM_TASK_COPY_HEAD and FM_TASK_COPY_ANCHOR name the HEAD and its anchor.
# Any other failure returns 1 with FM_TASK_COPY_REASON, a clause following the
# copy's path, and FM_TASK_COPY_DIRTY listing any dirt. A failure that stays the
# same until someone decides (not a worktree root, unresolved HEAD, an anchor
# naming another commit) also sets FM_TASK_COPY_STABLE to its predicate id; a
# Git read or write failure leaves it empty.
FM_TASK_COPY_HEAD=
FM_TASK_COPY_ANCHOR=
FM_TASK_COPY_DIRTY=
FM_TASK_COPY_STABLE=
fm_task_copy_preserve() {  # <project> <task> <copy> <write> [<nested-copy>...]
  local project=$1 task=$2 copy=$3 write=$4 top status ref short current
  shift 4
  FM_TASK_COPY_HEAD=
  FM_TASK_COPY_ANCHOR=
  FM_TASK_COPY_DIRTY=
  FM_TASK_COPY_STABLE=
  FM_TASK_COPY_REASON=
  top=$(git -C "$copy" rev-parse --show-toplevel 2>/dev/null) \
    && top=$(fm_task_copy_canonical_dir "$top") && [ "$top" = "$copy" ] || {
    FM_TASK_COPY_STABLE='copy-worktree-root'
    FM_TASK_COPY_REASON="is not a Git worktree root, so its contents cannot be proved preserved"
    return 1
  }
  status=$(git -C "$copy" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
    FM_TASK_COPY_REASON="cannot be inspected for uncommitted changes"
    return 1
  }
  FM_TASK_COPY_DIRTY=$(fm_task_copy_dirty_status "$status" "$copy" "$@")
  if [ -n "$FM_TASK_COPY_DIRTY" ]; then
    FM_TASK_COPY_REASON="has uncommitted or untracked-unignored changes"
    return 1
  fi
  FM_TASK_COPY_HEAD=$(git -C "$copy" rev-parse --verify --quiet 'HEAD^{commit}') || {
    FM_TASK_COPY_STABLE='copy-head-resolved'
    FM_TASK_COPY_REASON="has a HEAD that cannot be resolved"
    return 1
  }
  while IFS= read -r ref; do
    short=${ref#"refs/fm/anchor/$task-"}
    case "$short" in ''|*[!0-9a-f]*) continue ;; esac
    case "$FM_TASK_COPY_HEAD" in
      "$short"*)
        FM_TASK_COPY_ANCHOR=$ref
        return 0
        ;;
    esac
  done < <(git -C "$project" for-each-ref --points-at "$FM_TASK_COPY_HEAD" --format='%(refname)' "refs/fm/anchor/$task-*" 2>/dev/null)
  short=$(git -C "$copy" rev-parse --short "$FM_TASK_COPY_HEAD") || {
    FM_TASK_COPY_REASON="has a HEAD $FM_TASK_COPY_HEAD that could not be named for its preservation anchor"
    return 1
  }
  FM_TASK_COPY_ANCHOR="refs/fm/anchor/$task-$short"
  if git -C "$project" rev-parse --verify --quiet "$FM_TASK_COPY_ANCHOR" >/dev/null; then
    FM_TASK_COPY_STABLE='copy-anchor-commit'
    FM_TASK_COPY_REASON="cannot be anchored: preservation anchor $FM_TASK_COPY_ANCHOR already names a different commit"
    return 1
  fi
  [ "$write" = 1 ] || return 2
  git -C "$project" update-ref "$FM_TASK_COPY_ANCHOR" "$FM_TASK_COPY_HEAD" "" || {
    FM_TASK_COPY_REASON="could not be anchored: writing $FM_TASK_COPY_ANCHOR at $FM_TASK_COPY_HEAD failed"
    return 1
  }
  current=$(git -C "$project" rev-parse --verify "$FM_TASK_COPY_ANCHOR") \
    && [ "$current" = "$FM_TASK_COPY_HEAD" ] || {
    FM_TASK_COPY_REASON="could not be anchored: $FM_TASK_COPY_ANCHOR could not be verified at $FM_TASK_COPY_HEAD"
    return 1
  }
}

# True when <path> is an isolated worktree of <project>: a real directory that
# is its own worktree root, is not the project checkout itself, and is not the
# repository's primary checkout. FM_TASK_COPY_TOP is left holding the worktree
# root the check read, and FM_TASK_COPY_REASON a short phrase naming why a
# rejected path failed, both for refusal messages.
FM_TASK_COPY_TOP=
FM_TASK_COPY_REASON=
fm_task_copy_isolated() {  # <path> <project>
  local path=$1 project=$2 wt_real wt_top_real wt_git_dir proj_real proj_common
  FM_TASK_COPY_TOP=
  FM_TASK_COPY_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    FM_TASK_COPY_REASON="it is not a readable directory"
    return 1
  fi
  FM_TASK_COPY_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to the caller's OWN cwd and report the path as a
  # subdirectory of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$FM_TASK_COPY_TOP" ] && ! wt_top_real=$(cd "$FM_TASK_COPY_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    FM_TASK_COPY_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    FM_TASK_COPY_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  # The project may be spelled through a symlink; compare physical forms, and
  # fall back to the spelling given when it does not resolve.
  if ! proj_real=$(cd "$project" 2>/dev/null && pwd -P); then
    proj_real=$project
  fi
  if [ "$wt_real" = "$proj_real" ]; then
    FM_TASK_COPY_REASON="it is the project checkout itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked project home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    FM_TASK_COPY_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    FM_TASK_COPY_REASON="it is the repository's primary checkout (its git dir is the project's common git dir)"
    return 1
  fi
  return 0
}

# True when <path> is a checkout of the same repository as <project>: both
# resolve to one Git common directory. An isolated worktree of some other
# repository passes fm_task_copy_isolated but fails this.
fm_task_copy_same_repository() {  # <path> <project>
  local path=$1 project=$2 path_common proj_common
  path_common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    path_common=$(cd "$path_common" 2>/dev/null && pwd -P) || return 1
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || return 1
  [ "$path_common" = "$proj_common" ]
}

# Prints the canonical path of every worktree <canonical-clone> has registered
# strictly inside itself, one per line. A registered copy whose directory is
# gone keeps its raw path. Fails when the registration list cannot be read, so a
# caller never takes an unreadable list for an empty one.
fm_task_copy_registered_nested() {  # <canonical-clone>
  local clone=$1 field path canon
  while IFS= read -r -d '' field; do
    case "$field" in
      registration-list-unreadable) return 1 ;;
      'worktree '*) path=${field#worktree } ;;
      *) continue ;;
    esac
    canon=$(fm_task_copy_canonical_dir "$path") || canon=$path
    case "$canon" in "$clone"/*) printf '%s\n' "$canon" ;; esac
  done < <(git -C "$clone" worktree list --porcelain -z 2>/dev/null || printf '\0registration-list-unreadable\0')
}

# The local copies a task record names, one "<field> <path>" line each: the
# last worktree= and home= values (the values every reader of those fields
# uses) and every prior_worktree= line.
fm_task_copy_record_paths() {  # <meta>
  local meta=$1 value line
  for value in worktree home; do
    line=$(fm_meta_get "$meta" "$value")
    [ -z "$line" ] || printf '%s %s\n' "$value" "$line"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      prior_worktree=?*) printf 'prior_worktree %s\n' "${line#prior_worktree=}" ;;
    esac
  done < "$meta" 2>/dev/null || true
}

fm_task_copy_ancestor_current() {
  local meta=$1 state=$2 field=$3 copy=$4 target=$5 home owner parent id depth=0
  case "$field" in worktree|home) ;; *) return 1 ;; esac
  case "$target" in "$copy"/*) ;; *) return 1 ;; esac
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
  owner=$(fm_meta_get "$meta" home)
  [ -n "$owner" ] || owner=$(fm_meta_get "$meta" worktree)
  owner=$(fm_task_copy_canonical_dir "$owner") || return 1
  home=$(fm_task_copy_canonical_dir "$state") || return 1
  home=${home%/*}
  while [ "$depth" -lt 64 ]; do
    fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
    parent=$(fm_task_copy_canonical_dir "$FM_SECONDMATE_PARENT_HOME") || return 1
    if [ "$home" = "$owner" ]; then
      [ "${meta%/*}" -ef "$parent/state" ] || return 1
      id=${meta##*/}
      id=${id%.meta}
      secondmate_registry_validate_bindings "$parent/data/secondmates.md" \
        secondmate_registry_path_key "$id" "$home" || return 1
      [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 0 ]
      return
    fi
    home=$parent
    depth=$((depth + 1))
  done
  return 1
}

# Whether a task record in this home or any locally registered Firstmate home
# names a canonical copy overlapping <path> in worktree=, home=, or
# prior_worktree=. The current record is excluded, and so is every optional
# <skip-meta> record: bin/fm-control.sh reassociate passes the records it
# re-points together in one call, and checks those against each other itself.
# Returns 0 on overlap, setting FM_TASK_COPY_OTHER_ID and
# FM_TASK_COPY_OTHER_FIELD;
# 1 for no overlap or a missing path; 2 when the scan cannot be completed.
#
# Identity, not spelling: the same record reached through a differently
# resolved state dir (e.g. a symlinked $FM_HOME) is still <record-meta>. A
# differently named hardlink is another task's record, so the name must match
# too.
#
# A caller that sets FM_TASK_COPY_RELEASED_PRIOR_RETIRING to the retiring task's
# own record meta also passes over an overlap that is only another record's
# released root (fm_task_copy_prior_root_released); every other caller, and every
# other overlap, still counts.
FM_TASK_COPY_OTHER_ID=
FM_TASK_COPY_OTHER_FIELD=
FM_TASK_COPY_RELEASED_PRIOR_RETIRING=
fm_task_copy_other_record() {  # <record-meta> <record-state> <path> [<skip-meta>...]
  local record_meta=$1 record_state=$2 path=$3
  local target state_dir other_meta line field other_path other_real skip
  shift 3
  FM_TASK_COPY_OTHER_ID=
  FM_TASK_COPY_OTHER_FIELD=
  target=$(fm_task_copy_canonical_dir "$path") || return 1
  fm_local_firstmate_state_dirs "$record_state" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; nothing was changed" >&2
    return 2
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      [ "${other_meta##*/}" = "${record_meta##*/}" ] && [ "$other_meta" -ef "$record_meta" ] && continue
      for skip in "$@"; do
        [ "${other_meta##*/}" = "${skip##*/}" ] && [ "$other_meta" -ef "$skip" ] && continue 2
      done
      while IFS= read -r line || [ -n "$line" ]; do
        field=${line%% *}
        other_path=${line#* }
        [ -n "$other_path" ] || continue
        other_real=$(fm_task_copy_canonical_dir "$other_path") || continue
        fm_task_copy_paths_overlap "$other_real" "$target" || continue
        fm_task_copy_ancestor_current "$other_meta" "$record_state" "$field" "$other_real" "$target" && continue
        if [ "$field" = prior_worktree ] && [ -n "$FM_TASK_COPY_RELEASED_PRIOR_RETIRING" ] \
           && fm_task_copy_prior_root_released "$other_meta" "$other_real" "$target" \
             "$FM_TASK_COPY_RELEASED_PRIOR_RETIRING" "${FM_LOCAL_FIRSTMATE_STATES[@]}"; then
          continue
        fi
        FM_TASK_COPY_OTHER_ID=$(basename "$other_meta" .meta)
        FM_TASK_COPY_OTHER_FIELD=$field
        return 0
      done < <(fm_task_copy_record_paths "$other_meta")
    done
  done
  return 1
}

# Whether the prior_worktree= <root> of record <other-meta> is a pool slot root
# that task has left, so that it does not keep <target>, a copy of the retiring
# task strictly inside <root>, from being cleaned up. bin/fm-control.sh
# reassociate leaves two live records in this shape when it re-points them
# together off one slot root: each now works in its own copy nested in the root,
# and each names the root as prior_worktree=. All of these must hold, and any
# other shape keeps the overlap:
#   - <other-meta> is a ship or scout record, not an Orca task, and <root> is a
#     Treehouse pool slot of its project;
#   - its current copy (worktree=) lies strictly inside <root> and neither
#     contains, equals, nor lies inside <target>, so the record has been
#     re-pointed away from the root and its own copy is untouched;
#   - the retiring task is itself re-pointed off the root: <retiring-meta> names
#     <root> as a prior_worktree= of its own;
#   - no other record, apart from <other-meta> and the retiring task's
#     <retiring-meta>, still names <root> or a directory enclosing it as worktree=
#     or home=; a copy of some record inside <root> belongs to that record.
# <state-dir>... are the local Firstmate state directories to scan, as
# fm_local_firstmate_state_dirs produced them. <root> and <target> are canonical.
fm_task_copy_prior_root_released() {  # <other-meta> <root> <target> <retiring-meta> <state-dir>...
  local other=$1 root=$2 target=$3 retiring=$4 kind project wt state_dir meta field path real line named
  shift 4
  case "$target" in "$root"/*) ;; *) return 1 ;; esac
  kind=$(fm_meta_get "$other" kind)
  case "${kind:-ship}" in ship|scout) ;; *) return 1 ;; esac
  [ -z "$(fm_meta_get "$other" orca_worktree_id)" ] || return 1
  project=$(fm_meta_get "$other" project)
  [ -n "$project" ] && fm_treehouse_pool_slot "$project" "$root" || return 1
  wt=$(fm_task_copy_canonical_dir "$(fm_meta_get "$other" worktree)") || return 1
  case "$wt" in "$root"/*) ;; *) return 1 ;; esac
  ! fm_task_copy_paths_overlap "$wt" "$target" || return 1
  named=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*) ;; *) continue ;; esac
    [ "$(fm_task_copy_canonical_dir "${line#prior_worktree=}" 2>/dev/null)" != "$root" ] || named=1
  done < "$retiring"
  [ "$named" = 1 ] || return 1
  for state_dir in "$@"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "${meta##*/}" = "${other##*/}" ] && [ "$meta" -ef "$other" ] && continue
      [ "${meta##*/}" = "${retiring##*/}" ] && [ "$meta" -ef "$retiring" ] && continue
      for field in worktree home; do
        path=$(fm_meta_get "$meta" "$field")
        [ -n "$path" ] || continue
        real=$(fm_task_copy_canonical_dir "$path") || continue
        fm_task_copy_paths_overlap "$real" "$root" || continue
        case "$real" in "$root"/*) continue ;; esac
        return 1
      done
    done
  done
  return 0
}

# The pool slot of <project> that strictly contains <canonical-path>, or a
# failure when none does.
fm_task_copy_enclosing_pool_slot() {  # <project> <canonical-path>
  local project=$1 dir=${2%/*}
  while [ -n "$dir" ]; do
    if [ -f "${dir%/*/*}/treehouse-state.json" ] && fm_treehouse_pool_slot "$project" "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=${dir%/*}
  done
  return 1
}

# The lease holder Treehouse writes on every entry it rebuilds from a corrupt
# or truncated state file. Treehouse 3.1.0 and later free such an entry on their
# own, under the state lock of whichever pool command runs next (treehouse get
# included), once the slot is idle, tracked-clean, and landed; an ordinary lease
# is released only by treehouse return.
FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER='recovered: state file was corrupt or truncated; verify before reuse'

# Whether Treehouse's own pool state durably holds pool slot <slot>, so that
# treehouse get cannot hand it out. treehouse get reuses only a slot its state
# file records as not leased (`treehouse get --help`: a leased worktree is never
# handed out by a later get until treehouse return releases it); a live owner
# process, dirt, or an unmerged HEAD also make a get skip a slot, but each of
# those can change before the get runs, so none of them counts here. Every
# entry naming <slot>'s directory, however its path is spelled, must be leased:
# an ordinary lease holds; a
# recovered lease (FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER) holds only when
# <slot> is one of the given local Firstmate <home> directories, since a home
# freed and handed out is lost whole, nested copies or not. Reading the state
# needs jq; without it, with an unreadable state file, with no entry for
# <slot>, or with any relative or TSV-escaped entry path in the state, the slot
# is not proved held.
# Sets FM_TASK_COPY_SLOT_NAME to the slot's name in Treehouse state (the name
# treehouse status and treehouse lease use), or empty when no entry records
# <slot>; FM_TASK_COPY_SLOT_STATE to held, unleased, conflicting, recovered,
# escaped, relative, missing-jq, or unknown; FM_TASK_COPY_SLOT_HOLDER to the lease
# holder of the last leased entry that records <slot>, or empty; and on failure
# FM_TASK_COPY_SLOT_REASON to a clause following the slot's path.
# Returns 0 when held, 1 otherwise.
# The last state file read and its entries are kept in
# FM_TASK_COPY_POOL_STATE_FILE and FM_TASK_COPY_POOL_STATE_ENTRIES, so a scan
# reads each pool's state once; a scan clears both before it starts.
FM_TASK_COPY_SLOT_NAME=
FM_TASK_COPY_SLOT_HOLDER=
FM_TASK_COPY_SLOT_STATE=
FM_TASK_COPY_SLOT_REASON=
FM_TASK_COPY_POOL_STATE_FILE=
FM_TASK_COPY_POOL_STATE_ENTRIES=
fm_task_copy_pool_slot_held() {  # <slot> [<home>...]
  local slot=$1 state leaf entries name leased holder path home matched=0 is_home=0
  local has_unleased=0 has_recovered=0 named=0
  shift
  state="${slot%/*/*}/treehouse-state.json"
  leaf=${slot#"${slot%/*/*}"}
  FM_TASK_COPY_SLOT_NAME=
  FM_TASK_COPY_SLOT_HOLDER=
  FM_TASK_COPY_SLOT_STATE=unknown
  FM_TASK_COPY_SLOT_REASON=
  if ! command -v jq >/dev/null 2>&1; then
    FM_TASK_COPY_SLOT_STATE=missing-jq
    FM_TASK_COPY_SLOT_REASON="cannot be proved leased: reading Treehouse state $state needs jq, which is not installed"
    return 1
  fi
  # One line per entry. Each field carries a one-letter prefix so none is ever
  # empty: tab is IFS whitespace, so read would otherwise merge an empty field
  # into its neighbour.
  if [ "$state" = "$FM_TASK_COPY_POOL_STATE_FILE" ]; then
    entries=$FM_TASK_COPY_POOL_STATE_ENTRIES
  else
    entries=$(jq -r '.worktrees[]? | [("L" + (if .leased == true then "leased" else "unleased" end)), ("H" + (.lease_holder // "" | tostring)), ("N" + (.name // "" | tostring)), ("P" + (.path // "" | tostring))] | @tsv' "$state" 2>/dev/null) || {
      FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state cannot be read"
      return 1
    }
    FM_TASK_COPY_POOL_STATE_FILE=$state
    FM_TASK_COPY_POOL_STATE_ENTRIES=$entries
  fi
  for home in "$@"; do
    [ "$home" != "$slot" ] || is_home=1
  done
  while IFS=$'\t' read -r leased holder name path; do
    path=${path#P}
    [ -n "$path" ] || continue
    # @tsv escapes backslashes and line/field separators; relative paths
    # depend on the caller's working directory. Neither can prove identity.
    case "$path" in
      *\\*)
        FM_TASK_COPY_SLOT_STATE=escaped
        FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state contains an escaped entry path for entry '${name#N}': '$path' (TSV-escaped), which cannot be compared safely"
        return 1
        ;;
      /*) ;;
      *)
        FM_TASK_COPY_SLOT_STATE=relative
        FM_TASK_COPY_SLOT_REASON="cannot be proved leased: Treehouse state $state contains a relative entry path for entry '${name#N}': '$path'"
        return 1
        ;;
    esac
    if [ "$path" != "$slot" ]; then
      # Only ordinary leased entries may be skipped by their raw suffix:
      # skipping an unleased or recovered-lease alias can hide a conflict
      # with a matching leased entry.
      case "$leased$holder" in
        Lunleased*|"LleasedH$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER") ;;
        *) [ "${path#"${path%/*/*}"}" = "$leaf" ] || continue ;;
      esac
      # Bash's inode/device comparison resolves aliases without a subshell
      # and cd/pwd for every entry that reaches it in an unmatched scan.
      [ "$path" -ef "$slot" ] || continue
    fi
    matched=$((matched + 1))
    FM_TASK_COPY_SLOT_NAME=${name#N}
    [ "${leased#L}" != leased ] || FM_TASK_COPY_SLOT_HOLDER=${holder#H}
    if [ "${leased#L}" != leased ]; then
      has_unleased=1
    elif [ "${holder#H}" = "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER" ] && [ "$is_home" = 0 ]; then
      has_recovered=1
    fi
  done <<< "$entries"
  if [ "$has_unleased" = 1 ]; then
    if [ "$matched" = 1 ]; then
      # Ordinary leases safely skipped on the held path still affect the
      # remedy: any leased directory alias makes this a mixed slot, and a
      # duplicate name makes LeaseExisting select only its first record.
      while IFS=$'\t' read -r leased holder name path; do
        [ "${name#N}" != "$FM_TASK_COPY_SLOT_NAME" ] || named=$((named + 1))
        if [ "$leased" = Lleased ] && [ "${path#P}" -ef "$slot" ]; then
          matched=$((matched + 1))
          break
        fi
        [ "$named" -le 1 ] || break
      done <<< "$entries"
    fi
    if [ "$matched" -gt 1 ] || [ "$named" -gt 1 ]; then
      # LeaseExisting changes only the first entry with a given name: one
      # lease cannot reliably clear duplicate records in either entry order.
      FM_TASK_COPY_SLOT_STATE=conflicting
      FM_TASK_COPY_SLOT_REASON="has conflicting lease records in Treehouse state $state, including an unleased entry, so its hold cannot be proved"
    else
      FM_TASK_COPY_SLOT_STATE=unleased
      FM_TASK_COPY_SLOT_REASON="is not leased in Treehouse state $state, so treehouse get may hand it out"
    fi
    return 1
  fi
  if [ "$has_recovered" = 1 ]; then
    FM_TASK_COPY_SLOT_STATE=recovered
    FM_TASK_COPY_SLOT_REASON="is not a Firstmate home and carries Treehouse's recovered-state lease in $state, which Treehouse 3.1.0 and later release on their own once the slot is idle, clean, and landed"
    return 1
  fi
  if [ "$matched" -gt 0 ]; then
    FM_TASK_COPY_SLOT_STATE=held
    return 0
  fi
  FM_TASK_COPY_SLOT_REASON="has no entry in Treehouse state $state, so its lease cannot be proved"
  return 1
}

# The pool folder treehouse get would allocate from when run in <project>, as
# treehouse pool-dir reports it: one absolute directory line, read without a
# slot scan or the state lock. Firstmate never predicts where Treehouse puts a
# pool. Fails when the installed treehouse has no pool-dir, the command fails,
# or its output is not exactly one absolute path line naming a directory.
fm_task_copy_treehouse_pool_dir() {  # <project>
  local project=$1 out
  command -v treehouse >/dev/null 2>&1 || return 1
  out=$(cd "$project" 2>/dev/null && treehouse pool-dir </dev/null 2>/dev/null) || return 1
  case "$out" in /*) ;; *) return 1 ;; esac
  case "$out" in *$'\n'*) return 1 ;; esac
  [ -d "$out" ] || return 1
  printf '%s\n' "$out"
}

# treehouse status --json run from <project>, read once per process and kept,
# with a failed read kept as an empty listing, for every later call: one
# teardown reuses it across all its descendants. Sets
# FM_TASK_COPY_CURRENT_POOL_JSON; returns 0 only when the listing was read.
FM_TASK_COPY_CURRENT_POOL_JSON=
FM_TASK_COPY_POOL_LISTING_PROJECTS=()
FM_TASK_COPY_POOL_LISTINGS=()
fm_task_copy_current_pool_listing() {  # <project>
  local project=$1 i json=
  for ((i = 0; i < ${#FM_TASK_COPY_POOL_LISTING_PROJECTS[@]}; i++)); do
    [ "${FM_TASK_COPY_POOL_LISTING_PROJECTS[$i]}" = "$project" ] || continue
    FM_TASK_COPY_CURRENT_POOL_JSON=${FM_TASK_COPY_POOL_LISTINGS[$i]}
    [ -n "$FM_TASK_COPY_CURRENT_POOL_JSON" ]
    return
  done
  if command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    json=$(cd "$project" 2>/dev/null && treehouse status --json </dev/null 2>/dev/null) \
      && jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || json=
  fi
  FM_TASK_COPY_POOL_LISTING_PROJECTS+=("$project")
  FM_TASK_COPY_POOL_LISTINGS+=("$json")
  FM_TASK_COPY_CURRENT_POOL_JSON=$json
  [ -n "$json" ]
}

# Where pool slot <slot>, named <state-name> in its own pool folder's state, stands
# against the pool Treehouse resolves for <project> today. Repointing origin or
# moving the Treehouse root moves the project to a new, initially empty folder
# and leaves earlier copies in the old one, whose state file still records them.
# treehouse get allocates from the current pool only, and treehouse lease and
# treehouse return <name> resolve a slot NAME there, so a name taken from an
# older folder's state would act on a different copy that shares it. When
# treehouse pool-dir answers (fm_task_copy_treehouse_pool_dir), a slot is in the
# current pool only when its pool folder is that directory as a resolved path;
# otherwise only a path that the status listing
# (fm_task_copy_current_pool_listing) holds is.
FM_TASK_COPY_POOL_CURRENCY=
FM_TASK_COPY_CURRENT_SLOT_NAME=
fm_task_copy_slot_in_current_pool() {  # <project> <slot> <state-name>
  local project=$1 slot=$2 state_name=$3 current listing name path
  FM_TASK_COPY_POOL_CURRENCY=unknown
  FM_TASK_COPY_CURRENT_SLOT_NAME=
  if [ -n "$state_name" ] && current=$(fm_task_copy_treehouse_pool_dir "$project"); then
    if [ "${slot%/*/*}" -ef "$current" ]; then
      FM_TASK_COPY_POOL_CURRENCY=current
      FM_TASK_COPY_CURRENT_SLOT_NAME=$state_name
      return 0
    fi
    FM_TASK_COPY_POOL_CURRENCY=superseded
    return 1
  fi
  fm_task_copy_current_pool_listing "$project" || return 1
  listing=$(jq -r '.[] | ["N" + (.name // "" | tostring), "P" + (.path // "" | tostring)] | @tsv' \
    <<<"$FM_TASK_COPY_CURRENT_POOL_JSON" 2>/dev/null) || return 1
  FM_TASK_COPY_POOL_CURRENCY=superseded
  while IFS=$'\t' read -r name path; do
    path=${path#P}
    [ -n "$path" ] || continue
    if [ "$path" = "$slot" ] || [ "$path" -ef "$slot" ]; then
      FM_TASK_COPY_POOL_CURRENCY=current
      FM_TASK_COPY_CURRENT_SLOT_NAME=${name#N}
      return 0
    fi
  done <<< "$listing"
  return 1
}

# True when no pool slot of <project> that treehouse get could hand out strictly
# contains the current copy (worktree=) of a task record in this home or any
# locally registered Firstmate home. treehouse get resets and reassigns the slot
# it hands out, so a slot holding a live record's nested copy must not be
# allocatable; a slot Treehouse's state durably holds
# (fm_task_copy_pool_slot_held) is never handed out, whatever lies inside it,
# nor is an unleased slot in a superseded pool folder
# (fm_task_copy_slot_in_current_pool), which is judged again at each call, and a
# slot a task merely left is not a record's current copy, so none of them
# stops the allocation. A uniquely recorded unleased slot names the treehouse
# lease command that holds it in place without touching it; teardown's
# treehouse return releases that lease with the slot. Conflicting records
# instead need inspection and repair: lease selects only the first matching
# name, so it cannot reliably clear that refusal. No other refusal names a
# lease as a remedy. A registered local home
# that cannot be read is named in one warning line and skipped: one broken home
# must not stop every allocation for a project.
fm_task_copy_pool_slots_hold_no_current_copy() {  # <project> <record-state>
  local project=$1 record_state=$2 state_dir meta copy slot skipped id home remedy
  local -a homes=()
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  fm_local_firstmate_state_dirs "$record_state" tolerant
  for skipped in ${FM_LOCAL_FIRSTMATE_SKIPPED[@]+"${FM_LOCAL_FIRSTMATE_SKIPPED[@]}"}; do
    echo "warning: $skipped; its task records were not checked for a current copy inside a Treehouse pool slot" >&2
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    home=$(fm_task_copy_canonical_dir "${state_dir%/*}") && homes+=("$home")
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      copy=$(fm_meta_get "$meta" worktree)
      copy=$(fm_task_copy_canonical_dir "$copy") || continue
      slot=$(fm_task_copy_enclosing_pool_slot "$project" "$copy") || continue
      fm_task_copy_pool_slot_held "$slot" ${homes[@]+"${homes[@]}"} || true
      id=$(basename "$meta" .meta)
      case "$FM_TASK_COPY_SLOT_STATE" in
        held) continue ;;
        unleased)
          if fm_task_copy_slot_in_current_pool "$project" "$slot" "$FM_TASK_COPY_SLOT_NAME"; then
            remedy="To hold that slot in place without touching its contents, run: (cd '$project' && treehouse lease '$FM_TASK_COPY_CURRENT_SLOT_NAME' --lease-holder '$id')"
          elif [ "$FM_TASK_COPY_POOL_CURRENCY" = superseded ]; then
            continue
          else
            remedy="To hold that slot in place without touching its contents, confirm that treehouse status run from $project lists slot $FM_TASK_COPY_SLOT_NAME at $slot, then run: (cd '$project' && treehouse lease '$FM_TASK_COPY_SLOT_NAME' --lease-holder '$id')"
          fi
          ;;
        conflicting)
          remedy="Inspect the pool with: (cd '$project' && treehouse status); report the conflicting entries for repair before retrying. A lease cannot reliably clear this conflict."
          ;;
        recovered)
          remedy="treehouse lease refuses a slot that is already leased; inspect it with: (cd '$project' && treehouse status)"
          ;;
        escaped|relative)
          remedy="Have the pool owner remove or rename the offending entry so its recorded path is absolute and contains no TSV-escaped characters, then retry; a lease does not clear this refusal. A real path containing those characters remains unsupported while the entry exists."
          ;;
        missing-jq)
          remedy="Install jq so the pool state can be read, then retry; a lease does not clear this refusal."
          ;;
        *)
          remedy="A lease does not clear this refusal; inspect the pool with: (cd '$project' && treehouse status)"
          ;;
      esac
      echo "error: Treehouse pool slot $slot contains task $id's current copy $copy and $FM_TASK_COPY_SLOT_REASON; refusing allocation before treehouse get" >&2
      echo "$remedy" >&2
      return 1
    done
  done
}
