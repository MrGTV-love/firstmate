export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.rDLW52 TMUX_TMPDIR=/tmp/fml.nwNMvh
W=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M8ANFT7017QY5MVCBFVGZS9B
E=/Users/charlesabrooker/.no-mistakes/evidence/01M8ANFT7017QY5MVCBFVGZS9B
FX=$(cat $E/.fx-path); TASK=$(cat $E/.task-id); SUCC=fm/$TASK-v2; OLD=fm/$TASK
cd "$W"
fpall() { # one digest line per area
  for a in "$FM_HOME/state" "$FM_HOME/data" "$FX/slots/22/project" "$FX/project" "$FX/gate.git"; do
    printf '%s %s\n' "$(python3 -I -c '
import hashlib,os,sys
r=sys.argv[1];h=hashlib.sha256()
for b,ds,fs in os.walk(r):
  ds.sort()
  for n in sorted(fs):
    p=os.path.join(b,n)
    if n.endswith(".jsonl") and "guard-events" in n: continue
    h.update(os.path.relpath(p,r).encode())
    if os.path.islink(p): h.update(os.readlink(p).encode()); continue
    h.update(open(p,"rb").read())
print(h.hexdigest()[:16])' "$a")" "${a#$FX/}"
  done
}
fmc() { bash "$W/bin/fm-control.sh" "$@"; }
