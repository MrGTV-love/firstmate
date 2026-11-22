#!/usr/bin/env bash
# fm-home-write.sh - write one private home-state record under $FM_HOME/data/.
#
# Usage:
#   FM_HOME=<home> fm-home-write.sh [--replace] <path> < <content>
#   fm-home-write.sh --help
#
# Claude Code's background-session worktree guard (worktree.bgIsolation)
# refuses Write and Edit on every path inside an unisolated shared checkout,
# including gitignored data/ records that a linked worktree cannot hold.
# This is the route for those records, and it judges the harm the vendor
# guard protects against directly: it writes only when the resolved target
# is under $FM_HOME/data/, is not tracked by git, is gitignored, is reached
# without symbolic links, '.' or '..' segments, or case variants of an
# existing name, and is a regular file or absent.
# Everything else is refused unchanged: tracked source, force-added files,
# projects/, state/, config/, .env, paths outside the home, and data/ paths a
# gitignore negation un-ignores.
#
# <path> is absolute or relative to $FM_HOME. Content is read from stdin.
# Without --replace an existing file is refused; with it the file is replaced
# atomically and keeps its mode. Missing data/ subdirectories are created.
#
# Exit: 0 written, 2 usage error, 3 refused, 4 refused because FM_HOME, the
# git index or the ignore rules could not be read (fail closed).
# Each decision appends one home-state-write event through fm-guard-event.sh.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 0; }

start=$(now_ms)
if [ -z "${FM_HOME:-}" ]; then
  echo "fm-home-write: refused: FM_HOME is unset; run as FM_HOME=<home> bin/fm-home-write.sh <path>" >&2
  rc=4
else
  python3 -I "$SELF_DIR/fm-home-write.py" --home "$FM_HOME" "$@"
  rc=$?
fi

case "$rc" in
  0) decision=allow source_ok=true ;;
  3) decision=deny source_ok=true ;;
  4) decision=deny source_ok=false ;;
  *) decision=error source_ok=true ;;
esac
elapsed=$(( $(now_ms) - start ))
[ "$elapsed" -ge 0 ] 2>/dev/null || elapsed=0
"$SELF_DIR/fm-guard-event.sh" home-state-write "$decision" --source-ok "$source_ok" --elapsed-ms "$elapsed" 2>/dev/null || true
exit "$rc"
