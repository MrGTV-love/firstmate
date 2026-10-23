#!/usr/bin/env bash
# Live drive of bin/fm-copy-sweep.sh: real git, real lsof/du/nice, a disposable
# lab FM_HOME and a disposable Treehouse root. Only Vernant's closeout driver is a
# stand-in (python3 script at the slot's scripts/git-stability/closeout_pr.py).
# A pass-through git wrapper logs every git call the sweep makes (no behavior change).
set -u
REPO=$1; MODE=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-sweep-world.XXXXXX")
TH=$W/th; SLOT=$TH/pool1/1/repo; CTL=$W/ctl; LOGB=$W/bin
mkdir -p "$TH/pool1/1" "$CTL" "$LOGB"
REAL_GIT=$(command -v git)
cat > "$LOGB/git" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\${DRIVER_CALL:-sweep}" "\$*" >> "$W/git-calls.log"
exec "$REAL_GIT" "\$@"
SH
chmod +x "$LOGB/git"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
git init -q -b main "$SLOT"; echo base > "$SLOT/README"; git -C "$SLOT" add README; git -C "$SLOT" commit -qm base
git init -q --bare "$W/origin.git"; git -C "$SLOT" remote add origin "$W/origin.git"; git -C "$SLOT" push -q origin main; git -C "$SLOT" fetch -q origin
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
EXCL=$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)
printf 'scripts/\n.venv/\n*.log\nnode_modules/\n' >> "$EXCL"
mkdir -p "$SLOT/scripts/git-stability"
cat > "$SLOT/scripts/git-stability/closeout_pr.py" <<PY
# Stand-in for Vernant's closeout driver: same CLI, JSON verdict, own unlock+remove.
import json, os, shutil, subprocess, sys
args = sys.argv[1:]
copy = args[args.index("--cleanup-worktree") + 1]
execute = "--execute-cleanup" in args
name = os.path.basename(copy)
ctl = "$CTL"
with open("$W/driver-calls.log", "a") as f:
    f.write("%s\t%s\t%s\tgit=%s\n" % (os.getcwd(), name, "execute" if execute else "plan", shutil.which("git")))
env = dict(os.environ, DRIVER_CALL="driver")
def has(k): return os.path.exists(os.path.join(ctl, name + "." + k))
if not execute:
    if has("plan-refuse"):
        print(json.dumps({"allowed": False, "reason": "pull_request_not_merged"})); sys.exit(3)
    print(json.dumps({"allowed": True})); sys.exit(0)
if has("exec-temp"):
    print(json.dumps({"allowed": False, "reason": "cleanup_skipped_live_or_unknown"})); sys.exit(3)
if has("exec-perm"):
    print(json.dumps({"allowed": False, "reason": "cleanup_policy_not_allowed"})); sys.exit(3)
subprocess.check_call(["git", "worktree", "unlock", copy], env=env)
subprocess.check_call(["git", "worktree", "remove", copy], env=env)
print(json.dumps({"allowed": True, "removed": copy}))
PY
add_copy() {
  local name=$1 c=$SLOT/.claude/worktrees/$1
  git -C "$SLOT" worktree add -q -b "fm/$name" "$c"
  echo "$name" > "$c/$name.txt"; git -C "$c" add "$name.txt"; git -C "$c" commit -qm "$name"; git -C "$c" push -q origin "fm/$name"
}
dead_pid() { sleep 0.05 & local p=$!; wait "$p"; echo "$p"; }
lock_dead() { local p; p=$(dead_pid); git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$p launcher=$p" "$SLOT/.claude/worktrees/$1"; }
sweep() {
  ( cd "$REPO" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LOGB:$PATH" FM_HOME="$LAB" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" FM_TEARDOWN_VERNANT_PYTHON="$(command -v python3)" \
    bin/fm-copy-sweep.sh "$@" ); 
}
show() { echo "\$ fm-copy-sweep.sh $*"; sweep "$@" 2>&1 | sed "s#$W#<world>#g; s#$LAB#<labhome>#g"; echo "[exit ${PIPESTATUS[0]}]"; }
lockfile() { git -C "$SLOT/.claude/worktrees/$1" rev-parse --absolute-git-dir 2>/dev/null | sed 's#$#/locked#'; }
state() {
  echo "--- state"
  for n in "$@"; do c=$SLOT/.claude/worktrees/$n
    if [ -e "$c" ]; then l=$(lockfile "$n"); printf '%s: on disk; lock=%s\n' "$n" "$( [ -f "$l" ] && cat "$l" || echo none)"; else echo "$n: GONE"; fi
  done
  echo "worktree list:"; git -C "$SLOT" worktree list | sed "s#$W#<world>#g"
  echo "driver calls:"; sed "s#$W#<world>#g" "$W/driver-calls.log" 2>/dev/null; : > "$W/driver-calls.log"
  echo "receipts:"; ls "$LAB/data/copy-sweep/retained" 2>/dev/null
  echo "preserved files:"; find "$LAB/data/copy-sweep" -path '*nested-copy-preserved*' -type f 2>/dev/null | sed "s#$LAB#<labhome>#g"
  echo "copy-sweep.log:"; sed "s#$W#<world>#g" "$LAB/data/copy-sweep.log" 2>/dev/null
  echo "git calls logged: $(wc -l < "$W/git-calls.log" | tr -d ' ') total; sweep git calls touching lock/unlock/force/prune: $(awk -F '\t' '$1 == "sweep"' "$W/git-calls.log" | grep -cE 'unlock| lock |--force| -f |prune')"
  echo "driver git calls:"; awk -F '\t' '$1 == "driver"' "$W/git-calls.log" 2>/dev/null | sed "s#$W#<world>#g"; : > "$W/git-calls.log"
  echo
}
case "$MODE" in
mixed)
  add_copy deadlock; lock_dead deadlock
  mkdir -p "$SLOT/.claude/worktrees/deadlock/node_modules/pkg"; head -c 64000000 /dev/urandom > "$SLOT/.claude/worktrees/deadlock/node_modules/pkg/blob.bin"
  echo "channel outbox line" > "$SLOT/.claude/worktrees/deadlock/outbox.log"
  add_copy livelock; (cd "$W" && exec sleep 300) & LIVE=$!
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$LIVE launcher=$LIVE" "$SLOT/.claude/worktrees/livelock"
  add_copy planrefused; lock_dead planrefused; : > "$CTL/planrefused.plan-refuse"
  add_copy unpushed; echo x > "$SLOT/.claude/worktrees/unpushed/local.txt"; git -C "$SLOT/.claude/worktrees/unpushed" add local.txt; git -C "$SLOT/.claude/worktrees/unpushed" commit -qm local; lock_dead unpushed
  add_copy foreign; git -C "$SLOT" worktree lock --reason 'hand-held by an operator' "$SLOT/.claude/worktrees/foreign"
  add_copy plain
  : > "$W/git-calls.log"
  show; state deadlock livelock planrefused unpushed foreign plain
  show --apply; state deadlock livelock planrefused unpushed foreign plain
  show --apply; state deadlock livelock planrefused unpushed foreign plain
  kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
  ;;
temporary)
  add_copy tmp; lock_dead tmp; echo "channel outbox line" > "$SLOT/.claude/worktrees/tmp/outbox.log"; : > "$CTL/tmp.exec-temp"
  : > "$W/git-calls.log"
  echo "== run 1 (driver execute says cleanup_skipped_live_or_unknown)"; show --apply; state tmp
  echo "== run 2 (same temporary refusal)"; show --apply; state tmp
  rm -f "$CTL/tmp.exec-temp"
  echo "== run 3 (driver now allows)"; show --apply; state tmp
  ;;
permanent)
  add_copy perm; lock_dead perm; : > "$CTL/perm.exec-perm"
  : > "$W/git-calls.log"
  echo "== run 1 (driver execute refuses: cleanup_policy_not_allowed)"; show --apply; state perm
  echo "== run 2"; show --apply; state perm
  echo "== report run"; show; state perm
  ;;
esac
rm -rf "$LAB" "$W"
echo "lab and world removed: $( [ -e "$LAB" ] || [ -e "$W" ] && echo NO || echo yes)"
