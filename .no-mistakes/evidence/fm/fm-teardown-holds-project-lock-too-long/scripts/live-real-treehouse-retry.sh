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
[ -z "\${FM_LSOF_FAIL:-}" ] || exit 1
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

echo "== $LABEL: refused teardown after the slot was reserved, then a clean retry (real treehouse $MODE)"
run_fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_BACKEND=tmux TMUX="$SOCK,$TPID,0" TMUX_TMPDIR="$TMUXDIR" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" \
    FM_DURATION_FILE=off FM_MODEL_FRESHNESS=0 FM_PROJECT_LOCK_POLL_SECS=0.1 PATH="$SHIM:$PATH" "$@"
}
printf 'lab: discard the retiring task\n' > "$LAB/drop.txt"
st() { (cd "$PROJ" && treehouse status --json 2>/dev/null | jq -c '[.[]|{name,status,lease_holder}]'); }
echo "  attempt 1: process inventory (lsof) fails after the slot was reserved"
FM_LSOF_FAIL=1 run_fm "$UNDER/bin/fm-teardown.sh" retire --force --drop-file "$LAB/drop.txt" > "$LAB/attempt1.out" 2>&1
RC1=$?
echo "    rc=$RC1"; grep -E "REFUSED|warning|error" "$LAB/attempt1.out" | head -4 | sed 's/^/    /'
echo "    treehouse status -> $(st)"
check "attempt 1 refuses (nonzero)" test "$RC1" -ne 0
check "the task record is kept" test -e "$LAB/state/retire.meta"
check "the slot is still leased to the retiring task (not allocatable)" bash -c "(cd '$PROJ' && treehouse status --json 2>/dev/null | jq -e '.[] | select(.name==\"1\") | .status==\"leased\" and .lease_holder==\"retire\"')"
check "the return-pending record names the held slot" grep -q "^slot=" "$LAB/state/retire.teardown-return-pending"
check "the slot claim is kept for the retry" test -e "${SLOT%/*}/.fm-slot-owner"
check "the leaked process is untouched by a refused attempt" kill -0 "$SLEEPER"
# A fresh allocator in the refusal window must not receive the held slot.
GOT=$(cd "$PROJ" && treehouse get --lease --lease-holder lab-competitor --json 2>/dev/null | jq -r .path)
echo "    a fresh allocator in the refusal window got: $GOT"
check "a fresh allocator is not handed the held slot" test -n "$GOT" -a "$GOT" != "$SLOT"
echo "  session-start (real fm-bootstrap.sh) between the attempts:"
run_fm env FM_BOOTSTRAP_NETWORK=skip "$UNDER/bin/fm-bootstrap.sh" > "$LAB/bootstrap.out" 2>&1
grep -E "BACKLOG_RECONCILE|teardown|retire" "$LAB/bootstrap.out" | head -5 | sed 's/^/    /'
check "session start did not close the item or remove the record while the return is owed" test -e "$LAB/state/retire.meta"
echo "  attempt 2: the retry with a working process inventory"
run_fm "$UNDER/bin/fm-teardown.sh" retire --force --drop-file "$LAB/drop.txt" > "$LAB/attempt2.out" 2>&1
RC2=$?
echo "    rc=$RC2"; tail -2 "$LAB/attempt2.out" | sed 's/^/    /'
echo "    treehouse status -> $(st)"
check "the retry exits 0" test "$RC2" -eq 0
check "the record and the return-pending record are gone" bash -c "test ! -e '$LAB/state/retire.meta' && test ! -e '$LAB/state/retire.teardown-return-pending'"
check "the retired slot is back in the pool" bash -c "jq -e '.worktrees[] | select(.path==\"$SLOT\") | (.leased // false) == false' '$STATE_JSON'"
check "the competitor's slot is untouched" bash -c "jq -e '.worktrees[] | select(.path==\"$GOT\") | .leased == true' '$STATE_JSON'"
check "the leaked process was reaped" bash -c "! kill -0 $SLEEPER 2>/dev/null"
check "the backlog item is closed" bash -c "tasks-axi show retire --file '$LAB/data/backlog.md' 2>/dev/null | grep -q 'state: *done'"
echo "  FAILS=$FAILS"
[ "$FAILS" -eq 0 ]
