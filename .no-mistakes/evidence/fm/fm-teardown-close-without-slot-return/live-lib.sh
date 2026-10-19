#!/usr/bin/env bash
# Live-lab library: builds a disposable firstmate lab (marked FM_HOME, real git,
# bare origin, real treehouse pool, real tasks-axi backlog) and drives the real
# bin/fm-teardown.sh against it. Sourced by live-driver.sh. Nothing here touches
# the operator's fleet: every path lives under $LAB, which is outside any git tree.
#
# Only two outside tools are shadowed, both unrelated to the change under test:
# docker (teardown asks it which stacks the task owns) and no-mistakes (teardown
# asks it for a parked run). Both answer "nothing". git, treehouse, tasks-axi,
# lsof, jq and the teardown scripts are the real ones.

WT_ROOT=${WT_ROOT:?}          # the run worktree whose bin/ is under test
EVID=${EVID:?}                # evidence directory
CODE_BIN=${CODE_BIN:-$WT_ROOT/bin}

lab_new() {  # <label>  -> sets LAB, ORIGIN, PROJECT, SLOT, POOL
  local label=$1
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed" >&2; return 1; }
  mkdir -p "$LAB/tmux" "$LAB/shim" "$LAB/pool"
  LAB_LABEL=$label
  ORIGIN=$LAB/origin.git
  PROJECT=$LAB/projects/repo
  POOL=$LAB/pool
  cat > "$LAB/shim/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$LAB/shim/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$LAB/shim/docker" "$LAB/shim/no-mistakes"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN" "$LAB/_seed" 2>/dev/null
  git -C "$LAB/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$LAB/_seed" push -q origin main
  rm -rf "$LAB/_seed"
  mkdir -p "$LAB/projects"
  git clone -q "$ORIGIN" "$PROJECT"
  git -C "$PROJECT" remote set-head origin main
}

# lab_slot <mode>: acquire pool slot 1 with the REAL treehouse.
#   leased -> treehouse get --lease --lease-holder task-x1 (durable)
#   plain  -> plain treehouse get whose subshell exits at once, the lapsed
#             process-lease shape a crewmate slot has after its worker exits.
lab_slot() {
  local mode=${1:-leased} sh_stub
  if [ "$mode" = leased ]; then
    SLOT=$(cd "$PROJECT" && TREEHOUSE_ROOT=$POOL treehouse get --lease --lease-holder task-x1 2>/dev/null) || return 1
  else
    sh_stub=$LAB/shim/exit-shell
    printf '#!/bin/sh\nexit 0\n' > "$sh_stub"; chmod +x "$sh_stub"
    (cd "$PROJECT" && TREEHOUSE_ROOT=$POOL SHELL=$sh_stub treehouse get >"$LAB/treehouse-get.out" 2>&1) || true
    SLOT=$(jq -r '.worktrees[0].path' "$POOL"/.treehouse/*/treehouse-state.json)
  fi
  SLOT=$(cd "$SLOT" && pwd -P)
  POOL_STATE=$(ls "$POOL"/.treehouse/*/treehouse-state.json)
  printf 'task=task-x1\nhome=%s\n' "$LAB" > "$(dirname "$SLOT")/.fm-slot-owner"
}

# lab_task_work: the task's own work, landed on origin main (reachable from a remote).
lab_task_work() {
  git -C "$SLOT" switch -q -c fm/task-x1
  printf 'task work\n' > "$SLOT/task-work.txt"
  git -C "$SLOT" add task-work.txt
  git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q -m "task-x1 work"
  git -C "$SLOT" push -q origin HEAD:main
  git -C "$SLOT" fetch -q origin
}

lab_record() {
  local state=$LAB/state
  mkdir -p "$state"
  printf '%s\n' \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" \
    "branch=fm/task-x1" "project=$PROJECT" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=live-lab-task-x1" "pr=https://github.com/example/repo/pull/7" > "$state/task-x1.meta"
  touch "$state/.last-watcher-beat"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  tasks-axi add task-x1 "live lab task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
}

# lab_foreign <name> [unlanded] [ignored]: a clean-or-not sibling copy another
# task owns, registered in the slot under .claude/worktrees/<name>.
lab_foreign() {
  local name=$1 unlanded=${2:-} ignored=${3:-} copy exclude
  copy=$SLOT/.claude/worktrees/$name
  git -C "$SLOT" worktree add -q -b "fm/other-$name" "$copy" main
  if [ -n "$unlanded" ]; then
    printf 'unlanded foreign work\n' > "$copy/unlanded.txt"
    git -C "$copy" add unlanded.txt
    git -C "$copy" -c user.email=t@t -c user.name=t commit -q -m "unlanded foreign work"
  fi
  if [ -n "$ignored" ]; then
    exclude=$(git -C "$copy" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "$exclude"
    printf 'only here\n' > "$copy/unique.dat"
  fi
  FOREIGN=$copy
}

# lab_fingerprint <copy>: every path with mode/size/mtime, sha256 of every file,
# and the copy's git admin files, so any delete, move, rewrite or chmod shows.
lab_fingerprint() {
  local copy=$1 admin
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  (cd "$copy" && LC_ALL=C find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ldn
    LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  (cd "$admin" && for f in HEAD locked gitdir commondir; do
    if [ -e "$f" ]; then printf '%s ' "$f"; shasum -a 256 < "$f"; fi
  done)
}

lab_snapshot() {  # <copy>...
  local copy
  for copy in "$@"; do lab_fingerprint "$copy" > "$LAB/fp-before.$(basename "$copy")"; done
  cp "$POOL_STATE" "$LAB/lease-before.json"
  cp "$(dirname "$SLOT")/.fm-slot-owner" "$LAB/claim-before"
  git -C "$PROJECT" worktree list --porcelain > "$LAB/registrations-before"
}

lab_unchanged() {  # <copy> -> 0 when byte-identical to the snapshot
  lab_fingerprint "$1" | cmp -s - "$LAB/fp-before.$(basename "$1")"
}

lab_teardown() {  # <teardown-bin-dir> [args...] -> stdout/stderr in $LAB/out.{stdout,stderr}, rc in LAB_RC
  local bindir=$1
  shift
  LAB_RC=0
  (cd "$WT_ROOT" && env -u FM_GATE_REFUSE_BYPASS -u TMUX \
      FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" NM_HOME="$LAB/nm" TREEHOUSE_ROOT="$POOL" \
      PATH="$LAB/shim:$PATH" \
      "$bindir/fm-teardown.sh" task-x1 "$@" > "$LAB/out.stdout" 2> "$LAB/out.stderr") || LAB_RC=$?
}

lab_show() {  # <title>  prints the transcript of the last teardown
  printf '\n----- %s (exit %s) -----\n' "$1" "$LAB_RC"
  printf '[stdout]\n'; cat "$LAB/out.stdout"
  printf '[stderr]\n'; cat "$LAB/out.stderr"
}

lab_backlog_state() {
  tasks-axi show task-x1 --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

lab_leased() {  # -> prints true/false for slot "1"
  jq -r --arg p "$SLOT" '.worktrees[] | select(.path==$p) | .leased' "$POOL_STATE"
}

# A detached home-summary refresh may write into state/ shortly after teardown
# returns; wait for it, then remove the lab, and remove again if it wrote late.
LAB_ALL=()
lab_destroy() {
  LAB_ALL+=("$LAB")
  sleep 2
  rm -rf "$LAB"
}
lab_sweep() {
  local d
  sleep 2
  for d in ${LAB_ALL[@]+"${LAB_ALL[@]}"}; do rm -rf "$d"; done
}
