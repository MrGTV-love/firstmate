#!/usr/bin/env bash
# Live drive of `fm-control <task> successor` in a disposable lab home.
# The caller (a real Claude session) takes the lab home lock with bin/fm-lock.sh,
# so it is the lab's lock-owning main Firstmate. Scott-shaped scratch fixture only.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M7MYQZDENGWZ8TC0F3BXCXBA
cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
export FM_GUARD_EVENT_LOG="$LAB/state/guard-events.jsonl"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-scott-fixture.XXXXXX")
bash tests/fixtures/fm-scott-task-shape.sh "$FIX" >/dev/null
T=fm-slack-second-person-scott
cp -p "$FIX/home/state/$T.meta" "$FIX/home/state/$T.status" "$LAB/state/"
mkdir -p "$LAB/data/$T"; cp -p "$FIX/home/data/$T/brief.md" "$LAB/data/$T/"
P=$FIX/project
SHA_S=$(git -C "$P" rev-parse "fm/$T")
SHA_P=$(git -C "$P" rev-parse "fm/$T-v2")
ROOT=$(git -C "$P" rev-list --max-parents=0 HEAD | head -1)
CTL() { echo; echo "\$ fm-control $T successor $*"; bash bin/fm-control.sh "$T" successor "$@"; echo "[exit=$?]"; }
snap() { { sha256sum "$LAB/state/$T.meta" "$LAB/data/$T/brief.md" 2>/dev/null || shasum -a 256 "$LAB/state/$T.meta" "$LAB/data/$T/brief.md"; git -C "$P" for-each-ref --format='%(refname) %(objectname)'; git -C "$P" worktree list --porcelain; find "$FIX/slots" -type f -not -path '*/.git*' -exec shasum {} \; | sort; } ; }
echo "== lab home: $LAB"; echo "== fixture: $FIX"
echo "== S=$SHA_S P=$SHA_P ROOT=$ROOT"
echo; echo "== take the lab home lock as this real Claude session"
bash bin/fm-lock.sh; echo "[exit=$?]"; bash bin/fm-lock.sh status
echo; echo "== record before"; cat "$LAB/state/$T.meta" | grep -E '^(branch|successor)'; grep '^Ship branch' "$LAB/data/$T/brief.md"
snap > "$FIX/snap0"

echo; echo "######## A. worker call refused"
( export FM_TASK_ID=$T; CTL --branch "fm/$T-v2" --tip "$SHA_P" --note "worker try" )
echo; echo "######## B. first admission without --tip refused"
CTL --branch "fm/$T-v2" --note "Scott v2 custody"
echo; echo "######## C. --tip that is the shared base (root) refused"
CTL --branch "fm/$T-v2" --tip "$ROOT" --note "Scott v2 custody"
echo; echo "######## D. name refusals"
CTL --branch develop --tip "$SHA_P" --note n
CTL --branch "fm/$T-v2*" --tip "$SHA_P" --note n
CTL --branch "fm/$T" --tip "$SHA_P" --note n
CTL --branch "archive/$T-pipeline-${SHA_P:0:8}" --tip "$SHA_P" --note n
CTL --branch "fm/$T-v3" --tip "$SHA_P" --note n
CTL --branch "fm/$T-v2" --tip "${SHA_P:0:12}" --note n
echo; echo "######## E. planted archive at the root commit (worker-writable name) + --tip=root refused"
git -C "$P" branch "archive/$T-pipeline-${ROOT:0:8}" "$ROOT"
CTL --branch "fm/$T-v2" --tip "$ROOT" --note "planted"
snap > "$FIX/snap1"
echo; echo "== refusals changed record/brief/refs/worktrees? (expect only the planted archive ref line)"
diff "$FIX/snap0" "$FIX/snap1"

echo; echo "######## F. legitimate first admission: archive-tip route with --tip = pipeline head P"
CTL --branch "fm/$T-v2" --tip "$SHA_P" --note "Scott v2 custody: the run owns fm/$T-v2"
echo; echo "== record after"; grep -n -E '^(branch|successor)' "$LAB/state/$T.meta"
echo "== brief after"; grep -n '^Ship branch' "$LAB/data/$T/brief.md"; tail -n 9 "$LAB/data/$T/brief.md"
snap > "$FIX/snap2"
echo; echo "== diff of refs/worktrees/record hashes (expect only record + brief hash lines)"
diff "$FIX/snap1" "$FIX/snap2"
cp -p "$LAB/state/$T.meta" "$FIX/meta.after"; cp -p "$LAB/data/$T/brief.md" "$FIX/brief.after"

echo; echo "######## G. repeat call is a no-op (no --tip needed)"
CTL --branch "fm/$T-v2" --note "again"
cmp "$FIX/meta.after" "$LAB/state/$T.meta" && cmp "$FIX/brief.after" "$LAB/data/$T/brief.md" && echo "record+brief byte-identical after repeat"
echo; echo "######## H. a second, different successor refused"
git -C "$P" branch "fm/$T-v3" "$SHA_P"
CTL --branch "fm/$T-v3" --tip "$SHA_P" --note n
cmp "$FIX/meta.after" "$LAB/state/$T.meta" && echo "record byte-identical after H"

echo; echo "######## I. hand-edited record: successor_proved_tip=<root> refused at re-admission"
sed -i '' "s/^successor_proved_tip=.*/successor_proved_tip=$ROOT/" "$LAB/state/$T.meta"
CTL --branch "fm/$T-v2" --note "again"
cp -p "$FIX/meta.after" "$LAB/state/$T.meta"

echo; echo "######## J. successor reset off its proved tip refused at re-admission"
git -C "$P" update-ref "refs/heads/fm/$T-v2" "$ROOT"
CTL --branch "fm/$T-v2" --note "again"
git -C "$P" update-ref "refs/heads/fm/$T-v2" "$SHA_P"

echo; echo "######## K. non-owner: lock names a dead pid"
cp -p "$LAB/state/.lock" "$FIX/lock.keep"; echo 999999 > "$LAB/state/.lock"
CTL --branch "fm/$T-v2" --note "again"
cp -p "$FIX/lock.keep" "$LAB/state/.lock"

echo; echo "######## L. guard events written"
jq -c 'select(.guard=="successor-branch-admission") | {decision,rule,route,successor}' "$FM_GUARD_EVENT_LOG" 2>/dev/null

echo; echo "== teardown"
bin/fm-lab-home.sh teardown "$LAB" && rm -rf "$LAB"
echo "FIXTURE_KEPT_FOR_PROFILE_STEP=$FIX"
