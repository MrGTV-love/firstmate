#!/bin/bash -p
# fm-confined-git wrapper: explains a confined Git write refused under refs/heads/archive/.
#
# Usage:
#   fm-confined-git.sh install <dir> <task-id> <worktree>
#       Recreate <dir> holding git, a copy of this script, and config, which
#       names the task id and the canonical shared Git directory of <worktree>.
#       bin/fm-spawn.sh runs it for a seatbelt-v1 launch only, with <dir> set to
#       state/<task>.git-path, and puts <dir> first on PATH inside that launch's
#       sandbox, never in the pane shell. The task's write profile denies the
#       worker every write below state/<task>.git-path.
#       tests/fm-confined-git.test.sh checks that a confined process cannot
#       append to the folder's files, create a file in it or move it; that
#       case runs only where sandbox-exec can apply a profile and skips by
#       name elsewhere, so a run that skips it leaves this unverified.
#       Teardown removes the folder.
#   <dir>/git [<git argument>...]
#       Wrapper mode, selected by the invoked name git.
#
# The wrapper runs the real git: the first git on PATH that is neither this
# file nor another copy of this wrapper, so it never calls itself. Arguments,
# standard input, standard output, standard error and the exit status stay
# git's own; the wrapper never retries and never rewrites an argument. It reads
# git's trace2 error events through GIT_TRACE2_EVENT, pointed at
# TMPDIR/fm-confined-git.<wrapper pid>, only when FM_WRITE_CONFINEMENT=seatbelt-v1,
# GIT_TRACE2_EVENT is not already set, the config is readable and that file
# can be emptied or made; otherwise it execs the real git untouched. When git
# exits nonzero and an error event says a path under refs/heads/archive/ or
# logs/refs/heads/archive/ in the task's own shared Git directory was refused
# with "Operation not permitted", it appends one stderr line naming each
# refused ref and the two archive shapes the profile allows, with the task id
# spelled out. Git quotes the refused path, except for a branch rename or copy,
# whose refused reflog move it reports as "unable to move logfile
# <dir>/logs/refs/.tmp-renamed-log to <path>". bin/fm-write-confinement.py
# owns those shapes; this line only restates them, and
# tests/fm-confined-git.test.sh checks the profile accepts both.
#
# Limits: the line needs the English "Operation not permitted" text in a trace2
# error event, so a refusal Git reports another way gets no line: a nested name
# such as archive/<task>-x/y, whose folder Git reports only as "unable to
# create directory", and receive-pack's text for a push into the task's own
# clone. A refused path that holds a backslash gets no line, and one that holds a
# quote may get none. The
# wrapper is git's parent, so a signal sent only to the wrapper's pid stops the
# wrapper and leaves git to finish, and a git killed by a signal is reported as
# exit 128+n, the status a shell shows for it. For these calls
# GIT_TRACE2_EVENT replaces a trace2.eventTarget set in Git config. A wrapper
# stopped by a signal, or a Git process that outlives the call, such as a
# detached gc's children, can leave its trace file under TMPDIR, which
# teardown removes with the task temp root.

FM_CONFINED_GIT_MARKER='# fm-confined-git wrapper: explains a confined Git write refused under refs/heads/archive/.'

fm_confined_git_note() {  # <task> <common> <trace>
  local task=$1 common=$2 trace=$3 line msg path dir name names='' seen='' nl=$'\n' resolved
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in *'"event":"error"'*': Operation not permitted'*) ;; *) continue ;; esac
    msg=${line#*'"msg":"'}
    msg=${msg%'","fmt":"'*}
    case $msg in *\\*) continue ;; esac
    path=${msg%%': Operation not permitted'*}
    case $path in
      *"'") path=${path%"'"} path=${path##*"'"} ;;
      *'/logs/refs/.tmp-renamed-log to '*) path=${path#*'/logs/refs/.tmp-renamed-log to '} ;;
      *) continue ;;
    esac
    case $path in
      /*/logs/refs/heads/archive/?*) dir=${path%/logs/refs/heads/archive/*} name=${path##*/logs/refs/heads/archive/} ;;
      /*/refs/heads/archive/?*) dir=${path%/refs/heads/archive/*} name=${path##*/refs/heads/archive/} ;;
      *) continue ;;
    esac
    resolved=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || continue
    [ "$resolved" = "$common" ] || continue
    name=archive/${name%.lock}
    case $nl$seen$nl in *"$nl$name$nl"*) continue ;; esac
    seen=$seen$nl$name
    names=${names:+$names, }$name
  done <"$trace"
  [ -z "$names" ] || printf 'firstmate: write confinement refused %s; this task may write archive branches only as archive/%s-submitted-<8 lowercase hex> or archive/%s-pipeline-<8 lowercase hex>\n' \
    "$names" "$task" "$task" >&2
}

fm_confined_git_run() {
  local self=$0 rest entry real='' second task='' common='' trace status
  rest=${PATH-}:
  while [ -n "$rest" ]; do
    entry=${rest%%:*}
    rest=${rest#*:}
    entry=${entry:-.}/git
    [ -f "$entry" ] && [ -x "$entry" ] || continue
    [ ! "$entry" -ef "$self" ] || continue
    second=
    { read -r && IFS= read -r second; } 2>/dev/null <"$entry"
    [ "$second" != "$FM_CONFINED_GIT_MARKER" ] || continue
    real=$entry
    break
  done
  if [ -z "$real" ]; then
    printf 'git: command not found\n' >&2
    exit 127
  fi
  trace=${TMPDIR%/}/fm-confined-git.$$
  if [ "${FM_WRITE_CONFINEMENT-}" != seatbelt-v1 ] || [ -n "${GIT_TRACE2_EVENT+set}" ] || [ -z "${TMPDIR-}" ] \
    || ! [ -f "${self%/*}/config" ] || ! { IFS= read -r task && IFS= read -r common; } 2>/dev/null <"${self%/*}/config" \
    || [ -z "$task" ] || [ -z "$common" ] \
    || ! { : >"$trace"; } 2>/dev/null; then
    exec "$real" "$@"
  fi
  GIT_TRACE2_EVENT=$trace GIT_TRACE2_EVENT_BRIEF=true "$real" "$@"
  status=$?
  [ "$status" -eq 0 ] || fm_confined_git_note "$task" "$common" "$trace"
  /bin/rm -f -- "$trace"
  exit "$status"
}

fm_confined_git_install() {  # <dir> <task> <worktree>
  local dir=$1 task=$2 worktree=$3 self common staged
  self=$(cd -P -- "${0%/*}" && pwd -P) || return 1
  self=$self/${0##*/}
  if ! [[ $task =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$ ]]; then
    printf 'error: invalid task id: %s\n' "$task" >&2
    return 1
  fi
  common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir) || return 1
  common=$(cd -P -- "$common" && pwd -P) || return 1
  case $common in
    /*) ;;
    *) printf 'error: cannot record the shared Git directory of %s\n' "$worktree" >&2; return 1 ;;
  esac
  case $common in
    *$'\n'*) printf 'error: the shared Git directory of %s holds a newline\n' "$worktree" >&2; return 1 ;;
  esac
  case $dir in
    /*) ;;
    *) printf 'error: the wrapper folder must be an absolute path: %s\n' "$dir" >&2; return 1 ;;
  esac
  if [ -L "$dir" ]; then
    printf 'error: %s is a symbolic link\n' "$dir" >&2
    return 1
  fi
  mkdir -p -- "$dir" && chmod 700 "$dir" || return 1
  staged="$dir/.git.$$"
  if ! { cp -- "$self" "$staged" && chmod 500 "$staged" && mv -f -- "$staged" "$dir/git"; }; then
    rm -f -- "$staged"
    return 1
  fi
  staged="$dir/.config.$$"
  if ! { printf '%s\n%s\n' "$task" "$common" >"$staged" && mv -f -- "$staged" "$dir/config"; }; then
    rm -f -- "$staged"
    return 1
  fi
}

case ${0##*/} in
  git) fm_confined_git_run "$@" ;;
esac
if [ "${1-}" = install ] && [ "$#" -eq 4 ]; then
  fm_confined_git_install "$2" "$3" "$4"
  exit $?
fi
printf 'usage: fm-confined-git.sh install <dir> <task-id> <worktree>\n' >&2
exit 2
