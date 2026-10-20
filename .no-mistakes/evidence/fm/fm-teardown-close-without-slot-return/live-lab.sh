#!/usr/bin/env bash
# Live lab for the held-copy teardown change.
# Drives the REAL bin/fm-teardown.sh from the run worktree against:
#   - a disposable marked FM_HOME (bin/fm-lab-home.sh create), stock layout,
#   - real git (bare origin + project clone + linked worktrees),
#   - the REAL treehouse binary on a private pool (TREEHOUSE_ROOT in the lab),
#   - real lsof and real tasks-axi (backlog).
# Only the external-service / fleet-facing commands are shadowed on PATH:
# tmux, herdr, cmux, zellij, gh, gh-axi, no-mistakes, docker (so no real fleet
# pane, GitHub or Docker object can be touched).
# Usage: live-lab.sh <scenario> ; prints a transcript. Each scenario mints its
# own lab and removes it at the end.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BGXW5YY43YYE22GWDGR36G
TD_ROOT=${TD_ROOT:-$WT}
TEARDOWN=$TD_ROOT/bin/fm-teardown.sh

say() { printf '\n### %s\n' "$*"; }
chk() { # <label> <cmd...>
  local label=$1; shift
  if "$@"; then printf 'CHECK PASS: %s\n' "$label"; else printf 'CHECK FAIL: %s\n' "$label"; FAILS=$((FAILS + 1)); fi
}
FAILS=0

mk_lab() { # <name>: sets LAB, FAKEBIN, PROJ, ORIGIN, SLOT
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  LAB=$(cd "$LAB" && pwd -P)
  (cd "$WT" && bin/fm-lab-home.sh create "$LAB" >/dev/null) || { echo "lab create failed"; exit 99; }
  mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/work"
  touch "$LAB/state/.last-watcher-beat"
  FAKEBIN=$LAB/fakebin
  for c in tmux herdr cmux zellij no-mistakes docker; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$c"
    chmod +x "$FAKEBIN/$c"
  done
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2; exit 1
SH
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
  ORIGIN=$LAB/work/origin.git
  PROJ=$LAB/work/project
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN" "$LAB/work/_seed" 2>/dev/null
  git -C "$LAB/work/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$LAB/work/_seed" push -q origin HEAD:main
  rm -rf "$LAB/work/_seed"
  git clone -q "$ORIGIN" "$PROJ"
  git -C "$PROJ" remote set-head origin main 2>/dev/null || true
  git -C "$PROJ" config user.email t@t
  git -C "$PROJ" config user.name t
  export TREEHOUSE_ROOT=$LAB/pool
  export TREEHOUSE_LEASE_HOLDER=task-x1
}

# take_slot [plain|lease]: the real treehouse hands out slot 1 for the task.
# lease  = treehouse get --lease (durable lease, holder task-x1)
# plain  = a plain treehouse get (process lease only; the state records the slot
#          unleased once the worker's shell has gone), as a crewmate's spawn leaves it.
# Then the slot claim is written with the product's own fm_treehouse_slot_owner_claim.
take_slot() {
  local how=${1:-lease}
  if [ "$how" = lease ]; then
    SLOT=$(cd "$PROJ" && treehouse get --lease --no-fetch -b fm/task-x1 --lease-holder task-x1 2>/dev/null)
  else
    (cd "$PROJ" && SHELL=/usr/bin/true treehouse get --no-fetch -b fm/task-x1 </dev/null >/dev/null 2>&1)
    SLOT=$(jq -r '.worktrees[0].path' "$(pool_state_file)")
  fi
  SLOT=$(cd "$SLOT" && pwd -P)
  (. "$WT/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$SLOT" task-x1 "$LAB") || echo "slot claim failed"
}
pool_state_file() { ls "$LAB"/pool/.treehouse/*/treehouse-state.json 2>/dev/null | head -1; }

# land_own: the task's own work is committed, pushed and merged into origin/main.
land_own() {
  printf 'task work\n' > "$SLOT/feature.txt"
  git -C "$SLOT" add feature.txt
  git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q -m 'task work'
  git -C "$SLOT" push -q origin HEAD:refs/heads/fm/task-x1
  git -C "$SLOT" push -q origin HEAD:main
  git -C "$PROJ" fetch -q origin
}

write_meta() { # [mode]
  local mode=${1:-local-only}
  mkdir -p "$LAB/state" "$LAB/data"
  {
    echo "window=firstmate:fm-task-x1"
    echo "endpoint_task_id=task-x1"
    echo "worktree=$SLOT"
    echo "branch=fm/task-x1"
    echo "project=$PROJ"
    echo "kind=ship"
    echo "mode=$mode"
    echo "spawn_gen=live-lab-task-x1"
  } > "$LAB/state/task-x1.meta"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  tasks-axi add task-x1 "live lab task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
}

backlog_state() { tasks-axi show task-x1 --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }

# foreign copy: a sibling task's worktree in the same pool slot.
add_foreign() { # <name>  -> FC
  FC=$SLOT/.claude/worktrees/$1
  mkdir -p "$SLOT/.claude/worktrees"
  git -C "$PROJ" worktree add -q -b "fm/other-$1" "$FC" main
}
ignored_file() { # <copy> [name]
  local ex
  ex=$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' "${2:-unique.dat}" >> "$ex"
  printf 'only here\n' > "$1/${2:-unique.dat}"
}
unlanded_commit() { # <copy>
  printf 'unlanded\n' > "$1/unlanded.txt"
  git -C "$1" add unlanded.txt
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
}
fingerprint() { # <copy>
  local copy=$1 admin
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  (cd "$copy" && LC_ALL=C find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ldn
   LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  (cd "$admin" && for f in HEAD locked gitdir commondir; do [ -e "$f" ] && { printf '%s ' "$f"; shasum -a 256 < "$f"; }; done)
}

run_td() { # args... ; sets RC, OUT, ERR   (plain FM_HOME only, no *_OVERRIDE)
  OUT=$LAB/stdout; ERR=$LAB/stderr
  RC=0
  (cd "$TD_ROOT" && env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
     FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" PATH="$FAKEBIN:$PATH" TREEHOUSE_ROOT="$LAB/pool" \
     bash "$TEARDOWN" task-x1 "$@") > "$OUT" 2> "$ERR" || RC=$?
}
show() { echo "--- exit=$RC"; echo "--- stdout:"; cat "$OUT"; echo "--- stderr:"; cat "$ERR"; }
pool_state() { jq -c '.worktrees[] | {name,leased,lease_holder}' "$(pool_state_file)" 2>/dev/null; }

cleanup() {
  [ -n "${LAB:-}" ] || return 0
  # the treehouse pool worktrees are registered in the lab project; the whole lab goes away together
  rm -rf "$LAB"
}

has() { grep -Fq -- "$2" "$1"; }
lacks() { ! grep -Fq -- "$2" "$1"; }
