#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh against a disposable lab home with the real
# treehouse (private TREEHOUSE_ROOT), real git, real tmux (private TMUX_TMPDIR)
# and real tasks-axi. Only gh, gh-axi and no-mistakes are stubbed, so the run
# never reaches GitHub or the operator's no-mistakes daemon.
#
# Usage: live-gate409.sh <teardown-bin-dir> <variant: landed|slot-unlanded|copy-dirty> <out-dir> [teardown args...]
set -u
unset TMUX TMUX_PANE
BIN=$1 VARIANT=$2 OUT=$3
shift 3
mkdir -p "$OUT"
WT_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6GDEX1JNRK1E4JG7R4C5YC9
eval "$("$WT_ROOT/bin/fm-lab-home.sh" env 2>"$OUT/lab-env.stderr")"
[ -n "${TMUX_TMPDIR:-}" ] || { echo "no private TMUX_TMPDIR" >&2; exit 1; }
LAB=$FM_HOME
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-work.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
cleanup() {
  [ -z "${TMUX_TMPDIR:-}" ] || tmux kill-server 2>/dev/null || true
  "$WT_ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" "$WORK"
}
trap cleanup EXIT
export TREEHOUSE_ROOT="$WORK/treehouse"
mkdir -p "$TREEHOUSE_ROOT" "$WORK/stubs"
for s in gh gh-axi; do
  printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0;; "pr view") echo "error: pull request not found" >&2; exit 1;; esac\nexit 0\n' > "$WORK/stubs/$s"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stubs/no-mistakes"
chmod +x "$WORK/stubs/"*
export PATH="$WORK/stubs:$PATH"
export NM_HOME="$WORK/nm"
G() { git -c user.email=lab@lab -c user.name=lab "$@"; }

# Project: origin bare repo and a clone under the lab home.
G init -q --bare -b main "$WORK/origin.git"
G clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
printf 'base\n' > "$WORK/seed/README"
G -C "$WORK/seed" add README && G -C "$WORK/seed" commit -qm base && G -C "$WORK/seed" push -q origin HEAD:main
PROJ="$LAB/projects/demo"
G clone -q "$WORK/origin.git" "$PROJ"

# Real treehouse slot, durably leased to the task, plus Firstmate's slot claim.
SLOT=$(cd "$PROJ" && treehouse get --lease --lease-holder task-x1 2>"$OUT/treehouse-get.stderr")
SLOT=$(cd "$SLOT" && pwd -P)
printf 'task=task-x1\nhome=%s\n' "$LAB" > "${SLOT%/*}/.fm-slot-owner"

# The task's current copy nested inside the slot, as the gate-409 task had it.
COPY="$SLOT/.claude/worktrees/task-x1-v2"
mkdir -p "${COPY%/*}"
G -C "$PROJ" worktree add -q -b fm/task-x1-v2 "$COPY" origin/main
printf 'ship work\n' > "$COPY/ship.txt"
G -C "$COPY" add ship.txt && G -C "$COPY" commit -qm "ship work"
# The ship's commits reached main (as Vernant PR 3302 did for the real task).
G -C "$COPY" push -q origin HEAD:main
G -C "$PROJ" fetch -q origin
case "$VARIANT" in
  slot-unlanded)
    printf 'slot work\n' > "$SLOT/slot.txt"
    G -C "$SLOT" add slot.txt && G -C "$SLOT" commit -qm "slot work only in the slot root" ;;
  copy-dirty)
    printf 'dirty\n' > "$COPY/dirty.txt" && G -C "$COPY" add dirty.txt ;;
  gone-copy)
    # An earlier teardown already removed the nested copy and its parent dirs.
    G -C "$PROJ" worktree remove "$COPY" && rm -rf "$SLOT/.claude" ;;
esac

# Live endpoint: a tmux window on the lab's private server.
tmux new-session -d -s firstmate -n fm-task-x1 "sleep 3600"

# Task files: record with no prior_worktree= line, inbox, status, tasktmp,
# backlog row, and the two leftover files the failed gate-409 run wrote.
STATE=$LAB/state DATA=$LAB/data
mkdir -p "$STATE/task-x1.inbox" "$WORK/tasktmp" "$DATA"
printf 'steer\n' > "$STATE/task-x1.inbox/001.msg"
printf 'working: live lab\n' > "$STATE/task-x1.status"
printf 'scratch\n' > "$WORK/tasktmp/scratch.txt"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$COPY" "branch=fm/task-x1-v2" "project=$PROJ" "kind=ship" \
  "mode=no-mistakes" "spawn_gen=live-lab-task-x1" "tasktmp=$WORK/tasktmp" > "$STATE/task-x1.meta"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$DATA/backlog.md"
tasks-axi add task-x1 "live lab gate-409 shape" --kind ship --file "$DATA/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$DATA/backlog.md" >/dev/null
printf 'id=task-x1\ndata=%s\nspawn_gen=live-lab-task-x1\ncleanup_incomplete=0\narg=--note\narg=dropped\n' "$DATA" > "$STATE/task-x1.backlog-close"
printf 'spawn_gen=live-lab-task-x1\nslot=\n' > "$STATE/task-x1.teardown-return-pending"
printf 'The captain said the d5 copy may be dropped; its commits are on main.\n' > "$WORK/drop-words.txt"

snap() {
  {
    echo "== state files"; (cd "$STATE" && find . -name 'task-x1*' | LC_ALL=C sort | while read -r f; do
      if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -c1-16)"; else echo "$f/"; fi; done)
    echo "== tasktmp: $([ -d "$WORK/tasktmp" ] && echo present || echo absent)"
    echo "== nested copy: $([ -d "$COPY" ] && echo present || echo absent)"
    echo "== slot root: $([ -d "$SLOT" ] && echo present || echo absent)"
    echo "== slot claim: $(cat "${SLOT%/*}/.fm-slot-owner" 2>/dev/null | tr '\n' ' ' || echo absent)"
    echo "== tmux window: $(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ' || echo none)"
    echo "== treehouse status:"; (cd "$PROJ" && treehouse status 2>&1 | sed 's/^/   /')
    echo "== backlog row: $(tasks-axi show task-x1 --file "$DATA/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)"
  }
}
{
  echo "variant=$VARIANT teardown=$BIN/fm-teardown.sh args=$*"
  echo "slot=$SLOT"; echo "copy=$COPY"
  echo "---- record"; cat "$STATE/task-x1.meta"
  echo "---- BEFORE"; snap
} > "$OUT/transcript.txt" 2>&1
snap > "$OUT/before.snap" 2>&1
args=()
for a in "$@"; do [ "$a" = DROPFILE ] && a="$WORK/drop-words.txt"; args+=("$a"); done
rc=0
( cd "$PROJ" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$BIN/fm-teardown.sh" task-x1 ${args[@]+"${args[@]}"} ) > "$OUT/teardown.stdout" 2> "$OUT/teardown.stderr" || rc=$?
snap > "$OUT/after.snap" 2>&1
for f in backlog-close teardown-return-pending; do [ ! -f "$STATE/task-x1.$f" ] || cp "$STATE/task-x1.$f" "$OUT/after-first.$f"; done
{
  echo "---- TEARDOWN exit=$rc"
  echo "-- stdout (tail)"; tail -15 "$OUT/teardown.stdout"
  echo "-- stderr (tail)"; tail -15 "$OUT/teardown.stderr"
  echo "---- AFTER"; cat "$OUT/after.snap"
  echo "---- before/after diff"; diff "$OUT/before.snap" "$OUT/after.snap" && echo "(no change)"
} >> "$OUT/transcript.txt" 2>&1
echo "exit=$rc"
# Optional second teardown in the same lab (SECOND_BIN, same args): the
# recovery run on whatever the first run left behind.
if [ -n "${SECOND_BIN:-}" ]; then
  rc2=0
  ( cd "$PROJ" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" "$SECOND_BIN/fm-teardown.sh" task-x1 ${args[@]+"${args[@]}"} ) > "$OUT/teardown2.stdout" 2> "$OUT/teardown2.stderr" || rc2=$?
  snap > "$OUT/after2.snap" 2>&1
  {
    echo "==== SECOND TEARDOWN ($SECOND_BIN/fm-teardown.sh) exit=$rc2"
    echo "-- leftover files it started from"; for f in backlog-close teardown-return-pending; do echo "# task-x1.$f"; cat "$OUT/after-first.$f" 2>/dev/null || echo absent; done
    echo "-- stdout (tail)"; tail -15 "$OUT/teardown2.stdout"
    echo "-- stderr (tail)"; tail -15 "$OUT/teardown2.stderr"
    echo "---- AFTER SECOND"; cat "$OUT/after2.snap"
  } >> "$OUT/transcript.txt" 2>&1
  echo "exit2=$rc2"
fi
grep -n 'task-x1' "$DATA/backlog.md" > "$OUT/backlog-final.txt" 2>&1 || true
