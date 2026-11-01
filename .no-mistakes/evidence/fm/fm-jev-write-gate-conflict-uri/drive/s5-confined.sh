#!/usr/bin/env bash
# S5: proved-confinement worker. Real omp under the real Seatbelt profile with FM_WRITE_CONFINEMENT=seatbelt-v1.
WT_ROOT=$1; . /Users/charlesabrooker/.no-mistakes/evidence/01M6A4ZJ12RM84AK2CCJBAEXT9/drive/lib.sh
rig_up; trap rig_down EXIT
mkdir -p "$lab/home/projects" "$lab/home/data/native"
( src="$lab/home/projects/proj"; mkdir -p "$src"; cd "$src"; git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  printf 'base\n' > conflicted.txt; git add .; git commit -qm base
  git checkout -qb topic; printf 'topic\n' > conflicted.txt; git commit -qam topic
  git checkout -q main; printf 'main\n' > conflicted.txt; git commit -qam main
  git worktree add -q "$lab/worktree" topic; cd "$lab/worktree"; git rebase main >/dev/null 2>&1 || true; git status --short )
printf 'task=native\n' > "$lab/home/state/native.meta"
printf 'protected-config\n' > "$lab/home/config/victim.txt"
ln -s "$lab/home/config" "$lab/worktree/escape"
sed -i '' 's#data: `${lab}/home/data`#data: `${lab}/home/data/native`#' "$lab/guard.ts"
python3 "$WT_ROOT/bin/fm-write-confinement.py" --worktree "$lab/worktree" --home "$lab/home" --config "$lab/home/config" \
  --projects "$lab/home/projects" --data "$lab/home/data/native" --state "$lab/home/state" --task native --branch topic \
  --harness omp --agent-dir "$lab/agent" --profile "$lab/native.sb" || { echo profile-build-failed; exit 1; }
echo "profile-built=$(wc -l < "$lab/native.sb" | tr -d ' ') lines"
steps=$(python3 -I -c '
import json,sys
lab=sys.argv[1]; c=open(lab+"/worktree/conflicted.txt").read()
print(json.dumps([
 {"tool":"read","args":{"path":"conflicted.txt"}},
 {"tool":"write","args":{"path":"conflict://1","content":"resolved\n"}},
 {"tool":"edit","args":{"path":"conflict://1","old_string":"<<<<<<<","new_string":"x"}},
 {"tool":"edit","args":{"path":"conflicted.txt","old_string":c,"new_string":"resolved\n"}},
 {"tool":"edit","args":{"path":"escape/victim.txt","old_string":"protected-config\n","new_string":"PWNED\n"}},
 {"tool":"edit","args":{"path":lab+"/home/state/native.meta","old_string":"task=native\n","new_string":"PWNED\n"}},
]))' "$lab")
OMP_PREFIX=(env FM_WRITE_CONFINEMENT=seatbelt-v1 /usr/bin/sandbox-exec -f "$lab/native.sb")
run_omp "$steps" read,write,edit -e "$lab/guard.ts"
echo "== what the model saw =="; show
echo "== audit =="; node "$WT_ROOT/bin/fm-jev-audit-read.mjs" "$lab/home/state" 2>&1 | python3 -I -c '
import json,sys
for l in sys.stdin:
    try: r=json.loads(l)
    except Exception: print(l.rstrip()); continue
    if r.get("hook")=="tool_call": print({k:r.get(k) for k in ("tool","decision","enforcement","branch","confinement_owner","refused_path")})'
echo "== after =="; cat "$lab/worktree/conflicted.txt"; echo "config-victim=$(cat "$lab/home/config/victim.txt")"; echo "meta=$(cat "$lab/home/state/native.meta")"
tail -3 "$lab/native.out"
