#!/usr/bin/env bash
# Drive bin/fm-control.sh <task> relaunch for a confined Claude task whose
# Claude config root (HOME/.claude) holds no session folders, then list what
# the relaunch created and the regenerated profile's grants for those folders.
ROOT=$1
cd "$ROOT" || exit 1
# shellcheck disable=SC1091
. tests/fm-control-relaunch-helpers.sh
dir=$(new_case fresh-root rlfresh)
add_ship_task "$dir" rlfresh claude
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rlfresh)
printf 'busy_gen=%s\nclaude_session_id=%s\n' "$gen" 00000000-0000-4000-8000-000000000000 >> "$dir/home/state/rlfresh.meta"
mkdir -p "$dir/user-home"
echo "before relaunch: user-home/.claude exists? $([ -e "$dir/user-home/.claude" ] && echo yes || echo no)"
out=$(run_control "$dir" rlfresh relaunch --note "fresh root relaunch probe"); rc=$?
echo "relaunch rc=$rc"
echo "$out" | grep -E "relaunched|error" | head -5
echo "write_confinement=$(grep '^write_confinement=' "$dir/home/state/rlfresh.meta" | cut -d= -f2)"
sess=$(grep '^claude_session_id=' "$dir/home/state/rlfresh.meta" | cut -d= -f2)
echo "new claude_session_id=$sess"
echo "--- created under user-home/.claude (mode name):"
(cd "$dir/user-home/.claude" && find . -type d | sort | while read -r d; do printf '%s %s\n' "$(stat -f %Lp "$d")" "$d"; done)
wt_real=$(cd "$dir/wt" && pwd -P)
slug=$(printf '%s' "$wt_real" | sed 's/[^A-Za-z0-9]/-/g')
prof="$dir/home/state/rlfresh.write-confinement.sb"
echo "--- profile file-write-create grants:"
grep -o '(allow file-write-create[^\n]*' "$prof" | head
echo "--- confined own-session writes under regenerated profile on the relaunch-created folders:"
c="$dir/user-home/.claude"
other=99999999-8888-4777-8666-555555555555
for id in "$sess" "$other"; do
  for entry in "session-env/$id/probe" "file-history/$id/probe" "tasks/$id/probe" "projects/$slug/$id.jsonl"; do
    if /usr/bin/sandbox-exec -f "$prof" /bin/sh -c 'mkdir -p "$(dirname "$1")" && : >> "$1"' sh "$c/$entry" 2>/dev/null; then r=written; else r=refused; fi
    [ "$id" = "$sess" ] && who=own || who=foreign
    echo "$who $entry -> $r"
  done
done
