#!/usr/bin/env bash
# Live-lab driver helpers for the fm-relaunch-own-slot-manifest-and-scope test step.
# Real bin/fm-control.sh and bin/fm-spawn.sh from the run worktree, a marked lab FM_HOME
# (bin/fm-lab-home.sh), a private tmux server on the fm-lab socket, real git repos in a
# scratch dir, and a create-only fixture provisioner (the real Vernant provisioner is not
# available here). Every lifecycle call runs inside a pane on the lab tmux socket.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M873RS5NM0W8CR67ZQ68G8YG
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M873RS5NM0W8CR67ZQ68G8YG
ENVF=$EV/.lab-env.sh
[ -f "$ENVF" ] && . "$ENVF"

lab_up() {
  cd "$WT" || return 1
  eval "$(bin/fm-lab-home.sh env 2>"$EV/.lab-env.stderr")"
  SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-scr.XXXXXX")
  SCR=$(cd "$SCR" && pwd -P)
  {
    echo "export FM_HOME='$FM_HOME'"
    echo "export TMUX_TMPDIR='$TMUX_TMPDIR'"
    echo "SCR='$SCR'"
  } > "$ENVF"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    tmux -L fm-lab new-session -d -s fmses -n ctl -c "$SCR" -e FM_HOME="$FM_HOME" bash --norc --noprofile
}

# lab <name> <command...>: run a command in a fresh window of the lab tmux session, wait, print its output.
lab() {
  local name=$1 out rc i
  shift
  out="$SCR/run-$name.out"
  rm -f "$out" "$out.rc"
  printf '%s\n' "$*" > "$SCR/run-$name.cmd"
  tmux -L fm-lab new-window -d -t fmses -n "run-$name" -c "$WT" \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$FM_HOME' bash --norc --noprofile -c '. $SCR/run-$name.cmd' > '$out' 2>&1; echo \$? > '$out.rc'"
  for i in $(seq 1 900); do [ -s "$out.rc" ] && break; sleep 1; done
  rc=$(cat "$out.rc" 2>/dev/null || echo timeout)
  cat "$out"
  echo "[exit $rc]"
}

# Worker window fm-<id> running a plain shell: a dead worker after a reboot.
dead_window() { tmux -L fm-lab new-window -d -t fmses -n "fm-$1" -c "$2" bash --norc --noprofile; }

git_q() { git -c user.name=Tests -c user.email=tests@example.invalid "$@"; }

# write_provisioner <repo> <manifest> <sentinel>: create-only, counts runs, read-only --check-manifest-only.
write_provisioner() {
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<PY
import argparse, json, os, sys
from pathlib import Path
MANIFEST = Path("$2")
SENTINEL = "$3"
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
p.add_argument("--check-manifest-only", action="store_true")
a = p.parse_args()
if a.check_manifest_only:
    refused = MANIFEST.exists()
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "manifest_path": str(MANIFEST)} if refused else {"state": "PASS"}))
    raise SystemExit(2 if refused else 0)
with open(SENTINEL, "a", encoding="utf-8") as s:
    s.write(json.dumps(sys.argv[1:]) + "\n")
if MANIFEST.exists():
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "blocked_reasons": ["manifest_exists"], "manifest_path": str(MANIFEST)}))
    raise SystemExit(2)
record = dict(worktree_path=os.path.realpath(a.worktree_path), owner_id=a.owner_id, branch=a.branch,
              base_sha=a.base_sha, owned_paths=a.owned_path, lifecycle_state="worktree_active",
              repo_root=os.path.realpath(a.repo_root))
MANIFEST.write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(MANIFEST), **record)))
PY
}

# make_case <id> <with-manifest 0|1> <scope...>: project + origin + copy on fm/<id>, a task record, a dead window.
# Sets C (case dir), P (project), K (copy), M (manifest), S (sentinel), META.
make_case() {
  local id=$1 with=$2 base p
  shift 2
  C=$SCR/$id; P=$C/proj; K=$C/copy; M=$C/manifests/$id.json; S=$C/provisioner.called
  META=$FM_HOME/state/$id.meta
  mkdir -p "$C/manifests" "$P/src" "$FM_HOME/data/$id"
  : > "$S"
  git -C "$P" init -q -b main
  printf 'owned\n' > "$P/src/owned.txt"; printf 'docs\n' > "$P/docs.txt"
  write_provisioner "$P" "$M" "$S"
  git -C "$P" add -A; git_q -C "$P" commit -qm 'project with provisioner'
  git init -q --bare "$C/origin.git"
  git -C "$P" remote add origin "$C/origin.git"; git -C "$P" push -q origin main
  git -C "$P" fetch -q origin
  git -C "$P" worktree add -q -b "fm/$id" "$K" main
  git -C "$K" update-ref refs/remotes/origin/main "$(git -C "$P" rev-parse HEAD)"
  base=$(git -C "$K" rev-parse HEAD)
  cat > "$FM_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Live lab check of a relaunch for $id. Do nothing. Do not edit any file. Reply with one word and stop.

## Firstmate spec
Do nothing.
EOF
  {
    echo "window=fmses:fm-$id"; echo "endpoint_task_id=$id"; echo "worktree=$K"; echo "project=$P"
    echo "harness=codex"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "tasktmp=/tmp/fm-$id"
    echo "model=default"; echo "effort=default"; echo "branch=fm/$id"
  } > "$META"
  if [ "$with" = 1 ]; then
    local args=()
    for p in "$@"; do args+=(--owned-path "$p"); done
    python3 "$P/scripts/git-stability/provision_existing_slot.py" --repo-root "$P" --worktree-path "$K" \
      --owner-id "$id" --branch "fm/$id" --base-sha "$base" "${args[@]}" >/dev/null || { echo 'first provisioning failed'; return 1; }
    : > "$S"
    { echo "slot_manifest=$M"; echo "slot_base_sha=$base"; } >> "$META"
  fi
  for p in "$@"; do echo "slot_owned_path=$p" >> "$META"; done
  dead_window "$id" "$K"
}

inventory() { # <file...>: inode, size, sha256, mtime/ctime ns of each file
  python3 - "$@" <<'PY'
import hashlib, os, sys
for p in sys.argv[1:]:
    if not os.path.exists(p):
        print(p, "absent"); continue
    i = os.lstat(p)
    print(p, "ino=%d size=%d sha=%s mtime=%d ctime=%d" % (i.st_ino, i.st_size, hashlib.sha256(open(p,'rb').read()).hexdigest()[:16], i.st_mtime_ns, i.st_ctime_ns))
PY
}

agent_state() { # <id>
  lab "state-$1" ". bin/backends/tmux.sh 2>/dev/null || true; . bin/fm-backend.sh; fm_backend_agent_state tmux fmses:fm-$1; echo" | head -1
}

lab_down() {
  tmux -L fm-lab kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"
  rm -rf "$SCR"
  rm -f "$ENVF"
}
