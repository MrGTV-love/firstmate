#!/usr/bin/env bash
# Control: does the base guard (before this change) also pass a symlinked in-tree path on an unconfined worker?
WT_ROOT=$1; . /Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9/drive/lib.sh
rig_up; outside=$(mktemp -d "$E/drive/outside.XXXXXX"); trap 'rm -rf -- "$outside"; rig_down' EXIT; mk_conflict
printf 'victim\n' > "$outside/t.txt"; ln -s "$outside" "$lab/worktree/escape"
run_omp '[{"tool":"edit","args":{"path":"escape/t.txt","old_string":"victim\n","new_string":"PWNED\n"}}]' read,write,edit -e "$lab/guard.ts"
show; audit; echo "victim-after=$(cat "$outside/t.txt")"
