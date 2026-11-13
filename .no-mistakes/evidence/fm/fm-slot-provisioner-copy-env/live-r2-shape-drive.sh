#!/usr/bin/env bash
# Independent live drive of the real firstmate scripts against a disposable
# r2-shaped world: a home whose nested project clone has NO .venv, and a
# provisioned copy whose own .venv holds a stand-in "pydantic" package.
# The provisioner lives in the copy and imports worktree_liveness, which imports
# pydantic (the shape of the Mac mini failure).
# Usage: live-r2-shape-drive.sh <firstmate-root> <scratch-dir>
set -u
ROOT=$1 W=$2
PY=$(/opt/homebrew/bin/python3 -c 'import sys; print(sys.executable)')
rm -rf "$W"; mkdir -p "$W"
say() { printf '\n### %s\n' "$*"; }
g() { git -c user.name=Lab -c user.email=lab@example.invalid "$@"; }

make_world() { # <name> <venv: yes|no>
  local d=$W/$1
  mkdir -p "$d/home/projects" "$d/treehouse"
  g init -q -b main "$d/home/projects/vernant"
  local p=$d/home/projects/vernant
  mkdir -p "$p/scripts/git-stability"
  cat > "$p/scripts/git-stability/worktree_liveness.py" <<'PY'
import pydantic  # line 61 in the real file; only the copy's venv has it
PY
  cat > "$p/scripts/git-stability/provision_existing_slot.py" <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
print("provisioner sys.executable =", sys.executable, file=open(os.environ["LAB_DIAG"], "a"))
print("provisioner VIRTUAL_ENV    =", os.environ.get("VIRTUAL_ENV"), file=open(os.environ["LAB_DIAG"], "a"))
print("provisioner PYTHONPATH     =", os.environ.get("PYTHONPATH"), file=open(os.environ["LAB_DIAG"], "a"))
print("provisioner PATH head      =", os.environ["PATH"].split(":")[0], file=open(os.environ["LAB_DIAG"], "a"))
print("provisioner LAB_SENTINEL   =", os.environ.get("LAB_SENTINEL"), file=open(os.environ["LAB_DIAG"], "a"))
import worktree_liveness  # noqa
import argparse
a = argparse.ArgumentParser()
for f in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    a.add_argument("--" + f, required=True)
a.add_argument("--owned-path", action="append", required=True)
a.add_argument("--base-source")
x = a.parse_args()
rec = dict(worktree_path=os.path.realpath(x.worktree_path), owner_id=x.owner_id, branch=x.branch,
           base_sha=x.base_sha, owned_paths=x.owned_path, lifecycle_state="worktree_active")
m = Path(os.environ["LAB_MANIFEST"]); m.write_text(json.dumps(rec))
print(json.dumps(dict(state="PASS", manifest_path=str(m), **rec)))
PY
  g -C "$p" add . && g -C "$p" commit -qm provisioner
  g init -q --bare "$d/origin.git"
  g -C "$p" remote add origin "$d/origin.git" && g -C "$p" push -q origin main && g -C "$p" fetch -q origin
  printf '.venv\n' >> "$p/.git/info/exclude"
  g -C "$p" worktree add -q --detach "$d/treehouse/88" HEAD
  if [ "$2" = yes ]; then
    "$PY" -m venv --without-pip "$d/treehouse/88/.venv"
    site=$("$d/treehouse/88/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
    mkdir -p "$site/pydantic" && printf 'VERSION = "2.12.5-labstub"\n' > "$site/pydantic/__init__.py"
  fi
  # decoy venv for the ambient VIRTUAL_ENV, with a tool only it holds
  mkdir -p "$d/decoy/bin"; printf 'home = /x\n' > "$d/decoy/pyvenv.cfg"
  ln -s "$PY" "$d/decoy/bin/python3"; ln -s "$PY" "$d/decoy/bin/python"
  echo "$d"
}

provision() { # <world> [extra env]
  local d=$1; shift
  env -i HOME="$d/home" TMPDIR="$d" PATH="/usr/bin:/bin" LAB_MANIFEST="$d/manifest.json" LAB_DIAG="$d/diag.txt" \
    LAB_SENTINEL=kept FM_HOME="$d/home" FM_STATE_OVERRIDE="$d/home/state" FM_ROOT_DIR="$ROOT" "$@" \
    bash -c '
      . "$FM_ROOT_DIR/bin/fm-wake-lib.sh"; . "$FM_ROOT_DIR/bin/fm-secondmate-parent-lib.sh"
      . "$FM_ROOT_DIR/bin/fm-secondmate-registry-lib.sh"; . "$FM_ROOT_DIR/bin/fm-task-copy-lib.sh"
      . "$FM_ROOT_DIR/bin/fm-slot-provision-lib.sh"
      fm_slot_provision fm_slot_run_local "$1" "$2" lab-task fm/lab-task "$3" "" "" scripts
    ' bash "$d/home/projects/vernant" "$d/treehouse/88" "$d/report.json"
}

say "A. r2 shape: nested clone has no .venv, copy 88 has its own .venv (pydantic stub). Promote-path runner."
d=$(make_world a yes)
ls -a "$d/home/projects/vernant" | tr '\n' ' '; echo " <- clone entries (no .venv)"
provision "$d" VIRTUAL_ENV="$d/decoy" PATH="$d/decoy/bin:/usr/bin:/bin" PYTHONPATH=/polluted/pythonpath
echo "exit=$?"; echo "--- what the provisioner saw (side file):"; cat "$d/diag.txt"; echo "--- provisioner report:"; cat "$d/report.json"
echo "--- copy branch now: $(git -C "$d/treehouse/88" rev-parse --abbrev-ref HEAD)"; echo "--- slot manifest: $(cat "$d/manifest.json" 2>/dev/null || echo none)"
echo "--- clone .venv exists after run? $( [ -e "$d/home/projects/vernant/.venv" ] && echo YES || echo no)"

say "B. Copy with NO .venv: refused by name before any change"
d=$(make_world b no)
before_head=$(git -C "$d/treehouse/88" rev-parse HEAD); before_ref=$(git -C "$d/treehouse/88" symbolic-ref -q HEAD || echo detached)
before_list=$(cd "$d" && find home/projects treehouse -print | LC_ALL=C sort)
provision "$d"; echo "exit=$?"
echo "--- HEAD unchanged? $( [ "$(git -C "$d/treehouse/88" rev-parse HEAD)" = "$before_head" ] && echo yes || echo NO)  ref: $before_ref -> $(git -C "$d/treehouse/88" symbolic-ref -q HEAD || echo detached)"
echo "--- task branch fm/lab-task created? $(git -C "$d/treehouse/88" rev-parse -q --verify refs/heads/fm/lab-task >/dev/null && echo YES || echo no)"
after_list=$(cd "$d" && find home/projects treehouse -print | LC_ALL=C sort)
echo "--- full listing of copy+clone (ignored files and .git included) unchanged? $( [ "$before_list" = "$after_list" ] && echo yes || echo NO)"
echo "--- report file written? $( [ -e "$d/report.json" ] && echo YES || echo no)"

say "C. Copy .venv is a symlink to another tree's venv: refused by name"
d=$(make_world c no)
mkdir -p "$d/othertree"; "$PY" -m venv --without-pip "$d/othertree/.venv"; ln -s "$d/othertree/.venv" "$d/treehouse/88/.venv"
provision "$d"; echo "exit=$?"

say "D. bin/fm-copy-env.sh CLI after the review decision"
"$ROOT/bin/fm-copy-env.sh" check "$W/a/treehouse/88" 2>&1 | head -3; echo "check exit=${PIPESTATUS[0]}"
"$ROOT/bin/fm-copy-env.sh" run "$W/a/treehouse/88" --python "$PY" -- -c 'print(1)' 2>&1 | head -2; echo "run --python exit=${PIPESTATUS[0]}"
env -i PATH=/usr/bin:/bin VIRTUAL_ENV=/decoy PYTHONHOME=/bogus "$ROOT/bin/fm-copy-env.sh" run "$W/a/treehouse/88" -- -c 'import os,sys; print("run ->", sys.executable, os.environ.get("VIRTUAL_ENV"), os.environ.get("PYTHONHOME"))'; echo "run exit=$?"
"$ROOT/bin/fm-copy-env.sh" run "$W/b/treehouse/88" -- -c 'print(1)'; echo "run on copy with no venv exit=$?"
