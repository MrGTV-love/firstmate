#!/usr/bin/env bash
# Opt-in Git pre-commit and pre-merge-commit guard blocking direct commits or
# merges in a repository's primary checkout while permitting linked worktrees
# (such as Treehouse slots or isolated task worktrees).
#
# Usage:
#   fm-main-checkout-hook.sh check [--repo DIR]
#   fm-main-checkout-hook.sh install [--repo DIR]
#   fm-main-checkout-hook.sh remove [--repo DIR]
#   fm-main-checkout-hook.sh status [--repo DIR]
#
# Environment:
#   FM_ALLOW_MAIN_COMMIT=1  Emergency override allowing a primary-checkout commit
#                           or merge (recorded as an override guard event).
#
# Safety:
#   - `check` fails closed if Git worktree identity cannot be resolved.
#   - `install` and `remove` only manage files carrying the Firstmate marker and
#     never overwrite or delete unmanaged hooks or symbolic links.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MARKER="# FIRSTMATE-MANAGED-MAIN-CHECKOUT-HOOK"
HOOK_NAMES="pre-commit pre-merge-commit"

usage() {
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
}

emit_event() {
  [ -x "$SCRIPT_DIR/fm-guard-event.sh" ] || return 0
  "$SCRIPT_DIR/fm-guard-event.sh" main-checkout-commit "$@" >/dev/null 2>&1 || true
}

ACTION=${1:-}
case "$ACTION" in
  check|install|remove|status)
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'usage: %s check|install|remove|status [--repo DIR]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

REPO_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then
        printf 'usage: %s check|install|remove|status [--repo DIR]\n' "${0##*/}" >&2
        exit 2
      fi
      REPO_ARG=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'usage: %s check|install|remove|status [--repo DIR]\n' "${0##*/}" >&2
      exit 2
      ;;
  esac
done

git_in_target() {
  if [ -n "$REPO_ARG" ]; then
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
      git -C "$REPO_ARG" "$@"
  else
    git "$@"
  fi
}

resolve_git_dirs() {
  if [ -n "$REPO_ARG" ] && [ ! -d "$REPO_ARG" ]; then
    return 1
  fi
  local raw_gd raw_cd
  raw_gd=$(git_in_target rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  raw_cd=$(git_in_target rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$raw_gd" ] && [ -d "$raw_gd" ] || return 1
  [ -n "$raw_cd" ] && [ -d "$raw_cd" ] || return 1
  RESOLVED_GD=$(cd "$raw_gd" && pwd -P) || return 1
  RESOLVED_CD=$(cd "$raw_cd" && pwd -P) || return 1
  return 0
}

do_check() {
  if ! resolve_git_dirs; then
    emit_event deny --source-ok false
    printf 'fm-main-checkout-hook: refused: cannot resolve git worktree identity; commit from an isolated worktree created by bin/fm-spawn.sh or treehouse get --base main -b fm/<topic>.\n' >&2
    exit 1
  fi

  if [ "$RESOLVED_GD" != "$RESOLVED_CD" ]; then
    emit_event allow
    exit 0
  fi

  if [ "${FM_ALLOW_MAIN_COMMIT:-0}" = "1" ]; then
    emit_event allow --override --cleared-by env
    exit 0
  fi

  local top
  top=$(git_in_target rev-parse --show-toplevel 2>/dev/null || pwd -P)
  emit_event deny
  printf 'fm-main-checkout-hook: refused: direct commit or merge in primary checkout (%s); use treehouse get --base main -b fm/<topic> or bin/fm-spawn.sh (emergency override: FM_ALLOW_MAIN_COMMIT=1).\n' "$top" >&2
  exit 1
}

classify_hook() {
  local path=$1
  if [ -L "$path" ]; then
    printf 'symlink'
  elif [ ! -e "$path" ]; then
    printf 'absent'
  elif [ ! -f "$path" ]; then
    printf 'unmanaged'
  elif grep -qxF "$MARKER" "$path" 2>/dev/null; then
    printf 'installed'
  else
    printf 'unmanaged'
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

do_install() {
  if ! resolve_git_dirs; then
    printf 'fm-main-checkout-hook: refused: cannot resolve target git repository.\n' >&2
    exit 1
  fi
  local hooks_dir="$RESOLVED_CD/hooks"
  if [ -L "$hooks_dir" ]; then
    printf 'fm-main-checkout-hook: refused: hooks directory is a symbolic link (%s).\n' "$hooks_dir" >&2
    exit 1
  fi
  if [ -e "$hooks_dir" ] && [ ! -d "$hooks_dir" ]; then
    printf 'fm-main-checkout-hook: refused: hooks path is not a directory (%s).\n' "$hooks_dir" >&2
    exit 1
  fi

  local name path state
  for name in $HOOK_NAMES; do
    path="$hooks_dir/$name"
    state=$(classify_hook "$path")
    case "$state" in
      absent|installed) ;;
      *)
        printf 'fm-main-checkout-hook: refused: existing %s hook at %s is %s; remove or integrate it manually before running bin/fm-main-checkout-hook.sh install.\n' "$name" "$path" "$state" >&2
        exit 1
        ;;
    esac
  done

  mkdir -p "$hooks_dir" || {
    printf 'fm-main-checkout-hook: refused: could not create hooks directory (%s).\n' "$hooks_dir" >&2
    exit 1
  }

  local quoted_self tmp
  quoted_self=$(shell_quote "$SELF")
  for name in $HOOK_NAMES; do
    path="$hooks_dir/$name"
    tmp=$(mktemp "$hooks_dir/.fm-main-checkout-hook.XXXXXX") || {
      printf 'fm-main-checkout-hook: refused: could not create temp file in %s.\n' "$hooks_dir" >&2
      exit 1
    }
    cat > "$tmp" <<EOF
#!/usr/bin/env bash
$MARKER
exec $quoted_self check
EOF
    if ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$path"; then
      rm -f "$tmp"
      printf 'fm-main-checkout-hook: refused: could not write hook %s.\n' "$path" >&2
      exit 1
    fi
  done
  printf 'fm-main-checkout-hook: installed pre-commit and pre-merge-commit hooks in %s\n' "$hooks_dir"
}

do_remove() {
  if ! resolve_git_dirs; then
    printf 'fm-main-checkout-hook: refused: cannot resolve target git repository.\n' >&2
    exit 1
  fi
  local hooks_dir="$RESOLVED_CD/hooks"
  if [ -L "$hooks_dir" ]; then
    printf 'fm-main-checkout-hook: refused: hooks directory is a symbolic link (%s).\n' "$hooks_dir" >&2
    exit 1
  fi
  if [ ! -e "$hooks_dir" ]; then
    printf 'fm-main-checkout-hook: hooks already absent in %s\n' "$hooks_dir"
    exit 0
  fi

  local name path state
  for name in $HOOK_NAMES; do
    path="$hooks_dir/$name"
    state=$(classify_hook "$path")
    case "$state" in
      absent|installed) ;;
      *)
        printf 'fm-main-checkout-hook: refused: hook at %s is %s and not managed by Firstmate.\n' "$path" "$state" >&2
        exit 1
        ;;
    esac
  done

  for name in $HOOK_NAMES; do
    path="$hooks_dir/$name"
    if [ "$(classify_hook "$path")" = "installed" ]; then
      rm -f "$path"
    fi
  done
  printf 'fm-main-checkout-hook: removed managed hooks in %s\n' "$hooks_dir"
}

do_status() {
  if ! resolve_git_dirs; then
    printf 'fm-main-checkout-hook: error: cannot resolve target git repository.\n' >&2
    exit 1
  fi
  local hooks_dir="$RESOLVED_CD/hooks"
  local name path state all_installed=1
  for name in $HOOK_NAMES; do
    path="$hooks_dir/$name"
    if [ -L "$hooks_dir" ]; then
      state="symlink-dir"
    else
      state=$(classify_hook "$path")
    fi
    printf '%s: %s (%s)\n' "$name" "$state" "$path"
    [ "$state" = "installed" ] || all_installed=0
  done
  [ "$all_installed" -eq 1 ] && exit 0
  exit 1
}

case "$ACTION" in
  check) do_check ;;
  install) do_install ;;
  remove) do_remove ;;
  status) do_status ;;
esac
