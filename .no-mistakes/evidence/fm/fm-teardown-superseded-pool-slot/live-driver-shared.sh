#!/usr/bin/env bash
# Live driver for the shared-slot retire in a superseded pool folder: the real
# bin/fm-teardown.sh and the real installed treehouse (including its
# lease --path) on real pool folders in a throwaway TREEHOUSE_ROOT and HOME.
# Stubs: gh (prints the PR state given in PR_STATE), gh-axi, tmux,
# no-mistakes, docker, fm-fleet-sync.sh; these are forge/terminal surfaces.
# Usage: live-driver-shared.sh <worktree-root> <evidence-dir> <scenario> <MERGED|OPEN>
set -u
WT=$1 EVID=$2 SCEN=$3 LIVE_PR_STATE=$4
REAL_TH=$(command -v treehouse)
cd "$WT" || exit 1
# shellcheck disable=SC1091
. "$WT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
unset FM_HOME
T=$(fm_test_tmproot fm-live-shared)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" TREEHOUSE_ROOT="$T/thr"
mkdir -p "$HOME" "$TREEHOUSE_ROOT"
OUT="$EVID/$SCEN"; rm -rf "$OUT"; mkdir -p "$OUT"
log() { sed "s#$T#\$CASE#g" | tee -a "$OUT/transcript.txt"; }
id=shared-superseded
D=$T/case
mkdir -p "$D/home/state" "$D/home/data/$id" "$D/home/config" "$D/tb" "$D/code-root/bin"
git init -q --bare "$D/origin.git"; git -C "$D/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$D/origin.git" "$D/seed" 2>/dev/null
git -C "$D/seed" commit -q --allow-empty -m base; git -C "$D/seed" push -q origin main; rm -rf "$D/seed"
git clone -q "$D/origin.git" "$D/proj"; git -C "$D/proj" remote set-head origin main
git -C "$D/proj" worktree add -q -b "fm/$id" "$D/old" main
printf 'committed work\n' > "$D/old/work.txt"; git -C "$D/old" add work.txt; git -C "$D/old" commit -q -m 'old copy work'

cat > "$D/tb/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-} \${2:-}" = "lease --help" ] || printf '%s\n' "\$*" >> "$D/treehouse.log"
exec "$REAL_TH" "\$@"
SH
cat > "$D/tb/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in "pr view") printf '%s\n' "$LIVE_PR_STATE" ;; esac
exit 0
SH
cat > "$D/tb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
chmod +x "$D/tb/treehouse" "$D/tb/gh" "$D/tb/gh-axi"
fm_fake_exit0 "$D/tb" tmux no-mistakes
fm_fake_docker "$D/tb"
for tool in "$WT/bin"/*; do
  [ "${tool##*/}" = fm-fleet-sync.sh ] || ln -s "$tool" "$D/code-root/bin/${tool##*/}"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/code-root/bin/fm-fleet-sync.sh"; chmod +x "$D/code-root/bin/fm-fleet-sync.sh"
touch "$D/home/state/.last-watcher-beat"
export PATH="$D/tb:$PATH"

# Old pool folder: one real slot, unleased, holding the shared copy.
S=$(cd "$D/proj" && "$REAL_TH" get --lease --no-fetch --lease-holder setup 2>/dev/null </dev/null)
(cd "$D/proj" && "$REAL_TH" return "$S" --force) >/dev/null 2>&1 </dev/null
S=$(cd "$S" && pwd -P)
OLD_POOL=${S%/*/*}
git -C "$S" switch -q -c "fm/$id-slot"
fm_write_meta "$D/home/state/$id.meta" "window=fmses:fm-$id" "endpoint_task_id=$id" \
  "worktree=$S" "project=$D/proj" "kind=ship" "mode=no-mistakes" "branch=fm/$id" \
  "spawn_gen=finished" "pr=https://github.com/example/repo/pull/7"
fm_write_meta "$D/home/state/parked.meta" "worktree=$S" "kind=ship"
printf 'task=%s\nhome=%s\n' "$id" "$D/home" > "${S%/*}/.fm-slot-owner"
# Repoint origin: the project's current pool moves to a new folder.
git clone -q --bare "$D/origin.git" "$D/origin2.git"
git -C "$D/proj" remote set-url origin "$D/origin2.git"
N=$(cd "$D/proj" && "$REAL_TH" get --lease --no-fetch --lease-holder setup 2>/dev/null </dev/null)
(cd "$D/proj" && "$REAL_TH" return "$N" --force) >/dev/null 2>&1 </dev/null
NEW_POOL=$(cd "$D/proj" && "$REAL_TH" pool-dir)
: > "$D/treehouse.log"

snap() {
  {
    echo "== $1: pool-dir=$(cd "$D/proj" && "$REAL_TH" pool-dir)"
    echo "== $1: OLD pool state (holds the shared copy) sha256=$(shasum -a 256 "$OLD_POOL/treehouse-state.json" | cut -c1-16)"
    jq -c '.worktrees[] | {name, path, lease_holder: (.lease.holder // .lease_holder // null)}' "$OLD_POOL/treehouse-state.json"
    echo "== $1: NEW pool state sha256=$(shasum -a 256 "$NEW_POOL/treehouse-state.json" | cut -c1-16)"
    jq -c '.worktrees[] | {name, path, lease_holder: (.lease.holder // .lease_holder // null)}' "$NEW_POOL/treehouse-state.json"
    echo "== $1: claimant record present: $([ -f "$D/home/state/$id.meta" ] && echo yes || echo no); parked record present: $([ -f "$D/home/state/parked.meta" ] && echo yes || echo no); shared copy HEAD: $(git -C "$S" symbolic-ref -q --short HEAD)"
  } 2>&1 | log
}
echo "scenario=$SCEN claimant PR state=$LIVE_PR_STATE shared slot=$S" | log
snap before
rc=0
FM_HOME="$D/home" FM_ROOT_OVERRIDE="$D/code-root" FM_STATE_OVERRIDE="$D/home/state" \
  FM_DATA_OVERRIDE="$D/home/data" FM_CONFIG_OVERRIDE="$D/home/config" \
  "$WT/bin/fm-teardown.sh" "$id" > "$OUT/teardown.out" 2>&1 || rc=$?
sed -i '' "s#$T#\$CASE#g" "$OUT/teardown.out"
echo "== fm-teardown.sh $id exit=$rc" | log
echo "== treehouse commands teardown ran:" | log
log < "$D/treehouse.log"
echo "== teardown output (pool/refusal lines):" | log
grep -Ei 'REFUSED|merged|lease|slot|nothing' "$OUT/teardown.out" | head -12 | tee -a "$OUT/transcript.txt"
snap after
