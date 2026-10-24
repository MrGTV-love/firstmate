#!/usr/bin/env bash
# Disposable lab for bin/fm-copy-sweep.sh with Vernant's REAL closeout driver.
# Source me. Needs WT (the gate worktree) and LAB (a canonical mktemp dir).
VSLOT=$HOME/.treehouse/vernant-2ee7ec/102/vernant   # read-only source of the real driver + interpreter
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
new_world() {  # <name>: sets W HOMED TH SLOT
  W=$LAB/$1; HOMED=$W/home; TH=$W/th; SLOT=$TH/pool1/1/repo
  mkdir -p "$W" "$TH/pool1/1"
  "$WT/bin/fm-lab-home.sh" create "$HOMED" >/dev/null
  git init -q -b main --bare "$W/origin.git"
  git init -q -b main "$SLOT"
  printf 'base\n' > "$SLOT/README.md"
  git -C "$SLOT" add README.md; git -C "$SLOT" commit -qm base
  git -C "$SLOT" remote add origin "$W/origin.git"
  git -C "$SLOT" push -q -u origin main
  git -C "$VSLOT" archive HEAD scripts | tar -x -C "$SLOT"
  printf '%s\n' scripts/ .claude/ >> "$SLOT/.git/info/exclude"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
}
dead_pid() { sleep 0.05 & local p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p"; }
cp_of() { printf '%s\n' "$SLOT/.claude/worktrees/$1"; }
add_copy() {  # <name> <merged|pushed|unpushed> <launcher-pid>
  local name=$1 kind=$2 pid=$3 copy; copy=$(cp_of "$1")
  git -C "$SLOT" worktree add -q -b "fm/$name" "$copy"
  printf '%s\n' "$name" > "$copy/$name.txt"
  git -C "$copy" add "$name.txt"; git -C "$copy" commit -qm "$name"
  case "$kind" in
    merged)
      git -C "$copy" push -q origin "fm/$name"
      git -C "$SLOT" fetch -q origin "fm/$name"
      git -C "$SLOT" merge -q --no-ff -m "Merge PR $name" FETCH_HEAD
      git -C "$SLOT" push -q origin main ;;
    pushed) git -C "$copy" push -q origin "fm/$name" ;;
    unpushed) ;;
  esac
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$copy"
}
sweep() {  # [args...]: the gate worktree's real sweep, against this world only
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" PYTHONDONTWRITEBYTECODE=1 \
    FM_TEARDOWN_VERNANT_PYTHON="$VSLOT/.venv/bin/python" \
    "$WT/bin/fm-copy-sweep.sh" "$@"
}
state() {  # what is on disk now
  echo "--- worktrees:"; git -C "$SLOT" worktree list --porcelain | grep -E '^(worktree|locked)' | sed "s|$LAB|\$LAB|g"
  echo "--- data/copy-sweep:"; (cd "$HOMED/data" 2>/dev/null && find copy-sweep copy-sweep.log -print 2>/dev/null | sort)
}
