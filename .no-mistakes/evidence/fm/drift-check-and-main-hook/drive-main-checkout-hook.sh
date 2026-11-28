#!/usr/bin/env bash
# Live driver: real git commit/merge against disposable repos with bin/fm-main-checkout-hook.sh installed.
# Usage: drive-main-checkout-hook.sh <worktree-root>
set -u
SRC=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-hook-live.XXXXXX")
T=$(cd "$T" && pwd -P)
export GIT_CONFIG_GLOBAL="$T/empty-gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
export FM_GUARD_EVENT_LOG="$T/guard-events.jsonl"
unset FM_ALLOW_MAIN_COMMIT
PASS=0 FAIL=0
step() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %d]\n' "$rc"; return $rc; }
check() { if eval "$2"; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; fi; }

# Toolbelt: a real git repo holding a copy of bin/, with a linked worktree (a "slot").
TB="$T/toolbelt"
mkdir -p "$TB"
git -C "$SRC" archive HEAD bin/fm-main-checkout-hook.sh bin/fm-guard-event.sh | tar -x -C "$TB"
git init -q -b main "$TB"; git -C "$TB" -c user.name=f -c user.email=f@x.invalid add -A
git -C "$TB" -c user.name=f -c user.email=f@x.invalid commit -q -m toolbelt
git -C "$TB" worktree add -q --detach "$T/toolbelt-slot" main
HOOK="$TB/bin/fm-main-checkout-hook.sh"

mk() { git init -q -b main "$1"; git -C "$1" config user.name f; git -C "$1" config user.email f@x.invalid
  echo init > "$1/f.txt"; git -C "$1" add f.txt; git -C "$1" commit -q -m init; }

R="$T/target"; mk "$R"
step "setup: effective hooks path before install"
run git -C "$R" rev-parse --path-format=absolute --git-path hooks

step "S10 --help prints full header"
run bash "$HOOK" --help | tail -3
check "--help ends on full Safety sentence" "bash '$HOOK' --help | tail -1 | grep -q 'never overwrite or delete unmanaged hooks or symbolic links.'"

step "S8a install from a linked-worktree (slot) copy of the toolbelt"
run bash "$T/toolbelt-slot/bin/fm-main-checkout-hook.sh" install --repo "$R"
run cat "$R/.git/hooks/pre-commit"
check "wrapper points at primary toolbelt copy, not slot" "grep -qF \"guard='$HOOK'\" '$R/.git/hooks/pre-commit'"
run bash "$HOOK" status --repo "$R"; check "status installed exit 0" "bash '$HOOK' status --repo '$R' >/dev/null"
step "S8b delete the slot; hooks must keep working"
run git -C "$TB" worktree remove --force "$T/toolbelt-slot"

step "S1 direct commit in primary checkout through real git"
echo change >> "$R/f.txt"; git -C "$R" add f.txt
before=$(git -C "$R" rev-parse HEAD)
run git -C "$R" commit -m "direct primary commit"
check "primary commit refused (HEAD unchanged)" "[ \"\$(git -C '$R' rev-parse HEAD)\" = '$before' ]"
check "deny event logged" "grep -q '\"decision\":\"deny\"' '$FM_GUARD_EVENT_LOG' && grep -q main-checkout-commit '$FM_GUARD_EVENT_LOG'"
git -C "$R" reset -q --hard

step "S3 linked worktree: commit and --no-ff merge allowed"
run git -C "$R" worktree add -q -b fm/topic "$T/target-wt" main
echo wt >> "$T/target-wt/f.txt"
run git -C "$T/target-wt" commit -qam "linked worktree commit"
check "linked worktree commit landed" "[ \"\$(git -C '$T/target-wt' log -1 --format=%s)\" = 'linked worktree commit' ]"
git -C "$R" branch side main; git -C "$R" update-ref refs/heads/side "$(git -C "$R" commit-tree -p main -m side 'main^{tree}')"
run git -C "$T/target-wt" merge --no-ff -m "wt merge" side
check "linked worktree --no-ff merge landed" "[ \"\$(git -C '$T/target-wt' log -1 --format=%s)\" = 'wt merge' ]"

step "S2 --no-ff merge in primary checkout refused (pre-merge-commit)"
git -C "$R" branch side2 main; git -C "$R" update-ref refs/heads/side2 "$(git -C "$R" commit-tree -p main -m side2 'main^{tree}')"
before=$(git -C "$R" rev-parse HEAD)
run git -C "$R" merge --no-ff -m "primary merge" side2
check "primary merge refused (HEAD unchanged)" "[ \"\$(git -C '$R' rev-parse HEAD)\" = '$before' ]"
git -C "$R" merge --abort 2>/dev/null; git -C "$R" reset -q --hard

step "S4 FM_ALLOW_MAIN_COMMIT override"
echo o >> "$R/f.txt"; git -C "$R" add f.txt
for v in 0 true; do
  before=$(git -C "$R" rev-parse HEAD)
  run env FM_ALLOW_MAIN_COMMIT=$v git -C "$R" commit -qm "override $v"
  check "FM_ALLOW_MAIN_COMMIT=$v still refused" "[ \"\$(git -C '$R' rev-parse HEAD)\" = '$before' ]"
done
run env FM_ALLOW_MAIN_COMMIT=1 git -C "$R" commit -qm "override 1"
check "FM_ALLOW_MAIN_COMMIT=1 commit landed" "[ \"\$(git -C '$R' log -1 --format=%s)\" = 'override 1' ]"
check "override event logged (allow, override=true, cleared_by env)" "grep '\"decision\":\"allow\"' '$FM_GUARD_EVENT_LOG' | grep -q '\"override\":true' && grep -q '\"cleared_by\":\"env\"' '$FM_GUARD_EVENT_LOG'"

step "S5 fail closed when worktree identity cannot be resolved"
run bash "$HOOK" check --repo "$T/does-not-exist"; rc1=$?
mkdir -p "$T/notgit"; ( cd "$T/notgit" && GIT_CEILING_DIRECTORIES="$T" run bash "$HOOK" check ); rc2=$?
check "check on missing dir exits 1" "[ $rc1 -eq 1 ]"
check "check in non-git dir exits 1" "[ $rc2 -eq 1 ]"
check "source_ok false deny event logged" "grep -q '\"source_ok\":false' '$FM_GUARD_EVENT_LOG'"

step "S9 guard script missing: wrapper refuses clearly, not exit 127"
mv "$HOOK" "$HOOK.gone"
echo m >> "$R/f.txt"; git -C "$R" add f.txt
run git -C "$R" commit -m "guard missing" 2>&1 | tee "$T/missing.out"
check "missing-guard message printed" "grep -q 'guard script .* is missing or not executable' '$T/missing.out'"
check "pre-commit exit is 1 not 127" "bash '$R/.git/hooks/pre-commit'; [ \$? -eq 1 ]"
mv "$HOOK.gone" "$HOOK"; git -C "$R" reset -q --hard

step "S10b remove deletes only managed hooks"
echo '#!/bin/sh' > "$R/.git/hooks/post-commit"
run bash "$HOOK" remove --repo "$R"
check "managed hooks gone, unmanaged post-commit kept" "[ ! -e '$R/.git/hooks/pre-commit' ] && [ ! -e '$R/.git/hooks/pre-merge-commit' ] && [ -e '$R/.git/hooks/post-commit' ]"

step "S6 unmanaged and symlinked hooks are never overwritten or deleted"
U="$T/unmanaged"; mk "$U"
printf '#!/bin/sh\necho user hook\n' > "$U/.git/hooks/pre-merge-commit"; h0=$(shasum "$U/.git/hooks/pre-merge-commit")
run bash "$HOOK" install --repo "$U"; rc=$?
check "install refuses unmanaged pre-merge-commit" "[ $rc -eq 1 ]"
check "unmanaged bytes unchanged, pre-commit not written" "[ \"\$(shasum '$U/.git/hooks/pre-merge-commit')\" = '$h0' ] && [ ! -e '$U/.git/hooks/pre-commit' ]"
run bash "$HOOK" remove --repo "$U"; rc=$?
check "remove refuses unmanaged hook and keeps it" "[ $rc -eq 1 ] && [ \"\$(shasum '$U/.git/hooks/pre-merge-commit')\" = '$h0' ]"
L="$T/symlinked"; mk "$L"; printf '#!/bin/sh\n' > "$T/elsewhere-hook"; ln -s "$T/elsewhere-hook" "$L/.git/hooks/pre-commit"
run bash "$HOOK" install --repo "$L"; rc=$?
check "install refuses symlinked pre-commit; link intact" "[ $rc -eq 1 ] && [ -L '$L/.git/hooks/pre-commit' ] && [ \"\$(readlink '$L/.git/hooks/pre-commit')\" = '$T/elsewhere-hook' ]"
run bash "$HOOK" remove --repo "$L"; rc=$?
check "remove refuses symlinked pre-commit; link intact" "[ $rc -eq 1 ] && [ -L '$L/.git/hooks/pre-commit' ]"

step "S7 core.hooksPath set: install/remove refuse, status inactive"
H="$T/hookspath"; mk "$H"; git -C "$H" config core.hooksPath .husky
run bash "$HOOK" install --repo "$H"; rc=$?
check "install refuses with core.hooksPath" "[ $rc -eq 1 ] && [ ! -e '$H/.git/hooks/pre-commit' ]"
run bash "$HOOK" remove --repo "$H"; rc=$?; check "remove refuses with core.hooksPath" "[ $rc -eq 1 ]"
run bash "$HOOK" status --repo "$H"; rc=$?; check "status inactive exit 1" "[ $rc -eq 1 ]"

step "S8c install from slot copy refused when primary has no copy"
TB2="$T/toolbelt2"; mkdir -p "$TB2/bin"; cp "$SRC/bin/fm-main-checkout-hook.sh" "$TB2/bin/"
git init -q -b main "$TB2"; git -C "$TB2" -c user.name=f -c user.email=f@x.invalid add -A; git -C "$TB2" -c user.name=f -c user.email=f@x.invalid commit -qm tb
git -C "$TB2" worktree add -q --detach "$T/tb2-slot" main; rm "$TB2/bin/fm-main-checkout-hook.sh"
N="$T/newtarget"; mk "$N"
run bash "$T/tb2-slot/bin/fm-main-checkout-hook.sh" install --repo "$N"; rc=$?
check "install from slot refuses without primary copy, writes nothing" "[ $rc -eq 1 ] && [ ! -e '$N/.git/hooks/pre-commit' ]"

step "guard events (telemetry) recorded"
cat "$FM_GUARD_EVENT_LOG"
printf '\nSUMMARY: %d pass, %d fail\n' "$PASS" "$FAIL"
rm -rf "$T"
[ "$FAIL" -eq 0 ]
