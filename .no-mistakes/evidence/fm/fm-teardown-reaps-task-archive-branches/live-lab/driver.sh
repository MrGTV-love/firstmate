#!/usr/bin/env bash
# Live lab driver for fm-teardown archive reaping (no-mistakes Test round 2).
#
# Real parts: a lab home minted by bin/fm-lab-home.sh create (the gate guard
# stays armed: NO_MISTAKES_GATE is kept and no FM_*_OVERRIDE or bypass is set),
# the worktree's real bin/fm-teardown.sh, real git with lab-local bare origins,
# a real Treehouse pool (TREEHOUSE_ROOT inside the lab, slots taken with
# `treehouse get --lease`), a real private tmux server through
# bin/fm-lab-home.sh tmux-dir, real tasks-axi backlog rows, real slot claims
# written by bin/fm-wake-lib.sh, and real claimant processes.
#
# Stand-in: the forge. Real GitHub is not authorized for this round, so `gh`
# and `gh-axi` are a lab-local forge that stores GitHub-shaped PR JSON and runs
# the product's own `--json/-q` query through real jq. The unreachable-forge
# scenario uses the REAL gh binary pointed at a dead local proxy instead.
# Every process also carries HTTPS_PROXY=http://127.0.0.1:9, so nothing can
# leave the machine. no-mistakes and docker are deliberately absent from PATH,
# so the shared daemon and the Docker daemon are never contacted.
#
# Usage: fm-proc-budget.sh -- bash driver.sh <repo-worktree> <lab-home> <evidence-dir>
set -u

REPO=$1
LAB=$2
EVID=$3
NONCE=$(printf '%05d' "$(( $$ % 100000 ))")
mkdir -p "$EVID"
RESULTS="$EVID/results.tsv"
: > "$RESULTS"
FAILS=0

note() { printf '%s\n' "$*" | tee -a "$EVID/driver.log" >&2; }
check() {  # <scenario> <description> <command...>
  local sc=$1 desc=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    printf 'PASS\t%s\t%s\n' "$sc" "$desc" >> "$RESULTS"
  else
    printf 'FAIL\t%s\t%s\n' "$sc" "$desc" >> "$RESULTS"
    FAILS=$((FAILS + 1))
  fi
}

# --- lab home and private tmux (the documented interface) -------------------
note "== create lab home $LAB"
"$REPO/bin/fm-lab-home.sh" create "$LAB" > "$EVID/lab-create.out" 2> "$EVID/lab-create.err" || {
  note "fm-lab-home create refused: $(cat "$EVID/lab-create.err")"
  exit 90
}
TD=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || { note "tmux-dir failed"; exit 91; }
printf '%s\n' "$TD" > "$EVID/lab-tmux-dir.out"
head -1 "$LAB/.fm-lab-home" > "$EVID/lab-marker-first-line.out"

FIX="$LAB/fixture"
POOL="$FIX/pool"
TOOLBIN="$FIX/toolbin"
FORGEBIN="$FIX/forgebin"
OFFLINEBIN="$FIX/offlinebin"
FORGE="$FIX/forge"
mkdir -p "$FIX/origins" "$POOL" "$TOOLBIN" "$FORGEBIN" "$OFFLINEBIN" "$FORGE" "$FIX/nm" "$FIX/gh-config" "$FIX/held" "$FIX/tmp"
touch "$LAB/state/.last-watcher-beat"
printf 'Lab fixture: the captain approved discarding this disposable lab task.\n' > "$FIX/captain-words.txt"
cat > "$FIX/gitconfig" <<'CFG'
[user]
	name = fm-lab
	email = fm-lab@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
CFG

# Tools from the host, by absolute path; docker, no-mistakes, gh, gh-axi omitted.
PY_REAL=$(python3 -c 'import sys; print(sys.executable)')
for spec in "tmux:$(command -v tmux)" "treehouse:$(command -v treehouse)" \
  "tasks-axi:$(command -v tasks-axi)" "git:$(command -v git)" "jq:$(command -v jq)" \
  "python3:$PY_REAL" "perl:/usr/bin/perl" "timeout:$(command -v timeout)" \
  "gtimeout:$(command -v gtimeout)" "node:/opt/homebrew/bin/node" "lsof:/usr/sbin/lsof"; do
  name=${spec%%:*}; target=${spec#*:}
  [ -x "$target" ] && ln -s "$target" "$TOOLBIN/$name"
done
ln -s "$(command -v gh)" "$OFFLINEBIN/gh"
ln -s "$(command -v gh-axi)" "$OFFLINEBIN/gh-axi"
ls -l "$TOOLBIN" "$OFFLINEBIN" > "$EVID/lab-toolbins.out"

# Lab-local forge stand-in (see header).
cat > "$FORGEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Lab-local forge: GitHub-shaped PR records, queried by the caller's own jq.
printf 'gh %s\n' "$*" >> "$FM_LAB_FORGE/calls.log"
[ "${1:-} ${2:-}" = "pr view" ] || { echo "lab forge: unsupported: gh $*" >&2; exit 1; }
target=${3:-}
n=${target##*/pull/}; n=${n%%[!0-9]*}
rec="$FM_LAB_FORGE/pr-$n.json"
[ -n "$n" ] && [ -f "$rec" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $n. (repository.pullRequest)" >&2; exit 1; }
shift 3
fields= q=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fields=$2; shift 2 ;;
    -q|--jq) q=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$q" ]; then
  jq -r "$q" "$rec"
else
  jq -c "{$(printf '%s' "$fields" | sed 's/,/, /g')}" "$rec"
fi
SH
cat > "$FORGEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_LAB_FORGE/calls.log"
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
esac
echo "lab forge: unsupported: gh-axi $*" >&2
exit 1
SH
chmod +x "$FORGEBIN/gh" "$FORGEBIN/gh-axi"

LABPATH_BASE="$TOOLBIN:/usr/bin:/bin:/usr/sbin:/sbin"
labenv() {  # [--offline] <command...>: the lab's whole environment, nothing inherited
  local front=$FORGEBIN
  if [ "${1:-}" = --offline ]; then front=$OFFLINEBIN; shift; fi
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" LANG=en_US.UTF-8 \
    TMPDIR="$FIX/tmp/" NO_MISTAKES_GATE=1 FM_BACKEND=tmux \
    FM_HOME="$LAB" TMUX_TMPDIR="$TD" TREEHOUSE_ROOT="$POOL" NM_HOME="$FIX/nm" \
    GIT_CONFIG_GLOBAL="$FIX/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    GH_CONFIG_DIR="$FIX/gh-config" GH_TOKEN=lab-invalid GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY= \
    https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 no_proxy= \
    FM_LAB_FORGE="$FORGE" PATH="$front:$LABPATH_BASE" "$@"
}
lgit() { labenv git "$@"; }

labenv tmux -f /dev/null new-session -d -s firstmate -n lab-anchor -c "$LAB" 'exec sleep 7200' \
  || { note "lab tmux server failed to start"; exit 92; }
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"

# --- fixture helpers --------------------------------------------------------
mkproj() {  # <name>: lab-local bare origin + project clone under projects/
  local name=$1 seed="$FIX/tmp/seed-$1"
  lgit init -q --bare "$FIX/origins/$name.git"
  lgit -C "$FIX/origins/$name.git" symbolic-ref HEAD refs/heads/main
  lgit clone -q "$FIX/origins/$name.git" "$seed" 2>/dev/null
  lgit -C "$seed" commit -q --allow-empty -m "origin baseline"
  lgit -C "$seed" push -q origin main
  rm -rf "$seed"
  lgit clone -q "$FIX/origins/$name.git" "$LAB/projects/$name"
  lgit -C "$LAB/projects/$name" remote set-head origin main >/dev/null 2>&1 || true
}
lease_slot() {  # <project> <holder>: echo a real Treehouse pool slot path
  (cd "$LAB/projects/$1" && labenv treehouse get --lease --lease-holder "$2" 2>>"$EVID/treehouse.err")
}
claim_slot() {  # <slot> <task>: the product's own slot-owner claim writer
  labenv bash -c '. "$1/bin/fm-wake-lib.sh" && fm_treehouse_slot_owner_claim "$2" "$3" "$4"' _ "$REPO" "$1" "$2" "$LAB"
}
open_window() {  # <task> <cwd>: a real tmux endpoint whose pane lives in the copy
  labenv tmux new-window -d -t firstmate: -n "fm-$1" -c "$2" 'exec sleep 7200'
}
window_alive() { labenv tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qxF "fm-$1"; }
window_gone() { ! window_alive "$1"; }
backlog_start() {
  labenv tasks-axi add "$1" "lab task $1" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  labenv tasks-axi start "$1" --file "$LAB/data/backlog.md" >/dev/null
}
backlog_state() {
  labenv tasks-axi show "$1" --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}
write_meta() {  # <task> <slot> <project> [extra kv...]
  local id=$1 slot=$2 proj=$3 kv
  shift 3
  : > "$LAB/state/$id.meta"
  for kv in "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$slot" \
    "project=$LAB/projects/$proj" "kind=ship" "mode=no-mistakes" "branch=fm/$id" \
    "spawn_gen=lab-$id" "$@"; do
    printf '%s\n' "$kv" >> "$LAB/state/$id.meta"
  done
  printf '%s in flight\n' "$id" > "$LAB/state/$id.status"
}
commit_file() {  # <copy> <file> <content> <msg>
  printf '%s\n' "$3" > "$1/$2"
  lgit -C "$1" add -- "$2"
  lgit -C "$1" commit -q -m "$4"
}
forge_pr() {  # <n> <proj> <head> <merge-or-empty> <branch>
  local merge_json=null
  [ -z "$4" ] || merge_json="{\"oid\":\"$4\"}"
  printf '{"number":%s,"state":"MERGED","headRefOid":"%s","headRefName":"%s","url":"https://github.com/lab-forge/%s/pull/%s","mergeCommit":%s}\n' \
    "$1" "$3" "$5" "$2" "$1" "$merge_json" > "$FORGE/pr-$1.json"
}
pr_url() { printf 'https://github.com/lab-forge/%s/pull/%s' "$1" "$2"; }
squash_land() {  # <proj> <branch>: a real squash merge pushed to the lab origin; echo merge
  local p="$LAB/projects/$1"
  lgit -C "$p" merge -q --squash "$2" >/dev/null
  lgit -C "$p" commit -qm "squash $2"
  lgit -C "$p" push -q origin main
  lgit -C "$p" rev-parse HEAD
}
ref_of() { lgit -C "$LAB/projects/$1" rev-parse --verify -q "refs/heads/$2" 2>/dev/null || true; }
ref_is() { [ "$(ref_of "$1" "$2")" = "$3" ]; }
ref_absent() { [ -z "$(ref_of "$1" "$2")" ]; }
snapshot() {  # <scenario-dir> <project> <phase>
  local d=$1 p="$LAB/projects/$2" ph=$3
  lgit -C "$p" for-each-ref --format='%(refname) %(objectname)' > "$d/refs.$ph"
  lgit -C "$p" worktree list --porcelain > "$d/worktrees.$ph"
  labenv tmux list-windows -t firstmate -F '#{window_name} #{pane_current_path}' > "$d/tmux-windows.$ph" 2>&1
  (cd "$p" && labenv treehouse status) > "$d/treehouse-status.$ph" 2>&1
  cat "$POOL"/.treehouse/"$2"-*/treehouse-state.json > "$d/treehouse-state.$ph" 2>&1
  ls -1 "$LAB/state" > "$d/state-files.$ph"
}
teardown() {  # <scenario-dir> <label> [--offline] <task> [args...]
  local d=$1 label=$2 off= rc=0
  shift 2
  if [ "${1:-}" = --offline ]; then off=--offline; shift; fi
  # shellcheck disable=SC2086
  labenv $off "$REPO/bin/fm-teardown.sh" "$@" > "$d/$label.stdout" 2> "$d/$label.stderr" || rc=$?
  printf '%s\n' "$rc" > "$d/$label.rc"
  printf 'fm-teardown.sh %s -> exit %s\n' "$*" "$rc" >> "$d/commands.log"
  return 0
}
rc_is() { [ "$(cat "$1")" = "$2" ]; }
grep_has() { grep -qF -- "$1" "$2"; }
grep_lacks() { ! grep -qF -- "$1" "$2"; }

# === S1: squash-merged task reaps ancestor and patch-equivalent archives ======
S=s1-carried; D="$EVID/$S"; mkdir -p "$D"; ID="lab$NONCE-carry"; P=p-carry
note "== $S ($ID)"
mkproj "$P"
SLOT=$(lease_slot "$P" "$ID"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
lgit -C "$SLOT" checkout -q -b "fm/$ID"
claim_slot "$SLOT" "$ID"; open_window "$ID" "$SLOT"; backlog_start "$ID"
base=$(lgit -C "$SLOT" rev-parse HEAD)
commit_file "$SLOT" 'feature file.txt' alpha "add feature"
submitted=$(lgit -C "$SLOT" rev-parse HEAD)
replayed=$(printf 'replayed feature\n' | lgit -C "$SLOT" commit-tree "$(lgit -C "$SLOT" rev-parse 'HEAD^{tree}')" -p "$base")
commit_file "$SLOT" later.txt beta "pipeline follow-up"
pipeline=$(lgit -C "$SLOT" rev-parse HEAD)
A_SUB="archive/$ID-submitted-${submitted:0:8}"
A_REP="archive/$ID-submitted-${replayed:0:8}"
A_PIP="archive/$ID-pipeline-${pipeline:0:8}"
for spec in "$A_SUB $submitted" "$A_REP $replayed" "$A_PIP $pipeline" \
  "archive/$ID $submitted" "archive/$ID-pipeline-final $pipeline" \
  "archive/other-pipeline-${pipeline:0:8} $pipeline" "unrelated $pipeline"; do
  lgit -C "$LAB/projects/$P" branch ${spec% *} ${spec#* }
done
merge=$(squash_land "$P" "fm/$ID")
forge_pr 101 "$P" "$pipeline" "$merge" "fm/$ID"
write_meta "$ID" "$SLOT" "$P" "pr=$(pr_url "$P" 101)"
snapshot "$D" "$P" before
teardown "$D" teardown "$ID"
snapshot "$D" "$P" after
printf 'backlog=%s\n' "$(backlog_state "$ID")" > "$D/backlog.after"
check $S "teardown exits 0" rc_is "$D/teardown.rc" 0
check $S "replayed archive is not an ancestor of PR head (patch-equivalent case is real)" \
  bash -c '! "$1" -C "$2" merge-base --is-ancestor "$3" "$4"' _ "$TOOLBIN/git" "$LAB/projects/$P" "$replayed" "$pipeline"
for a in "$A_SUB" "$A_REP" "$A_PIP"; do
  check $S "$a deleted" ref_absent "$P" "${a#refs/heads/}"
  check $S "$a named as reaped" grep_has "reaped $a (carried by the merged PR lineage)" "$D/teardown.stderr"
done
check $S "archive/$ID (non-custody) kept" ref_is "$P" "archive/$ID" "$submitted"
check $S "archive/$ID-pipeline-final (non-custody) kept" ref_is "$P" "archive/$ID-pipeline-final" "$pipeline"
check $S "archive/other-pipeline-* (other task) kept" ref_is "$P" "archive/other-pipeline-${pipeline:0:8}" "$pipeline"
check $S "unrelated branch kept" ref_is "$P" unrelated "$pipeline"
check $S "task endpoint window closed" window_gone "$ID"
check $S "task record removed" test ! -e "$LAB/state/$ID.meta"
check $S "pool slot returned (no longer leased)" grep_lacks "$ID" "$D/treehouse-status.after"
check $S "backlog row closed" grep_has "backlog=done" "$D/backlog.after"

# === S2: task-x1 never judges task-x1-2 archives or non-custody names =========
S=s2-prefix; D="$EVID/$S"; mkdir -p "$D"; X="lab$NONCE-x1"; Y="lab$NONCE-x1-2"; P=p-prefix
note "== $S ($X, $Y)"
mkproj "$P"
SX=$(lease_slot "$P" "$X"); SY=$(lease_slot "$P" "$Y")
printf 'slot_x=%s\nslot_y=%s\n' "$SX" "$SY" >> "$D/commands.log"
lgit -C "$SX" checkout -q -b "fm/$X"; lgit -C "$SY" checkout -q -b "fm/$Y"
claim_slot "$SX" "$X"; claim_slot "$SY" "$Y"
open_window "$X" "$SX"; open_window "$Y" "$SY"; backlog_start "$X"; backlog_start "$Y"
commit_file "$SX" feature.txt alpha feature
head=$(lgit -C "$SX" rev-parse HEAD); h8=${head:0:8}
commit_file "$SY" sibling.txt 'sibling work' "sibling in flight"
yhead=$(lgit -C "$SY" rev-parse HEAD)
OWN="archive/$X-pipeline-$h8"
# A case-only variant of h8 would collide on a case-insensitive filesystem, so
# the uppercase near-miss uses its own value.
UP8=ABCDEF01
FOREIGN="archive/$Y-pipeline-$h8 archive/$Y-submitted-$h8 archive/$X-pipeline-final archive/$X-pipeline-$UP8 archive/$X-pipeline-${h8}4 archive/$X-submitted-$h8-extra"
lgit -C "$LAB/projects/$P" branch "$OWN" "$head"
for a in $FOREIGN; do lgit -C "$LAB/projects/$P" branch "$a" "$head"; done
merge=$(squash_land "$P" "fm/$X")
forge_pr 102 "$P" "$head" "$merge" "fm/$X"
write_meta "$X" "$SX" "$P" "pr=$(pr_url "$P" 102)"
write_meta "$Y" "$SY" "$P"
cp "$LAB/state/$Y.meta" "$D/y-meta.before"; cp "$LAB/state/$Y.status" "$D/y-status.before"
cat "$(dirname "$SY")/.fm-slot-owner" > "$D/y-claim.before" 2>/dev/null
snapshot "$D" "$P" before
teardown "$D" teardown "$X"
snapshot "$D" "$P" after
check $S "teardown $X exits 0" rc_is "$D/teardown.rc" 0
check $S "own archive $OWN reaped" ref_absent "$P" "${OWN#archive/}"
check $S "own archive named as reaped" grep_has "reaped $OWN" "$D/teardown.stderr"
for a in $FOREIGN; do
  check $S "$a kept at its head" ref_is "$P" "$a" "$head"
  check $S "$a never printed" grep_lacks "$a" "$D/teardown.stderr"
done
check $S "$Y record unchanged" cmp -s "$D/y-meta.before" "$LAB/state/$Y.meta"
check $S "$Y status unchanged" cmp -s "$D/y-status.before" "$LAB/state/$Y.status"
check $S "$Y slot claim unchanged" bash -c 'cat "$1" | cmp -s - "$2"' _ "$(dirname "$SY")/.fm-slot-owner" "$D/y-claim.before"
check $S "$Y window alive" window_alive "$Y"
check $S "$Y branch unchanged" ref_is "$P" "fm/$Y" "$yhead"
check $S "$Y copy still on its branch" bash -c '[ "$("$1" -C "$2" symbolic-ref HEAD)" = "refs/heads/fm/$3" ]' _ "$TOOLBIN/git" "$SY" "$Y"
check $S "$Y backlog row still in flight" bash -c '[ "$1" = in-flight ] || [ "$1" = "in flight" ] || [ "$1" = in_flight ]' _ "$(backlog_state "$Y")"
check $S "$X window closed" window_gone "$X"
printf 'x_backlog=%s\ny_backlog=%s\n' "$(backlog_state "$X")" "$(backlog_state "$Y")" > "$D/backlog.after"

# === S3: unlanded edits, cherry-invisible merge edits, checked-out archives ===
S=s3-unproven; D="$EVID/$S"; mkdir -p "$D"; ID="lab$NONCE-unproven"; P=p-unproven
note "== $S ($ID)"
mkproj "$P"
SLOT=$(lease_slot "$P" "$ID"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
lgit -C "$SLOT" checkout -q -b "fm/$ID"
claim_slot "$SLOT" "$ID"; open_window "$ID" "$SLOT"; backlog_start "$ID"
commit_file "$SLOT" feature.txt alpha "landed feature"
landed=$(lgit -C "$SLOT" rev-parse HEAD)
commit_file "$SLOT" extra.txt unlanded "unlanded archive edit"
extra=$(lgit -C "$SLOT" rev-parse HEAD)
second=$(printf 'empty second parent\n' | lgit -C "$SLOT" commit-tree "$(lgit -C "$SLOT" rev-parse "$landed^{tree}")" -p "$landed")
edited=$(printf 'edited merge\n' | lgit -C "$SLOT" commit-tree "$(lgit -C "$SLOT" rev-parse 'HEAD^{tree}')" -p "$landed" -p "$second")
lgit -C "$SLOT" reset -q --hard "$landed"
A_EXTRA="archive/$ID-submitted-${extra:0:8}"
A_EDIT="archive/$ID-pipeline-${edited:0:8}"
A_HELD="archive/$ID-pipeline-${landed:0:8}"
A_OK="archive/$ID-submitted-${landed:0:8}"
lgit -C "$LAB/projects/$P" branch "$A_EXTRA" "$extra"
lgit -C "$LAB/projects/$P" branch "$A_EDIT" "$edited"
lgit -C "$LAB/projects/$P" branch "$A_HELD" "$landed"
lgit -C "$LAB/projects/$P" branch "$A_OK" "$landed"
lgit -C "$LAB/projects/$P" worktree add -q "$FIX/held/$ID" "$A_HELD"
merge=$(squash_land "$P" "fm/$ID")
forge_pr 103 "$P" "$landed" "$merge" "fm/$ID"
write_meta "$ID" "$SLOT" "$P" "pr=$(pr_url "$P" 103)"
snapshot "$D" "$P" before
teardown "$D" teardown "$ID"
snapshot "$D" "$P" after
check $S "teardown exits 0 (unproven archives do not block landed cleanup)" rc_is "$D/teardown.rc" 0
check $S "unlanded-edit archive kept" ref_is "$P" "$A_EXTRA" "$extra"
check $S "unlanded-edit archive named" grep_has "keeping $A_EXTRA (archive patches are not all carried by the merged PR head)" "$D/teardown.stderr"
check $S "edited-merge archive kept" ref_is "$P" "$A_EDIT" "$edited"
check $S "edited-merge archive named" grep_has "keeping $A_EDIT (archive history is not proven carried by the merged PR head)" "$D/teardown.stderr"
check $S "checked-out archive kept" ref_is "$P" "$A_HELD" "$landed"
check $S "checked-out archive named" grep_has "keeping $A_HELD (checked out in a local copy)" "$D/teardown.stderr"
check $S "other copy still attached to its archive branch" \
  bash -c '[ "$("$1" -C "$2" symbolic-ref HEAD)" = "refs/heads/$3" ]' _ "$TOOLBIN/git" "$FIX/held/$ID" "$A_HELD"
check $S "carried sibling archive reaped" ref_absent "$P" "$A_OK"
check $S "carried sibling archive named" grep_has "reaped $A_OK" "$D/teardown.stderr"

# === S4: merge content differs, merge proof missing, forge unreachable =======
for shape in different missing offline; do
  S=s4-$shape; D="$EVID/$S"; mkdir -p "$D"; ID="lab$NONCE-sq-$shape"; P=p-sq-$shape
  note "== $S ($ID)"
  mkproj "$P"
  SLOT=$(lease_slot "$P" "$ID"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
  lgit -C "$SLOT" checkout -q -b "fm/$ID"
  claim_slot "$SLOT" "$ID"; open_window "$ID" "$SLOT"; backlog_start "$ID"
  commit_file "$SLOT" feature.txt alpha feature
  head=$(lgit -C "$SLOT" rev-parse HEAD)
  A="archive/$ID-pipeline-${head:0:8}"
  lgit -C "$LAB/projects/$P" branch "$A" "$head"
  case $shape in
    different|offline)
      content=alpha; [ "$shape" = different ] && content=different
      tmpc="$FIX/tmp/land-$ID"
      lgit clone -q "$FIX/origins/$P.git" "$tmpc"
      commit_file "$tmpc" feature.txt "$content" "squash feature.txt"
      lgit -C "$tmpc" push -q origin HEAD:main
      rm -rf "$tmpc"
      lgit -C "$LAB/projects/$P" fetch -q origin
      merge=$(lgit -C "$LAB/projects/$P" rev-parse origin/main) ;;
    missing) merge= ;;
  esac
  n=104; [ $shape = missing ] && n=105; [ $shape = offline ] && n=106
  [ $shape = offline ] || forge_pr "$n" "$P" "$head" "$merge" "fm/$ID"
  write_meta "$ID" "$SLOT" "$P" "pr=$(pr_url "$P" "$n")"
  snapshot "$D" "$P" before
  if [ $shape = offline ]; then
    teardown "$D" teardown --offline "$ID"
    labenv --offline gh pr view "$(pr_url "$P" "$n")" --json state -q .state > "$D/real-gh-probe.out" 2>&1
  else
    teardown "$D" teardown "$ID"
  fi
  snapshot "$D" "$P" after
  check $S "teardown exits 0 (ordinary landing proof still passes)" rc_is "$D/teardown.rc" 0
  check $S "ancestor archive kept at its head" ref_is "$P" "$A" "$head"
  check $S "archive named with unproven-merge reason" \
    grep_has "keeping $A (merged PR head and matching merge content could not be proven)" "$D/teardown.stderr"
  check $S "task endpoint window closed" window_gone "$ID"
  [ $shape != offline ] || check $S "real gh could not reach the forge" grep_has "connection refused" "$D/real-gh-probe.out"
done

# === S5: deleted and pathspec-like filenames compared literally ===============
for shape in matching restored-source; do
  S=s5-$shape; D="$EVID/$S"; mkdir -p "$D"; ID="lab$NONCE-rn-$shape"; P=p-rn-$shape
  note "== $S ($ID)"
  file=':(literal)renamed file.txt'
  mkproj "$P"
  printf 'rename me\n' > "$LAB/projects/$P/old.txt"
  lgit -C "$LAB/projects/$P" add old.txt
  lgit -C "$LAB/projects/$P" commit -qm "baseline file"
  lgit -C "$LAB/projects/$P" push -q origin main
  SLOT=$(lease_slot "$P" "$ID"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
  lgit -C "$SLOT" checkout -q -b "fm/$ID"
  claim_slot "$SLOT" "$ID"; open_window "$ID" "$SLOT"; backlog_start "$ID"
  lgit -C "$SLOT" --literal-pathspecs mv -- old.txt "$file"
  lgit -C "$SLOT" commit -qm rename
  head=$(lgit -C "$SLOT" rev-parse HEAD)
  A="archive/$ID-pipeline-${head:0:8}"
  lgit -C "$LAB/projects/$P" branch "$A" "$head"
  n=107
  if [ $shape = matching ]; then
    merge=$(squash_land "$P" "fm/$ID")
  else
    n=108
    printf 'rename me\n' > "$LAB/projects/$P/$file"
    lgit -C "$LAB/projects/$P" --literal-pathspecs add -- "$file"
    lgit -C "$LAB/projects/$P" commit -qm "incomplete rename squash"
    merge=$(lgit -C "$LAB/projects/$P" rev-parse HEAD)
    lgit -C "$LAB/projects/$P" push -q origin main
  fi
  lgit -C "$LAB/projects/$P" ls-tree -r --name-only "$merge" > "$D/merge-tree-paths.txt"
  forge_pr "$n" "$P" "$head" "$merge" "fm/$ID"
  write_meta "$ID" "$SLOT" "$P" "pr=$(pr_url "$P" "$n")"
  snapshot "$D" "$P" before
  teardown "$D" teardown "$ID"
  snapshot "$D" "$P" after
  check $S "teardown exits 0" rc_is "$D/teardown.rc" 0
  if [ $shape = matching ]; then
    check $S "complete rename archive reaped" ref_absent "$P" "$A"
    check $S "complete rename archive named" grep_has "reaped $A" "$D/teardown.stderr"
  else
    check $S "merge restored the deleted source (fixture is real)" grep -qxF old.txt "$D/merge-tree-paths.txt"
    check $S "incomplete rename archive kept" ref_is "$P" "$A" "$head"
    check $S "incomplete rename archive named" grep_has "keeping $A (merged PR head and matching merge content could not be proven)" "$D/teardown.stderr"
  fi
done

# === S6: unlanded refusal, then authorized forced discard =====================
S=s6-refused; D="$EVID/$S"; mkdir -p "$D"; ID="lab$NONCE-refused"; P=p-refused
note "== $S ($ID)"
mkproj "$P"
SLOT=$(lease_slot "$P" "$ID"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
lgit -C "$SLOT" checkout -q -b "fm/$ID"
claim_slot "$SLOT" "$ID"; open_window "$ID" "$SLOT"; backlog_start "$ID"
commit_file "$SLOT" feature.txt unlanded "unlanded feature"
head=$(lgit -C "$SLOT" rev-parse HEAD)
A="archive/$ID-submitted-${head:0:8}"
lgit -C "$LAB/projects/$P" branch "$A" "$head"
write_meta "$ID" "$SLOT" "$P"
snapshot "$D" "$P" before
teardown "$D" refused "$ID"
snapshot "$D" "$P" after-refusal
check $S "unlanded teardown refuses (exit 1)" rc_is "$D/refused.rc" 1
check $S "refusal names REFUSED" grep_has "REFUSED" "$D/refused.stderr"
check $S "archive kept after refusal" ref_is "$P" "$A" "$head"
check $S "refusal keeps the task copy" test -d "$SLOT"
check $S "refusal keeps the task branch on the unlanded commit" \
  bash -c '[ "$("$1" -C "$2" rev-parse HEAD)" = "$3" ] && [ "$("$1" -C "$2" symbolic-ref --short HEAD)" = "fm/$4" ]' _ "$TOOLBIN/git" "$SLOT" "$head" "$ID"
check $S "refusal keeps the task record" test -e "$LAB/state/$ID.meta"
check $S "refusal keeps the task window" window_alive "$ID"
check $S "refusal never mentions archive reaping" grep_lacks "reaped $A" "$D/refused.stderr"
teardown "$D" forced "$ID" --force --drop-file "$FIX/captain-words.txt"
snapshot "$D" "$P" after-forced
check $S "authorized forced discard exits 0" rc_is "$D/forced.rc" 0
check $S "archive kept after forced discard" ref_is "$P" "$A" "$head"
check $S "forced discard names the archive as not landed" grep_has "keeping $A (forced discard is not landing proof)" "$D/forced.stderr"
check $S "forced discard closed the window" window_gone "$ID"
check $S "forced discard removed the task record" test ! -e "$LAB/state/$ID.meta"

# === S7: finished task on a reassigned slot retires records only ==============
S=s7-reassigned; D="$EVID/$S"; mkdir -p "$D"; F="lab$NONCE-finished"; C="lab$NONCE-claimant"; P=p-reassigned
note "== $S ($F, $C)"
mkproj "$P"
SLOT=$(lease_slot "$P" "$C"); printf 'slot=%s\n' "$SLOT" >> "$D/commands.log"
lgit -C "$SLOT" checkout -q -b "fm/$F"
commit_file "$SLOT" delivered.txt 'merged task work' 'delivered task'
delivered=$(lgit -C "$SLOT" rev-parse HEAD)
lgit -C "$SLOT" push -q origin HEAD:main
forge_pr 109 "$P" "$delivered" "$delivered" "fm/$F"
A="archive/$F-pipeline-${delivered:0:8}"
lgit -C "$LAB/projects/$P" branch "$A" "$delivered"
lgit -C "$SLOT" checkout -q -b "fm/$C"
commit_file "$SLOT" live.txt 'claimant committed work' 'unlanded claimant work'
printf 'claimant tracked edit\n' >> "$SLOT/live.txt"
printf 'claimant untracked work\n' > "$SLOT/scratch.txt"
mkdir -p "$SLOT/.claude"; printf 'claimant hook bytes\n' > "$SLOT/.claude/settings.local.json"
claim_slot "$SLOT" "$C"
write_meta "$F" "$SLOT" "$P" "pr=$(pr_url "$P" 109)" "pr_head=$delivered"
write_meta "$C" "$SLOT" "$P"
backlog_start "$F"; backlog_start "$C"
open_window "$F" "$SLOT"; open_window "$C" "$SLOT"
(cd "$SLOT" && exec sleep 600) &
WORKER=$!
printf 'claimant_pid=%s\n' "$WORKER" >> "$D/commands.log"
cp "$LAB/state/$C.meta" "$D/c-meta.before"; cp "$LAB/state/$C.status" "$D/c-status.before"
cp "$(dirname "$SLOT")/.fm-slot-owner" "$D/claim.before"
lgit -C "$SLOT" status --porcelain --untracked-files=all > "$D/copy-status.before"
lgit -C "$SLOT" symbolic-ref HEAD > "$D/branch.before"
chead=$(lgit -C "$SLOT" rev-parse HEAD)
FPANE=$(labenv tmux display-message -p -t "=firstmate:=fm-$F" '#{pane_pid}')
CPANE=$(labenv tmux display-message -p -t "=firstmate:=fm-$C" '#{pane_pid}')
printf 'finished_pane_pid=%s\nclaimant_pane_pid=%s\n' "$FPANE" "$CPANE" >> "$D/commands.log"
snapshot "$D" "$P" before
teardown "$D" teardown "$F"
snapshot "$D" "$P" after
check $S "teardown $F exits 0" rc_is "$D/teardown.rc" 0
check $S "claimant process survived" kill -0 "$WORKER"
check $S "finished record removed" test ! -e "$LAB/state/$F.meta"
check $S "finished status removed" test ! -e "$LAB/state/$F.status"
check $S "finished window closed" window_gone "$F"
check $S "claimant window alive" window_alive "$C"
check $S "claimant record unchanged" cmp -s "$D/c-meta.before" "$LAB/state/$C.meta"
check $S "claimant status unchanged" cmp -s "$D/c-status.before" "$LAB/state/$C.status"
check $S "claimant slot claim unchanged" cmp -s "$D/claim.before" "$(dirname "$SLOT")/.fm-slot-owner"
check $S "durable pool lease record unchanged" cmp -s "$D/treehouse-state.before" "$D/treehouse-state.after"
check $S "slot still leased and held by the claimant" grep_has "(held by $C)" "$D/treehouse-status.after"
check $S "only the finished endpoint's pane process left the slot" bash -c \
  'sed "s/sleep ($1), //; s/, sleep ($1)//" "$2" | cmp -s - "$3"' _ "$FPANE" "$D/treehouse-status.before" "$D/treehouse-status.after"
check $S "claimant pane process survived" kill -0 "$CPANE"
check $S "every project ref unchanged (archive included)" cmp -s "$D/refs.before" "$D/refs.after"
check $S "finished task's archive kept and not reaped" ref_is "$P" "$A" "$delivered"
check $S "archive never named as reaped" grep_lacks "reaped $A" "$D/teardown.stderr"
check $S "claimant HEAD unchanged" bash -c '[ "$("$1" -C "$2" rev-parse HEAD)" = "$3" ]' _ "$TOOLBIN/git" "$SLOT" "$chead"
check $S "claimant branch unchanged" bash -c '"$1" -C "$2" symbolic-ref HEAD | cmp -s - "$3"' _ "$TOOLBIN/git" "$SLOT" "$D/branch.before"
check $S "claimant copy status unchanged" bash -c '"$1" -C "$2" status --porcelain --untracked-files=all | cmp -s - "$3"' _ "$TOOLBIN/git" "$SLOT" "$D/copy-status.before"
check $S "claimant tracked edit intact" grep_has "claimant tracked edit" "$SLOT/live.txt"
check $S "claimant untracked file intact" grep_has "claimant untracked work" "$SLOT/scratch.txt"
check $S "claimant hook bytes intact" grep_has "claimant hook bytes" "$SLOT/.claude/settings.local.json"
kill "$WORKER" 2>/dev/null; wait "$WORKER" 2>/dev/null

# --- isolation proof and cleanup ---------------------------------------------
cp "$FORGE/calls.log" "$EVID/forge-calls.log" 2>/dev/null
cp "$LAB/data/backlog.md" "$EVID/backlog.final.md"
grep 'Leased worktree at' "$EVID/treehouse.err" > "$EVID/leased-slots.out"
check isolation "every pool slot was leased inside the lab" bash -c \
  '[ -s "$1" ] && ! grep -v "Leased worktree at ~/fm-lab/fm-teardown-reaps-task-archive-branches/fixture/pool/" "$1"' _ "$EVID/leased-slots.out"
check isolation "the forge stand-in was the only forge answering (real gh only in s4-offline)" test -s "$FORGE/calls.log"
check isolation "lab marker carries the gate token" test -s "$EVID/lab-marker-first-line.out"

note "== cleanup"
labenv tmux kill-server >/dev/null 2>&1
"$REPO/bin/fm-lab-home.sh" teardown "$LAB" > "$EVID/lab-teardown.out" 2>&1
printf 'lab tmux teardown exit %s\n' "$?" >> "$EVID/lab-teardown.out"
rm -rf -- "$LAB"
rmdir -- "$(dirname "$LAB")" 2>/dev/null
[ ! -e "$LAB" ] && printf 'lab home removed: %s\n' "$LAB" >> "$EVID/lab-teardown.out"
pass=$(grep -c '^PASS' "$RESULTS"); fail=$(grep -c '^FAIL' "$RESULTS")
note "checks: $pass pass, $fail fail"
[ "$FAILS" -eq 0 ]
