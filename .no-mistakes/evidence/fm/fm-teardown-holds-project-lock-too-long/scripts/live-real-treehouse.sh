#!/usr/bin/env bash
# live-real-treehouse.sh <code-root> <label> <lease|nolease> [slow-secs]
#
# Drives <code-root>'s real bin/fm-teardown.sh against the machine's real
# `treehouse` (isolated by TREEHOUSE_ROOT), real git, real tmux (a private
# fm-lab socket), real lsof/jq and a real tasks-axi backlog, all inside a
# disposable marked lab home (bin/fm-lab-home.sh). One slow non-pool phase is
# injected by wrapping the real lsof so its first call sleeps. While that slow
# phase runs, a competing allocator does what a fresh spawn does: it queues for
# the project lock through bin/fm-project-lock-lib.sh and then runs the real
# `treehouse get --lease`. "nolease" hides `treehouse lease` behind a wrapper
# that rejects it as an unknown command, like the Treehouse v2.0.1 CI installed.
set -u
UNDER=${1:?code root}; LABEL=${2:?label}; MODE=${3:?lease|nolease}; SECS=${4:-8}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE_WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M50Z5BM4BGYDHKQ31BMVK6ZB
FAILS=0
check() { # <desc> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; else echo "  FAIL  $desc"; FAILS=$((FAILS+1)); fi
}
now() { python3 -c 'import time;print("%.3f" % time.time())'; }
elapsed() { python3 -c "print('%.1f' % ($2 - $1))"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
# The lab owner is this process; the helper stamps the marker lifecycle calls need.
"$GATE_WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "cannot mint lab home"; exit 1; }
mkdir -p "$LAB/tmux"
TMUXDIR=$("$GATE_WT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
cleanup() {
  TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab kill-server >/dev/null 2>&1
  "$GATE_WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  [ -z "${SLEEPER:-}" ] || kill "$SLEEPER" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TREEHOUSE_ROOT="$LAB/pool"
PROJ="$LAB/proj"
git init -q -b main "$PROJ" && printf 'lab\n' > "$PROJ/README.md" && git -C "$PROJ" add README.md && git -C "$PROJ" commit -q -m initial
git clone -q --bare "$PROJ" "$LAB/proj.origin.git" && git -C "$PROJ" remote add origin "file://$LAB/proj.origin.git" && git -C "$PROJ" fetch -q origin

# Home: backlog + crew harness, as a stock firstmate home carries.
mkdir -p "$LAB/data/retire"
printf '%s\n' codex > "$LAB/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
tasks-axi add retire "item for retire" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start retire --file "$LAB/data/backlog.md" >/dev/null
printf '# Task\n## Captain'"'"'s intent\nlab\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$LAB/data/retire/brief.md"

# A pool slot whose worker has exited: allocate durably, then return it, which
# is the unleased state a lapsed process lease leaves behind.
SLOT=$(cd "$PROJ" && treehouse get --lease --lease-holder seed --json 2>/dev/null | jq -r .path)
[ -d "$SLOT" ] || { echo "cannot allocate a real pool slot"; exit 1; }
(cd "$PROJ" && treehouse return "$SLOT" >/dev/null 2>&1)
STATE_JSON="${SLOT%/*/*}/treehouse-state.json"
printf 'task=retire\nhome=%s\n' "$LAB" > "${SLOT%/*}/.fm-slot-owner"

# Real tmux on the lab's private socket; the recorded window is a real pane.
TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab new-session -d -s firstmate -n fm-retire -c "$SLOT" 'sleep 3000'
SOCK=$(TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab display-message -p '#{socket_path}')
TPID=$(TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab display-message -p '#{pid}')
cat > "$LAB/state/retire.meta" <<EOF
window=firstmate:fm-retire
endpoint_task_id=retire
worktree=$SLOT
project=$PROJ
harness=codex
kind=ship
mode=no-mistakes
yolo=off
spawn_gen=s-retire
EOF
# A process of the retiring task left running with its cwd in the slot.
( cd "$SLOT" && exec sleep 3000 ) & SLEEPER=$!

# Wrappers: a delaying lsof (first call only) and, for nolease, a lease-rejecting treehouse.
SHIM="$LAB/shim"; mkdir -p "$SHIM"
REAL_LSOF=$(command -v lsof); REAL_TREEHOUSE=$(command -v treehouse)
cat > "$SHIM/lsof" <<EOF
#!/usr/bin/env bash
if [ -n "\${FM_SLOW_SECS:-}" ] && mkdir "$LAB/delay-owned" 2>/dev/null; then
  python3 -c 'import time;print("%.3f" % time.time())' > "$LAB/reached"
  sleep "\$FM_SLOW_SECS"
fi
exec "$REAL_LSOF" "\$@"
EOF
cat > "$SHIM/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = lease ] && [ "$MODE" = nolease ]; then
  echo 'Error: unknown command "lease" for "treehouse"' >&2
  exit 1
fi
exec "$REAL_TREEHOUSE" "\$@"
EOF
chmod +x "$SHIM/lsof" "$SHIM/treehouse"

echo "== $LABEL: mode=$MODE slow_phase=${SECS}s slot=$SLOT"
echo "  before: treehouse status -> $(jq -c '[.worktrees[]|{name,leased,lease_holder}]' "$STATE_JSON")"

# Env for every firstmate script: the lab home only, the lab tmux socket, no bypass.
run_fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_BACKEND=tmux TMUX="$SOCK,$TPID,0" TMUX_TMPDIR="$TMUXDIR" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" \
    FM_DURATION_FILE=off FM_MODEL_FRESHNESS=0 FM_PROJECT_LOCK_POLL_SECS=0.1 PATH="$SHIM:$PATH" "$@"
}

T0=$(now)
FM_SLOW_SECS=$SECS run_fm "$UNDER/bin/fm-teardown.sh" retire --force --drop-file "$LAB/drop.txt" > "$LAB/teardown.out" 2>&1 &
TD=$!
printf 'lab: discard the retiring task for the lock-hold measurement\n' > "$LAB/drop.txt"
i=0; while [ ! -f "$LAB/reached" ]; do i=$((i+1)); [ "$i" -lt 600 ] || { echo "teardown never reached the slow phase"; cat "$LAB/teardown.out"; kill "$TD" 2>/dev/null; exit 1; }; sleep 0.05; done
T_SLOW=$(cat "$LAB/reached")

echo "  during the slow phase (teardown is still running: $(kill -0 $TD 2>/dev/null && echo yes || echo NO)):"
STATUS_DURING=$(cd "$PROJ" && treehouse status --json 2>/dev/null | jq -c '[.[]|{name,status,lease_holder}]')
echo "    treehouse status -> $STATUS_DURING"
if [ "$MODE" = lease ]; then
  check "the retiring slot is not allocatable during the slow phase (not available)" \
    bash -c "echo '$STATUS_DURING' | jq -e '.[] | select(.name==\"1\") | .status != \"available\"'"
  check "the slot is durably leased to the retiring task (holder=retire)" \
    bash -c "echo '$STATUS_DURING' | jq -e '.[] | select(.name==\"1\") | .lease_holder == \"retire\"'"
fi
check "the retiring task's leaked process is still alive (the reap phase is genuinely in progress)" kill -0 "$SLEEPER"

# Competing allocator: queue for the project lock like a fresh spawn, then take a real slot.
(
  export FM_HOME="$LAB" TMUX="$SOCK,$TPID,0" TMUX_TMPDIR="$TMUXDIR" FM_PROJECT_LOCK_POLL_SECS=0.1
  unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  # shellcheck disable=SC1091
  . "$UNDER/bin/fm-wake-lib.sh"; . "$UNDER/bin/fm-project-lock-lib.sh"
  lock=$(fm_treehouse_project_lock_path "$PROJ") || exit 3
  t_q=$(python3 -c 'import time;print("%.3f" % time.time())')
  fm_project_lock_acquire "$lock" "spawn lab-competitor" >/dev/null 2>&1 || exit 4
  t_got=$(python3 -c 'import time;print("%.3f" % time.time())')
  got=$(cd "$PROJ" && "$REAL_TREEHOUSE" get --lease --lease-holder lab-competitor --json 2>/dev/null | jq -r .path)
  fm_project_lock_release "$lock"
  printf '%s %s %s\n' "$t_q" "$t_got" "$got" > "$LAB/competitor.out"
) &
CP=$!
wait "$CP"; CRC=$?
TD_ALIVE_AFTER_COMPETITOR=$(kill -0 $TD 2>/dev/null && echo yes || echo no)
read -r T_Q T_GOT COMP_SLOT < "$LAB/competitor.out"
COMP_WAIT=$(elapsed "$T_Q" "$T_GOT")
echo "    competing allocator waited ${COMP_WAIT}s for the project lock (teardown still running afterwards: $TD_ALIVE_AFTER_COMPETITOR) and got $COMP_SLOT"
if [ "$MODE" = lease ]; then
  check "competing allocator proceeded while the slow phase was still running" test "$TD_ALIVE_AFTER_COMPETITOR" = yes
  check "competing allocator got a different slot than the retiring one" test -n "$COMP_SLOT" -a "$COMP_SLOT" != "$SLOT"
else
  check "without a lease command, project custody is kept: the competitor only got in after teardown ended" test "$TD_ALIVE_AFTER_COMPETITOR" = no
fi

wait "$TD"; TRC=$?
T_END=$(now)
echo "  teardown rc=$TRC wall=$(elapsed "$T0" "$T_END")s"
sed -n 's/^/    teardown: /p' "$LAB/teardown.out" | grep -i -E "warning|REFUSED|complete|lease|custody" | head -8
echo "  holds (state-dir lock record):"
sed 's/^/    /' "$LAB"/state/.treehouse-project-*.lock.holds 2>/dev/null
HOLD_SUM=0; HOLD_N=0; HOLD_MAX=0
while IFS= read -r l; do
  case "$l" in *"operation=teardown retire") s=${l#*seconds=}; s=${s%% *}; HOLD_SUM=$((HOLD_SUM+s)); HOLD_N=$((HOLD_N+1)); [ "$s" -le "$HOLD_MAX" ] || HOLD_MAX=$s ;; esac
done < <(cat "$LAB"/state/.treehouse-project-*.lock.holds 2>/dev/null)
echo "  RESULT label=$LABEL mode=$MODE slow_phase=${SECS}s teardown_rc=$TRC teardown_lock_holds=$HOLD_N teardown_lock_hold_sum=${HOLD_SUM}s teardown_longest_hold=${HOLD_MAX}s competitor_lock_wait=${COMP_WAIT}s teardown_wall=$(elapsed "$T0" "$T_END")s"

echo "  after:"
echo "    treehouse status -> $(cd "$PROJ" && treehouse status --json 2>/dev/null | jq -c '[.[]|{name,status,lease_holder}]')"
check "teardown exits 0" test "$TRC" -eq 0
check "the task record is gone" test ! -e "$LAB/state/retire.meta"
check "no return-pending record is left" test ! -e "$LAB/state/retire.teardown-return-pending"
check "the retiring task's slot claim is dropped" test ! -e "${SLOT%/*}/.fm-slot-owner"
check "the retiring slot is no longer held for the retiring task" bash -c "jq -e '.worktrees[] | select(.path==\"$SLOT\") | (.lease_holder // \"\") != \"retire\"' '$STATE_JSON'"
[ "$MODE" != lease ] || check "the retiring slot is back in the pool (not leased)" bash -c "jq -e '.worktrees[] | select(.path==\"$SLOT\") | (.leased // false) == false' '$STATE_JSON'"
check "the leaked process was reaped before the slot went back" bash -c "! kill -0 $SLEEPER 2>/dev/null"
check "the real tmux window was closed" bash -c "! TMUX_TMPDIR='$TMUXDIR' tmux -L fm-lab list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx fm-retire"
check "the backlog item is closed" bash -c "tasks-axi show retire --file '$LAB/data/backlog.md' 2>/dev/null | grep -q 'state: *done'"
check "the competitor's own slot stays leased to it" bash -c "jq -e '.worktrees[] | select(.path==\"$COMP_SLOT\") | .leased == true' '$STATE_JSON'"
echo "  FAILS=$FAILS"
[ "$FAILS" -eq 0 ]
