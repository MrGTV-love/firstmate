#!/usr/bin/env bash
# S1: the incident. Real omp reads a conflicted file, hits conflict://N, is refused, follows the remedy, finishes the rebase.
WT_ROOT=$1; . /Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9/drive/lib.sh
rig_up; trap rig_down EXIT; mk_conflict
echo "omp=$(omp --version) guard-tree=$(git -C "$WT_ROOT" rev-parse --short HEAD 2>/dev/null || echo archive)"
echo "== before =="; git -C "$lab/worktree" status --short; cat "$lab/worktree/conflicted.txt"
steps=$(python3 -I -c '
import json,sys
lab=sys.argv[1]
print(json.dumps([
 {"tool":"read","args":{"path":"conflicted.txt"}},
 {"tool":"write","args":{"path":"conflict://1","content":"resolved\n"}},
 {"tool":"write","args":{"path":"conflict://4","content":"resolved\n"}},
 {"tool":"edit","args":{"path":"conflict://1","old_string":"<<<<<<<","new_string":"resolved"}},
 {"tool":"write","args":{"path":"[conflict://1#ABCD]","content":"resolved\n"}},
 {"tool":"edit","args":{"path":"conflicted.txt","old_string":open(lab+"/worktree/conflicted.txt").read(),"new_string":"resolved\n"}},
 {"tool":"edit","args":{"path":lab+"/worktree/second.txt","old_string":open(lab+"/worktree/second.txt").read(),"new_string":"resolved2\n"}},
 {"tool":"bash","args":{"command":"git add conflicted.txt second.txt && GIT_EDITOR=true git rebase --continue && git status && git log --oneline"}},
]))' "$lab")
run_omp "$steps" read,write,edit,bash -e "$lab/guard.ts"
echo "== what the model saw =="; show
echo "== audit =="; audit
echo "== after =="; git -C "$lab/worktree" status | head -5; git -C "$lab/worktree" log --oneline; cat "$lab/worktree/conflicted.txt" "$lab/worktree/second.txt"
echo "markers-left=$(grep -l '<<<<<<<' "$lab/worktree/conflicted.txt" "$lab/worktree/second.txt" | wc -l | tr -d ' ') jev-requests=$(wc -l < "$lab/jev.jsonl" | tr -d ' ')"
echo "== native output tail =="; tail -3 "$lab/native.out"
