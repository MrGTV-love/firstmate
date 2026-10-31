#!/usr/bin/env bash
# Live driver: builds disposable fixtures with the suite's own builders, then runs
# the REAL bin/fm-teardown.sh (new HEAD and the base commit) and keeps transcripts.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M68GF830317Z1CY4KG3GZSJ4
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M68GF830317Z1CY4KG3GZSJ4/live
mkdir -p "$EV"
cd "$WT"
. tests/fm-teardown-helpers.sh
OLDBIN="$TMP_ROOT/base-bin"
mkdir -p "$OLDBIN"
git -C "$WT" archive 3c750632e bin | tar -x -C "$OLDBIN"
OLDBIN="$OLDBIN/bin"
T="$EV/transcript.txt"; : > "$T"

say() { printf '\n===== %s =====\n' "$*" | tee -a "$T"; }
# drive <label> <case> <bin> [extra env...] -- [teardown args]
drive() {
  local label=$1 case_dir=$2 bin=$3; shift 3
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$case_dir/code-root/bin"; ln -s "$bin" "$case_dir/code-root/bin"
  local rc=0
  env ${envs[@]+"${envs[@]}"} \
  FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" PATH="$case_dir/fakebin:$PATH" \
    "$bin/fm-teardown.sh" task-x1 "$@" > "$case_dir/out" 2>&1 || rc=$?
  { echo "\$ bin/fm-teardown.sh task-x1 $* ($label)"; sed "s#$TMP_ROOT#<tmp>#g" "$case_dir/out"; echo "exit=$rc"; } | tee -a "$T"
  LAST_RC=$rc
}
hold() {  # <case> <args...>
  local case_dir=$1; shift
  FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" "$WT/bin/fm-captain-hold.sh" "$@"
}
mkbundle() {  # <case> <bundle>  (header recipe, verbatim)
  local case_dir=$1 bundle=$2 copy="$1/wt" task=task-x1 FM_HOME="$1/data/.."; local digest tips
  mkdir -p "${bundle%/*}" "$case_dir/data/$task"
  git -C "$copy" bundle create "$bundle" --all 2>/dev/null &&
  git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1 &&
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$case_dir/data/$task/preservation-bundles.tsv"
}
newcase() {  # <name>
  local c; c=$(make_case "$1"); write_meta "$c" no-mistakes ship
  printf 'recoverable work\n' > "$c/wt/work.txt"; git -C "$c/wt" add work.txt
  git -C "$c/wt" -c user.email=t@t -c user.name=t commit -qm 'unpublished work'
  printf '%s\n' "$c"
}
held_call() {  # <case> : file captain call naming bundle + tips on existing row
  local c=$1 rec="$1/data/task-x1/preservation-bundles.tsv"
  hold "$c" hold task-x1 --owner captain --reason "Land or drop the unlanded commits of task-x1: preserved in bundle $(cut -f1 "$rec"), recorded tips $(cut -f3 "$rec")." >/dev/null
}
result() { printf 'RESULT %s: %s\n' "$1" "$2" | tee -a "$T"; }

# ---- S1 before vs after, no bundle ----
say "S1 BEFORE (base 3c750632e): unpushed commit, no bundle"
c=$(newcase s1-before); drive base "$c" "$OLDBIN"; b_rc=$LAST_RC
say "S1 AFTER (HEAD): same copy, no bundle"
c=$(newcase s1-after); drive head "$c" "$WT/bin"
[ "$LAST_RC" = "$b_rc" ] && [ -d "$c/wt" ] && grep -q 'bundle preservation unavailable' "$c/out" && grep -q 'bundle create' "$c/out" \
  && result S1 "pass (same exit $LAST_RC, copy kept, predicate + recipe printed)" || result S1 FAIL

# ---- S2 bundle recorded, backlog without a row, no captain call: printed command run verbatim, then teardown ----
say "S2 bundle recorded, backlog has no task-x1 row, no captain call"
c=$(newcase s2); B="$c/bundles/work.bundle"; mkbundle "$c" "$B"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$c/data/backlog.md"
drive head "$c" "$WT/bin"; rc1=$LAST_RC
cmd=$(sed -n -e 's/^Hold it for the captain, then retry ordinary teardown: //p' \
      -e 's/^File the land-or-drop call as its own task, then retry ordinary teardown: //p' \
      -e 's/^File the land-or-drop call as its row, then retry ordinary teardown: //p' "$c/out")
echo "printed command: $cmd" | sed "s#$TMP_ROOT#<tmp>#g" | tee -a "$T"
if [ "$rc1" = 1 ] && [ -d "$c/wt" ] && [[ "$cmd" == 'bin/fm-captain-hold.sh hold task-x1 --title '*' --repo project --owner captain --reason '* ]]; then result S2a "pass (refused, single hold-with-title command carries --repo project)"; else result S2a FAIL; fi
( cd "$WT"; export FM_HOME="$c/primary-home" FM_STATE_OVERRIDE="$c/state" FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" PATH="$c/fakebin:$PATH"; eval "$cmd" ) > "$c/hold.out" 2>&1 || { echo "hold command failed:"; cat "$c/hold.out"; } | tee -a "$T"
echo "backlog row after printed command:" | tee -a "$T"; tasks-axi show task-x1 --full --file "$c/data/backlog.md" 2>&1 | sed "s#$TMP_ROOT#<tmp>#g" | tee -a "$T"
full=$(tasks-axi show task-x1 --full --file "$c/data/backlog.md" 2>&1)
grep -Eq '^  repo: *project$' <<<"$full" && grep -Eq '^  hold_kind: *captain$' <<<"$full" && result S2b "pass (captain-held row under repo project)" || result S2b FAIL
say "S2 retry ordinary teardown, no --force"
drive head "$c" "$WT/bin"
digest=$(shasum -a 256 "$B" | awk '{print $1}'); t=$(cut -f3 "$c/data/task-x1/preservation-bundles.tsv")
if [ "$LAST_RC" = 0 ] && [ ! -e "$c/wt" ] && grep -q "$digest" "$c/out" && grep -q "work.bundle" "$c/out" && grep -q "${t%% *}" "$c/out"; then result S2c "pass (copy removed with no --force; path, sha256, tip printed)"; else result S2c FAIL; fi
r="$TMP_ROOT/restore-s2"; git init -q "$r"
for x in $t; do git -C "$r" fetch -q "$B" "$x:refs/heads/rec-${x:0:8}" || echo "fetch $x failed" | tee -a "$T"; done
git -C "$r" show "rec-${t:0:8}:work.txt" 2>/dev/null | grep -q 'recoverable work' && echo "restored work.txt from bundle: recoverable work" | tee -a "$T" && result S2d "pass (commit recovered from bundle)" || result S2d FAIL
echo "backlog row after teardown:" | tee -a "$T"; tasks-axi show task-x1 --full --file "$c/data/backlog.md" 2>&1 | sed "s#$TMP_ROOT#<tmp>#g" | tee -a "$T"
grep -Eq '^  hold_kind: *captain$' <(tasks-axi show task-x1 --full --file "$c/data/backlog.md" 2>&1) && result S2e "pass (row stays open and captain-held after removal)" || result S2e FAIL

# ---- S3 base commit with the same valid bundle + held call: still refuses (proves behavior is new) ----
say "S3 BEFORE (base) with valid bundle + captain call"
c=$(newcase s3); seed_backlog_in_flight "$c"; B="$c/bundles/work.bundle"; mkbundle "$c" "$B"; held_call "$c"
drive base "$c" "$OLDBIN"; [ "$LAST_RC" != 0 ] && [ -d "$c/wt" ] && result S3 "pass (base refuses: before text)" || result S3 FAIL

# ---- adversarial ----
adv() {  # <name> <mutator-fn> <expect-substring> [env...]
  local name=$1 fn=$2 want=$3; shift 3
  say "ADV $name"
  c=$(newcase "adv-$name"); seed_backlog_in_flight "$c"; B="$c/bundles/work.bundle"; mkbundle "$c" "$B"
  [ "$fn" = m_nocall ] || held_call "$c"
  "$fn" "$c"
  drive head "$c" "$WT/bin" "$@"
  if [ "$LAST_RC" != 0 ] && [ -d "$c/wt" ] && [ -f "$c/state/task-x1.meta" ] && grep -qF -- "$want" "$c/out"; then result "ADV-$name" "pass (refused exit $LAST_RC, copy kept, names: $want)"; else result "ADV-$name" FAIL; fi
}
m_second_tip() { local s; s=$(git -C "$1/wt" commit-tree 'HEAD^{tree}' -p origin/main -m 'second tip'); git -C "$1/wt" update-ref refs/heads/fm/second "$s"; }
m_hash() { printf 'x\n' >> "$1/bundles/work.bundle"; }
m_inside() { mkdir -p "$1/wt/.claude"; mv "$1/bundles/work.bundle" "$1/wt/.claude/work.bundle"; local r="$1/data/task-x1/preservation-bundles.tsv"; awk -v p="$1/wt/.claude/work.bundle" 'BEGIN{FS=OFS="\t"}{$1=p;print}' "$r" > "$r.n" && mv "$r.n" "$r"; }
m_norecord() { rm "$1/data/task-x1/preservation-bundles.tsv"; }
m_verify() { local r="$1/data/task-x1/preservation-bundles.tsv"; printf 'not a bundle\n' > "$1/bundles/work.bundle"; local d; d=$(shasum -a 256 "$1/bundles/work.bundle"|awk '{print $1}'); awk -v d="$d" 'BEGIN{FS=OFS="\t"}{$2=d;print}' "$r" > "$r.n" && mv "$r.n" "$r"; }
m_malformed() { printf 'garbage line\n' >> "$1/data/task-x1/preservation-bundles.tsv"; }
m_dirty() { printf 'uncommitted\n' >> "$1/wt/work.txt"; }
m_none() { :; }
m_nocall() { :; }
m_away() { printf away > "$1/state/.afk"; }
adv two-tips-bundle-lists-one m_second_tip "bundle does not list unlanded tip"
adv sha-changed m_hash "sha256 does not match record"
adv bundle-inside-copy m_inside "bundle is inside"
adv no-record m_norecord "missing preservation record"
adv verify-fails m_verify "git bundle verify failed"
adv malformed-record m_malformed "exactly one line required"
adv dirty-copy-valid-bundle m_dirty "uncommitted"
adv supervision-branch-valid-bundle m_none "REFUSED: the ship deliverable is not landed" FM_SUPERVISION_ACTOR=branch
adv away-valid-bundle m_away "REFUSED: the ship deliverable is not landed"
adv no-captain-call m_nocall "Hold it for the captain, then retry ordinary teardown: bin/fm-captain-hold.sh hold task-x1"
say "ADV extra: two tips, bundle lists both -> removed"
c=$(newcase two-tips-both); seed_backlog_in_flight "$c"; m_second_tip "$c"; B="$c/bundles/work.bundle"; mkbundle "$c" "$B"; held_call "$c"
drive head "$c" "$WT/bin"; [ "$LAST_RC" = 0 ] && [ ! -e "$c/wt" ] && result TWO-TIPS-BOTH "pass (removed)" || result TWO-TIPS-BOTH FAIL

say "ADV own-copy live process with valid bundle + call"
c=$(newcase adv-process); seed_backlog_in_flight "$c"; B="$c/bundles/work.bundle"; mkbundle "$c" "$B"; held_call "$c"
teardown_fixture_start "$c/wt" KILL sleep 300; pid=$TEARDOWN_FIXTURE_PID
drive head "$c" "$WT/bin"
alive=no; kill -0 "$pid" 2>/dev/null && alive=yes
[ "$LAST_RC" != 0 ] && [ -d "$c/wt" ] && [ "$alive" = yes ] && result ADV-own-process "pass (refused exit $LAST_RC, copy kept, process $pid untouched)" || result ADV-own-process "FAIL (rc=$LAST_RC alive=$alive)"
teardown_fixture_stop "$pid"

say "FORCE unchanged: unbundled unpushed copy with --force, base vs head"
c=$(newcase force-base); drive base "$c" "$OLDBIN" -- --force; fb=$LAST_RC; fbk=$([ -d "$c/wt" ] && echo kept || echo removed)
c=$(newcase force-head); drive head "$c" "$WT/bin" -- --force; fh=$LAST_RC; fhk=$([ -d "$c/wt" ] && echo kept || echo removed)
echo "base: exit=$fb copy=$fbk ; head: exit=$fh copy=$fhk" | tee -a "$T"
[ "$fb" = "$fh" ] && [ "$fbk" = "$fhk" ] && result FORCE "pass (same exit and copy outcome)" || result FORCE FAIL
grep '^RESULT' "$T" > "$EV/results.txt"
