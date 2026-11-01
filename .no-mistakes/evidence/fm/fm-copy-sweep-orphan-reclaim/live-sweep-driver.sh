#!/usr/bin/env bash
# Live driver for fm-copy-sweep-orphan-reclaim. It runs the real bin/fm-copy-sweep.sh
# from the run worktree, with real git, real lsof and real ps, on marked disposable
# lab homes (bin/fm-lab-home.sh). Only the Vernant closeout driver is a fixture: the
# real one is Vernant-owned and is not part of this repository. Fault injection is
# named where it is used.
# Usage: live-sweep-driver.sh <worktree> <scenario>...
set -u
WT=$1; shift
SWEEP="$WT/bin/fm-copy-sweep.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
PASSES=0 FAILS=0 BG_PIDS=() LABS=()

ok() { PASSES=$((PASSES + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; }
eq() { if [ "$1" = "$2" ]; then ok "$3 [$1]"; else bad "$3: want [$1] got [$2]"; fi; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3: missing [$2]";; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3: found [$2]";; *) ok "$3";; esac; }
present() { if [ -e "$1" ]; then ok "$2 (present)"; else bad "$2: gone: $1"; fi; }
absent() { if [ -e "$1" ]; then bad "$2: still there: $1"; else ok "$2 (absent)"; fi; }

cleanup() {
  local p l
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  for l in ${LABS[@]+"${LABS[@]}"}; do
    "$WT/bin/fm-lab-home.sh" teardown "$l" >/dev/null 2>&1
    rm -rf "$l"
  done
}
trap cleanup EXIT

new_world() {  # <name>
  printf '\n=== world %s ===\n' "$1"
  eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"
  LABS+=("$FM_HOME")
  LAB=$FM_HOME
  printf 'lab home: %s (marker: %s)\n' "$LAB" "$(ls -a "$LAB/state" | grep -c fm-lab)"
  CLONE="$LAB/projects/example"
  WTS="$CLONE/.claude/worktrees"
  ORIGIN="$LAB/scratch-origin.git"
  NOPOOL="$LAB/scratch-no-pool"
  mkdir -p "$NOPOOL" "$CLONE"
  git -C "$CLONE" init -q -b main
  printf 'seed\n' > "$CLONE/README.md"
  git -C "$CLONE" add README.md
  git -C "$CLONE" commit -qm seed
  git init -q --bare -b main "$ORIGIN"
  git -C "$CLONE" remote add origin "$ORIGIN"
  git -C "$CLONE" push -q -u origin main
  POOLROOT=$NOPOOL
}

# The fixture closeout driver: a real python program at the clone's driver path.
install_driver() {
  mkdir -p "$CLONE/scripts/git-stability"
  cat > "$CLONE/scripts/git-stability/closeout_pr.py" <<'PY'
import json, os, subprocess, sys
args = sys.argv[1:]
copy = args[args.index("--cleanup-worktree") + 1]
execute = "--execute-cleanup" in args
name = os.path.basename(copy)
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "calls.log"), "a") as log:
    log.write(("execute" if execute else "plan") + " " + name + "\n")
if name.startswith("driver-refuses"):
    print(json.dumps({"allowed": False, "reason": "fixture driver refuses this copy"}))
    sys.exit(0)
if name.startswith("archive-retain"):
    print(json.dumps({"allowed": True, "ignored_payload_disposition": "archive_then_retain_tree"}))
    sys.exit(0)
if not execute:
    print(json.dumps({"allowed": True}))
    sys.exit(0)
subprocess.check_call(["git", "worktree", "unlock", copy])
subprocess.check_call(["git", "worktree", "remove", copy])
print(json.dumps({"allowed": True, "removed": True}))
PY
  DRIVER_LOG="$CLONE/scripts/git-stability/calls.log"
  : > "$DRIVER_LOG"
  export FM_TEARDOWN_VERNANT_PYTHON=/usr/bin/python3
}

gone_pid() { local p; sleep 0.1 & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
vlock() { git -C "$CLONE" worktree lock --reason "vernant-session-active owner=launcher:$2 launcher=$2" "$WTS/$1"; }

run() {  # <label> <args...>; real sweep through its documented entry
  local label=$1; shift
  RC=0
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="${LAB_PATH_PREFIX:-}$PATH" FM_HOME="$LAB" FM_COPY_SWEEP_TREEHOUSE_ROOT="$POOLROOT" "$@" 2>&1) || RC=$?
  printf -- '--- %s: exit %s\n%s\n--- end %s\n' "$label" "$RC" "$OUT" "$label"
}
report() { run "$1" bash "$SWEEP"; }
apply() { run "$1" bash "$SWEEP" --apply; }
hourly() { run "$1" bash "$WT/bin/fm-proc-budget.sh" -- bash "$SWEEP" --apply; }
class_of() { printf '%s\n' "$OUT" | awk -F '\t' -v c="$1" 'NF >= 4 && $3 == c { print $1; exit }'; }
row_of() { printf '%s\n' "$OUT" | awk -F '\t' -v c="$1" 'NF >= 4 && $3 == c { print; exit }'; }
preserve_dirs() { local k; k=$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1); find "$LAB/data/copy-sweep" -type d -path "*/nested-copy-preserved/$k" 2>/dev/null; }
pcount() { preserve_dirs "$1" | grep -c . ; }

snapshot() {  # everything a report must not move, apart from Git objects
  git -C "$CLONE" for-each-ref
  git -C "$CLONE" worktree list --porcelain
  find "$CLONE/.git/worktrees" -type f \( -name index -o -name locked -o -name HEAD \) -exec stat -f '%N %m %z' {} + | LC_ALL=C sort
  find "$WTS" -path '*/.git' -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  find "$LAB/data" "$LAB/state" -type f 2>/dev/null | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
squash() {
  new_world squash
  printf '.claude/\nscripts/\n' > "$CLONE/.gitignore"
  for i in $(seq 1 100); do printf 'line %s\n' "$i"; done > "$CLONE/shared.txt"
  git -C "$CLONE" add .gitignore shared.txt
  git -C "$CLONE" commit -qm 'base'
  git -C "$CLONE" push -q origin main
  FORK=$(git -C "$CLONE" rev-parse HEAD)
  git -C "$CLONE" worktree add -qb fm/feature "$WTS/source"
  sed -i '' 's/^line 1$/line 1 delivered/' "$WTS/source/shared.txt"
  git -C "$WTS/source" commit -qam 'delivered part one'
  printf 'second\n' > "$WTS/source/feature.txt"
  git -C "$WTS/source" add feature.txt
  git -C "$WTS/source" commit -qm 'delivered part two'
  TIP=$(git -C "$WTS/source" rev-parse HEAD)
  # A work tree that later gets its change landed, then reverted on main.
  git -C "$CLONE" worktree add -qb fm/revert "$WTS/reverted" "$FORK"
  printf 'landed then reverted\n' > "$WTS/reverted/r.txt"
  git -C "$WTS/reverted" add r.txt
  git -C "$WTS/reverted" commit -qm 'to be reverted'
  git -C "$CLONE" merge -q --squash fm/revert
  git -C "$CLONE" commit -qm 'squash revertable'
  git -C "$CLONE" revert --no-edit HEAD >/dev/null
  # The real squash merge and a later main edit to the same file.
  git -C "$CLONE" merge -q --squash fm/feature
  git -C "$CLONE" commit -qm 'squash feature (#3159)'
  sed -i '' 's/^line 50$/line 50 later main edit/' "$CLONE/shared.txt"
  git -C "$CLONE" commit -qam 'later main edit, same file'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" worktree remove "$WTS/source"
  if git -C "$CLONE" merge-base --is-ancestor "$TIP" origin/main; then bad 'fixture is not a squash merge'; else ok 'tip is no ancestor of origin/main: a true squash merge'; fi
  for n in unlocked-clean locked-clean locked-impossible-pid unique locked-unique tracked untracked locked-tracked similar-message \
           live-launcher driver-refuses archive-retain foreign-lock live-task proc-inside; do
    git -C "$CLONE" worktree add -q --detach "$WTS/$n" "$TIP"
  done
  git -C "$CLONE" worktree add -q --detach "$WTS/conflict" "$FORK"
  sed -i '' 's/^line 50$/line 50 never delivered/' "$WTS/conflict/shared.txt"
  git -C "$WTS/conflict" commit -qam 'conflicting unlanded'
  # One unique clean-merging commit on top of the squash-delivered tip.
  for n in unique locked-unique; do
    printf 'not delivered\n' > "$WTS/$n/unique.txt"
    git -C "$WTS/$n" add unique.txt
    git -C "$WTS/$n" commit -qm 'unique unlanded content'
  done
  printf 'dirty\n' >> "$WTS/tracked/feature.txt"
  printf 'dirty\n' >> "$WTS/locked-tracked/feature.txt"
  printf 'untracked bytes\n' > "$WTS/untracked/new.txt"
  # Same commit message as the merged PR, other bytes: a message is no proof.
  git -C "$WTS/similar-message" commit -q --allow-empty -m 'squash feature (#3159)'
  printf 'other bytes\n' > "$WTS/similar-message/feature.txt"
  git -C "$WTS/similar-message" commit -qam 'squash feature (#3159)'
  mkdir -p "$WTS/archive-retain/.claude/channel-outbox"
  printf '{"m":1}\n' > "$WTS/archive-retain/.claude/channel-outbox/a.jsonl"
  install_driver
  vlock locked-clean "$(gone_pid)"
  vlock locked-unique "$(gone_pid)"
  vlock locked-tracked "$(gone_pid)"
  vlock driver-refuses "$(gone_pid)"
  vlock archive-retain "$(gone_pid)"
  # 999999 is above the macOS PID limit, so ps prints its exact not-found line.
  vlock locked-impossible-pid 999999
  sleep 3600 & LIVE=$!; BG_PIDS+=("$LIVE"); disown "$LIVE" 2>/dev/null
  vlock live-launcher "$LIVE"
  git -C "$CLONE" worktree lock --reason 'some other tool holds this' "$WTS/foreign-lock"
  printf 'worktree=%s\nkind=ship\n' "$WTS/live-task" > "$LAB/state/live-task.meta"
  ( cd "$WTS/proc-inside" && exec sleep 3600 ) & PROC=$!; BG_PIDS+=("$PROC"); disown "$PROC" 2>/dev/null
  sleep 1

  echo; echo '## scenario: report is a dry run and predicts apply'
  git -C "$CLONE" count-objects -v | sed -n 's/^count/objects before/p'
  S1=$(snapshot)
  report 'report (no flag)'
  S2=$(snapshot)
  git -C "$CLONE" count-objects -v | sed -n 's/^count/objects after/p'
  eq 0 "$RC" 'report exits 0'
  eq "$S1" "$S2" 'report moved no ref, worktree, index, lock, copy file, data or state file'
  eq 0 "$(grep -c . "$DRIVER_LOG")" 'report never called the closeout driver'
  has "$OUT" 'copies=' 'report prints a total'
  has "$OUT" 'content already in the default branch' 'report names the squash content proof'
  has "$OUT" 'regenerable:' 'report prints a regenerable total line'
  check_classes report

  echo; echo '## scenario: hourly apply reaps only the proven copies'
  hourly 'hourly apply (bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh --apply)'
  eq 0 "$RC" 'hourly apply exits 0 with refused plans (they hold, they do not fail)'
  absent "$WTS/unlocked-clean" 'M1: squash-merged clean unlocked orphan is reaped'
  absent "$WTS/locked-clean" 'P1: squash-merged clean locked orphan is reaped through the driver'
  absent "$WTS/locked-impossible-pid" 'a lock naming an impossible PID is proved gone (exact macOS not-found line) and released'
  has "$OUT" "REMOVED"$'\t'"$WTS/unlocked-clean" 'apply reports the unlocked removal'
  has "$OUT" "REMOVED"$'\t'"$WTS/locked-clean" 'apply reports the locked removal'
  present "$WTS/unique/unique.txt" 'M1: same copy with one unique commit is held'
  present "$WTS/locked-unique/unique.txt" 'P1: locked copy with one unique commit is held'
  present "$WTS/conflict" 'conflicting unlanded commit is held'
  present "$WTS/reverted/r.txt" 'work landed then reverted on main is held'
  present "$WTS/similar-message" 'same PR message with other bytes is held'
  present "$WTS/tracked" 'tracked edit is held'
  present "$WTS/locked-tracked" 'locked tracked edit is held'
  present "$WTS/untracked/new.txt" 'untracked file is held'
  present "$WTS/live-launcher" 'live launcher is held'
  present "$WTS/driver-refuses" 'driver refusal is held'
  present "$WTS/archive-retain/.claude/channel-outbox/a.jsonl" 'archive_then_retain_tree stays held (Main2323 scope)'
  present "$WTS/foreign-lock" 'foreign lock is held'
  present "$WTS/live-task" 'active task record is held'
  present "$WTS/proc-inside" 'process cwd inside is held'
  check_classes apply
  eq 'second' "$(tail -n 1 "$WTS/unique/feature.txt")" 'held copy keeps its bytes'
  eq 'dirty' "$(tail -n 1 "$WTS/tracked/feature.txt")" 'tracked edit bytes kept'
  CALLS=$(cat "$DRIVER_LOG")
  printf 'driver calls:\n%s\n' "$CALLS"
  has "$CALLS" 'plan locked-clean' 'driver was planned for the locked copy'
  has "$CALLS" 'execute locked-clean' 'driver executed for the locked copy'
  hasnt "$CALLS" 'execute driver-refuses' 'refused plan got no execute'
  hasnt "$CALLS" 'execute archive-retain' 'archive-retain plan got no execute'
  hasnt "$CALLS" 'locked-unique' 'unique locked copy never reached the driver'
  hasnt "$CALLS" 'locked-tracked' 'dirty locked copy never reached the driver'
  hasnt "$CALLS" 'live-launcher' 'live launcher never reached the driver'
  eq 0 "$(find "$LAB" -name '*.tar*' | grep -c .)" 'the sweep wrote no archive tar'
  eq 0 "$(pcount "$WTS/archive-retain")" 'archive-retain got no preserve'
  has "$(row_of "$WTS/live-launcher")" 'is alive' 'live launcher reason names it alive'
  has "$(row_of "$WTS/driver-refuses")" 'fixture driver refuses' 'refused plan row shows the driver words'

  echo; echo '## scenario: repeat apply is stable'
  apply 'second apply'
  eq 0 "$RC" 'second apply exits 0'
  has "$OUT" 'reaped=0' 'second apply reaps nothing more'
  check_classes apply2
  git -C "$CLONE" worktree list --porcelain | grep -c '^worktree ' | sed 's/^/registered worktrees after apply: /'
}

check_classes() {  # <phase>
  local cand=PENDING-DRIVER
  [ "$1" = report ] || cand=REAPABLE-DRIVER
  if [ "$1" = report ]; then
    eq REAPABLE-PROVEN "$(class_of "$WTS/unlocked-clean")" 'report: unlocked squash copy'
    eq PENDING-DRIVER "$(class_of "$WTS/locked-clean")" 'report: locked squash copy'
    eq PENDING-DRIVER "$(class_of "$WTS/locked-impossible-pid")" 'report: lock naming an impossible PID'
    eq PENDING-DRIVER "$(class_of "$WTS/driver-refuses")" 'report: plan not asked yet'
    eq PENDING-DRIVER "$(class_of "$WTS/archive-retain")" 'report: plan not asked yet'
  fi
  eq HELD-UNPUSHED "$(class_of "$WTS/unique")" "$1: unique commit"
  eq HELD-UNPUSHED "$(class_of "$WTS/locked-unique")" "$1: locked unique commit"
  eq HELD-UNPUSHED "$(class_of "$WTS/conflict")" "$1: conflicting commit"
  eq HELD-UNPUSHED "$(class_of "$WTS/reverted")" "$1: landed then reverted"
  eq HELD-UNPUSHED "$(class_of "$WTS/similar-message")" "$1: same message, other bytes"
  eq HELD-DIRTY "$(class_of "$WTS/tracked")" "$1: tracked edit"
  eq HELD-DIRTY "$(class_of "$WTS/locked-tracked")" "$1: locked tracked edit"
  eq HELD-DIRTY "$(class_of "$WTS/untracked")" "$1: untracked file"
  eq HELD-LOCKED "$(class_of "$WTS/live-launcher")" "$1: live launcher"
  eq HELD-LOCKED "$(class_of "$WTS/foreign-lock")" "$1: foreign lock"
  eq HELD-LIVE-TASK "$(class_of "$WTS/live-task")" "$1: active task record"
  eq HELD-LIVE-TASK "$(class_of "$WTS/proc-inside")" "$1: process inside"
  case "$1" in
    apply|apply2)
      eq HELD-LOCKED "$(class_of "$WTS/driver-refuses")" "$1: driver refused"
      eq HELD-LOCKED "$(class_of "$WTS/archive-retain")" "$1: archive_then_retain_tree" ;;
  esac
}

# ---------------------------------------------------------------------------
preserved() {
  new_world preserved
  printf '.claude/\n.import_linter_cache/\n.tac/\ngraft/\nunique.dat\nnode_modules/\nbuild/\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore payloads'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" fetch -q origin
  declare -a NAMES=(cache scratch log generated unique missing mismatch regen regen-build)
  for n in "${NAMES[@]}"; do git -C "$CLONE" worktree add -q --detach "$WTS/$n" origin/main; done
  mkp() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
  mkp "$WTS/cache/.import_linter_cache/payload" 'cache bytes'
  mkp "$WTS/scratch/.tac/tmp/payload" 'scratch bytes'
  mkp "$WTS/log/.claude/logs/payload" 'log bytes'
  mkp "$WTS/generated/graft/payload" 'generated bytes'
  mkp "$WTS/unique/unique.dat" 'unique non-cache bytes'
  mkp "$WTS/missing/.import_linter_cache/payload" 'missing-case bytes'
  mkp "$WTS/mismatch/.import_linter_cache/payload" 'mismatch-case bytes'
  mkp "$WTS/regen/node_modules/pkg/index.js" 'regenerable'
  dd if=/dev/zero of="$WTS/regen/node_modules/pkg/blob" bs=1048576 count=11 2>/dev/null
  mkp "$WTS/regen/.claude/deep/node_modules/deep.js" 'deep regenerable'
  mkp "$WTS/regen/.claude/deep/keep.txt" 'keep scratch output'
  # build/ is no named class: its plain file is unique ignored work and holds an unlocked copy.
  mkp "$WTS/regen-build/build/keep.txt" 'unique build output'
  mkp "$WTS/regen-build/node_modules/pkg/index.js" 'regenerable beside it'
  for pair in cache:.import_linter_cache/payload scratch:.tac/tmp/payload log:.claude/logs/payload generated:graft/payload; do
    eval "HASH_${pair%%:*}=\$(shasum -a 256 \"\$WTS/${pair%%:*}/${pair#*:}\" | cut -d' ' -f1)"
  done
  # Fault injection: a cp wrapper loses or corrupts the preserved bytes of two copies.
  mkdir -p "$LAB/scratch-bin"
  REAL_CP=$(command -v cp); export REAL_CP
  cat > "$LAB/scratch-bin/cp" <<'SH'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit $?
case "${2:-}" in
  */worktrees/missing/.import_linter_cache) rm -f "$3/payload" ;;
  */worktrees/mismatch/.import_linter_cache) printf 'corrupted\n' > "$3/payload" ;;
esac
SH
  chmod +x "$LAB/scratch-bin/cp"

  echo; echo '## scenario: report on preserved classes'
  report 'report'
  for n in cache scratch log generated missing mismatch regen; do eq REAPABLE-PROVEN "$(class_of "$WTS/$n")" "report: $n"; done
  eq HELD-DIRTY "$(class_of "$WTS/unique")" 'report: unique non-cache ignored file'
  eq HELD-DIRTY "$(class_of "$WTS/regen-build")" 'report: regenerable bytes never release a copy with unique ignored work'
  has "$(row_of "$WTS/regen")" 'regenerable 0.01 GiB removed with it, not preserved' 'report row names regenerable bytes'
  hasnt "$(row_of "$WTS/unique")" 'regenerable' 'held row stays unchanged'
  has "$OUT" 'regenerable: 0.01 GiB in 1 proven copies, 0 proven copies not sized' 'report total names regenerable bytes'

  echo; echo '## scenario: apply with hash-preserved bytes and injected preservation faults'
  LAB_PATH_PREFIX="$LAB/scratch-bin:"
  apply 'apply'
  LAB_PATH_PREFIX=
  eq 1 "$RC" 'a failed preservation fails the apply run'
  for pair in cache:.import_linter_cache/payload scratch:.tac/tmp/payload log:.claude/logs/payload generated:graft/payload; do
    n=${pair%%:*} rel=${pair#*:}
    absent "$WTS/$n" "M2/PC1: preserved $n payload does not hold the copy"
    dir=$(preserve_dirs "$WTS/$n")
    eq 1 "$(pcount "$WTS/$n")" "$n has exactly one preserve"
    src=$(eval "printf %s \"\$HASH_$n\"")
    eq "$src" "$(shasum -a 256 "$dir/$rel" | cut -d' ' -f1)" "$n preserved bytes hash equals the source hash"
    has "$(cat "$dir/SHA256SUMS")" "$src  $rel" "$n manifest records the actual hash"
    printf 'class=%s source_sha256=%s preserved=%s\n' "$n" "$src" "$dir/$rel"
  done
  present "$WTS/unique/unique.dat" 'M2: unique non-cache ignored file still holds the copy'
  eq HELD-DIRTY "$(class_of "$WTS/unique")" 'apply: unique ignored file class'
  eq 'missing-case bytes' "$(cat "$WTS/missing/.import_linter_cache/payload")" 'missing preserve keeps the original'
  eq 'mismatch-case bytes' "$(cat "$WTS/mismatch/.import_linter_cache/payload")" 'mismatched preserve keeps the original'
  has "$OUT" "FAILED"$'\t'"$WTS/missing" 'missing preserve is reported as a failure'
  has "$OUT" "FAILED"$'\t'"$WTS/mismatch" 'mismatched preserve is reported as a failure'
  absent "$WTS/regen" 'regenerable bytes do not hold a proven copy'
  dir=$(preserve_dirs "$WTS/regen")
  eq 'keep scratch output' "$(cat "$dir/.claude/deep/keep.txt")" 'other ignored bytes survive by preserve'
  eq 'unique build output' "$(cat "$WTS/regen-build/build/keep.txt")" 'held copy keeps unique ignored bytes'
  present "$WTS/regen-build/node_modules/pkg/index.js" 'held copy keeps its regenerable bytes'
  eq 0 "$(find "$dir" -type d -name node_modules | grep -c .)" 'preserve holds no regenerable directory'
  has "$(printf '%s\n' "$OUT" | grep -F "REMOVED"$'\t'"$WTS/regen")" 'net freed 0.01 GiB' 'removal line shows freed space'
  grep -c . "$LAB/data/copy-sweep.log" | sed 's/^/copy-sweep.log lines: /'
}

# ---------------------------------------------------------------------------
refused() {
  new_world refused
  printf '.claude/\nnode_modules/\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" -c protocol.file.allow=always submodule --quiet add "$ORIGIN" vendored
  git -C "$CLONE" commit -qm 'submodule'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" fetch -q origin
  git -C "$CLONE" worktree add -q --detach "$WTS/refused" origin/main
  git -C "$WTS/refused" -c protocol.file.allow=always submodule --quiet update --init
  mkdir -p "$WTS/refused/.claude" "$WTS/refused/node_modules/big"
  printf 'original bytes\n' > "$WTS/refused/.claude/keep.txt"
  dd if=/dev/zero of="$WTS/refused/node_modules/big/blob" bs=1048576 count=2 2>/dev/null
  BEFORE=$(du -sk "$LAB/data" 2>/dev/null | cut -f1)
  echo; echo '## scenario: three failed applies on one refused copy'
  for r in 1 2 3; do
    apply "apply $r"
    eq 1 "$RC" "run $r exits 1 on the refusal"
    has "$OUT" "FAILED"$'\t'"$WTS/refused"$'\t'"git worktree remove refused" "run $r: git really refused"
    n=$(pcount "$WTS/refused")
    if [ "$n" -le 1 ]; then ok "run $r: at most one preserve [$n]"; else bad "run $r: preserves grew to $n"; fi
    eq 'original bytes' "$(cat "$WTS/refused/.claude/keep.txt")" "run $r: original bytes kept"
    present "$WTS/refused/node_modules/big/blob" "run $r: regenerable bytes kept"
  done
  printf 'data dir KiB before=%s after=%s\n' "${BEFORE:-0}" "$(du -sk "$LAB/data" | cut -f1)"
  find "$LAB/data" -maxdepth 3 | sed "s|$LAB|<lab>|"
}

# ---------------------------------------------------------------------------
fetchfail() {
  new_world fetchfail
  printf '.claude/\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm ignore
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" worktree add -qb fm/x "$WTS/squashed"
  printf 'x\n' > "$WTS/squashed/x.txt"
  git -C "$WTS/squashed" add x.txt
  git -C "$WTS/squashed" commit -qm x
  git -C "$CLONE" merge -q --squash fm/x
  git -C "$CLONE" commit -qm 'squash x'
  git -C "$CLONE" push -q origin main
  echo; echo '## scenario: origin cannot be reached in apply'
  mv "$ORIGIN" "$ORIGIN.moved"
  report 'report with origin gone'
  eq REAPABLE-PROVEN "$(class_of "$WTS/squashed")" 'report reads local refs only'
  apply 'apply with origin gone'
  present "$WTS/squashed/x.txt" 'failed fetch holds the content-proved copy'
  eq HELD-UNPUSHED "$(class_of "$WTS/squashed")" 'failed fetch class'
  eq 0 "$(pcount "$WTS/squashed")" 'failed fetch leaves no preserve'
  mv "$ORIGIN.moved" "$ORIGIN"
  echo; echo '## scenario: local proof is stale: origin main rewound without the squash'
  git --git-dir="$ORIGIN" update-ref refs/heads/main "$(git -C "$CLONE" rev-parse HEAD~1)"
  report 'report on stale ref'
  apply 'apply after main lost the squash'
  present "$WTS/squashed/x.txt" 'apply refetched and held a copy main no longer contains'
  eq HELD-UNPUSHED "$(class_of "$WTS/squashed")" 'class after the refetch'
}

# ---------------------------------------------------------------------------
observe() {
  new_world observe
  printf '.claude/\nscripts/\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm ignore
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" fetch -q origin
  for n in diag sevenstate confined-live confined-gone; do git -C "$CLONE" worktree add -q --detach "$WTS/$n" origin/main; done
  install_driver
  sleep 3600 & LIVE=$!; BG_PIDS+=("$LIVE"); disown "$LIVE" 2>/dev/null
  G1=$(gone_pid); G2=$(gone_pid); G3=$(gone_pid)
  vlock diag "$G1"
  vlock sevenstate "$G2"
  vlock confined-live "$LIVE"
  vlock confined-gone "$G3"
  mkdir -p "$LAB/scratch-bin"
  # Fault injection for the probe only: ps answers per PID, every other call is real.
  cat > "$LAB/scratch-bin/ps" <<SH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    $G1) echo 'ps: failed to read process information' >&2; exit 1 ;;
    $G2) exit 2 ;;
    $LIVE|$G3) exit 126 ;;
  esac
done
exec /bin/ps "\$@"
SH
  chmod +x "$LAB/scratch-bin/ps"
  echo; echo '## scenario: unknown process observation holds; exit 126 uses fm-proc-info.py'
  LAB_PATH_PREFIX="$LAB/scratch-bin:"
  apply 'apply with injected ps results'
  LAB_PATH_PREFIX=
  eq HELD-LOCKED "$(class_of "$WTS/diag")" 'ps exit 1 with a diagnostic is unknown, so held'
  has "$(row_of "$WTS/diag")" 'cannot be observed' 'reason says absence is not proved'
  eq HELD-LOCKED "$(class_of "$WTS/sevenstate")" 'ps exit 2 is unknown, so held'
  eq HELD-LOCKED "$(class_of "$WTS/confined-live")" 'exit 126 + real helper sees the live launcher'
  has "$(row_of "$WTS/confined-live")" 'is alive' 'exit 126 live reason'
  present "$WTS/diag" 'diag copy kept'
  present "$WTS/sevenstate" 'exit 2 copy kept'
  present "$WTS/confined-live" 'live launcher copy kept under exit 126'
  absent "$WTS/confined-gone" 'exit 126 + real helper proves a gone launcher absent, driver releases'
  CALLS=$(cat "$DRIVER_LOG"); printf 'driver calls:\n%s\n' "$CALLS"
  hasnt "$CALLS" 'diag' 'unknown launcher never reached the driver'
  hasnt "$CALLS" 'confined-live' 'live launcher never reached the driver'
}

# ---------------------------------------------------------------------------
drytotal() {
  new_world drytotal
  TH="$LAB/scratch-treehouse"
  SLOT="$TH/pool-a/1/repo"
  mkdir -p "$TH/pool-a/1"
  git clone -q "$ORIGIN" "$SLOT"
  printf '.claude/\n' > "$SLOT/.gitignore"
  git -C "$SLOT" add .gitignore
  git -C "$SLOT" commit -qm ignore
  git -C "$SLOT" push -q origin main
  jq -n --arg p "$SLOT" '{worktrees: [{path: $p}]}' > "$TH/pool-a/treehouse-state.json"
  POOLROOT=$TH
  N="$SLOT/.claude/worktrees"
  git -C "$SLOT" worktree add -qb fm/y "$N/orphan-squashed"
  printf 'y\n' > "$N/orphan-squashed/y.txt"
  git -C "$N/orphan-squashed" add y.txt
  git -C "$N/orphan-squashed" commit -qm y
  git -C "$SLOT" merge -q --squash fm/y
  git -C "$SLOT" commit -qm 'squash y'
  git -C "$SLOT" push -q origin main
  dd if=/dev/zero of="$N/orphan-squashed/.claude-placeholder" bs=1 count=0 2>/dev/null; rm -f "$N/orphan-squashed/.claude-placeholder"
  mkdir -p "$N/orphan-squashed/.claude"
  dd if=/dev/zero of="$N/orphan-squashed/.claude/big" bs=1048576 count=12 2>/dev/null
  git -C "$SLOT" worktree add -q --detach "$N/orphan-unique" origin/main
  printf 'u\n' > "$N/orphan-unique/u.txt"
  git -C "$N/orphan-unique" add u.txt
  git -C "$N/orphan-unique" commit -qm u
  # A closed task: the record is gone, as with the real orphans.
  echo; echo '## scenario: dry run on a pool slot and home lists what would be freed'
  S1=$(git -C "$SLOT" for-each-ref; git -C "$SLOT" worktree list --porcelain)
  report 'report on a pool slot'
  S2=$(git -C "$SLOT" for-each-ref; git -C "$SLOT" worktree list --porcelain)
  eq 0 "$RC" 'dry run exits 0'
  eq "$S1" "$S2" 'dry run moved nothing'
  eq REAPABLE-PROVEN "$(class_of "$N/orphan-squashed")" 'pool slot squash orphan class'
  eq HELD-UNPUSHED "$(class_of "$N/orphan-unique")" 'pool slot unique orphan class'
  has "$OUT" 'REAPABLE-PROVEN=1' 'report counts the candidate'
  has "$(row_of "$N/orphan-squashed")" 'content already in the default branch' 'row names its proof'
  present "$N/orphan-squashed/.claude/big" 'dry run removed nothing'
  printf '%s\n' "$OUT" | grep -E 'GiB|REAPABLE-PROVEN=' | sed 's/^/size line: /' || true
}

for s in "$@"; do "$s"; done
printf '\nRESULT scenarios=[%s] passes=%s fails=%s\n' "$*" "$PASSES" "$FAILS"
[ "$FAILS" = 0 ]
