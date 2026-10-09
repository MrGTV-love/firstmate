#!/usr/bin/env bash
# fm-claude-memory-lib.sh - the single owner of which memory files a Claude
# worker must NOT load because they belong to a firstmate home above it.
#
# A project copy nested under a firstmate home (a pool rooted inside the home,
# or <home>/projects/<project>/.claude/worktrees/<task>) sits below that
# home's CLAUDE.md, which imports AGENTS.md - the supervisor contract. Claude
# Code loads every ancestor CLAUDE.md, so the worker would be handed the first
# mate's job description and meet the "Allow external CLAUDE.md file imports?"
# dialog, whose declining option a key-limited steering plane cannot move.
# The documented claudeMdExcludes setting (picomatch globs over absolute
# paths, verified against the installed binary by
# tests/fm-claude-nested-home-live-e2e.test.sh) drops exactly the memory files
# of every firstmate home that is a STRICT ancestor of the pane's directory.
# A home that IS the pane directory (a secondmate, or a ship of the firstmate
# repo itself) is not an ancestor and keeps loading its own AGENTS.md. A home
# is recognized by the same evidence the rest of firstmate uses: the seeded
# secondmate marker, or the instance's own AGENTS.md beside bin/fm-spawn.sh.
# Both the logical and the physical spelling of each ancestor are listed,
# because Claude matches the path it walked, not the path we resolved.
#
# Sourced by bin/fm-spawn.sh, whose launch template carries the fragment in its
# per-launch --settings JSON.

# fm_claude_md_excludes_json <pane-directory>
# Prints the settings fragment (leading comma) or nothing when no ancestor is
# a firstmate home; the fragment is already safe inside a single-quoted
# --settings JSON argument.
fm_claude_md_excludes_json() {
  local spelling dir real home_glob list='' seen=' ' sq="'\\''"
  real=$(cd "$1" 2>/dev/null && pwd -P) || real=$1
  for spelling in "$1" "$real"; do
    dir=${spelling%/}
    while :; do
      dir=${dir%/*}
      [ -n "$dir" ] || break
      case "$seen" in *" $dir "*) continue ;; esac
      if [ -f "$dir/.fm-secondmate-home" ] || { [ -f "$dir/AGENTS.md" ] && [ -f "$dir/bin/fm-spawn.sh" ]; }; then
        seen="$seen$dir "
        # picomatch metacharacters in the home path would change what matches,
        # and the glob then rides inside a JSON string.
        home_glob=$(printf '%s' "$dir" | sed 's/[][\\*?{}()!+@^$|]/\\&/g; s/\\/\\\\/g; s/"/\\"/g')
        list="$list${list:+,}\"$home_glob/CLAUDE.md\",\"$home_glob/CLAUDE.local.md\",\"$home_glob/AGENTS.md\",\"$home_glob/.claude/CLAUDE.md\",\"$home_glob/.claude/rules/**\""
      fi
    done
  done
  [ -n "$list" ] || return 0
  printf ',"claudeMdExcludes":[%s]' "${list//\'/$sq}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  excludes=$1 program=$2
  shift 2
  args=() settings='{}'
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --) args+=("$@"); break ;;
    --settings)
      [ "$#" -ge 2 ] || { printf '%s\n' 'error: --settings requires a value' >&2; exit 1; }
      settings=$2
      shift 2
      ;;
    --settings=*) settings=${1#*=}; shift ;;
    *) args+=("$1"); shift ;;
    esac
  done
  if [ -f "$settings" ]; then
    settings=$(jq -ce 'select(type == "object")' "$settings") || exit 1
  else
    settings=$(printf '%s' "$settings" | jq -ce 'select(type == "object")') || exit 1
  fi
  settings=$(printf '%s' "$settings" | jq -ce --argjson required "$excludes" \
    '.claudeMdExcludes = (((.claudeMdExcludes // []) + $required.claudeMdExcludes) | unique)') || exit 1
  exec "$program" --settings "$settings" "${args[@]}"
fi
