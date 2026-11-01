#!/usr/bin/env bash
# S0: failing-before control on the base commit guard, and a no-guard control showing conflict://N is a real omp target.
WT_ROOT=$1; . /Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9/drive/lib.sh
rig_up; trap rig_down EXIT; mk_conflict
echo "guard-tree=$(cat "$WT_ROOT/.base-id" 2>/dev/null)"
steps='[{"tool":"read","args":{"path":"conflicted.txt"}},{"tool":"write","args":{"path":"conflict://1","content":"resolved\n"}},{"tool":"write","args":{"path":"conflict://4","content":"resolved\n"}}]'
run_omp "$steps" read,write,edit -e "$lab/guard.ts"
echo "== base guard: model saw =="; show
echo "== base guard: audit =="; audit
echo "markers-left=$(grep -c '<<<<<<<' "$lab/worktree/conflicted.txt")"
mk_conflict
steps='[{"tool":"read","args":{"path":"conflicted.txt"}},{"tool":"write","args":{"path":"conflict://1","content":"resolved-by-omp-handler\n"}}]'
run_omp "$steps" read,write,edit
echo "== NO guard control: model saw =="; show
echo "== NO guard control: file =="; cat "$lab/worktree/conflicted.txt"; git -C "$lab/worktree" status --short
