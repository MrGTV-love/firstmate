#!/usr/bin/env bash
# Live driver: bin/fm-drift-check.sh against a disposable bare origin + clone with real branches/worktrees.
# Usage: drive-drift-check.sh <worktree-root>
set -u
SRC=$1
DRIFT="$SRC/bin/fm-drift-check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift-live.XXXXXX"); T=$(cd "$T" && pwd -P)
export GIT_CONFIG_GLOBAL="$T/empty-gitconfig" GIT_CONFIG_NOSYSTEM=1; : > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@x.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@x.invalid
PASS=0 FAIL=0
step() { printf '\n### %s\n' "$*"; }
d() { printf '$ fm-drift-check.sh %s\n' "$*"; OUT=$(bash "$DRIFT" "$@" 2>&1); RC=$?; printf '%s\n[exit %d]\n' "$OUT" "$RC"; }
check() { if eval "$2"; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; fi; }
snap() { { git -C "$C" for-each-ref; git -C "$C" status --porcelain=v2 --branch; git -C "$C" worktree list --porcelain;
  find "$C/.git" -type f ! -name '*.lock' -exec shasum {} + | sort; } > "$1"; }

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
echo a > "$T/seed/f.txt"; git -C "$T/seed" add f.txt; git -C "$T/seed" commit -qm init; git -C "$T/seed" push -q origin main
C="$T/home"; git clone -q "$T/origin.git" "$C"; git -C "$C" checkout -q --detach origin/main
git -C "$C" branch -q -D main

step "D1 clean primary: detached at origin/main, untracked file does not flag"
echo junk > "$C/untracked.txt"
d --repo "$C"
check "clean -> OK, exit 0" "[ $RC -eq 0 ] && grep -q '^OK:' <<<\"\$OUT\""
rm "$C/untracked.txt"

step "D2 primary on branch, HEAD != base, tracked dirty"
git -C "$C" checkout -q -b work; echo b >> "$C/f.txt"; git -C "$C" commit -qam local; echo c >> "$C/f.txt"
d --repo "$C"
check "on-branch flagged" "grep -q \"on branch 'work'\" <<<\"\$OUT\""
check "HEAD != base flagged" "grep -q 'HEAD .* != origin/main' <<<\"\$OUT\""
check "tracked dirty flagged" "grep -q 'modified tracked files' <<<\"\$OUT\" && [ $RC -eq 1 ]"
step "D7a --warn-only prints drift but exits 0"
d --repo "$C" --warn-only
check "--warn-only exit 0 with DRIFT lines" "[ $RC -eq 0 ] && grep -q '^DRIFT' <<<\"\$OUT\""
git -C "$C" checkout -q -- f.txt; git -C "$C" checkout -q --detach origin/main; git -C "$C" branch -q -D work

step "D3 --max-ahead boundary (3 ahead: max 3 ok, max 2 flagged)"
git -C "$C" branch -q ahead origin/main
for i in 1 2 3; do git -C "$C" update-ref refs/heads/ahead "$(git -C "$C" commit-tree -p ahead -m a$i 'ahead^{tree}')"; done
git -C "$C" push -q origin ahead
d --repo "$C" --max-ahead 3
check "3 ahead with --max-ahead 3 not flagged" "[ $RC -eq 0 ]"
d --repo "$C" --max-ahead 2
check "3 ahead with --max-ahead 2 flagged" "[ $RC -eq 1 ] && grep -q 'ahead (+3' <<<\"\$OUT\""
git -C "$C" branch -q -D ahead; git -C "$C" push -q origin --delete ahead; git -C "$C" fetch -q --prune

step "D4 old unpushed branch flagged; same branch after push not flagged"
old=$(GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" git -C "$C" commit-tree -p HEAD -m old 'HEAD^{tree}')
git -C "$C" update-ref refs/heads/oldtopic "$old"
d --repo "$C" --max-age-days 7
check "old unpushed branch flagged on_origin=0" "[ $RC -eq 1 ] && grep -q 'oldtopic .*on_origin=0' <<<\"\$OUT\""
git -C "$C" push -q origin oldtopic
d --repo "$C" --max-age-days 7
check "old pushed branch not flagged" "[ $RC -eq 0 ]"
git -C "$C" branch -q -D oldtopic; git -C "$C" push -q origin --delete oldtopic; git -C "$C" fetch -q --prune

step "D5 worktrees: prunable + non-Treehouse flagged, .treehouse/ not flagged"
mkdir -p "$T/.treehouse/pool"
git -C "$C" worktree add -q --detach "$T/.treehouse/pool/slot1" origin/main
d --repo "$C"
check "treehouse slot alone not flagged" "[ $RC -eq 0 ]"
git -C "$C" worktree add -q --detach "$T/stray-wt" origin/main
git -C "$C" worktree add -q --detach "$T/gone-wt" origin/main; rm -rf "$T/gone-wt"
d --repo "$C"
check "prunable worktree flagged" "grep -q 'prunable worktree' <<<\"\$OUT\" && grep -q 'gone-wt' <<<\"\$OUT\""
check "stray non-Treehouse worktree flagged, slot and primary not listed" "grep -A3 'non-Treehouse' <<<\"\$OUT\" | grep -q stray-wt && ! grep -q 'slot1' <<<\"\$OUT\" && ! grep -qE '^  $C\$' <<<\"\$OUT\""

step "D8 read-only: repository state identical before and after"
snap "$T/before"; bash "$DRIFT" --repo "$C" >/dev/null 2>&1; snap "$T/after"
check "refs, status, worktree list, .git file hashes unchanged; prunable entry kept" "cmp -s '$T/before' '$T/after' && git -C '$C' worktree list --porcelain | grep -q prunable"

step "D6 --repo <linked worktree> reports the primary, same as --repo <primary>"
P_OUT=$(bash "$DRIFT" --repo "$C" 2>&1)
d --repo "$T/.treehouse/pool/slot1"
check "slot view equals primary view" "[ \"\$OUT\" = \"\$P_OUT\" ]"
git -C "$C" worktree remove --force "$T/stray-wt"; git -C "$C" worktree prune
git -C "$T/.treehouse/pool/slot1" checkout -q -b fm/slot-branch
d --repo "$T/.treehouse/pool/slot1"
check "slot on branch: primary not mislabeled as on-branch, primary not in non-Treehouse list" "[ $RC -eq 0 ] && ! grep -q 'on branch' <<<\"\$OUT\""
git -C "$T/.treehouse/pool/slot1" checkout -q --detach; git -C "$C" branch -q -D fm/slot-branch

step "D6b bare primary: NOTE, linked worktree from bare repo not mislabeled"
B="$T/bare.git"; git clone -q --bare "$T/origin.git" "$B"; git -C "$B" update-ref refs/remotes/origin/main main
mkdir -p "$T/.treehouse/bpool"; git -C "$B" worktree add -q --detach "$T/.treehouse/bpool/s" main
d --repo "$T/.treehouse/bpool/s"
check "bare primary NOTE printed and bare not listed as non-Treehouse" "grep -q 'NOTE: primary worktree .* is a bare repository' <<<\"\$OUT\" && ! grep -q non-Treehouse <<<\"\$OUT\""

step "D7b usage and git errors exit 2"
d --repo "$C" --max-ahead abc; check "bad --max-ahead exit 2" "[ $RC -eq 2 ]"
d --repo "$C" --max-age-days -1; check "bad --max-age-days exit 2" "[ $RC -eq 2 ]"
d --repo "$C" --base origin/nope; check "unresolvable --base exit 2" "[ $RC -eq 2 ]"
mkdir -p "$T/plain"; d --repo "$T/plain"; check "non-repo exit 2" "[ $RC -eq 2 ]"
d --repo "$T/missing"; check "missing dir exit 2" "[ $RC -eq 2 ]"
d --bogus; check "unknown flag exit 2" "[ $RC -eq 2 ]"
d --repo "$C" --base HEAD; check "custom --base ref honored" "[ $RC -eq 0 ] && grep -q 'clean at HEAD' <<<\"\$OUT\""

printf '\nSUMMARY: %d pass, %d fail\n' "$PASS" "$FAIL"
rm -rf "$T"
[ "$FAIL" -eq 0 ]
