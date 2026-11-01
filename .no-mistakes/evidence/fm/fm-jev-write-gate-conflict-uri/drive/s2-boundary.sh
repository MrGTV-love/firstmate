#!/usr/bin/env bash
# S2: adversarial. The remedy must not widen reach: outside paths, traversal, symlink out, and non-conflict URIs.
WT_ROOT=$1; . /Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9/drive/lib.sh
rig_up; trap 'rm -rf -- "$outside"; rig_down' EXIT; mk_conflict
outside="$E/drive/outside-copy"; rm -rf -- "$outside"; mkdir -p "$outside"
printf '<<<<<<< HEAD\nvictim\n=======\nother\n>>>>>>> x\n' > "$outside/conflicted.txt"
ln -s "$outside" "$lab/worktree/escape"
victim=$(cat "$outside/conflicted.txt")
steps=$(python3 -I -c '
import json,sys,os
lab,out=sys.argv[1:3]; v=open(out+"/conflicted.txt").read()
rel=os.path.relpath(out+"/conflicted.txt",lab+"/worktree")
e=lambda p:{"tool":"edit","args":{"path":p,"old_string":v,"new_string":"PWNED\n"}}
w=lambda p:{"tool":"write","args":{"path":p,"content":"PWNED\n"}}
print(json.dumps([e(out+"/conflicted.txt"),w(out+"/conflicted.txt"),e(rel),w(rel),e("escape/conflicted.txt"),w("escape/conflicted.txt"),e("/etc/conflicted.txt"),
  e("ssh://remote/file"),w("ssh://remote/file"),w("agent://x"),w("cfg://y"),
  e("conflict://999999"),w("conflict://*"),w("CONFLICT://1"),w("conflict://1 "),w("[conflict://1#ABCD]  "),w("conflict://../../etc/x")]))' "$lab" "$outside")
run_omp "$steps" read,write,edit -e "$lab/guard.ts"
echo "== what the model saw =="; show
echo "== audit =="; audit
echo "== victim file after =="; cat "$outside/conflicted.txt"
[ "$(cat "$outside/conflicted.txt")" = "$victim" ] && echo victim-unchanged=yes || echo victim-unchanged=NO
[ -e /etc/conflicted.txt ] && echo etc-created=YES || echo etc-created=no
echo "tree-markers=$(grep -l '<<<<<<<' "$lab/worktree/conflicted.txt" | wc -l | tr -d ' ') jev-requests=$(wc -l < "$lab/jev.jsonl" | tr -d ' ')"
tail -2 "$lab/native.out"
