#!/usr/bin/env bash
# Live-lab helpers for the fm-teardown nested-copy scenarios.
# Source after the lab env file ($W/env.sh): needs FM_HOME, TMUX_TMPDIR, W, TREEHOUSE_ROOT.
# Real products: bin/fm-teardown.sh, git, treehouse (temp TREEHOUSE_ROOT), tasks-axi
# (lab data), tmux (lab TMUX_TMPDIR socket). Stubs only for outward services:
# no-mistakes (shared daemon), gh/gh-axi (forge), docker.
set -u
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6GYA85H99BKCG23EW25BNTC
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6GYA85H99BKCG23EW25BNTC
FAKEBIN=$W/fakebin

lab_guard() {
  case "$TREEHOUSE_ROOT" in "$W"/th) ;; *) echo "ABORT: TREEHOUSE_ROOT=$TREEHOUSE_ROOT" >&2; exit 99 ;; esac
  case "$FM_HOME" in */fm-lab.*) ;; *) echo "ABORT: FM_HOME=$FM_HOME" >&2; exit 99 ;; esac
  [ -z "${TMUX:-}" ] || { echo "ABORT: TMUX is set" >&2; exit 99; }
  case "$TMUX_TMPDIR" in /tmp/fml.*) ;; *) echo "ABORT: TMUX_TMPDIR=$TMUX_TMPDIR" >&2; exit 99 ;; esac
}

lab_fakebin() {
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
# lab stub: no active no-mistakes run, never reaches the shared daemon
exit 0
SH
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2 ; exit 1 ;; esac
exit 0
SH
  cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN"/*
}

# lab_case <name> <claim: mine|other> <variant: landed|slot-unlanded|copy-dirty>
# Sets C, ID, PROJ, SLOT, COPY.
lab_case() {
  local name=$1 claim=$2 variant=$3 pooldir
  lab_guard
  C=$W/$name; ID=task-$name
  mkdir -p "$C"
  git init -q --bare "$C/origin.git"
  git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$C/origin.git" "$C/_seed" 2>/dev/null
  printf 'base\n' > "$C/_seed/README"
  git -C "$C/_seed" add README
  git -C "$C/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$C/_seed" push -q origin main
  rm -rf "$C/_seed"
  git clone -q "$C/origin.git" "$C/project"
  git -C "$C/project" remote set-head origin main 2>/dev/null || true
  PROJ=$C/project
  pooldir=$(cd "$PROJ" && treehouse pool-dir)
  case "$pooldir" in "$W"/th/*) ;; *) echo "ABORT: pool-dir=$pooldir" >&2; exit 99 ;; esac
  if [ "${LAB_CUSTODY:-lease}" = lapsed ]; then
    # A crewmate-style slot: interactive treehouse get, whose process lease
    # lapses when the subshell exits, so the slot reads available.
    (cd "$PROJ" && echo exit | SHELL=/bin/bash treehouse get) > "$C/get.out" 2>&1
    SLOT=$(cd "$PROJ" && treehouse status --json | jq -r '.[0].path')
  else
    SLOT=$(cd "$PROJ" && treehouse get --lease --lease-holder "$ID" 2>"$C/get.stderr")
  fi
  SLOT=$(cd "$SLOT" && pwd -P)
  case "$SLOT" in "$W"/th/*) ;; *) echo "ABORT: slot=$SLOT" >&2; exit 99 ;; esac
  COPY=$SLOT/.claude/worktrees/$ID-v2
  mkdir -p "${COPY%/*}"
  git -C "$PROJ" worktree add -q -b "fm/$ID-v2" "$COPY" main
  (
    # shellcheck source=/dev/null
    . "$REPO/bin/fm-wake-lib.sh"
    if [ "$claim" = mine ]; then
      fm_treehouse_slot_owner_claim "$SLOT" "$ID" "$FM_HOME"
    else
      fm_treehouse_slot_owner_claim "$SLOT" other-task "$FM_HOME"
    fi
  ) || { echo "ABORT: claim write failed" >&2; exit 99; }
  mkdir -p "$FM_HOME/state/$ID.inbox" "$C/tasktmp"
  printf 'steer\n' > "$FM_HOME/state/$ID.inbox/001.msg"
  printf 'working: lab fixture\n' > "$FM_HOME/state/$ID.status"
  printf 'scratch\n' > "$C/tasktmp/scratch.txt"
  printf '%s\n' "window=firstmate:fm-$ID" "endpoint_task_id=$ID" "worktree=$COPY" \
    "branch=fm/$ID-v2" "project=$PROJ" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=gen-$ID" "tasktmp=$C/tasktmp" > "$FM_HOME/state/$ID.meta"
  [ -f "$FM_HOME/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"
  tasks-axi add "$ID" "lab nested fixture $name" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$FM_HOME/data/backlog.md" >/dev/null
  if tmux has-session -t firstmate 2>/dev/null; then
    tmux new-window -d -t firstmate -n "fm-$ID" 'sleep 99999'
  else
    tmux new-session -d -s firstmate -n "fm-$ID" 'sleep 99999'
  fi
  case "$variant" in
    slot-unlanded)
      printf 'slot work\n' > "$SLOT/slot.txt"
      git -C "$SLOT" add slot.txt
      git -C "$SLOT" -c user.email=t@t -c user.name=t commit -qm "slot work"
      ;;
    copy-dirty)
      printf 'dirty\n' > "$COPY/dirty.txt"
      git -C "$COPY" add dirty.txt
      ;;
  esac
  printf 'The captain said the copy may be dropped; its commits are on main.\n' > "$C/drop-words.txt"
}

# lab_leftovers: the gate-409 leftover markers, as the recorded case left them.
lab_leftovers() {
  printf 'id=%s\ndata=%s\nspawn_gen=gen-%s\ncleanup_incomplete=0\narg=--note\narg=dropped\n' \
    "$ID" "$FM_HOME/data" "$ID" > "$FM_HOME/state/$ID.backlog-close"
  printf 'spawn_gen=gen-%s\nslot=\n' "$ID" > "$FM_HOME/state/$ID.teardown-return-pending"
}

# lab_snapshot <out>: every byte a refusal must leave alone, plus live pool,
# tmux and backlog state.
lab_snapshot() {
  local out=$1 f
  {
    echo "## state files for $ID (sha256)"
    find "$FM_HOME/state" -name "$ID*" | LC_ALL=C sort | while IFS= read -r f; do
      if [ -f "$f" ]; then printf 'file %s %s\n' "$f" "$(shasum -a 256 < "$f" | awk '{print $1}')"; else printf 'dir %s\n' "$f"; fi
    done
    find "$FM_HOME/state/$ID.inbox" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      printf 'file %s %s\n' "$f" "$(shasum -a 256 < "$f" | awk '{print $1}')"; done
    echo "## tasktmp"
    if [ -d "$C/tasktmp" ]; then find "$C/tasktmp" | LC_ALL=C sort; else echo "tasktmp absent"; fi
    echo "## copy and slot"
    printf 'copy %s %s\n' "$COPY" "$([ -e "$COPY" ] && echo present || echo absent)"
    printf 'copy-head %s\n' "$(git -C "$COPY" rev-parse HEAD 2>/dev/null || echo absent)"
    printf 'copy-status %s\n' "$(git -C "$COPY" status --porcelain 2>/dev/null | tr '\n' ' ')"
    printf 'slot %s %s\n' "$SLOT" "$([ -e "$SLOT" ] && echo present || echo absent)"
    printf 'slot-head %s\n' "$(git -C "$SLOT" rev-parse HEAD 2>/dev/null || echo absent)"
    git -C "$PROJ" for-each-ref --format='ref %(refname) %(objectname)' refs/heads
    echo "## slot claim"
    f=$(dirname "$SLOT")/.fm-slot-owner
    if [ -f "$f" ]; then sed 's/^/claim /' "$f"; else echo "claim absent"; fi
    echo "## treehouse status (real, temp root)"
    (cd "$PROJ" && treehouse status --json 2>&1) | jq -c '[.. | objects | select(has("path")) | {path, leased: (.leased // null), lease_holder: (.lease_holder // null), status: (.status // .state // null)}]' 2>/dev/null \
      || (cd "$PROJ" && treehouse status 2>&1)
    echo "## tmux windows (lab socket)"
    tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -F "fm-$ID" || echo "window fm-$ID absent"
    echo "## backlog row"
    tasks-axi show "$ID" --file "$FM_HOME/data/backlog.md" 2>&1 | head -6
  } > "$out"
}

# lab_teardown <script-root> [args...]: run the real teardown from <script-root>.
lab_teardown() {
  local root=$1; shift
  lab_guard
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    PATH="$FAKEBIN:$PATH" FM_HOME="$FM_HOME" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" TMUX_TMPDIR="$TMUX_TMPDIR" \
    "$root/bin/fm-teardown.sh" "$ID" "$@"
}
