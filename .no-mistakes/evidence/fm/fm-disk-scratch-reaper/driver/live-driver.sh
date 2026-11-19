#!/usr/bin/env bash
# Live driver for bin/fm-scratch-reaper.sh in this change's worktree.
# Builds disposable worlds under a private temp folder and runs the REAL reaper script in them.
# No run names /private/tmp, ~/tmp, a real home, a treehouse pool or the operator's FM_HOME:
# every root, config, state, data and archive folder lives inside the world built here.
# The only stand-ins are fault-injection `lsof` and `df` binaries in a world-local fakebin folder.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7SPWYTNRFX8SACE90CH6NJ7
RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-sr.XXXXXX") || exit 1
SLEEPERS=()
FAILS=0

cleanup() {
  local p
  for p in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf -- "$RUN"
}
trap cleanup EXIT

pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
observe() { printf 'OBSERVED - %s\n' "$1"; }
check() {  # <description> <command...>
  local d=$1; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
age() { find "$1" -exec touch -h -t 202501010000 {} + ; }
realdir() { (cd -P -- "$1" && pwd -P); }

world() {  # <name>: a fresh private world; sets W
  W="$RUN/$1"
  mkdir -p "$W/home" "$W/tmp" "$W/fm/state" "$W/fm/data" "$W/fm/config" "$W/root" "$W/outside" "$W/fakebin" || exit 1
}
config() {  # <lines...>: write this world's scratch-reaper config
  printf '%s\n' "$@" > "$W/fm/config/scratch-reaper"
}
fakedf() {  # <free KiB>: a world-local df stand-in that reports that much free space
  cat > "$W/fakebin/df" <<SH
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/fake 1 1 $1 50%% /fake\n'
SH
  chmod +x "$W/fakebin/df"
}
reap() {  # <args...>: run the real reaper with only this world's paths; SR_PATH, SEAM, NOW_AT optional
  env -i PATH="${SR_PATH:-$PATH}" HOME="$W/home" TMPDIR="$W/tmp" \
    FM_HOME="$W/fm" FM_ROOT_OVERRIDE="$WT" FM_STATE_OVERRIDE="$W/fm/state" \
    FM_CONFIG_OVERRIDE="$W/fm/config" FM_DATA_OVERRIDE="$W/fm/data" \
    ${SEAM:+FM_TEST_SEAM=1} ${NOW_AT:+FM_SCRATCH_REAPER_NOW=$NOW_AT} \
    bash "$WT/bin/fm-scratch-reaper.sh" "$@"
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }          # the last run's output holds the text
logHas() { grep -qF -- "$1" "$W/fm/state/scratch-reaper.log" 2>/dev/null; }
logLine() { grep -F -- "$1" "$W/fm/state/scratch-reaper.log" 2>/dev/null | grep -qF -- "$2"; }
wakeRows() { grep -rF -- "scratch-reaper-low-disk" "$W/fm/state" 2>/dev/null | wc -l | tr -d ' '; }
show() { printf '\n--- %s ---\n%s\n' "$1" "$OUT"; }

# ============================================================================
# SR1 + SR2 + SR4 main world: dry run, then apply, over one world with every kind of directory.
# ============================================================================
printf '=== SR1/SR2 main world ===\n'
world main
config "$W/root fm-*"
R=$(realdir "$W/root")
mkdir -p "$R/fm-clean/nested/deep" "$R/fm-bigfile" "$R/fm-young" "$R/fm-busy" "$R/fm-escape" "$R/other-old"
printf 'run one\n' > "$R/fm-clean/run.log"
printf 'err line\n' > "$R/fm-clean/nested/deep/err.out"
printf '{"ok":1}\n' > "$R/fm-clean/result.json"
printf 'not a log\n' > "$R/fm-clean/data.bin"
head -c 2097152 /dev/zero > "$R/fm-bigfile/big.log"
printf 'small\n' > "$R/fm-bigfile/small.log"
printf 'old\n' > "$R/fm-young/old.log"
printf 'busy\n' > "$R/fm-busy/busy.log"
printf 'keep me\n' > "$W/outside/precious.txt"
ln -s "$W/outside/precious.txt" "$R/fm-escape/link.txt"
ln -s "$W/outside" "$R/fm-linkchild"
git -C "$W" init -q repo && git -C "$W/repo" -c user.name=live -c user.email=live@invalid.test commit -q --allow-empty -m init \
  && git -C "$W/repo" worktree add -q "$R/fm-gitwt" -b scratch-live
mkdir -p "$R/fm-nl"$'\n'"x" && printf 'nl\n' > "$R/fm-nl"$'\n'"x/run.log"
printf 'plain\n' > "$R/fm-plain.txt"
age "$R"
printf 'fresh\n' > "$R/fm-young/fresh.txt"          # a new entry makes the whole tree young
( cd "$R/fm-busy" && exec sleep 600 ) &              # a live process whose cwd is inside fm-busy
SLEEPERS+=("$!")
sleep 1

find "$R" "$W/outside" -mindepth 0 | LC_ALL=C sort > "$RUN/main-before.txt"
OUT=$(reap 2>&1); RC=$?
show "SR1 dry run (no --apply)"
find "$R" "$W/outside" -mindepth 0 | LC_ALL=C sort > "$RUN/main-after.txt"
check "SR1 dry run exits 0" [ "$RC" -eq 0 ]
check "SR1 dry run changes nothing on disk" cmp -s "$RUN/main-before.txt" "$RUN/main-after.txt"
check "SR1 dry run writes no decision log" [ ! -e "$W/fm/state/scratch-reaper.log" ]
check "SR1 dry run says would-remove fm-clean" has "would-remove $R/fm-clean bytes="
check "SR1 dry run says would-remove fm-bigfile" has "would-remove $R/fm-bigfile bytes="
check "SR1 dry run says would-remove fm-escape" has "would-remove $R/fm-escape bytes="
check "SR1 kept young directory with reason young" has "kept $R/fm-young reason=young"
check "SR1 kept directory with open cwd with reason open handle" has "kept $R/fm-busy reason=open handle"
check "SR1 kept git worktree with reason git" has "kept $R/fm-gitwt reason=git"
check "SR1 kept symlink child with reason symlink" has "kept $R/fm-linkchild reason=symlink"
check "SR1 kept newline-named directory with reason control-character-name" has "kept $R/fm-nl?x reason=control-character-name"
check "SR1 names no directory outside the glob" [ "$(printf '%s\n' "$OUT" | grep -c 'other-old')" -eq 0 ]
check "SR1 never treats a plain file as a candidate" [ "$(printf '%s\n' "$OUT" | grep -c 'fm-plain')" -eq 0 ]

# Hashes of the small logs before the real run, to compare with the archive copies.
H_RUN=$(sha "$R/fm-clean/run.log"); H_ERR=$(sha "$R/fm-clean/nested/deep/err.out")
H_JSON=$(sha "$R/fm-clean/result.json"); H_SMALL=$(sha "$R/fm-bigfile/small.log")

OUT=$(reap --apply 2>&1); RC=$?
show "SR1/SR2 apply (--apply)"
DAY=$(date -u +%Y-%m-%d)
D1="$W/fm/data/scratch-reaper-archive/$DAY/fm-clean"
D2="$W/fm/data/scratch-reaper-archive/$DAY/fm-bigfile"
check "SR1 apply exits 0" [ "$RC" -eq 0 ]
check "SR1 removed fm-clean" [ ! -e "$R/fm-clean" ]
check "SR1 removed fm-bigfile (with an oversize log)" [ ! -e "$R/fm-bigfile" ]
check "SR1 removed fm-escape (its symlink was not followed)" [ ! -e "$R/fm-escape" ]
check "SR1 kept fm-young on disk" [ -d "$R/fm-young" ]
check "SR1 kept fm-busy on disk" [ -d "$R/fm-busy" ]
check "SR1 kept fm-gitwt on disk" [ -e "$R/fm-gitwt/.git" ]
check "SR1 kept fm-linkchild symlink on disk" [ -L "$R/fm-linkchild" ]
check "SR1 kept the newline-named directory on disk" [ -d "$R/fm-nl"$'\n'"x" ]
check "SR1 kept other-old, outside the glob" [ -d "$R/other-old" ]
check "SR1 kept plain file fm-plain.txt" [ -f "$R/fm-plain.txt" ]
check "SR4 symlink target outside the root is untouched" [ "$(cat "$W/outside/precious.txt")" = "keep me" ]
check "SR2 archived run.log matches original sha256" [ "$(sha "$D1/run.log")" = "$H_RUN" ]
check "SR2 archived nested err.out keeps its relative path and sha256" [ "$(sha "$D1/nested/deep/err.out")" = "$H_ERR" ]
check "SR2 archived result.json matches original sha256" [ "$(sha "$D1/result.json")" = "$H_JSON" ]
check "SR2 did not archive data.bin (not a log extension)" [ ! -e "$D1/data.bin" ]
check "SR2 did not archive oversize big.log" [ ! -e "$D2/big.log" ]
check "SR2 archived small.log of fm-bigfile matches original sha256" [ "$(sha "$D2/small.log")" = "$H_SMALL" ]
check "SR2 log line: fm-clean archived=3 skipped_logs=0" logLine "removed $R/fm-clean " "archived=3 skipped_logs=0"
check "SR2 log line: fm-bigfile says one log skipped" logLine "removed $R/fm-bigfile " "archived=1 skipped_logs=1"
check "SR1 log holds a kept line for fm-busy" logHas "kept $R/fm-busy reason=open handle"
check "SR1 log holds a kept line for fm-young" logHas "kept $R/fm-young reason=young"
check "SR1 fm-busy process is still alive" kill -0 "${SLEEPERS[0]}"
show "SR1 decision log (state/scratch-reaper.log)"
cat "$W/fm/state/scratch-reaper.log"
printf '\n'
kill "${SLEEPERS[0]}" 2>/dev/null; wait "${SLEEPERS[0]}" 2>/dev/null

# ============================================================================
# SR2 archive failure: the archive folder cannot be created, so the directory must be kept.
# ============================================================================
printf '\n=== SR2 archive failure ===\n'
world archfail
config "$W/root fm-*"
mkdir -p "$W/root/fm-arch" && printf 'arch\n' > "$W/root/fm-arch/run.log" && age "$W/root"
printf 'not a folder\n' > "$W/fm/data/scratch-reaper-archive"   # blocks the archive folder
RA=$(realdir "$W/root")
H_ARCH=$(sha "$W/root/fm-arch/run.log")
OUT=$(reap --apply 2>&1); RC=$?
show "SR2 apply with a blocked archive folder"
check "SR2 archive failure exits 0" [ "$RC" -eq 0 ]
check "SR2 kept the directory with reason archive failed" has "kept $RA/fm-arch reason=archive failed"
check "SR2 the directory and its log are untouched" [ "$(sha "$W/root/fm-arch/run.log")" = "$H_ARCH" ]

# ============================================================================
# SR1 lsof failure: every candidate that needs the snapshot is kept, exit 3.
# ============================================================================
printf '\n=== SR1 lsof failure ===\n'
world lsoffail
config "$W/root fm-*"
mkdir -p "$W/root/fm-lsof" && printf 'l\n' > "$W/root/fm-lsof/run.log" && age "$W/root"
printf '#!/bin/sh\nexit 1\n' > "$W/fakebin/lsof" && chmod +x "$W/fakebin/lsof"
RL=$(realdir "$W/root")
OUT=$(SR_PATH="$W/fakebin:$PATH" reap --apply 2>&1); RC=$?
show "SR1 apply with a failing lsof stand-in"
check "SR1 lsof failure exits 3" [ "$RC" -eq 3 ]
check "SR1 lsof failure keeps the candidate with reason lsof failed" has "kept $RL/fm-lsof reason=lsof failed"
check "SR1 lsof failure removes nothing" [ -f "$W/root/fm-lsof/run.log" ]
mkdir -p "$W/root/fm-lsof2" && printf 'l2\n' > "$W/root/fm-lsof2/run.log" && age "$W/root"
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$(date +%s) reap --scheduled 2>&1); RC=$?
show "SR3 scheduled run with a failing lsof stand-in"
check "SR3 failed scheduled run keeps its candidate (lsof failed)" [ -f "$W/root/fm-lsof2/run.log" ]
check "SR3 failed scheduled run returns to its caller with rc 3 (the watcher ignores it)" [ "$RC" -eq 3 ]
check "SR3 failed scheduled run is logged as error rc=3" logHas "error rc=3"

# ============================================================================
# SR3 scheduled run: one run per 30-minute window, none inside it, using a fake clock.
# ============================================================================
printf '\n=== SR3 scheduled window ===\n'
world sched
config "$W/root fm-*"
N0=$(date +%s)
mkdir -p "$W/root/fm-s1" && printf 's1\n' > "$W/root/fm-s1/run.log" && age "$W/root"
OUT=$(SEAM=1 NOW_AT=$N0 reap --scheduled 2>&1); RC=$?
show "SR3 scheduled run at t0"
check "SR3 first scheduled run exits 0" [ "$RC" -eq 0 ]
check "SR3 first scheduled run removed fm-s1" [ ! -e "$W/root/fm-s1" ]
check "SR3 next-run marker is t0 plus 1800 s" [ "$(cat "$W/fm/state/.scratch-reaper-next")" = "$((N0 + 1800))" ]
mkdir -p "$W/root/fm-s2" && printf 's2\n' > "$W/root/fm-s2/run.log" && age "$W/root"
LOGN_BEFORE=$(wc -l < "$W/fm/state/scratch-reaper.log")
OUT=$(SEAM=1 NOW_AT=$((N0 + 600)) reap --scheduled 2>&1); RC=$?
check "SR3 run inside the window exits 0" [ "$RC" -eq 0 ]
check "SR3 run inside the window prints nothing" [ -z "$OUT" ]
check "SR3 run inside the window adds no decision-log line" [ "$(wc -l < "$W/fm/state/scratch-reaper.log")" -eq "$LOGN_BEFORE" ]
check "SR3 run inside the window leaves fm-s2 alone" [ -f "$W/root/fm-s2/run.log" ]
OUT=$(SEAM=1 NOW_AT=$((N0 + 1800)) reap --scheduled 2>&1); RC=$?
show "SR3 scheduled run at t0 plus 1800 s"
check "SR3 run at the window edge removes fm-s2" [ ! -e "$W/root/fm-s2" ]

# ============================================================================
# SR3 low-disk alarm: one wake per low episode, repeats only after 6 hours, cleared on recovery.
# ============================================================================
printf '\n=== SR3 low-disk alarm ===\n'
world lowdisk
config "$W/root fm-*"
L0=$(date +%s)
fakedf 1000000   # about 0.95 GiB free: under the 20 GiB floor
M="$W/fm/state/.scratch-reaper-alarmed"
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$L0 reap --scheduled 2>&1); RC=$?
show "SR3 low disk, nothing removed, first run"
check "SR3 low disk first run exits 0" [ "$RC" -eq 0 ]
check "SR3 low disk raises one wake" [ "$(wakeRows)" -eq 1 ]
check "SR3 low disk records the alarm marker" [ "$(cat "$M" 2>/dev/null)" = "$L0" ]
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$((L0 + 1800)) reap --scheduled 2>&1); RC=$?
check "SR3 low disk within 6 hours raises no second wake" [ "$(wakeRows)" -eq 1 ]
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$((L0 + 21600 + 1800)) reap --scheduled 2>&1); RC=$?
check "SR3 low disk after 6 hours raises the wake again" [ "$(wakeRows)" -eq 2 ]
fakedf 31457280  # 30 GiB free: recovered
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$((L0 + 21600 + 3600)) reap --scheduled 2>&1); RC=$?
check "SR3 recovered space clears the alarm marker" [ ! -e "$M" ]
check "SR3 recovered space raises no wake" [ "$(wakeRows)" -eq 2 ]
fakedf 1000000
mkdir -p "$W/root/fm-l1" && printf 'l1\n' > "$W/root/fm-l1/run.log" && age "$W/root"
OUT=$(SR_PATH="$W/fakebin:$PATH" SEAM=1 NOW_AT=$((L0 + 21600 + 5400)) reap --scheduled 2>&1); RC=$?
show "SR3 low disk but the run frees bytes"
check "SR3 low disk with bytes freed removes fm-l1" [ ! -e "$W/root/fm-l1" ]
check "SR3 low disk with bytes freed raises no wake" [ "$(wakeRows)" -eq 2 ]

# ============================================================================
# SR4 / SR1 refusals: a bad root stops the run with exit 2 and removes nothing.
# ============================================================================
printf '\n=== SR4 root refusals ===\n'
world cfgmissing
config "$W/root fm-*" "$W/nope fm-*"
mkdir -p "$W/root/fm-cm" && printf 'c\n' > "$W/root/fm-cm/run.log" && age "$W/root"
OUT=$(reap --apply 2>&1); RC=$?
show "SR4 configured root that is missing"
check "SR4 missing configured root exits 2" [ "$RC" -eq 2 ]
check "SR4 missing configured root names the config file and the root" has "root $W/nope from $W/fm/config/scratch-reaper is missing"
check "SR4 missing configured root removes nothing" [ -f "$W/root/fm-cm/run.log" ]

world cfgprotected
config "$W/fm fm-*"
OUT=$(reap --apply 2>&1); RC=$?
show "SR4 root that contains the home"
check "SR4 root holding the home exits 2" [ "$RC" -eq 2 ]
check "SR4 root holding the home says protected" has "is, contains or lies under a protected path"

world cfgsymlink
ln -s "$W/root" "$W/rootlink"
config "$W/rootlink fm-*"
mkdir -p "$W/root/fm-sl" && printf 'sl\n' > "$W/root/fm-sl/run.log" && age "$W/root"
OUT=$(reap --apply 2>&1); RC=$?
show "SR4 symlink root"
check "SR4 symlink root exits 2" [ "$RC" -eq 2 ]
check "SR4 symlink root removes nothing behind it" [ -f "$W/root/fm-sl/run.log" ]

world cfgrelative
config "relroot fm-*"
OUT=$(reap --apply 2>&1); RC=$?
show "SR4 relative root"
check "SR4 relative root exits 2" [ "$RC" -eq 2 ]
check "SR4 relative root says not absolute" has "root 'relroot' is not absolute or ~/"

# ============================================================================
# Adversarial: a glob-matching name in the current folder (owner-declined item, observed only).
# ============================================================================
printf '\n=== cwd name trap (owner-declined review item, observed) ===\n'
world cwdtrap
config "$W/root fm-*"
mkdir -p "$W/root/fm-cw" && printf 'cw\n' > "$W/root/fm-cw/run.log" && age "$W/root"
mkdir -p "$W/trap/fm-trap"
OUT=$(cd "$W/trap" && reap --apply 2>&1); RC=$?
show "run from a folder holding fm-trap"
if [ -f "$W/root/fm-cw/run.log" ]; then
  observe "aged fm-cw was kept when the run's cwd held a fm-* name (glob expanded against cwd)"
else
  observe "aged fm-cw was removed from a cwd holding a fm-* name"
fi

printf '\n=== summary: %s failing check(s) ===\n' "$FAILS"
exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
