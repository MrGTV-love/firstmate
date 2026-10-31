#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh in a disposable marked lab home, with a real
# git project, a real bare origin, and a real Treehouse pool under TREEHOUSE_ROOT.
# Usage: drive.sh <code-root> <label> <scenario>
set -u
CODE=$1 LABEL=$2 SC=$3
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M67VAH25S0376YM8DE0BNQ90
OUT=/Users/charlesabrooker/.no-mistakes/evidence/01M67VAH25S0376YM8DE0BNQ90/live/${TAG:-$SC.$LABEL}
mkdir -p "$OUT"
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$OUT/lab-env.stderr")"
printf '%s\n' "$FM_HOME" >> /Users/charlesabrooker/.no-mistakes/evidence/01M67VAH25S0376YM8DE0BNQ90/live/labs-created.txt
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-work.XXXXXX"); W=$(cd "$W" && pwd -P)
export TREEHOUSE_ROOT="$W/pool" GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$W/stub"
printf '#!/bin/sh\necho "no-mistakes unavailable in lab" >&2\nexit 1\n' > "$W/stub/no-mistakes"; chmod +x "$W/stub/no-mistakes"
log() { printf '+ %s\n' "$*" >> "$OUT/setup.log"; }
{
git init -q --bare "$W/origin.git"
git init -q -b main "$W/project"
printf 'base\n' > "$W/project/README"; printf 'cache/\n' > "$W/project/.gitignore"
git -C "$W/project" add -A; git -C "$W/project" commit -qm base
git -C "$W/project" remote add origin "$W/origin.git"; git -C "$W/project" push -q origin main
git -C "$W/project" fetch -q origin
} >> "$OUT/setup.log" 2>&1
SLOT=$(cd "$W/project" && treehouse get --lease --lease-holder task-x1 -b fm/task-x1 2>>"$OUT/setup.log" </dev/null)
SLOT=$(cd "$SLOT" && pwd -P)
log "slot=$SLOT"
printf 'task=task-x1\nhome=%s\n' "$FM_HOME" > "$(dirname "$SLOT")/.fm-slot-owner"
printf 'unpublished work\n' > "$SLOT/work.txt"; git -C "$SLOT" add work.txt; git -C "$SLOT" commit -qm 'unpublished work'
HEAD1=$(git -C "$SLOT" rev-parse HEAD); log "head=$HEAD1"
BCOPY=$SLOT
if [ "${LANDED:-0}" = 1 ]; then git -C "$W/project" merge -q --ff-only fm/task-x1 >>"$OUT/setup.log" 2>&1; log "merged fm/task-x1 into local main (landed baseline)"; fi
if [ "${FOREIGN:-0}" = 1 ]; then
  FC="$SLOT/.claude/worktrees/fc-one"; mkdir -p "${FC%/*}"
  git -C "$W/project" worktree add -q -b fm/fc "$FC" main >>"$OUT/setup.log" 2>&1
  printf 'unpublished foreign bytes\n' > "$FC/fwork.txt"; git -C "$FC" add fwork.txt; git -C "$FC" commit -qm 'unpublished foreign work'
  FHEAD=$(git -C "$FC" rev-parse HEAD); log "foreign copy $FC head=$FHEAD"; BCOPY=$FC
fi
mkdir -p "$FM_HOME/state" "$FM_HOME/data/task-x1"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$SLOT" "branch=fm/task-x1" \
  "project=$W/project" "kind=ship" "mode=local-only" "spawn_gen=lab-task-x1" > "$FM_HOME/state/task-x1.meta"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"
tasks-axi add task-x1 "lab bundle ship" --kind ship --file "$FM_HOME/data/backlog.md" >>"$OUT/setup.log" 2>&1
tasks-axi start task-x1 --file "$FM_HOME/data/backlog.md" >>"$OUT/setup.log" 2>&1
BUNDLE="$W/durable/task.bundle"
make_bundle() {  # documented recipe from bin/fm-teardown.sh header
  local copy=$BCOPY task=task-x1 bundle=$BUNDLE digest tips
  mkdir -p "${bundle%/*}" "$FM_HOME/data/$task"
  git -C "$copy" bundle create "$bundle" --all &&
  git -C "$copy" bundle verify "$bundle" &&
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/$task/preservation-bundles.tsv"
}
hold() {
  local tips; tips=$(cut -f3 "$FM_HOME/data/task-x1/preservation-bundles.tsv")
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$FM_HOME" "$WT/bin/fm-captain-hold.sh" hold task-x1 --owner captain \
    --reason "Land or drop the unlanded commits of task-x1: preserved in bundle $BUNDLE, recorded tips $tips." >>"$OUT/setup.log" 2>&1
}
SLEEPPID=
case "$SC" in
  valid|dirty|process|ignored|unattended|force) [ "${NOBUNDLE:-0}" = 1 ] || { make_bundle >>"$OUT/setup.log" 2>&1; hold; } ;;
  no-bundle) : ;;
  absent-row) make_bundle >>"$OUT/setup.log" 2>&1; printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"; log "backlog has no task-x1 row" ;;
  no-hold|no-hold-remedy) make_bundle >>"$OUT/setup.log" 2>&1 ;;
  missing-tip)
    make_bundle >>"$OUT/setup.log" 2>&1; hold
    git -C "$SLOT" checkout -q -b fm/side; printf 'side\n' > "$SLOT/side.txt"; git -C "$SLOT" add side.txt; git -C "$SLOT" commit -qm side
    SIDE=$(git -C "$SLOT" rev-parse HEAD); git -C "$SLOT" checkout -q fm/task-x1; log "side=$SIDE (not in bundle)" ;;
  tampered) make_bundle >>"$OUT/setup.log" 2>&1; hold; printf 'x' >> "$BUNDLE"; log "appended one byte to bundle" ;;
  in-pool) BUNDLE="$(cd "$W/project" && treehouse pool-dir </dev/null)/task.bundle"; log "bundle=$BUNDLE"; make_bundle >>"$OUT/setup.log" 2>&1; hold ;;
esac
case "$SC" in
  dirty) printf 'unsaved\n' >> "$BCOPY/$([ "$BCOPY" = "$SLOT" ] && echo work.txt || echo fwork.txt)" ;;
  ignored) printf 'only copy of notes\n' > "$BCOPY/notes.local"; printf 'notes.local\n' >> "$(git -C "$BCOPY" rev-parse --path-format=absolute --git-path info/exclude)"; log "ignored: $(git -C "$BCOPY" status --porcelain --ignored | tr '\n' ';')" ;;
  process) (cd "$BCOPY" && exec sleep 600) & SLEEPPID=$!; sleep 1; log "live process pid=$SLEEPPID cwd=$SLOT" ;;
  unattended) touch "$FM_HOME/state/.afk"; log "away record $FM_HOME/state/.afk" ;;
esac
cp "$FM_HOME/data/backlog.md" "$OUT/backlog.before.md"
ARGS=(task-x1); [ "$SC" = force ] && ARGS+=(--force)
rc=0
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$FM_HOME" NM_HOME="$W/nm" PATH="$W/stub:$PATH" "$CODE/bin/fm-teardown.sh" "${ARGS[@]}" >"$OUT/stdout" 2>"$OUT/stderr" </dev/null || rc=$?
if [ "$SC" = no-hold-remedy ] || [ "$SC" = absent-row ]; then
  cmd=$(grep -o "bin/fm-captain-hold.sh hold .*" "$OUT/stderr" | head -1)
  printf '%s\n' "first exit=$rc" "printed remedy: $cmd" > "$OUT/remedy.txt"
  (cd "$WT" && env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$FM_HOME" bash -c "$cmd") >>"$OUT/remedy.txt" 2>&1; echo "remedy exit=$?" >> "$OUT/remedy.txt"
  tasks-axi show task-x1 --file "$FM_HOME/data/backlog.md" >> "$OUT/remedy.txt" 2>&1
  cp "$OUT/stderr" "$OUT/stderr.first"; rc=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$FM_HOME" NM_HOME="$W/nm" PATH="$W/stub:$PATH" "$CODE/bin/fm-teardown.sh" "${ARGS[@]}" >"$OUT/stdout" 2>"$OUT/stderr" </dev/null || rc=$?
  echo "retry exit=$rc" >> "$OUT/remedy.txt"
fi
{
  echo "scenario=$SC code=$LABEL exit=$rc landed=${LANDED:-0} foreign=${FOREIGN:-0} nobundle=${NOBUNDLE:-0}"
  [ -z "${FC:-}" ] || { echo "foreign_copy_present=$([ -e "$FC/.git" ] && echo yes || echo no)"; echo "foreign_notes_local=$(cat "$FC/notes.local" 2>&1)"; echo "held_log=$(cat "$FM_HOME/data/held-foreign-copies.log" 2>&1 | tr '\n' ';')"; }
  [ -z "$SLEEPPID" ] || echo "sleep_alive_after=$(kill -0 "$SLEEPPID" 2>/dev/null && echo yes || echo no)"
  echo "own_notes_local=$(cat "$SLOT/notes.local" 2>&1)"
  echo "copy_head=$(git -C "$SLOT" rev-parse HEAD 2>&1) (work commit $HEAD1)"
  echo "copy_work_txt_present=$([ -e "$SLOT/work.txt" ] && echo yes || echo no)"
  echo "copy_status=$(git -C "$SLOT" status --porcelain --untracked-files=all 2>&1 | tr '\n' ';')"
  echo "meta_present=$([ -e "$FM_HOME/state/task-x1.meta" ] && echo yes || echo no)"
  echo "bundle_present=$([ -f "$BUNDLE" ] && echo yes || echo no)"
  echo "record_present=$([ -f "$FM_HOME/data/task-x1/preservation-bundles.tsv" ] && echo yes || echo no)"
  echo "--- treehouse status (lab pool)"; (cd "$W/project" && treehouse status </dev/null 2>&1) | head -12
  if [ -f "$BUNDLE" ]; then
    git init -q --bare "$W/restored.git"; git -C "$W/restored.git" bundle unbundle "$BUNDLE" >/dev/null 2>&1
    echo "restored work.txt at $HEAD1: $(git -C "$W/restored.git" show "$HEAD1:work.txt" 2>&1)"
    [ -z "${FHEAD:-}" ] || echo "restored fwork.txt at $FHEAD: $(git -C "$W/restored.git" show "$FHEAD:fwork.txt" 2>&1)"
  fi
  echo "--- backlog row after"; tasks-axi show task-x1 --file "$FM_HOME/data/backlog.md" 2>&1 | head -12
} > "$OUT/result.txt" 2>&1
cp "$FM_HOME/data/backlog.md" "$OUT/backlog.after.md" 2>/dev/null
[ -z "$SLEEPPID" ] || kill "$SLEEPPID" 2>/dev/null
# teardown: lab-only pool, lab home, work dir
(cd "$W/project" && treehouse return --force "$SLOT" </dev/null >/dev/null 2>&1) || true
grep -o "/[^ ]*fm-lab-home.sh teardown [^ ]* && rm -rf [^ ]*" "$OUT/lab-env.stderr" > "$OUT/teardown-line.txt"
bash -c "$(cat "$OUT/teardown-line.txt")" >/dev/null 2>&1
rm -rf "$W"
cat "$OUT/result.txt"; echo "--- stderr"; cat "$OUT/stderr"
