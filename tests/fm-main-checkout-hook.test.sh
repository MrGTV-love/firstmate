#!/usr/bin/env bash
# Regression tests for bin/fm-main-checkout-hook.sh, the main-checkout-commit guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-main-checkout-hook)
STABLE_BIN="$TMP_ROOT/toolbelt/bin"
mkdir -p "$STABLE_BIN"
cp "$ROOT/bin/fm-main-checkout-hook.sh" "$ROOT/bin/fm-guard-event.sh" "$STABLE_BIN/"
HOOK="$STABLE_BIN/fm-main-checkout-hook.sh"

make_repo() {
  local name=$1
  local repo="$TMP_ROOT/$name"
  git init -q -b main "$repo"
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf 'initial\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "initial"
  printf '%s\n' "$repo"
}

REPO=$(make_repo primary)
EVENT_LOG="$TMP_ROOT/guard-events.jsonl"

# 1. Status before install reports absent and exits 1.
out=$(bash "$HOOK" status --repo "$REPO" 2>&1)
rc=$?
assert_equals "1" "$rc" "status before install exits 1"
assert_contains "$out" "pre-commit: absent" "pre-commit reported absent"
assert_contains "$out" "pre-merge-commit: absent" "pre-merge-commit reported absent"

# 2. Install creates managed hooks idempotently and status exits 0.
out=$(bash "$HOOK" install --repo "$REPO" 2>&1)
assert_equals "0" "$?" "install succeeds in clean repo"
assert_contains "$out" "installed pre-commit and pre-merge-commit hooks" "install confirmation printed"
out_idem=$(bash "$HOOK" install --repo "$REPO" 2>&1)
assert_equals "0" "$?" "re-running install is idempotent"
assert_contains "$out_idem" "installed pre-commit and pre-merge-commit hooks" "idempotent install confirmation printed"
out_st=$(bash "$HOOK" status --repo "$REPO" 2>&1)
assert_equals "0" "$?" "status after install exits 0"
assert_contains "$out_st" "pre-commit: installed" "pre-commit installed"
assert_contains "$out_st" "pre-merge-commit: installed" "pre-merge-commit installed"

# 3. Direct commit in primary checkout is refused by the real Git pre-commit hook.
head_before=$(git -C "$REPO" rev-parse HEAD)
printf 'blocked\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt
out=$(FM_GUARD_EVENT_LOG="$EVENT_LOG" git -C "$REPO" commit -m "should block" 2>&1)
rc=$?
head_after=$(git -C "$REPO" rev-parse HEAD)
assert_not_equals "0" "$rc" "real git commit in primary checkout fails"
assert_equals "$head_before" "$head_after" "primary checkout HEAD unchanged after refusal"
assert_contains "$out" "fm-main-checkout-hook: refused:" "refusal marker emitted"
assert_contains "$out" "treehouse get --base main" "runnable remedy emitted"
assert_contains "$(tail -n 1 "$EVENT_LOG")" '"decision":"deny"' "deny guard event recorded"

# 4. Linked worktree commit succeeds through the same installed hook.
WT="$TMP_ROOT/linked-slot"
git -C "$REPO" worktree add -q -b feat-slot "$WT" HEAD
printf 'allowed\n' > "$WT/slot.txt"
git -C "$WT" add slot.txt
wt_before=$(git -C "$WT" rev-parse HEAD)
out=$(FM_GUARD_EVENT_LOG="$EVENT_LOG" git -C "$WT" commit -m "linked worktree commit" 2>&1)
rc=$?
wt_after=$(git -C "$WT" rev-parse HEAD)
assert_equals "0" "$rc" "real git commit in linked worktree succeeds"
assert_not_equals "$wt_before" "$wt_after" "linked worktree HEAD advances"
assert_contains "$(tail -n 1 "$EVENT_LOG")" '"decision":"allow"' "allow guard event recorded for linked worktree"

# 5. Emergency override FM_ALLOW_MAIN_COMMIT=1 permits primary checkout commit and records override.
out=$(FM_ALLOW_MAIN_COMMIT=1 FM_GUARD_EVENT_LOG="$EVENT_LOG" git -C "$REPO" commit -m "emergency override" 2>&1)
rc=$?
head_override=$(git -C "$REPO" rev-parse HEAD)
assert_equals "0" "$rc" "FM_ALLOW_MAIN_COMMIT=1 allows primary checkout commit"
assert_not_equals "$head_before" "$head_override" "primary checkout HEAD advances with override"
last_ev=$(tail -n 1 "$EVENT_LOG")
assert_contains "$last_ev" '"decision":"allow"' "override records allow"
assert_contains "$last_ev" '"override":true' "override flag set in telemetry"

# 6. Pre-merge-commit hook refuses a real merge commit in the primary checkout and allows it in a linked worktree.
git -C "$REPO" checkout -q main
merge_before=$(git -C "$REPO" rev-parse HEAD)
out=$(FM_GUARD_EVENT_LOG="$EVENT_LOG" git -C "$REPO" merge --no-ff -m "blocked merge" feat-slot 2>&1)
rc=$?
assert_not_equals "0" "$rc" "non-ff merge in primary checkout is refused"
assert_equals "$merge_before" "$(git -C "$REPO" rev-parse HEAD)" "primary HEAD unchanged on refused merge"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

WT2="$TMP_ROOT/linked-merge-slot"
git -C "$REPO" worktree add -q -b merge-slot "$WT2" main
out=$(FM_GUARD_EVENT_LOG="$EVENT_LOG" git -C "$WT2" merge --no-ff -m "allowed merge" feat-slot 2>&1)
rc=$?
assert_equals "0" "$rc" "non-ff merge in linked worktree succeeds"

# 7. Check fails closed when git worktree identity cannot be resolved.
NON_GIT="$TMP_ROOT/not-a-repo"
mkdir -p "$NON_GIT"
out=$(FM_GUARD_EVENT_LOG="$EVENT_LOG" bash "$HOOK" check --repo "$NON_GIT" 2>&1)
rc=$?
assert_equals "1" "$rc" "check fails closed outside a git repo"
assert_contains "$out" "fm-main-checkout-hook: refused:" "fail-closed refusal message"
assert_contains "$(tail -n 1 "$EVENT_LOG")" '"source_ok":false' "source_ok=false recorded on unreadable git dir"

# 8. Remove removes managed hooks cleanly and is idempotent.
bash "$HOOK" remove --repo "$REPO" >/dev/null 2>&1
assert_equals "0" "$?" "remove succeeds for managed hooks"
assert_absent "$REPO/.git/hooks/pre-commit" "pre-commit removed"
assert_absent "$REPO/.git/hooks/pre-merge-commit" "pre-merge-commit removed"
bash "$HOOK" remove --repo "$REPO" >/dev/null 2>&1
assert_equals "0" "$?" "second remove is idempotent"

# 9. Unmanaged existing hooks are never overwritten by install or deleted by remove.
REPO_CUSTOM=$(make_repo custom)
mkdir -p "$REPO_CUSTOM/.git/hooks"
printf '#!/bin/sh\necho custom-hook\n' > "$REPO_CUSTOM/.git/hooks/pre-commit"
chmod 0755 "$REPO_CUSTOM/.git/hooks/pre-commit"

bash "$HOOK" install --repo "$REPO_CUSTOM" >/dev/null 2>&1
assert_equals "1" "$?" "install refuses to overwrite unmanaged pre-commit hook"
assert_contains "$(cat "$REPO_CUSTOM/.git/hooks/pre-commit")" "custom-hook" "unmanaged hook bytes preserved"
assert_absent "$REPO_CUSTOM/.git/hooks/pre-merge-commit" "install leaves pre-merge-commit untouched on preflight refusal"

bash "$HOOK" remove --repo "$REPO_CUSTOM" >/dev/null 2>&1
assert_equals "1" "$?" "remove refuses to delete unmanaged pre-commit hook"
assert_present "$REPO_CUSTOM/.git/hooks/pre-commit" "unmanaged hook still present after refused remove"

# 10. Symlinked hooks directory is refused on install and remove.
REPO_SYM=$(make_repo symlink)
rm -rf "$REPO_SYM/.git/hooks"
mkdir -p "$TMP_ROOT/external-hooks"
ln -s "$TMP_ROOT/external-hooks" "$REPO_SYM/.git/hooks"
bash "$HOOK" install --repo "$REPO_SYM" >/dev/null 2>&1
assert_equals "1" "$?" "install refuses symlinked hooks directory"
bash "$HOOK" remove --repo "$REPO_SYM" >/dev/null 2>&1
assert_equals "1" "$?" "remove refuses symlinked hooks directory"

# 11. A symlinked individual hook file is refused on install and remove, even when its target looks managed.
REPO_LINK=$(make_repo hook-file-link)
mkdir -p "$REPO_LINK/.git/hooks"
printf '#!/usr/bin/env bash\n# FIRSTMATE-MANAGED-MAIN-CHECKOUT-HOOK\nexit 0\n' > "$TMP_ROOT/linked-pre-commit"
chmod 0755 "$TMP_ROOT/linked-pre-commit"
ln -s "$TMP_ROOT/linked-pre-commit" "$REPO_LINK/.git/hooks/pre-commit"
out=$(bash "$HOOK" install --repo "$REPO_LINK" 2>&1)
assert_equals "1" "$?" "install refuses a symlinked pre-commit hook"
assert_contains "$out" "is symlink" "install names the symlinked hook"
assert_absent "$REPO_LINK/.git/hooks/pre-merge-commit" "install writes no hooks after symlink refusal"
out=$(bash "$HOOK" remove --repo "$REPO_LINK" 2>&1)
assert_equals "1" "$?" "remove refuses a symlinked pre-commit hook"
assert_present "$REPO_LINK/.git/hooks/pre-commit" "symlinked hook kept after refused remove"
assert_present "$TMP_ROOT/linked-pre-commit" "symlink target kept after refused remove"

# 12. core.hooksPath pointing elsewhere makes install and remove refuse and status report inactive.
REPO_HP=$(make_repo hooks-path)
git -C "$REPO_HP" config core.hooksPath .husky
out=$(bash "$HOOK" install --repo "$REPO_HP" 2>&1)
assert_equals "1" "$?" "install refuses when core.hooksPath redirects hooks"
assert_contains "$out" "core.hooksPath" "install refusal names core.hooksPath"
assert_absent "$REPO_HP/.git/hooks/pre-commit" "no inert hook written to .git/hooks"
assert_absent "$REPO_HP/.husky/pre-commit" "no hook written to the core.hooksPath directory"
out=$(bash "$HOOK" status --repo "$REPO_HP" 2>&1)
assert_equals "1" "$?" "status exits 1 when core.hooksPath redirects hooks"
assert_contains "$out" "inactive" "status reports hooks inactive"
out=$(bash "$HOOK" remove --repo "$REPO_HP" 2>&1)
assert_equals "1" "$?" "remove refuses when core.hooksPath redirects hooks"

# 12b. A core.hooksPath injected only through the environment does not redirect the repository's own hooks.
REPO_ENV_HP=$(make_repo env-hooks-path)
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$TMP_ROOT/injected-hooks" \
  bash "$HOOK" install --repo "$REPO_ENV_HP" >/dev/null 2>&1
assert_equals "0" "$?" "install ignores an environment-injected core.hooksPath"
printf 'blocked\n' >> "$REPO_ENV_HP/file.txt"
git -C "$REPO_ENV_HP" add file.txt
out=$(git -C "$REPO_ENV_HP" commit -m "should block" 2>&1)
assert_not_equals "0" "$?" "primary commit refused after install under injected core.hooksPath"
assert_contains "$out" "direct commit or merge in primary checkout" "installed guard runs from the repository hooks dir"

# 13. Install from a linked worktree of the toolbelt repository points the hook at the primary checkout's copy.
TB="$TMP_ROOT/toolbelt-repo"
git init -q -b main "$TB"
git -C "$TB" config user.name fixture
git -C "$TB" config user.email fixture@example.invalid
mkdir -p "$TB/bin"
cp "$ROOT/bin/fm-main-checkout-hook.sh" "$TB/bin/"
git -C "$TB" add bin
git -C "$TB" commit -q -m "toolbelt"
TB_WT="$TMP_ROOT/toolbelt-slot"
git -C "$TB" worktree add -q --detach "$TB_WT" HEAD
REPO_TB=$(make_repo toolbelt-target)
bash "$TB_WT/bin/fm-main-checkout-hook.sh" install --repo "$REPO_TB" >/dev/null 2>&1
assert_equals "0" "$?" "install from a linked toolbelt worktree succeeds"
git -C "$TB" worktree remove -f "$TB_WT"
printf 'blocked\n' >> "$REPO_TB/file.txt"
git -C "$REPO_TB" add file.txt
out=$(git -C "$REPO_TB" commit -m "should block" 2>&1)
assert_not_equals "0" "$?" "primary commit still refused after the installing worktree is removed"
assert_contains "$out" "direct commit or merge in primary checkout" "guard runs from the primary toolbelt copy"
TB_TARGET_WT="$TMP_ROOT/toolbelt-target-slot"
git -C "$REPO_TB" worktree add -q -b tb-slot "$TB_TARGET_WT" HEAD
printf 'allowed\n' > "$TB_TARGET_WT/slot.txt"
git -C "$TB_TARGET_WT" add slot.txt
git -C "$TB_TARGET_WT" commit -q -m "linked commit" >/dev/null 2>&1
assert_equals "0" "$?" "linked worktree commit still succeeds after the installing worktree is removed"

# 14. Install from a linked worktree whose primary is bare has no stable copy and is refused.
TB_BARE="$TMP_ROOT/toolbelt-bare.git"
git clone -q --bare "$TB" "$TB_BARE"
TB_BARE_WT="$TMP_ROOT/toolbelt-bare-slot"
git -C "$TB_BARE" worktree add -q --detach "$TB_BARE_WT" HEAD
REPO_BARE_TB=$(make_repo bare-toolbelt-target)
out=$(bash "$TB_BARE_WT/bin/fm-main-checkout-hook.sh" install --repo "$REPO_BARE_TB" 2>&1)
assert_equals "1" "$?" "install from a linked worktree with a bare primary is refused"
assert_contains "$out" "primary checkout has no executable copy" "refusal explains the missing primary copy"
assert_absent "$REPO_BARE_TB/.git/hooks/pre-commit" "no hook written after bare-primary refusal"

# 15. A hook whose guard script disappeared refuses with a remedy instead of a bare exec failure.
GONE_BIN="$TMP_ROOT/gone-toolbelt/bin"
mkdir -p "$GONE_BIN"
cp "$ROOT/bin/fm-main-checkout-hook.sh" "$GONE_BIN/"
REPO_GONE=$(make_repo gone-guard)
bash "$GONE_BIN/fm-main-checkout-hook.sh" install --repo "$REPO_GONE" >/dev/null 2>&1
assert_equals "0" "$?" "install from a standalone copy succeeds"
rm -f "$GONE_BIN/fm-main-checkout-hook.sh"
printf 'blocked\n' >> "$REPO_GONE/file.txt"
git -C "$REPO_GONE" add file.txt
gone_before=$(git -C "$REPO_GONE" rev-parse HEAD)
out=$(git -C "$REPO_GONE" commit -m "guard gone" 2>&1)
assert_not_equals "0" "$?" "commit refused when the guard script is missing"
assert_equals "$gone_before" "$(git -C "$REPO_GONE" rev-parse HEAD)" "HEAD unchanged when the guard script is missing"
assert_contains "$out" "is missing or not executable" "missing guard refusal names the problem"

git -C "$REPO" worktree remove -f "$WT"
git -C "$REPO" worktree remove -f "$WT2"
git -C "$REPO_TB" worktree remove -f "$TB_TARGET_WT"
git -C "$TB_BARE" worktree remove -f "$TB_BARE_WT"
pass "fm-main-checkout-hook"
