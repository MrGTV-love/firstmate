#!/usr/bin/env bash
# Live lab drive of bin/fm-teardown.sh's verified-bundle route.
# Runs the real teardown, real git, real tasks-axi, real fm-captain-hold.sh,
# real fleet snapshot and bearings, and real tmux on the lab's private socket,
# against a disposable marked lab home minted by bin/fm-lab-home.sh env.
# Shimmed external services only: treehouse (a plain `git worktree remove
# --force` for the non-pool copy), gh/gh-axi (no PR), no-mistakes (no run) and
# docker (no stacks), so nothing reaches the real pool, forge, daemon or Docker.
# The same shapes are replayed against the base commit's bin/ for before/after.
# Usage: bash live-bundle-teardown-lab.sh <worktree-root>
set -u
ROOT=$1
BASE=3c750632e88113254e14d012ea6240e66ecde1df
cd "$ROOT" || exit 1
unset TMUX TMUX_PANE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
case "$LAB" in */fm-lab.*) ;; *) echo "lab home not minted: '$LAB'"; exit 1 ;; esac
case "${TMUX_TMPDIR:-}" in '') echo "no private TMUX_TMPDIR"; exit 1 ;; esac
cleanup() {
  [ -z "${SLEEP_PID:-}" ] || kill "$SLEEP_PID" 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"
  echo "lab removed: $LAB (exists after: $([ -e "$LAB" ] && echo yes || echo no))"
}
trap cleanup EXIT
echo "lab FM_HOME=$FM_HOME"
echo "lab TMUX_TMPDIR=$TMUX_TMPDIR"
P=$LAB/projects
SHIM=$P/shim
mkdir -p "$SHIM" "$P/copies" "$P/bundles" "$LAB/state" "$LAB/data" "$P/out"
touch "$LAB/state/.last-watcher-beat"
cat > "$SHIM/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_HOME}/projects/treehouse.log"
case "${1:-}" in
  return)
    shift; dir=
    for a in "$@"; do case "$a" in --*) ;; *) dir=$a ;; esac; done
    [ -n "$dir" ] && [ -d "$dir" ] && git -C "$dir" worktree remove --force "$dir"
    ;;
esac
exit 0
SH
cat > "$SHIM/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$SHIM/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1 ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/no-mistakes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/docker"
chmod +x "$SHIM"/*
export PATH="$SHIM:$PATH"

# Disposable project "demo" with a local bare origin.
git init -q --bare "$P/origin.git"
git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P/origin.git" "$P/seed" 2>/dev/null
git -C "$P/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
git -C "$P/seed" push -q origin main
rm -rf "$P/seed"
git clone -q "$P/origin.git" "$P/demo"
git -C "$P/demo" remote set-head origin main
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

PASSES=0 FAILS=0
check() {  # <label> <fixed-string> <file>
  if grep -Fq -- "$2" "$3"; then echo "CHECK PASS [$1]: found: $2"; PASSES=$((PASSES+1))
  else echo "CHECK FAIL [$1]: missing: $2"; FAILS=$((FAILS+1)); fi
}
check_no() {  # <label> <fixed-string> <file>
  if grep -Fq -- "$2" "$3"; then echo "CHECK FAIL [$1]: unexpected: $2"; FAILS=$((FAILS+1))
  else echo "CHECK PASS [$1]: absent: $2"; PASSES=$((PASSES+1)); fi
}
truth() {  # <label> <command...>
  if "${@:2}"; then echo "CHECK PASS [$1]"; PASSES=$((PASSES+1)); else echo "CHECK FAIL [$1]"; FAILS=$((FAILS+1)); fi
}

new_task() {  # <id> [norow]  -> copy at $P/copies/<id> with one unpushed commit
  local id=$1 c=$P/copies/$1
  git -C "$P/demo" worktree add -q -b "fm/$id" "$c" main
  printf 'work of %s\n' "$id" > "$c/work.txt"
  git -C "$c" add work.txt
  git -C "$c" -c user.email=t@t -c user.name=t commit -qm "unpublished work of $id"
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$c" \
    "project=$P/demo" "kind=ship" "mode=local-only" "spawn_gen=live-$id" > "$LAB/state/$id.meta"
  [ "${2:-}" = norow ] && return 0
  tasks-axi add "$id" "live bundle lab $id" --kind ship --repo demo --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
}
# The documented recipe from bin/fm-teardown.sh's header.
record_bundle() {  # <id>
  local task=$1 copy=$P/copies/$1 bundle=$P/bundles/$1.bundle digest tips
  mkdir -p "${bundle%/*}" "$FM_HOME/data/$task"
  git -C "$copy" bundle create "$bundle" --all 2>/dev/null &&
  git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1 &&
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/$task/preservation-bundles.tsv"
}
hold_call() {  # <id>
  local task=$1 bundle tips
  bundle=$(cut -f1 "$FM_HOME/data/$task/preservation-bundles.tsv")
  tips=$(cut -f3 "$FM_HOME/data/$task/preservation-bundles.tsv")
  bin/fm-captain-hold.sh hold "$task" --owner captain \
    --reason "Land or drop the unlanded commits of $task: preserved in bundle $bundle, recorded tips $tips." >/dev/null
}
OUT=
teardown() {  # <tag> <id> [args]  transcript -> $OUT, echoed; returns exit status
  local tag=$1 id=$2 rc=0; shift 2
  OUT=$P/out/$tag.txt
  echo "\$ FM_HOME=\$LAB ${BIN:-bin}/fm-teardown.sh $id $*"
  "${BIN:-bin}/fm-teardown.sh" "$id" "$@" > "$OUT" 2>&1 || rc=$?
  cat "$OUT"
  echo "[exit $rc]"
  return $rc
}
copy_kept() { [ -d "$P/copies/$1" ] && [ -f "$LAB/state/$1.meta" ]; }
copy_gone() { [ ! -d "$P/copies/$1" ] && [ ! -f "$LAB/state/$1.meta" ]; }
rc_is() { [ "$1" = "$2" ]; }

echo; echo "===== S1 baseline: unpushed commit, no bundle -> refused"
new_task live-a; rc=0; teardown s1 live-a || rc=$?
truth "S1 exit 1" rc_is "$rc" 1
check "S1 refusal text" "REFUSED: the ship deliverable is not landed" "$OUT"
truth "S1 copy kept" copy_kept live-a

echo; echo "===== S2 bundle recorded, no captain call -> refused with printed hold command; run it verbatim"
record_bundle live-a; rc=0; teardown s2 live-a || rc=$?
truth "S2 exit 1" rc_is "$rc" 1
check "S2 predicate" "is not held for the captain's land-or-drop call" "$OUT"
truth "S2 copy kept" copy_kept live-a
hint=$(sed -n 's/^Hold it for the captain, then retry ordinary teardown: //p' "$OUT")
echo "printed completing step: $hint"
truth "S2 hint printed" test -n "$hint"
eval "$hint" >/dev/null 2>&1; echo "[printed hold command exit $?]"

echo; echo "===== S3 retry after the printed call -> ordinary teardown (no --force) removes copy"
head_a=$(git -C "$P/copies/live-a" rev-parse HEAD)
digest_a=$(cut -f2 "$LAB/data/live-a/preservation-bundles.tsv")
bundle_a=$(cut -f1 "$LAB/data/live-a/preservation-bundles.tsv")
rc=0; teardown s3 live-a || rc=$?
truth "S3 exit 0" rc_is "$rc" 0
truth "S3 copy and meta removed" copy_gone live-a
check "S3 names bundle path" "$bundle_a" "$OUT"
check "S3 names sha256" "$digest_a" "$OUT"
check "S3 names tip" "$head_a" "$OUT"
stored=$LAB/data/live-a/preserved-bundles/$digest_a.bundle
check "S3 names stored copy" "$stored" "$OUT"
truth "S3 stored digest matches" test "$(shasum -a 256 "$stored" | awk '{print $1}')" = "$digest_a"
echo "--- backlog row after S3:"
tasks-axi show live-a --file "$LAB/data/backlog.md" 2>&1 | tee "$P/out/s3-row.txt"
grep -n 'live-a' "$LAB/data/backlog.md" | tee -a "$P/out/s3-row.txt"
check_no "S3 row not closed [x]" "- [x] live-a" "$P/out/s3-row.txt"
rm -f "$bundle_a"; echo "original source bundle deleted"
git -C "$P/demo" worktree prune
git -C "$P/demo" branch -D fm/live-a >/dev/null 2>&1 || true
git init -q --bare "$P/restore.git"
git -C "$P/restore.git" fetch -q "$stored" "$head_a:refs/heads/recovered" 2>&1
truth "S3 restore from stored copy into fresh repo" test "$(git -C "$P/restore.git" show recovered:work.txt 2>/dev/null)" = "work of live-a"
echo "--- fleet snapshot record for live-a:"
FM_SNAPSHOT_NOW=2026-10-31T12:00:00Z bin/fm-fleet-snapshot.sh --json > "$P/out/snapshot.json" 2>"$P/out/snapshot.err"; echo "[snapshot exit $?]"
jq -c '.backlog.records[] | select(.id=="live-a") | {id,state,captain_drop,hold_kind,hold_set,hold_reason}' "$P/out/snapshot.json" | tee "$P/out/s3-snapshot-row.txt"
check_no "S3 snapshot captain_drop not true" '"captain_drop":true' "$P/out/s3-snapshot-row.txt"
FM_BEARINGS_NOW=2026-10-31T12:00:00Z bin/fm-bearings.sh --json --all-landed > "$P/out/bearings.json" 2>"$P/out/bearings.err"; echo "[bearings exit $?]"
jq -c '{landed_ids: [.landed[]?.id]}' "$P/out/bearings.json" | tee "$P/out/s3-landed.txt"
check_no "S3 not in Recently Landed" '"live-a"' "$P/out/s3-landed.txt"

echo; echo "===== S4 adversarial: bundle lacks a newer unlanded tip -> refused"
new_task live-b; record_bundle live-b; hold_call live-b
git -C "$P/copies/live-b" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'commit made after bundling'
rc=0; teardown s4 live-b || rc=$?
truth "S4 exit 1" rc_is "$rc" 1
check "S4 predicate" "bundle does not list unlanded tip $(git -C "$P/copies/live-b" rev-parse HEAD)" "$OUT"
check "S4 refusal unchanged" "REFUSED: the ship deliverable is not landed" "$OUT"
truth "S4 copy kept" copy_kept live-b

echo; echo "===== S5 adversarial: bundle bytes changed after recording -> refused"
new_task live-c; record_bundle live-c; hold_call live-c
printf 'tamper\n' >> "$P/bundles/live-c.bundle"
rc=0; teardown s5 live-c || rc=$?
truth "S5 exit 1" rc_is "$rc" 1
check "S5 predicate" "sha256 does not match record" "$OUT"
truth "S5 copy kept" copy_kept live-c

echo; echo "===== S6 adversarial: valid bundle + call, uncommitted change -> refused (dirt not waived)"
new_task live-d; record_bundle live-d; hold_call live-d
printf 'dirty\n' >> "$P/copies/live-d/work.txt"
rc=0; teardown s6 live-d || rc=$?
truth "S6 exit 1" rc_is "$rc" 1
check "S6 predicate" "has uncommitted changes" "$OUT"
truth "S6 copy kept" copy_kept live-d

echo; echo "===== S7 adversarial: valid bundle + call, away mode (.afk) -> refused"
new_task live-e; record_bundle live-e; hold_call live-e
: > "$LAB/state/.afk"
rc=0; teardown s7 live-e || rc=$?
truth "S7 exit 1" rc_is "$rc" 1
check "S7 predicate" "recorded bundles require attended teardown" "$OUT"
truth "S7 copy kept" copy_kept live-e
rm -f "$LAB/state/.afk"

echo; echo "===== S8 adversarial: valid bundle + call, live process inside copy"
new_task live-f; record_bundle live-f; hold_call live-f
( cd "$P/copies/live-f" && exec sleep 300 ) & SLEEP_PID=$!
sleep 1
rc=0; teardown s8 live-f || rc=$?
echo "S8 new-code exit=$rc copy_kept=$(copy_kept live-f && echo yes || echo no) sleep_alive=$(kill -0 $SLEEP_PID 2>/dev/null && echo yes || echo no)"
S8_NEW="rc=$rc kept=$(copy_kept live-f && echo yes || echo no) alive=$(kill -0 $SLEEP_PID 2>/dev/null && echo yes || echo no)"
kill $SLEEP_PID 2>/dev/null; wait $SLEEP_PID 2>/dev/null; SLEEP_PID=

echo; echo "===== S9 adversarial: malformed second record line -> refused with named reason"
new_task live-g; record_bundle live-g; hold_call live-g
printf 'garbage line\n' >> "$LAB/data/live-g/preservation-bundles.tsv"
rc=0; teardown s9 live-g || rc=$?
truth "S9 exit 1" rc_is "$rc" 1
check "S9 predicate" "exactly one line required" "$OUT"
truth "S9 copy kept" copy_kept live-g

echo; echo "===== S10 task with no backlog row: printed --title --repo command files row under project demo; retry passes"
new_task live-n norow; record_bundle live-n
rc=0; teardown s10a live-n || rc=$?
truth "S10 first exit 1" rc_is "$rc" 1
check "S10 predicate" "has no backlog row to hold the captain's land-or-drop call" "$OUT"
hint=$(sed -n 's/^File the land-or-drop call as its row, then retry ordinary teardown: //p' "$OUT")
echo "printed completing step: $hint"
case "$hint" in *"--repo demo"*) echo "CHECK PASS [S10 hint names --repo demo]"; PASSES=$((PASSES+1)) ;; *) echo "CHECK FAIL [S10 hint names --repo demo]"; FAILS=$((FAILS+1)) ;; esac
eval "$hint" >/dev/null 2>&1; echo "[printed hold command exit $?]"
grep -n 'live-n' "$LAB/data/backlog.md" | tee "$P/out/s10-row.txt"
jq -c '.backlog.records[]? | select(.id=="live-n") | {id,repo,kind,state,hold_kind}' < <(FM_SNAPSHOT_NOW=2026-10-31T12:00:00Z bin/fm-fleet-snapshot.sh --json 2>/dev/null) | tee -a "$P/out/s10-row.txt"
check "S10 row repo is demo" '"repo":"demo"' "$P/out/s10-row.txt"
rc=0; teardown s10b live-n || rc=$?
truth "S10 retry exit 0" rc_is "$rc" 0
truth "S10 copy removed" copy_gone live-n

echo; echo "===== S11 --force on a bundle-less unpushed copy (compare with base below)"
new_task live-h; rc=0; teardown s11 live-h --force || rc=$?
S11_NEW="rc=$rc kept=$(copy_kept live-h && echo yes || echo no)"; echo "S11 new: $S11_NEW"

echo; echo "################ BASE comparison: same shapes against base $BASE bin/ (before the change)"
mkdir -p "$LAB/base"
git -C "$ROOT" archive "$BASE" bin | tar -x -C "$LAB/base"
BIN=$LAB/base/bin
echo "--- BASE S1: unpushed commit, no bundle"
new_task base-1; rc=0; teardown b1 base-1 || rc=$?
truth "BASE S1 exit 1" rc_is "$rc" 1
truth "BASE S1 copy kept" copy_kept base-1
diff <(grep -v 'base-1\|live-a' "$P/out/b1.txt" | sed 's/[0-9a-f]\{7,40\}/<sha>/g') <(grep -v 'base-1\|live-a' "$P/out/s1.txt" | sed 's/[0-9a-f]\{7,40\}/<sha>/g') > "$P/out/s1-vs-base.diff" && echo "S1 refusal identical to base (ids/shas masked)" || { echo "S1 differs from base:"; cat "$P/out/s1-vs-base.diff"; }
echo "--- BASE S3 shape: verified bundle + captain call (before: refused)"
new_task base-3; record_bundle base-3; hold_call base-3; rc=0; teardown b3 base-3 || rc=$?
truth "BASE S3 exit 1 (bundle ignored before)" rc_is "$rc" 1
truth "BASE S3 copy kept" copy_kept base-3
echo "--- BASE S6: dirty copy"
new_task base-6; printf 'dirty\n' >> "$P/copies/base-6/work.txt"; rc=0; teardown b6 base-6 || rc=$?
truth "BASE S6 exit 1" rc_is "$rc" 1
check "BASE S6 predicate" "has uncommitted changes" "$OUT"
echo "--- BASE S8: live process in copy"
new_task base-8
( cd "$P/copies/base-8" && exec sleep 300 ) & SLEEP_PID=$!
sleep 1
rc=0; teardown b8 base-8 || rc=$?
S8_BASE="rc=$rc kept=$(copy_kept base-8 && echo yes || echo no) alive=$(kill -0 $SLEEP_PID 2>/dev/null && echo yes || echo no)"
kill $SLEEP_PID 2>/dev/null; wait $SLEEP_PID 2>/dev/null; SLEEP_PID=
echo "S8 new (with valid bundle): $S8_NEW"
echo "S8 base (no bundle):       $S8_BASE"
echo "--- BASE S11: --force on bundle-less copy"
new_task base-11; rc=0; teardown b11 base-11 --force || rc=$?
S11_BASE="rc=$rc kept=$(copy_kept base-11 && echo yes || echo no)"
echo "S11 new: $S11_NEW"; echo "S11 base: $S11_BASE"
truth "S11 --force same as base" test "$S11_NEW" = "$S11_BASE"
truth "S8 process outcome same as base" test "$S8_NEW" = "$S8_BASE"

echo; echo "SUMMARY: $PASSES checks passed, $FAILS checks failed"
