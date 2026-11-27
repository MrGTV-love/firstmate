#!/usr/bin/env bash
# Live drive of the real bin/fm-fleet-sync.sh (HEAD and BASE) against a disposable lab FM_HOME.
# Usage: live-fleet-sync.sh <worktree> <base-sha> <lab-home>
set -u
WT=$1 BASE_SHA=$2 LAB=$3
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-scratch.XXXXXX")
mkdir -p "$S/home"
export HOME="$S/home" XDG_CONFIG_HOME="$S/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export FM_HOME=$LAB
mkdir -p "$S/base" && git -C "$WT" archive "$BASE_SHA" bin | tar -x -C "$S/base"
HEAD_FS="$WT/bin/fm-fleet-sync.sh"; BASE_FS="$S/base/bin/fm-fleet-sync.sh"
echo "git: $(git --version)"; echo "head: $(git -C "$WT" rev-parse HEAD)"; echo "base: $BASE_SHA"
P=$LAB/projects; mkdir -p "$P" "$LAB/data"
key() { git -C "$1" config --local --get maintenance.pack-refs.enabled 2>/dev/null || echo '<unset>'; }
origin_of() { git -C "$S" init -q --bare -b main "$S/$1.git"; git clone -q "$S/$1.git" "$S/seed-$1" 2>/dev/null; git -C "$S/seed-$1" commit -q --allow-empty -m init; git -C "$S/seed-$1" push -q origin main; }
mkclone() { origin_of "$1"; git clone -q "$S/$1.git" "$P/$1"; }

echo; echo "=== S1: fleet-sync writes maintenance.pack-refs.enabled=false in every clone root ==="
cat > "$LAB/data/projects.md" <<R
- alpha [no-mistakes] - remote clone
- beta [local-only] - local-only clone
- gamma [no-mistakes] - key preset to true
- dirty [no-mistakes] - dirty clone
- badfetch [no-mistakes] - fetch fails
- noorigin [no-mistakes] - no origin
R
mkclone alpha; mkclone gamma; mkclone dirty; mkclone badfetch
git init -q -b main "$P/beta"; git -C "$P/beta" commit -q --allow-empty -m init
git init -q -b main "$P/noorigin"; git -C "$P/noorigin" commit -q --allow-empty -m init
git clone -q "$S/alpha.git" "$P/unreg"   # not in registry
git -C "$P/gamma" config maintenance.pack-refs.enabled true
git -C "$P/gamma" config core.custom keep-me
echo junk > "$P/dirty/junk"
git -C "$P/badfetch" remote set-url origin "$S/does-not-exist.git"
mkdir -p "$S/outer" && git init -q "$S/outer" && mkdir -p "$S/outer/sub" && ln -s "$S/outer/sub" "$P/notroot"
git init -q -b main "$LAB" 2>/dev/null; git -C "$LAB" commit -q --allow-empty -m home
cp "$P/gamma/.git/config" "$S/gamma-config.before"
echo "-- BASE fleet-sync run (control) --"; bash "$BASE_FS" 2>&1 | sed 's/^/  base| /'
for c in alpha beta gamma dirty badfetch noorigin unreg; do echo "  after BASE: $c key=$(key "$P/$c")"; done
echo "-- HEAD fleet-sync run --"; bash "$HEAD_FS" 2>&1 | sed 's/^/  head| /'
for c in alpha beta gamma dirty badfetch noorigin unreg; do
  echo "  after HEAD: $c key=$(key "$P/$c")  origin=$(git -C "$P/$c" config --local --show-origin --get maintenance.pack-refs.enabled | cut -f1)  maintenance.auto=$(git -C "$P/$c" config --get maintenance.auto || echo unset)"
done
echo "  home repo ($LAB) key=$(key "$LAB")"
echo "  notroot outer repo key=$(key "$S/outer") (must stay <unset>)"
echo "  gamma neighbour core.custom=$(git -C "$P/gamma" config core.custom)"
echo "  gamma config diff vs before (only the key line may change):"; diff "$S/gamma-config.before" "$P/gamma/.git/config" | sed 's/^/    /'
for c in alpha beta gamma; do shasum "$P/$c/.git/config"; done > "$S/sums1"
bash "$HEAD_FS" >/dev/null 2>&1
for c in alpha beta gamma; do shasum "$P/$c/.git/config"; done > "$S/sums2"
if cmp -s "$S/sums1" "$S/sums2"; then echo "  second HEAD run: config bytes unchanged (idempotent) OK"; else echo "  second HEAD run: CONFIG CHANGED FAIL"; fi
echo "-- single-name form on a new clone --"
mkclone epsilon; echo "- epsilon [no-mistakes] - new" >> "$LAB/data/projects.md"
echo "  before: epsilon key=$(key "$P/epsilon")"
bash "$HEAD_FS" epsilon 2>&1 | sed 's/^/  head| /'
echo "  after single-name run: epsilon key=$(key "$P/epsilon")"

echo; echo "=== S2: write failure (pre-created .git/config.lock) warns and the sync continues ==="
mkclone lockcl; echo "- lockcl [no-mistakes] - locked config" >> "$LAB/data/projects.md"
mkclone after1; echo "- after1 [no-mistakes] - later clone" >> "$LAB/data/projects.md"
: > "$P/lockcl/.git/config.lock"
bash "$HEAD_FS" 2>&1 | grep -E '^(lockcl|after1):' | sed 's/^/  head| /'
echo "  lockcl key=$(key "$P/lockcl")  after1 key=$(key "$P/after1")"
rm -f "$P/lockcl/.git/config.lock"

echo; echo "=== S3: auto maintenance from a LINKED worktree leaves refs/heads/fm in place (20 loose fm refs + main) ==="
# one fixture per trigger; keyed = key written by HEAD fleet-sync; control = same clone, BASE fleet-sync (no key)
run_trigger() { # <clone> <trigger>
  local c=$1 t=$2 lw="$S/lw-$1-$2" gd tr
  gd=$(git -C "$P/$c" rev-parse --absolute-git-dir)
  git -C "$P/$c" config maintenance.autoDetach false
  for i in $(seq 1 20); do git -C "$P/$c" branch "fm/b$i"; done
  git -C "$P/$c" worktree add -q -b "fm/wt-$t" "$lw" 2>/dev/null
  tr="$S/trace-$c-$t.json"
  case $t in
    commit) echo x > "$lw/f"; git -C "$lw" add f; GIT_TRACE2_EVENT=$tr git -C "$lw" commit -q -m c ;;
    amend) echo x > "$lw/f"; git -C "$lw" add f; git -C "$lw" -c maintenance.auto=false commit -q -m c; GIT_TRACE2_EVENT=$tr git -C "$lw" commit -q --amend -m c2 ;;
    fetch) git -C "$S/seed-$c" commit -q --allow-empty -m up; git -C "$S/seed-$c" push -q origin main; GIT_TRACE2_EVENT=$tr git -C "$lw" fetch -q origin ;;
    merge) git -C "$S/seed-$c" commit -q --allow-empty -m up2; git -C "$S/seed-$c" push -q origin main; git -C "$lw" -c maintenance.auto=false fetch -q origin; GIT_TRACE2_EVENT=$tr git -C "$lw" merge -q --ff-only origin/main ;;
    rebase) git -C "$S/seed-$c" commit -q --allow-empty -m up3; git -C "$S/seed-$c" push -q origin main; git -C "$lw" -c maintenance.auto=false fetch -q origin; echo y > "$lw/g"; git -C "$lw" add g; git -C "$lw" -c maintenance.auto=false commit -q -m g; GIT_TRACE2_EVENT=$tr git -C "$lw" rebase -q origin/main ;;
  esac
  local rc=$? pk=no mt=no folder loose
  grep '"event":"child_start"' "$tr" 2>/dev/null | grep -qF '"argv":["git","pack-refs"' && pk=yes
  grep '"event":"child_start"' "$tr" 2>/dev/null | grep -qF '"argv":["git","maintenance","run"' && mt=yes
  if [ -d "$gd/refs/heads/fm" ]; then folder=present; else folder=ABSENT; fi
  loose=$(find "$gd/refs/heads/fm" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  $c/$t: rc=$rc key=$(key "$P/$c") maintenance_child=$mt pack_refs_child=$pk refs/heads/fm=$folder loose_fm=$loose"
}
for t in commit amend fetch merge rebase; do
  for kind in keyed ctl; do
    c="m-$kind-$t"; mkclone "$c"; echo "- $c [no-mistakes] - maint" >> "$LAB/data/projects.md"
    if [ $kind = keyed ]; then bash "$HEAD_FS" "$c" >/dev/null 2>&1; else bash "$BASE_FS" "$c" >/dev/null 2>&1; fi
    run_trigger "$c" "$t"
  done
done

echo; echo "=== S4: object gc stays available with the key set ==="
mkclone gcc; echo "- gcc [no-mistakes] - gc control" >> "$LAB/data/projects.md"; bash "$HEAD_FS" gcc >/dev/null 2>&1
git -C "$P/gcc" config gc.auto 100; git -C "$P/gcc" config maintenance.autoDetach false
for i in $(seq 1 3000); do printf "blob %s\n" "$i" > "$S/blobf"; git -C "$P/gcc" hash-object -w "$S/blobf" >/dev/null; done
b=$(git -C "$P/gcc" count-objects | cut -d' ' -f1); git -C "$P/gcc" maintenance run --auto; a=$(git -C "$P/gcc" count-objects | cut -d' ' -f1)
echo "  key=$(key "$P/gcc") loose objects before=$b after=$a"

echo; echo "=== S5: fleet-sync prune of the last loose fm/ ref restores refs/heads/<prefix> ==="
prune_case() { # <name> <registry-bracket> <branch> <script> [link]
  local c=$1 br=$2 b=$3 fs=$4 link=${5-} gd out
  mkclone "$c"; echo "- $c [$br] - prune" >> "$LAB/data/projects.md"
  git -C "$S/seed-$c" push -q origin "main:$b"
  git -C "$P/$c" fetch -q origin; git -C "$P/$c" branch -q --track "$b" "origin/$b"
  gd=$(git -C "$P/$c" rev-parse --absolute-git-dir)
  if [ -n "$link" ]; then mkdir -p "$S/outside-$c"; fi
  git -C "$S/seed-$c" push -q origin --delete "$b"
  out=$(bash "$fs" "$c" 2>&1)
  echo "  [$c reg=$br branch=$b script=$(basename "$(dirname "$(dirname "$fs")")")] output: $(echo "$out" | tr '\n' ';')"
  for d in refs/heads/fm refs/heads/fix logs/refs/heads/fm logs/refs/heads/fix; do
    [ -d "$gd/$d" ] && echo "    $d present" || echo "    $d ABSENT"
  done
  echo "    branch $b exists after: $(git -C "$P/$c" rev-parse --verify -q "refs/heads/$b" >/dev/null && echo yes || echo no)"
}
prune_case pr-head no-mistakes fm/gone "$HEAD_FS"
prune_case pr-base no-mistakes fm/gone "$BASE_FS"
prune_case pr-prefix "no-mistakes branch=fix/" fm/gone "$HEAD_FS"
prune_case pr-prefix-base "no-mistakes branch=fix/" fm/gone "$BASE_FS"
echo "-- one of several loose refs deleted (nothing else changes) --"
mkclone pr-many; echo "- pr-many [no-mistakes] - prune" >> "$LAB/data/projects.md"
git -C "$P/pr-many" branch fm/stay; git -C "$S/seed-pr-many" push -q origin main:fm/gone
git -C "$P/pr-many" fetch -q origin; git -C "$P/pr-many" branch -q --track fm/gone origin/fm/gone
git -C "$S/seed-pr-many" push -q origin --delete fm/gone
bash "$HEAD_FS" pr-many 2>&1 | sed 's/^/  head| /'; ls "$P/pr-many/.git/refs/heads/fm" | sed 's/^/    loose: /'
echo "-- adversarial: registered prefix team/fm/, refs/heads/team is a symlink to a folder outside the clone --"
mkclone pr-link; echo "- pr-link [no-mistakes branch=team/fm/] - link" >> "$LAB/data/projects.md"
git -C "$S/seed-pr-link" push -q origin main:fm/gone
git -C "$P/pr-link" fetch -q origin; git -C "$P/pr-link" branch -q --track fm/gone origin/fm/gone
mkdir -p "$S/outside"; ln -s "$S/outside" "$P/pr-link/.git/refs/heads/team"
git -C "$S/seed-pr-link" push -q origin --delete fm/gone
bash "$HEAD_FS" pr-link 2>&1 | sed 's/^/  head| /'
echo "    link target contents: [$(ls -A "$S/outside")] (must be empty)"; ls -la "$P/pr-link/.git/refs/heads" | sed 's/^/    /'
rm -rf "$S"
echo "done"
