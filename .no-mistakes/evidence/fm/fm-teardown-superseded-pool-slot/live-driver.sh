#!/usr/bin/env bash
# Live driver: runs the real bin/fm-teardown.sh against the real installed
# treehouse with two real pool folders in a throwaway TREEHOUSE_ROOT and HOME.
# Only tmux, gh, gh-axi, no-mistakes and docker are the fixture stubs from
# tests/fm-teardown-helpers.sh make_case (peripheral to the pool logic).
# Usage: live-driver.sh <worktree-root> <evidence-dir> <scenario> [code-bin]
set -u
WT=$1 EVID=$2 SCEN=$3 CODE_BIN=${4:-$1/bin}
REAL_TH=$(command -v treehouse)
cd "$WT" || exit 1
# shellcheck disable=SC1091
. "$WT/tests/fm-teardown-helpers.sh"
export HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
mkdir -p "$HOME"
OUT="$EVID/$SCEN"
rm -rf "$OUT"; mkdir -p "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }

C=$(make_case "$SCEN")
export TREEHOUSE_ROOT="$C/thr"
mkdir -p "$TREEHOUSE_ROOT"
# Logging pass-through to the REAL treehouse. NO_POOL_DIR=1 hides pool-dir only,
# to drive the status-listing fallback an older Treehouse takes.
cat > "$C/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$C/treehouse.log"
if [ "\${1:-}" = pool-dir ] && [ -n "\${NO_POOL_DIR:-}" ]; then
  echo 'Error: unknown command "pool-dir" for "treehouse"' >&2; exit 1
fi
exec "$REAL_TH" "\$@"
SH
chmod +x "$C/fakebin/treehouse"
export PATH="$C/fakebin:$PATH"
P=$C/project

mkslots() {  # make two unleased real slots in the project's current pool
  local a b
  a=$(cd "$P" && treehouse get --lease --no-fetch --lease-holder setup 2>/dev/null </dev/null)
  b=$(cd "$P" && treehouse get --lease --no-fetch --lease-holder setup 2>/dev/null </dev/null)
  (cd "$P" && treehouse return "$a" --force && treehouse return "$b" --force) >/dev/null 2>&1 </dev/null
  printf '%s %s\n' "$(cd "$a" && pwd -P)" "$(cd "$b" && pwd -P)"
}

OLD_POOL_DIR=$(cd "$P" && "$REAL_TH" pool-dir)
read -r OLD1 OLD2 < <(mkslots)
# The task's copy: old-folder slot 2, on its task branch, unleased (as a plain
# get whose shell exited leaves it).
SLOT=$OLD2
[ "$SCEN" != current-pool-copy ] || SLOT=
# Repoint origin: Treehouse derives the pool folder from origin, so the
# project's pool moves to a new folder and the old one keeps its state.
git clone -q --bare "$C/origin.git" "$C/origin2.git"
git -C "$P" remote set-url origin "$C/origin2.git"
NEW_POOL_DIR=$(cd "$P" && "$REAL_TH" pool-dir)
read -r NEW1 NEW2 < <(mkslots)
[ -n "$SLOT" ] || SLOT=$NEW2
git -C "$SLOT" switch -q -c fm/pool-root
printf 'task=task-x1\nhome=%s\n' "$C/primary-home" > "${SLOT%/*}/.fm-slot-owner"
mkdir -p "$C/primary-home/state"
fm_write_meta "$C/state/task-x1.meta" \
  'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
  "worktree=$SLOT" "project=$P" 'kind=ship' 'mode=local-only' \
  'spawn_gen=teardown-test-task-x1' 'branch=fm/pool-root'
printf 'manual\n' > "$C/config/backlog-backend"

lease_new() {  # <slot-name> <holder>: a real lease by NAME in the current pool
  (cd "$P" && treehouse lease "$1" --lease-holder "$2") >/dev/null 2>&1 </dev/null
}
case "$SCEN" in
  superseded-copy|superseded-copy-base|superseded-copy-no-pool-dir|incident-recovery)
    lease_new 1 other-task ;;
  misdirected-own) lease_new 2 task-x1; lease_new 1 other-task ;;
  misdirected-other) lease_new 2 other-task ;;
  unlanded-commit)
    printf 'unlanded\n' > "$SLOT/unlanded.txt"
    git -C "$SLOT" add unlanded.txt
    git -C "$SLOT" commit -q -m 'unlanded work' ;;
  dirty) printf 'unfinished\n' > "$SLOT/unfinished.txt" ;;
  current-pool-copy) lease_new 1 other-task ;;
esac
: > "$C/treehouse.log"

snap() {  # <label>
  {
    echo "== $1: treehouse pool-dir (from project): $(cd "$P" && "$REAL_TH" pool-dir)"
    echo "== $1: OLD pool state $OLD_POOL_DIR/treehouse-state.json sha256=$(shasum -a 256 "$OLD_POOL_DIR/treehouse-state.json" | cut -c1-16)"
    jq -c '.worktrees[] | {name, path, leased: (.lease != null or .leased == true), lease_holder: (.lease.holder // .lease_holder // null)}' "$OLD_POOL_DIR/treehouse-state.json"
    echo "== $1: NEW (current) pool state $NEW_POOL_DIR/treehouse-state.json sha256=$(shasum -a 256 "$NEW_POOL_DIR/treehouse-state.json" | cut -c1-16)"
    jq -c '.worktrees[] | {name, path, leased: (.lease != null or .leased == true), lease_holder: (.lease.holder // .lease_holder // null)}' "$NEW_POOL_DIR/treehouse-state.json"
    echo "== $1: real treehouse status --json (current pool)"
    (cd "$P" && "$REAL_TH" status --json </dev/null | jq -c '.[] | {name, path, status, lease_holder}')
    echo "== $1: recorded copy HEAD: $(git -C "$SLOT" symbolic-ref -q --short HEAD || echo detached) claim-marker: $([ -e "${SLOT%/*}/.fm-slot-owner" ] && echo present || echo absent)"
    echo "== $1: task record present: $([ -f "$C/state/task-x1.meta" ] && echo yes || echo no)"
  } 2>&1 | sed "s#$C#\$CASE#g" | tee -a "$OUT/transcript.txt"
  cp "$NEW_POOL_DIR/treehouse-state.json" "$OUT/new-state.$1.json"
  cp "$OLD_POOL_DIR/treehouse-state.json" "$OUT/old-state.$1.json"
}

run_td() {  # <label>
  local rc=0
  mkdir -p "$C/code-root-run"
  rm -f "$C/code-root-run/bin"; ln -s "$CODE_BIN" "$C/code-root-run/bin"
  FM_HOME="$C/primary-home" FM_ROOT_OVERRIDE="$C/code-root-run" FM_STATE_OVERRIDE="$C/state" \
    FM_DATA_OVERRIDE="$C/data" FM_CONFIG_OVERRIDE="$C/config" NM_HOME="$C/nm" \
    "$CODE_BIN/fm-teardown.sh" task-x1 > "$OUT/teardown.$1.stdout" 2> "$OUT/teardown.$1.stderr" || rc=$?
  sed -i '' "s#$C#\$CASE#g" "$OUT/teardown.$1.stdout" "$OUT/teardown.$1.stderr"
  log "== $1: fm-teardown.sh task-x1 exit=$rc (code: $CODE_BIN)"
  log "== $1: treehouse commands teardown ran:"
  sed "s#$C#\$CASE#g" "$C/treehouse.log" | grep -v -e '^lease --help' | tee -a "$OUT/transcript.txt"
  : > "$C/treehouse.log"
  log "== $1: teardown stderr (filtered to pool lines):"
  grep -Ei 'pool|lease|slot|REFUSED|refus|landed|nothing' "$OUT/teardown.$1.stderr" | head -20 | tee -a "$OUT/transcript.txt"
  return 0
}

log "scenario=$SCEN  recorded copy=$(sed "s#$C#\$CASE#g" <<<"$SLOT")"
log "old pool=$(sed "s#$C#\$CASE#g" <<<"$OLD_POOL_DIR")  new pool=$(sed "s#$C#\$CASE#g" <<<"$NEW_POOL_DIR")"
snap before
run_td run1
snap after1
case "$SCEN" in
  incident-recovery) CODE_BIN=$WT/bin; log "== rerun with the fixed code (target commit)"; run_td run2; snap after2 ;;
  unlanded-commit) git -C "$P" merge -q --ff-only fm/pool-root; log "== landed the commit into local main; retrying"; run_td run2; snap after2 ;;
  dirty) rm -f "$SLOT/unfinished.txt"; log "== removed the dirt; retrying"; run_td run2; snap after2 ;;
esac
