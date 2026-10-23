#!/usr/bin/env bash
# Live lab for bin/fm-copy-sweep.sh dead-launcher release.
# Builds throwaway Treehouse pools (real git, real bare origin, real worktree
# copies, real Vernant-format creation locks), a marked disposable FM_HOME from
# bin/fm-lab-home.sh, and a stand-in Vernant closeout driver at the slot's own
# scripts/git-stability/closeout_pr.py run by <slot>/.venv/bin/python. The sweep
# itself, git, du, nice, lsof and the process budget are all real. GIT_TRACE
# records every git command the sweep runs; the driver strips it from its own git.
# Usage: copy-sweep-live-lab.sh <repo-worktree> <python3>
set -u
REPO=$1
PY=$2
LABS=()
BGPIDS=""
cleanup() { for p in $BGPIDS; do kill "$p" 2>/dev/null; done; for l in ${LABS[@]+"${LABS[@]}"}; do rm -rf "$l"; done; }
trap cleanup EXIT
PASS=0
FAILN=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL  %s\n' "$*"; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0\n'; }

export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid
export GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export GIT_CONFIG_NOSYSTEM=1 FM_DURATION_FILE=off

new_world() {  # <name>
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  LABS+=("$LAB")
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
  export HOME="$LAB/hhome" GIT_CONFIG_GLOBAL="$LAB/hhome/.gitconfig"
  mkdir -p "$HOME"
  W="$LAB/world"; TH="$W/th"; SLOT="$TH/pool1/1/repo"; CTL="$W/ctl"
  mkdir -p "$TH/pool1/1" "$CTL"
  git init -q --bare -b main "$W/origin.git"
  git init -q -b main "$SLOT"
  printf 'base\n' > "$SLOT/README"
  git -C "$SLOT" add README && git -C "$SLOT" commit -qm base
  git -C "$SLOT" remote add origin "$W/origin.git"
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
  printf '%s\n' scripts/ .venv/ .claude/ unique.dat node_modules/ >> "$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/scripts/git-stability" "$SLOT/.venv/bin"
  ln -s "$PY" "$SLOT/.venv/bin/python"
  cat > "$SLOT/scripts/git-stability/closeout_pr.py" <<PYEOF
import json, os, subprocess, sys
CTL = "$CTL"
args = sys.argv[1:]
copy = args[1]
execute = "--execute-cleanup" in args
env = {k: v for k, v in os.environ.items() if k != "GIT_TRACE"}
with open(os.path.join(CTL, "closeout.log"), "a") as f:
    f.write(os.getcwd() + "|" + " ".join(args) + "\n")
def ctl(name):
    p = os.path.join(CTL, name)
    return open(p).read().strip() if os.path.exists(p) else None
def git(*a):
    return subprocess.run(["git", *a], env=env).returncode
if not execute:
    if ctl("plan-refuse") is not None:
        print(json.dumps({"allowed": False, "reason": "pull_request_not_merged"}))
        sys.exit(3)
    relock = ctl("plan-relock")
    if relock is not None:
        git("worktree", "unlock", copy)
        git("worktree", "lock", "--reason", relock, copy)
    print(json.dumps({"allowed": True}))
    sys.exit(0)
w = ctl("exec-write")
if w is not None:
    with open(os.path.join(copy, "unique.dat"), "w") as f:
        f.write(w + "\n")
t = ctl("exec-temporary")
if t is not None:
    print(json.dumps({"allowed": False, "reason": t}))
    sys.exit(3)
if ctl("exec-permanent") is not None:
    print("refused: pull request is not merged")
    print("next: wait for the merge")
    sys.exit(3)
if git("worktree", "unlock", copy) != 0:
    sys.exit(4)
sys.exit(git("worktree", "remove", copy))
PYEOF
}

cpath() { printf '%s/.claude/worktrees/%s\n' "$SLOT" "$1"; }

add_copy() {  # <name> [nopush]
  local c; c=$(cpath "$1")
  git -C "$SLOT" worktree add -q -b "fm/$1" "$c"
  printf '%s\n' "$1" > "$c/$1.txt"
  git -C "$c" add "$1.txt" && git -C "$c" commit -qm "$1"
  [ "${2:-}" = nopush ] || git -C "$c" push -q origin "fm/$1"
}

dead_pid() { local p; sleep 0 & p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p"; }

lock_vernant() {  # <name> <pid>
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$2 launcher=$2" "$(cpath "$1")"
}

lock_sha() { shasum -a 256 "$(git -C "$(cpath "$1")" rev-parse --absolute-git-dir)/locked" | awk '{print $1}'; }
registered() { git -C "$SLOT" worktree list --porcelain | grep -qxF "worktree $(cpath "$1")"; }
class_of() { printf '%s\n' "$OUT" | awk -F '\t' -v p="$(cpath "$1")" '$3 == p { print $1 }'; }
preserves() { find "$LAB/data/copy-sweep" -path '*/nested-copy-preserved/*' -name unique.dat -type f 2>/dev/null | sort; }

# The real sweep, as the hourly job runs it: under the process budget, from the
# repository, with only lab paths in its environment.
sweep() {
  RC=0
  OUT=$(cd "$REPO" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEARDOWN_VERNANT_PYTHON \
    FM_HOME="$LAB" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" GIT_TRACE="$W/git-trace.log" \
    nice -n 20 timeout 600 bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh "$@" 2>&1) || RC=$?
  printf '\n$ bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh %s   (exit %s)\n%s\n\n' "$*" "$RC" "$OUT"
}

no_forbidden_git() {
  [ -f "$W/git-trace.log" ] || return 0
  ! grep -E 'trace: (built-in|exec): git .*(worktree (unlock|lock)|--force|( -f( |$))|( -ff( |$)))' "$W/git-trace.log"
}

echo "=================================================================="
echo "S1-S3: report, check, then hourly --apply on a dead-launcher locked copy"
echo "=================================================================="
new_world release
add_copy locked
printf 'durable state\n' > "$(cpath locked)/unique.dat"
mkdir -p "$(cpath locked)/node_modules"
dd if=/dev/urandom of="$(cpath locked)/node_modules/blob.bin" bs=1048576 count=96 2>/dev/null
lock_vernant locked "$(dead_pid)"
add_copy plain
add_copy dirty; printf 'scratch\n' > "$(cpath dirty)/untracked.txt"
LOCK0=$(lock_sha locked)
HEAD0=$(git -C "$(cpath locked)" rev-parse HEAD)
echo "lock: $(cat "$(git -C "$(cpath locked)" rev-parse --absolute-git-dir)/locked")"
sweep
check "S1 report exits 0" [ "$RC" = 0 ]
check "S1 report classes the dead-launcher copy PENDING-DRIVER" [ "$(class_of locked)" = PENDING-DRIVER ]
check "S1 report says not yet proven removable" has "$OUT" "not yet proven removable"
check "S1 report never ran the closeout driver" [ "$(lines "$CTL/closeout.log")" = 0 ]
check "S1 report kept every copy" registered locked
sweep check
check "S2 check exits 0" [ "$RC" = 0 ]
check "S2 check never ran the closeout driver" [ "$(lines "$CTL/closeout.log")" = 0 ]
check "S2 check removed nothing" registered locked
check "S2 lock bytes unchanged after report and check" [ "$(lock_sha locked)" = "$LOCK0" ]
sweep --apply
LAST=$(printf '%s\n' "$OUT" | tail -n 1)
REMLINE=$(printf '%s\n' "$OUT" | grep -F "REMOVED"$'\t'"$(cpath locked)")
check "S3 apply exits 0" [ "$RC" = 0 ]
check "S3 apply printed a REMOVED line for the locked copy" [ -n "$REMLINE" ]
check "S3 REMOVED line reports copy, preserved and net freed GiB" has "$REMLINE" "net freed 0.09 GiB"
check "S3 locked copy is gone from disk and from git" bash -c "[ ! -e '$(cpath locked)' ] && ! git -C '$SLOT' worktree list --porcelain | grep -qxF 'worktree $(cpath locked)'"
check "S3 driver was asked to plan, then to execute, from the slot" [ "$(cat "$CTL/closeout.log")" = "$SLOT|--cleanup-worktree $(cpath locked)"$'\n'"$SLOT|--cleanup-worktree $(cpath locked) --execute-cleanup" ]
P=$(preserves)
check "S3 unique ignored file preserved with exact bytes" [ "$(cat "$P" 2>/dev/null)" = "durable state" ]
check "S3 preserve has a SHA-256 manifest" has "$(cat "$(dirname "$P")/SHA256SUMS" 2>/dev/null)" "$(shasum -a 256 "$P" | awk '{print $1}')  unique.dat"
check "S3 regenerable node_modules was not preserved" bash -c "! find '$LAB/data/copy-sweep' -name blob.bin | grep -q ."
check "S3 branch keeps the exact commit locally and on the remote" bash -c "[ \"\$(git -C '$SLOT' rev-parse refs/heads/fm/locked)\" = $HEAD0 ] && [ \"\$(git -C '$W/origin.git' rev-parse refs/heads/fm/locked)\" = $HEAD0 ]"
check "S3 unlocked proven copy removed too" bash -c "[ ! -e '$(cpath plain)' ]"
check "S3 dirty copy kept" registered dirty
check "S3 final accounting line reports reaped and freed GiB" has "$LAST" "reaped=2 freed="
check "S3 removal log line carries proof and preserved bytes" bash -c "grep -F '$(cpath locked)' '$LAB/data/copy-sweep.log' | grep -q 'preserved_kib='"
check "S3 sweep itself issued no unlock, lock, or force git command" no_forbidden_git
check "S3 no retention receipt or waiting record left" bash -c "[ -z \"\$(ls -A '$LAB/data/copy-sweep/retained' 2>/dev/null)\" ] && [ -z \"\$(ls -A '$LAB/data/copy-sweep/waiting' 2>/dev/null)\" ]"
echo "removal log:"; cat "$LAB/data/copy-sweep.log"
echo "preserve manifest:"; cat "$(dirname "$P")/SHA256SUMS"

echo "=================================================================="
echo "S4: copies that must never reach the driver"
echo "=================================================================="
new_world held
add_copy live
(cd "$W" && exec sleep 600) & LIVEPID=$!; BGPIDS="$BGPIDS $LIVEPID"
lock_vernant live "$LIVEPID"
add_copy foreign
git -C "$SLOT" worktree lock --reason 'hand-held by an operator' "$(cpath foreign)"
add_copy unpushed nopush
lock_vernant unpushed "$(dead_pid)"
add_copy proc
lock_vernant proc "$(dead_pid)"
mkdir -p "$(cpath proc)/sub"
(cd "$(cpath proc)/sub" && exec sleep 600) & PROCPID=$!; BGPIDS="$BGPIDS $PROCPID"
sleep 1
for n in live foreign unpushed proc; do eval "BEFORE_$n=\$(lock_sha $n)"; done
sweep --apply
check "S4 apply exits 0" [ "$RC" = 0 ]
check "S4 live-launcher copy HELD-LOCKED" [ "$(class_of live)" = HELD-LOCKED ]
check "S4 live launcher pid named alive" has "$OUT" "launcher $LIVEPID is alive"
check "S4 foreign-lock copy HELD-LOCKED" [ "$(class_of foreign)" = HELD-LOCKED ]
check "S4 unpushed dead-launcher copy HELD-UNPUSHED" [ "$(class_of unpushed)" = HELD-UNPUSHED ]
check "S4 copy with a live process inside HELD-LIVE-TASK (real lsof)" [ "$(class_of proc)" = HELD-LIVE-TASK ]
check "S4 the driver was never called" [ "$(lines "$CTL/closeout.log")" = 0 ]
for n in live foreign unpushed proc; do
  check "S4 $n still registered with byte-identical lock" bash -c "git -C '$SLOT' worktree list --porcelain | grep -qxF 'worktree $(cpath "$n")' && [ \"\$(shasum -a 256 \"\$(git -C '$(cpath "$n")' rev-parse --absolute-git-dir)/locked\" | awk '{print \$1}')\" = $(eval "printf %s \"\$BEFORE_$n\"") ]"
done
check "S4 sweep itself issued no unlock, lock, or force git command" no_forbidden_git
kill "$LIVEPID" "$PROCPID" 2>/dev/null; wait "$LIVEPID" "$PROCPID" 2>/dev/null

echo "=================================================================="
echo "S5: driver plan refuses"
echo "=================================================================="
new_world planrefuse
add_copy locked; printf 'durable state\n' > "$(cpath locked)/unique.dat"
lock_vernant locked "$(dead_pid)"; LOCK0=$(lock_sha locked)
: > "$CTL/plan-refuse"
sweep --apply
check "S5 a refused plan is not a failure (exit 0)" [ "$RC" = 0 ]
check "S5 copy HELD-LOCKED" [ "$(class_of locked)" = HELD-LOCKED ]
check "S5 driver's own reason recorded" has "$OUT" "pull_request_not_merged"
check "S5 driver planned only, never executed" [ "$(cat "$CTL/closeout.log")" = "$SLOT|--cleanup-worktree $(cpath locked)" ]
check "S5 nothing preserved" [ -z "$(preserves)" ]
check "S5 copy and lock unchanged" bash -c "git -C '$SLOT' worktree list --porcelain | grep -qxF 'worktree $(cpath locked)'"
check "S5 lock bytes unchanged" [ "$(lock_sha locked)" = "$LOCK0" ]

echo "=================================================================="
echo "S6: driver execute refuses permanently"
echo "=================================================================="
new_world permanent
add_copy locked; printf 'durable state\n' > "$(cpath locked)/unique.dat"
lock_vernant locked "$(dead_pid)"
: > "$CTL/exec-permanent"
sweep --apply
FL=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(cpath locked)")
check "S6 run 1 exits 1" [ "$RC" = 1 ]
check "S6 FAILED line carries the driver's own refusal text" has "$FL" "refused: pull request is not merged"
check "S6 copy stays" registered locked
check "S6 retention receipt written" [ -n "$(ls -A "$LAB/data/copy-sweep/retained" 2>/dev/null)" ]
check "S6 preserve kept" [ "$(cat "$(preserves)" 2>/dev/null)" = "durable state" ]
sweep --apply
check "S6 run 2 exits 0" [ "$RC" = 0 ]
check "S6 run 2 holds the copy HELD-LOCKED by its receipt" [ "$(class_of locked)" = HELD-LOCKED ]
check "S6 run 2 did not call the driver again" [ "$(lines "$CTL/closeout.log")" = 2 ]
check "S6 run 2 added no preserve" [ "$(preserves | grep -c .)" = 1 ]

echo "=================================================================="
echo "S7: driver execute refuses with a temporary reason, next run releases"
echo "=================================================================="
new_world temporary
add_copy locked; printf 'durable state\n' > "$(cpath locked)/unique.dat"
lock_vernant locked "$(dead_pid)"; LOCK0=$(lock_sha locked)
printf 'cleanup_lease_conflict\n' > "$CTL/exec-temporary"
sweep --apply
FL=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(cpath locked)")
check "S7 run 1 exits 1" [ "$RC" = 1 ]
check "S7 FAILED line carries the driver's reason" has "$FL" "cleanup_lease_conflict"
check "S7 FAILED line says the next run plans it again" has "$FL" "next sweep run plans it again"
check "S7 no retention receipt" [ -z "$(ls -A "$LAB/data/copy-sweep/retained" 2>/dev/null)" ]
check "S7 this run's preserve discarded" [ -z "$(preserves)" ]
check "S7 original still in the copy, lock unchanged" bash -c "[ \"\$(cat '$(cpath locked)/unique.dat')\" = 'durable state' ] && [ \"\$(shasum -a 256 \"\$(git -C '$(cpath locked)' rev-parse --absolute-git-dir)/locked\" | awk '{print \$1}')\" = $LOCK0 ]"
rm -f "$CTL/exec-temporary"
sweep --apply
check "S7 run 2 exits 0" [ "$RC" = 0 ]
check "S7 run 2 REMOVED the copy" has "$OUT" "REMOVED"$'\t'"$(cpath locked)"
check "S7 run 2 planned and executed again (4 driver calls total)" [ "$(lines "$CTL/closeout.log")" = 4 ]
check "S7 exactly one preserve with the original bytes" bash -c "[ \"\$(find '$LAB/data/copy-sweep' -path '*/nested-copy-preserved/*' -name unique.dat -type f | wc -l | tr -d ' ')\" = 1 ]"
check "S7 sweep itself issued no unlock, lock, or force git command" no_forbidden_git

echo "=================================================================="
echo "S8: content keeps changing -> WAITING, first quiet run preserves once and releases"
echo "=================================================================="
new_world waiting
add_copy locked; printf 'v0\n' > "$(cpath locked)/unique.dat"
lock_vernant locked "$(dead_pid)"
printf 'cleanup_skipped_live_or_unknown\n' > "$CTL/exec-temporary"
printf 'v1\n' > "$CTL/exec-write"
sweep --apply
check "S8 run 1 exits 1" [ "$RC" = 1 ]
check "S8 run 1 keeps its preserve of the old content" has "$OUT" "this run's preserve stays"
rm -f "$CTL/exec-write"
printf 'v2\n' > "$(cpath locked)/unique.dat"
sweep --apply
check "S8 run 2 exits 0" [ "$RC" = 0 ]
check "S8 run 2 classes the copy WAITING (not HELD)" [ "$(class_of locked)" = WAITING ]
check "S8 run 2 did not call the driver" [ "$(lines "$CTL/closeout.log")" = 2 ]
check "S8 run 2 added no preserve" [ "$(preserves | grep -c .)" = 1 ]
rm -f "$CTL/exec-temporary"
sweep --apply
check "S8 run 3 (quiet) exits 0" [ "$RC" = 0 ]
check "S8 run 3 REMOVED the copy" has "$OUT" "REMOVED"$'\t'"$(cpath locked)"
check "S8 run 3 preserved once: v0 and v2 kept" [ "$(preserves | while IFS= read -r f; do cat "$f"; done | sort | tr '\n' ' ')" = "v0 v2 " ]
check "S8 waiting record cleared" [ -z "$(ls -A "$LAB/data/copy-sweep/waiting" 2>/dev/null)" ]

echo "=================================================================="
echo "S9: content changes back to its earlier preserve -> release reports unmeasured freed"
echo "=================================================================="
new_world revert
add_copy locked; printf 'v0\n' > "$(cpath locked)/unique.dat"
mkdir -p "$(cpath locked)/node_modules"
dd if=/dev/urandom of="$(cpath locked)/node_modules/blob.bin" bs=1048576 count=64 2>/dev/null
lock_vernant locked "$(dead_pid)"
printf 'cleanup_lease_conflict\n' > "$CTL/exec-temporary"
printf 'v1\n' > "$CTL/exec-write"
sweep --apply
check "S9 run 1 exits 1" [ "$RC" = 1 ]
rm -f "$CTL/exec-write"
printf 'v0\n' > "$(cpath locked)/unique.dat"
sweep --apply
check "S9 run 2 WAITING" [ "$(class_of locked)" = WAITING ]
rm -f "$CTL/exec-temporary"
sweep --apply
REMLINE=$(printf '%s\n' "$OUT" | grep -F "REMOVED"$'\t'"$(cpath locked)")
check "S9 run 3 exits 0" [ "$RC" = 0 ]
check "S9 REMOVED line says preserved in an earlier run, net freed unmeasured" has "$REMLINE" "preserved - GiB (preserved in an earlier run), net freed - GiB, unmeasured"
check "S9 sizes line discloses the unmeasured removal" has "$OUT" "1 removed copies unmeasured"
check "S9 final freed total does not count unmeasured bytes" has "$(printf '%s\n' "$OUT" | tail -n 1)" "reaped=1 freed=0.00"
check "S9 removal log records preserved_kib=-" bash -c "tail -n 1 '$LAB/data/copy-sweep.log' | grep -q \$'\tpreserved_kib=-\t'"
check "S9 no duplicate preserve" [ "$(preserves | grep -c .)" = 1 ]

echo "=================================================================="
echo "S10: lock replaced with another valid dead-launcher lock while the plan runs"
echo "=================================================================="
new_world relock
add_copy locked; printf 'durable state\n' > "$(cpath locked)/unique.dat"
lock_vernant locked "$(dead_pid)"
NEWPID=$(dead_pid)
printf 'vernant-session-active owner=launcher:%s launcher=%s\n' "$NEWPID" "$NEWPID" > "$CTL/plan-relock"
sweep --apply
check "S10 copy not removed" registered locked
check "S10 no REMOVED line" bash -c "! printf '%s\n' \"\$1\" | grep -q REMOVED" _ "$OUT"
check "S10 driver never executed" bash -c "! grep -q -- --execute-cleanup '$CTL/closeout.log'"

echo "=================================================================="
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAILN"
for l in "${LABS[@]}"; do rm -rf "$l"; done
printf 'labs removed: %s\n' "${#LABS[@]}"
[ "$FAILN" = 0 ]
