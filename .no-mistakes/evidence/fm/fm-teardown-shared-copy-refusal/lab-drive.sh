#!/usr/bin/env bash
# Live lab driver for fm-teardown shared/reassigned-copy scenarios.
# Usage: lab-drive.sh <src-root> <scenario> <out-dir>
#   src-root: checkout whose bin/fm-teardown.sh is driven
#   scenario: reassigned-finished | reassigned-unlanded | reassigned-clean-unlanded | shared-finished | shared-unlanded
# Builds a disposable marked lab FM_HOME (bin/fm-lab-home.sh), real Git
# origin/project/pool slot, a real private tmux server holding both tasks'
# windows, a real claimant process, and a real tasks-axi backlog; then runs the
# real teardown from inside a lab tmux pane and records before/after state.
# Shims stand in only for external services (GitHub, Docker, no-mistakes
# daemon, Treehouse pool admin) and log any call.
set -u
SRC=$1 SCEN=$2 OUT=$3
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 2; }
TD=$("$SRC/bin/fm-lab-home.sh" tmux-dir "$LAB") || { echo "tmux-dir failed"; exit 2; }
T() { TMUX_TMPDIR="$TD" tmux -L fm-lab "$@"; }
G() { git -c user.email=t@t -c user.name=t "$@"; }
log() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }
: > "$OUT/transcript.txt"
log "== scenario $SCEN on $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "$SRC")"
log "lab=$LAB"

# Shims for external services only.
SH="$LAB/shims"; mkdir -p "$SH"
for s in gh gh-axi docker no-mistakes treehouse; do
  cat > "$SH/$s" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$s" "\$*" >> "$LAB/external-calls.log"
case "$s:\${1:-} \${2:-}" in
  gh:"pr view") echo "no such PR" >&2; exit 1 ;;
  gh-axi:"pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  gh-axi:"pr view") echo "no such PR" >&2; exit 1 ;;
  treehouse:*) echo "treehouse shim: refusing pool admin in lab" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SH/$s"
done

# Real Git: origin, project clone, pool slot worktree.
G init -q --bare "$LAB/origin.git"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
G clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
G -C "$LAB/seed" commit -q --allow-empty -m baseline
G -C "$LAB/seed" push -q origin main
rm -rf "$LAB/seed"
PROJ="$LAB/projects/proj"
G clone -q "$LAB/origin.git" "$PROJ"
git -C "$PROJ" remote set-head origin main
mkdir -p "$LAB/pool/1"
SLOT="$LAB/pool/1/proj"
G -C "$PROJ" worktree add -q -b fm/task-x1 "$SLOT" main
SLOT=$(cd "$SLOT" && pwd -P)
printf 'task-x1 deliverable\n' > "$SLOT/delivered.txt"
G -C "$SLOT" add delivered.txt
G -C "$SLOT" commit -q -m 'task-x1 deliverable'
case "$SCEN" in
  *-finished)
    # Land task-x1's own branch on origin main (real fast-forward push).
    G -C "$SLOT" push -q origin fm/task-x1:main
    G -C "$PROJ" fetch -q origin
    log "task-x1 branch landed on origin/main at $(git -C "$PROJ" rev-parse --short origin/main)" ;;
  *-unlanded) log "task-x1 branch left unlanded (no PR, not on origin/main)" ;;
esac

case "$SCEN" in
  reassigned-clean-unlanded)
    # Claimant freshly took the slot: clean copy on its own branch at main.
    G -C "$SLOT" checkout -q -b fm/live-task main
    printf 'task=live-task\nhome=%s\n' "$LAB" > "$LAB/pool/1/.fm-slot-owner"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$SLOT" > "$LAB/pool/treehouse-state.json"
    ;;
  reassigned-*)
    # Slot reassigned: claimant live-task switched the copy to its own branch,
    # has an unlanded commit, tracked edit, untracked file and hook bytes.
    G -C "$SLOT" checkout -q -b fm/live-task
    printf 'claimant committed\n' > "$SLOT/live.txt"
    G -C "$SLOT" add live.txt; G -C "$SLOT" commit -q -m 'unlanded claimant work'
    printf 'claimant tracked edit\n' >> "$SLOT/live.txt"
    printf 'claimant untracked\n' > "$SLOT/scratch.txt"
    mkdir -p "$SLOT/.claude"; printf 'claimant hook\n' > "$SLOT/.claude/settings.local.json"
    printf 'task=live-task\nhome=%s\n' "$LAB" > "$LAB/pool/1/.fm-slot-owner"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$SLOT" > "$LAB/pool/treehouse-state.json"
    ;;
  shared-*)
    # Shared root: both records name the same root; claim is task-x1's own and
    # the slot is durably leased for the remaining task. Remaining task's dirt.
    printf 'remaining task untracked\n' > "$SLOT/remaining.txt"
    printf 'task=task-x1\nhome=%s\n' "$LAB" > "$LAB/pool/1/.fm-slot-owner"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"live-task"}]}\n' "$SLOT" > "$LAB/pool/treehouse-state.json"
    ;;
esac

# Records, statuses, backlog.
S="$LAB/state"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" \
  "project=$PROJ" "kind=ship" "mode=no-mistakes" "branch=fm/task-x1" "spawn_gen=lab-x1" > "$S/task-x1.meta"
printf '%s\n' "window=firstmate:fm-live-task" "endpoint_task_id=live-task" "worktree=$SLOT" \
  "project=$PROJ" "kind=ship" "mode=no-mistakes" "branch=fm/live-task" "spawn_gen=lab-live" > "$S/live-task.meta"
printf 'task-x1 status\n' > "$S/task-x1.status"
printf 'live-task working\n' > "$S/live-task.status"
touch "$S/.last-watcher-beat"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
for t in task-x1 live-task; do
  tasks-axi add "$t" "lab $t" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$t" --file "$LAB/data/backlog.md" >/dev/null
done

# Real tmux server: one window per task, claimant process running in the slot.
T new-session -d -s firstmate -n fm-task-x1 -c "$SLOT" "sleep 3600"
T new-window -d -t firstmate: -n fm-live-task -c "$SLOT" "sleep 3600"
(cd "$SLOT" && exec sleep 3600) & CLAIMANT_PID=$!

snap() {
  local tag=$1 f; f="$OUT/$tag.txt"
  {
    echo "## records"; ls -1 "$S" | grep -E '\.(meta|status)$'
    echo "## live-task.meta"; cat "$S/live-task.meta"
    echo "## slot claim"; cat "$LAB/pool/1/.fm-slot-owner" 2>/dev/null || echo '(none)'
    echo "## pool lease"; cat "$LAB/pool/treehouse-state.json"
    echo "## tmux windows"; T list-windows -t firstmate -F '#{window_name}' 2>&1
    echo "## slot HEAD"; git -C "$SLOT" symbolic-ref HEAD; git -C "$SLOT" rev-parse HEAD
    echo "## slot status"; git -C "$SLOT" status --porcelain --untracked-files=all; echo "## claimant files"; cat "$SLOT/live.txt" "$SLOT/scratch.txt" "$SLOT/.claude/settings.local.json" "$SLOT/remaining.txt" 2>/dev/null
    echo "## project refs"; git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)'
    echo "## claimant pid $CLAIMANT_PID"; kill -0 "$CLAIMANT_PID" 2>/dev/null && echo alive || echo DEAD
    echo "## backlog"; for t in task-x1 live-task; do printf '%s: ' "$t"; tasks-axi show "$t" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; done
  } > "$f" 2>&1
}
snap before

# Run the real teardown from inside a lab tmux pane (inherits the lab $TMUX).
RUN="$LAB/run.sh"
cat > "$RUN" <<EOF
#!/usr/bin/env bash
cd "$SRC"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" NM_HOME="$LAB/nm" PATH="$SH:\$PATH" \
  "$SRC/bin/fm-teardown.sh" task-x1 > "$LAB/teardown.out" 2> "$LAB/teardown.err"
echo \$? > "$LAB/teardown.rc"
EOF
chmod +x "$RUN"
T new-window -d -t firstmate: -n driver "$RUN"
for _ in $(seq 1 600); do [ -f "$LAB/teardown.rc" ] && break; sleep 1; done
RC=$(cat "$LAB/teardown.rc" 2>/dev/null || echo timeout)
snap after
log "teardown exit code: $RC"
log "--- teardown stdout"; cat "$LAB/teardown.out" >> "$OUT/transcript.txt"
log "--- teardown stderr"; cat "$LAB/teardown.err" >> "$OUT/transcript.txt"
log "--- external service calls"; cat "$LAB/external-calls.log" >> "$OUT/transcript.txt" 2>/dev/null || log "(none)"
log "--- before/after diff"; diff "$OUT/before.txt" "$OUT/after.txt" >> "$OUT/transcript.txt"
log "--- after state"; cat "$OUT/after.txt" >> "$OUT/transcript.txt"
echo "$RC" > "$OUT/rc"

# Teardown of the lab.
kill "$CLAIMANT_PID" 2>/dev/null; wait "$CLAIMANT_PID" 2>/dev/null
T kill-server 2>/dev/null
"$SRC/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
rm -rf "$LAB"
log "lab removed: $([ -e "$LAB" ] && echo NO || echo yes)"
