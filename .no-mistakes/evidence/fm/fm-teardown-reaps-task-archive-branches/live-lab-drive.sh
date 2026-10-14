#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh, real git, marked lab FM_HOME (stock layout).
# Stand-ins (not the product): forge gh/gh-axi, tmux, treehouse, docker, no-mistakes.
set -u
LAB=/Users/charlesabrooker/fm-lab/fm-teardown-reaps-task-archive-branches
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4XSA40PXMFF1K4MDWKBC5FJ
TD="$WT/bin/fm-teardown.sh"
FB="$LAB/fakebin"
RESULTS="$LAB/results"
mkdir -p "$FB" "$RESULTS"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
FAILS=0

for b in treehouse docker no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/$b"; done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/endpoint.log"\nexit 0\n' "$LAB" > "$FB/tmux"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/treehouse.log"\nexit 0\n' "$LAB" > "$FB/treehouse"
cat > "$FB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$FB"/*

say() { printf '%s\n' "$*"; }
ck() {  # name cond-result msg
  if [ "$2" = ok ]; then say "  PASS: $1"; else say "  FAIL: $1 -- $3"; FAILS=$((FAILS+1)); fi
}
ref_sha() { git -C "$1" rev-parse --verify -q "refs/heads/$2" 2>/dev/null || true; }

# forge shim: merged PR 7 with head $2 and merge commit $3 ("" = no merge object); mode "down" = unreachable
set_forge() {  # case head merge|down
  local c=$1 head=$2 merge=${3:-}
  if [ "$head" = down ]; then
    printf '#!/usr/bin/env bash\necho "error: forge unreachable" >&2\nexit 1\n' > "$c/fakebin/gh"
    cp "$c/fakebin/gh" "$c/fakebin/gh-axi"
  else
    cat > "$c/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED '$head' '$merge'; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$head' 'https://github.com/example/repo/pull/7'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head'; exit 0 ;;
    esac ;;
esac
exit 0
SH
    cp "$c/fakebin/gh" "$c/fakebin/gh-axi"
  fi
  chmod +x "$c/fakebin/gh" "$c/fakebin/gh-axi"
}

# newcase <name> [taskid]: bare origin + project clone under the lab + task worktree.
newcase() {
  local name=$1 id=${2:-task-x1} c
  c="$LAB/cases/$name"
  mkdir -p "$c/fakebin"; cp "$FB"/* "$c/fakebin/"
  git init -q --bare "$c/origin.git"; git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/_seed" 2>/dev/null
  git -C "$c/_seed" commit -q --allow-empty -m baseline; git -C "$c/_seed" push -q origin main; rm -rf "$c/_seed"
  git clone -q "$c/origin.git" "$c/project"; git -C "$c/project" remote set-head origin main 2>/dev/null
  git -C "$c/project" worktree add -q -b "fm/$id" "$c/wt" main
  printf '%s\n' "$c"
}
wtfile() { printf '%s\n' "$3" > "$1/wt/$2"; git -C "$1/wt" add -- "$2"; git -C "$1/wt" commit -q -m "${4:-add $2}"; }
write_meta() {  # case [id]
  local c=$1 id=${2:-task-x1}
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$c/wt" "project=$c/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=live-$id" > "$LAB/state/$id.meta"
  touch "$LAB/state/.last-watcher-beat"
}
pr_meta() { printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$LAB/state/${2:-task-x1}.meta"; }
squash() {  # case [id]: real squash merge of fm/<id> into project main, pushed; prints merge sha
  local c=$1 id=${2:-task-x1}
  git -C "$c/project" merge -q --squash "fm/$id" >/dev/null && git -C "$c/project" commit -qm "squash $id"
  git -C "$c/project" push -q origin main; git -C "$c/project" rev-parse HEAD
}
land_content() {  # case file content -> merge sha of a squash-lookalike pushed to origin
  local c=$1 t="$1/_land"
  git clone -q "$c/origin.git" "$t"; printf '%s\n' "$3" > "$t/$2"; git -C "$t" add -- "$2"
  git -C "$t" commit -q -m "squash $2"; git -C "$t" push -q origin HEAD:main; git -C "$t" rev-parse HEAD; rm -rf "$t"
}

# run_td <case> <id> [args]: the REAL teardown with FM_HOME=$LAB, no overrides.
run_td() {
  local c=$1 id=$2; shift 2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" NM_HOME="$c/nm" PATH="$c/fakebin:$PATH" \
      "$TD" "$id" "$@" > "$c/stdout" 2> "$c/stderr"
}
show() { say "  --- teardown stderr ($1) ---"; sed 's/^/  | /' "$1" ; }
reset_home() { rm -rf "$LAB/state" "$LAB/data" && mkdir -p "$LAB/state" "$LAB/data"; touch "$LAB/state/.last-watcher-beat"; }

############ S1: reap ancestor + patch-equivalent archives
say "=== S1 squash-merged task: reap ancestor and patch-equivalent custody archives"
reset_home; c=$(newcase s1); write_meta "$c"
base=$(git -C "$c/wt" rev-parse HEAD)
wtfile "$c" 'feature file.txt' alpha "add feature"; submitted=$(git -C "$c/wt" rev-parse HEAD)
replayed=$(printf 'replayed feature\n' | git -C "$c/project" commit-tree "$(git -C "$c/wt" rev-parse 'HEAD^{tree}')" -p "$base")
wtfile "$c" later.txt beta "pipeline follow-up"; pipeline=$(git -C "$c/wt" rev-parse HEAD)
git -C "$c/project" branch archive/task-x1-submitted-0a0a0a01 "$submitted"
git -C "$c/project" branch archive/task-x1-submitted-0a0a0a02 "$replayed"
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b01 "$pipeline"
git -C "$c/project" branch archive/other-pipeline-final "$pipeline"
git -C "$c/project" branch archive/task-x1 "$submitted"
git -C "$c/project" branch unrelated "$pipeline"
head=$(git -C "$c/wt" rev-parse HEAD); merge=$(squash "$c"); pr_meta "$c"; set_forge "$c" "$head" "$merge"
git -C "$c/project" for-each-ref refs/heads --format='%(refname) %(objectname)' > "$c/refs.before"
run_td "$c" task-x1; rc=$?; show "$c/stderr"
git -C "$c/project" for-each-ref refs/heads --format='%(refname) %(objectname)' > "$c/refs.after"
say "  refs before/after diff:"; diff "$c/refs.before" "$c/refs.after" | sed 's/^/  /'
ck "teardown exit 0" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
for n in submitted-0a0a0a01 submitted-0a0a0a02 pipeline-0b0b0b01; do
  ck "archive/task-x1-$n deleted" "$([ -z "$(ref_sha "$c/project" archive/task-x1-$n)" ] && echo ok)" "still present"
  ck "reaped message names $n" "$(grep -qF "reaped archive/task-x1-$n" "$c/stderr" && echo ok)" "no message"
done
ck "archive/other-pipeline-final kept" "$([ "$(ref_sha "$c/project" archive/other-pipeline-final)" = "$pipeline" ] && echo ok)" ""
ck "archive/task-x1 (non-custody) kept" "$([ "$(ref_sha "$c/project" archive/task-x1)" = "$submitted" ] && echo ok)" ""
ck "unrelated kept" "$([ "$(ref_sha "$c/project" unrelated)" = "$pipeline" ] && echo ok)" ""
ck "task meta retired" "$([ ! -e "$LAB/state/task-x1.meta" ] && echo ok)" "meta still there"

############ S2: prefix collision task-x1 vs task-x1-2 and non-custody names
say "=== S2 teardown task-x1 never judges task-x1-2 or non-custody names"
reset_home; c=$(newcase s2); write_meta "$c"
wtfile "$c" feature.txt alpha feature; head=$(git -C "$c/wt" rev-parse HEAD)
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b01 "$head"
others="task-x1-2-pipeline-0b0b0b02 task-x1-2-submitted-0a0a0a02 task-x1-pipeline-final task-x1-pipeline-0B0B0B03 task-x1-pipeline-0b0b0b044 task-x1-submitted-0a0a0a05-extra"
for n in $others; do git -C "$c/project" branch "archive/$n" "$head"; done
merge=$(squash "$c"); pr_meta "$c"; set_forge "$c" "$head" "$merge"
run_td "$c" task-x1; rc=$?; show "$c/stderr"
ck "teardown exit 0" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
ck "own archive reaped" "$([ -z "$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b01)" ] && echo ok)" ""
for n in $others; do
  ck "archive/$n untouched" "$([ "$(ref_sha "$c/project" archive/$n)" = "$head" ] && echo ok)" "moved/deleted"
  ck "archive/$n never printed" "$(grep -qF "archive/$n" "$c/stderr" "$c/stdout" && echo bad || echo ok)" "named in output"
done

############ S3: unlanded edits, cherry-invisible merge, checked-out archive
say "=== S3 landed teardown keeps+names unlanded edits, edited merge, checked-out archive"
reset_home; c=$(newcase s3); write_meta "$c"
wtfile "$c" feature.txt alpha "landed feature"; landed=$(git -C "$c/wt" rev-parse HEAD)
wtfile "$c" extra.txt unlanded "unlanded archive edit"; extra=$(git -C "$c/wt" rev-parse HEAD)
mrg=$(git -C "$c/wt" rev-parse "$landed^{tree}" | xargs -I{} sh -c "printf 'empty second parent\n' | git -C '$c/wt' commit-tree {} -p $landed")
edited=$(printf 'edited merge\n' | git -C "$c/project" commit-tree "$(git -C "$c/wt" rev-parse 'HEAD^{tree}')" -p "$landed" -p "$mrg")
git -C "$c/project" branch archive/task-x1-submitted-0a0a0a03 "$extra"
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b02 "$edited"
git -C "$c/wt" reset -q --hard "$landed"
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b03 "$landed"
git -C "$c/project" worktree add -q "$c/archive-held" archive/task-x1-pipeline-0b0b0b03
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b04 "$landed"
merge=$(squash "$c"); pr_meta "$c"; set_forge "$c" "$landed" "$merge"
run_td "$c" task-x1; rc=$?; show "$c/stderr"
ck "teardown exit 0" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
ck "unlanded-edit archive kept" "$([ "$(ref_sha "$c/project" archive/task-x1-submitted-0a0a0a03)" = "$extra" ] && echo ok)" ""
ck "edited-merge archive kept" "$([ "$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b02)" = "$edited" ] && echo ok)" ""
ck "checked-out archive kept" "$([ "$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b03)" = "$landed" ] && echo ok)" ""
ck "plain carried archive 04 reaped" "$([ -z "$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b04)" ] && echo ok)" ""
for n in submitted-0a0a0a03 pipeline-0b0b0b02 pipeline-0b0b0b03; do
  ck "keeping notice names $n" "$(grep -qF "keeping archive/task-x1-$n" "$c/stderr" && echo ok)" "no notice"
done
ck "other copy's HEAD still on archive branch" "$([ "$(git -C "$c/archive-held" symbolic-ref HEAD)" = refs/heads/archive/task-x1-pipeline-0b0b0b03 ] && echo ok)" "detached"

############ S4: content differs / merge proof missing / forge unreachable
say "=== S4 retain archives when merge content differs, merge proof missing, forge down"
for shape in different missing offline; do
  reset_home; c=$(newcase "s4-$shape"); write_meta "$c"
  wtfile "$c" feature.txt alpha feature; head=$(git -C "$c/wt" rev-parse HEAD)
  git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b01 "$head"; pr_meta "$c"
  case "$shape" in
    different) merge=$(land_content "$c" feature.txt different); git -C "$c/project" fetch -q origin; set_forge "$c" "$head" "$merge" ;;
    missing) land_content "$c" feature.txt alpha >/dev/null; set_forge "$c" "$head" "" ;;
    offline) land_content "$c" feature.txt alpha >/dev/null; set_forge "$c" down ;;
  esac
  run_td "$c" task-x1; rc=$?; say " [$shape]"; show "$c/stderr"
  ck "$shape: teardown exit 0 (ordinary landing proof)" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
  ck "$shape: archive kept" "$([ "$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b01)" = "$head" ] && echo ok)" "deleted!"
  ck "$shape: archive named in keeping notice" "$(grep -qF 'keeping archive/task-x1-pipeline-0b0b0b01' "$c/stderr" && echo ok)" ""
done

############ S5: deleted + pathspec-like filename
say "=== S5 deleted path and pathspec-like filename compared literally"
for shape in matching restored-source; do
  reset_home; c=$(newcase "s5-$shape"); write_meta "$c"
  file=':(literal)renamed file.txt'
  printf 'rename me\n' > "$c/project/old.txt"; git -C "$c/project" add old.txt; git -C "$c/project" commit -qm "baseline file"; git -C "$c/project" push -q origin main
  base=$(git -C "$c/project" rev-parse HEAD); git -C "$c/wt" reset -q --hard "$base"
  git -C "$c/wt" --literal-pathspecs mv -- old.txt "$file"; git -C "$c/wt" commit -qm rename
  head=$(git -C "$c/wt" rev-parse HEAD); arch=archive/task-x1-pipeline-0b0b0b05
  git -C "$c/project" branch "$arch" "$head"
  if [ $shape = matching ]; then merge=$(squash "$c")
  else
    printf 'rename me\n' > "$c/project/$file"; git -C "$c/project" --literal-pathspecs add -- "$file"
    git -C "$c/project" commit -qm "incomplete rename squash"; merge=$(git -C "$c/project" rev-parse HEAD); git -C "$c/project" push -q origin main
  fi
  pr_meta "$c"; set_forge "$c" "$head" "$merge"
  run_td "$c" task-x1; rc=$?; say " [$shape]"; show "$c/stderr"
  ck "$shape: teardown exit 0" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
  if [ $shape = matching ]; then
    ck "matching rename reaped" "$([ -z "$(ref_sha "$c/project" $arch)" ] && echo ok)" "still there"
  else
    ck "incomplete rename (deletion not carried) kept" "$([ "$(ref_sha "$c/project" $arch)" = "$head" ] && echo ok)" "deleted!"
    ck "incomplete rename named" "$(grep -qF "keeping $arch" "$c/stderr" && echo ok)" ""
  fi
done

############ S6: refusal + forced discard
say "=== S6 unlanded refusal and authorized forced discard preserve archives"
reset_home; c=$(newcase s6); write_meta "$c"
wtfile "$c" feature.txt unlanded "unlanded feature"; head=$(git -C "$c/wt" rev-parse HEAD)
git -C "$c/project" branch archive/task-x1-submitted-0a0a0a04 "$head"
run_td "$c" task-x1; rc=$?; show "$c/stderr"
ck "unlanded teardown refuses (non-zero)" "$([ $rc != 0 ] && echo ok)" "rc=$rc"
ck "archive intact after refusal" "$([ "$(ref_sha "$c/project" archive/task-x1-submitted-0a0a0a04)" = "$head" ] && echo ok)" ""
ck "task meta retained after refusal" "$([ -e "$LAB/state/task-x1.meta" ] && echo ok)" ""
ck "worktree retained after refusal" "$([ -d "$c/wt" ] && echo ok)" ""
words="$c/captain-words.txt"; printf 'Captain approved discarding this work (lab fixture).\n' > "$words"
run_td "$c" task-x1 --force --drop-file "$words"; rc=$?; say " [forced]"; show "$c/stderr"
ck "authorized forced discard succeeds" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
ck "archive preserved through forced discard" "$([ "$(ref_sha "$c/project" archive/task-x1-submitted-0a0a0a04)" = "$head" ] && echo ok)" "deleted!"
ck "forced notice names the kept archive" "$(grep -qF 'keeping archive/task-x1-submitted-0a0a0a04' "$c/stderr" && echo ok)" ""

############ S7: reassigned slot, finished task retires without touching claimant
say "=== S7 finished task on reassigned slot retires; claimant work/process/refs unchanged"
rm -f "$LAB/endpoint.log" "$LAB/treehouse.log"; reset_home; c=$(newcase s7); write_meta "$c" >/dev/null
wtfile "$c" delivered.txt 'merged task work' 'delivered task'; delivered=$(git -C "$c/wt" rev-parse HEAD)
git -C "$c/wt" push -q origin HEAD:main
set_forge "$c" "$delivered" "$delivered"
git -C "$c/project" branch archive/task-x1-pipeline-0b0b0b06 "$delivered"
mkdir -p "$c/pool/1"; slot="$c/pool/1/project"
git -C "$c/project" worktree move "$c/wt" "$slot"
git -C "$slot" checkout -q -b fm/live-task
printf 'claimant committed work\n' > "$slot/live.txt"; git -C "$slot" add live.txt; git -C "$slot" commit -qm 'unlanded claimant work'
printf 'claimant tracked edit\n' >> "$slot/live.txt"; printf 'claimant untracked work\n' > "$slot/scratch.txt"
mkdir -p "$slot/.claude"; printf 'claimant hook bytes\n' > "$slot/.claude/settings.local.json"
printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" > "$c/pool/treehouse-state.json"
printf 'task=live-task\nhome=%s\n' "$LAB" > "$c/pool/1/.fm-slot-owner"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$slot" "project=$c/project" "kind=ship" \
  "mode=no-mistakes" "branch=fm/task-x1" "spawn_gen=finished" "pr=https://github.com/example/repo/pull/7" "pr_head=$delivered" > "$LAB/state/task-x1.meta"
printf '%s\n' "window=firstmate:fm-live-task" "endpoint_task_id=live-task" "worktree=$slot" "project=$c/project" "kind=ship" "spawn_gen=live" > "$LAB/state/live-task.meta"
printf 'finished task\n' > "$LAB/state/task-x1.status"; printf 'live task\n' > "$LAB/state/live-task.status"
cp "$LAB/state/live-task.meta" "$c/lm.before"; cp "$LAB/state/live-task.status" "$c/ls.before"
cp "$c/pool/1/.fm-slot-owner" "$c/claim.before"; cp "$c/pool/treehouse-state.json" "$c/lease.before"
git -C "$slot" status --porcelain --untracked-files=all > "$c/st.before"; git -C "$slot" symbolic-ref HEAD > "$c/br.before"
git -C "$c/project" for-each-ref refs/heads --format='%(refname) %(objectname)' | grep -v 'archive/task-x1-pipeline-0b0b0b06' > "$c/refs.before"
head=$(git -C "$slot" rev-parse HEAD)
(cd "$slot" && exec sleep 300) & worker=$!
run_td "$c" task-x1; rc=$?; show "$c/stderr"
alive=no; kill -0 "$worker" 2>/dev/null && alive=yes; kill "$worker" 2>/dev/null; wait "$worker" 2>/dev/null
ck "finished task teardown exit 0" "$([ $rc = 0 ] && echo ok)" "rc=$rc"
ck "claimant process still alive" "$([ $alive = yes ] && echo ok)" "killed"
ck "finished meta/status removed" "$([ ! -e "$LAB/state/task-x1.meta" ] && [ ! -e "$LAB/state/task-x1.status" ] && echo ok)" ""
ck "finished endpoint closed" "$(grep -qF 'kill-window -t =firstmate:=fm-task-x1' "$LAB/endpoint.log" && echo ok)" ""
ck "claimant endpoint NOT closed" "$(grep -qF 'fm-live-task' "$LAB/endpoint.log" && echo bad || echo ok)" ""
ck "pool not administered (no treehouse call)" "$([ ! -e "$LAB/treehouse.log" ] && echo ok)" "$(cat "$LAB/treehouse.log" 2>/dev/null)"
ck "claimant meta/status unchanged" "$(cmp -s "$c/lm.before" "$LAB/state/live-task.meta" && cmp -s "$c/ls.before" "$LAB/state/live-task.status" && echo ok)" ""
ck "slot claim + lease unchanged" "$(cmp -s "$c/claim.before" "$c/pool/1/.fm-slot-owner" && cmp -s "$c/lease.before" "$c/pool/treehouse-state.json" && echo ok)" ""
ck "claimant HEAD/branch unchanged" "$([ "$head" = "$(git -C "$slot" rev-parse HEAD)" ] && git -C "$slot" symbolic-ref HEAD | cmp -s - "$c/br.before" && echo ok)" ""
ck "claimant copy status unchanged" "$(git -C "$slot" status --porcelain --untracked-files=all | cmp -s - "$c/st.before" && echo ok)" ""
ck "claimant files intact" "$(grep -q 'claimant tracked edit' "$slot/live.txt" && grep -q 'claimant untracked work' "$slot/scratch.txt" && grep -q 'claimant hook bytes' "$slot/.claude/settings.local.json" && echo ok)" ""
ck "no other branch ref changed" "$(git -C "$c/project" for-each-ref refs/heads --format='%(refname) %(objectname)' | grep -v 'archive/task-x1-pipeline-0b0b0b06' | cmp -s - "$c/refs.before" && echo ok)" ""
a=$(ref_sha "$c/project" archive/task-x1-pipeline-0b0b0b06)
say "  archive/task-x1-pipeline-0b0b0b06 after records-only retirement: ${a:-<deleted>} (records-only shared slot: header says refs stay untouched)"
ck "archive on records-only reassigned slot untouched (intent: shared/reassigned slots stay untouched)" "$([ "$a" = "$delivered" ] && echo ok)" "reaped instead"

say "=== DONE failures=$FAILS"
exit $FAILS
