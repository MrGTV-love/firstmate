#!/usr/bin/env bash
# Live replay of the train-4 / PR 303 incident against the real bin/fm-pr-merge.sh.
# Two disposable homes are real git clones of this Firstmate checkout (real
# Firstmate history, real remote URLs). Only the forge is a local stand-in
# (tests/fm-pr-merge-helpers.sh add_gh_mocks), so no real PR is ever merged.
# Usage: drive-cross-home-landing.sh <firstmate-worktree>
set -u
WT=$1
cd "$WT" || exit 2
# shellcheck source=/dev/null
. "$WT/tests/fm-pr-merge-helpers.sh"

step() { printf '\n===== %s =====\n' "$*"; }
show() { printf -- '--- %s (rc=%s)\n' "$1" "$2"; sed 's/^/    /' "$3"; }
verdict() { printf 'SCENARIO %s: %s\n' "$1" "$2"; }

case_dir=$(make_case incident)
main="$case_dir/main"          # Main home: the operator's primary Firstmate checkout
repair="$case_dir/fm-repair"   # repair home: separate clone, origin + upstream like fm-repair
git -c advice.detachedHead=false clone -q "$WT" "$main"
git -C "$main" remote set-url origin https://github.com/MrGTV-love/firstmate
git -c advice.detachedHead=false clone -q "$main" "$repair"
git -C "$repair" remote set-url origin https://github.com/MrGTV-love/firstmate
git -C "$repair" remote add upstream https://github.com/kunchenguid/firstmate
head=$(git -C "$main" rev-parse HEAD)
git -C "$main" update-ref refs/remotes/origin/main "$(git -C "$main" rev-parse HEAD~1)"
git -C "$main" rev-parse HEAD~1 > "$case_dir/github-base"
git -C "$main" update-ref refs/remotes/origin/fm/fixture "$head"
git -C "$repair" update-ref refs/remotes/origin/fm/fixture "$head"
add_gh_mocks "$case_dir" "$head"
for h in "$main" "$repair"; do
  mkdir -p "$h/data" "$h/state" "$h/config"
  fm_test_tasks_toml "$h/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$h/data/backlog.md"
done
printf 'maintainer github.com/MrGTV-love/firstmate\n' > "$main/config/firstmate-role"
echo "Main home:   $main  (config/firstmate-role: $(cat "$main/config/firstmate-role"))"
echo "Repair home: $repair  (no role file)"
git -C "$repair" remote -v | sed 's/^/  repair remote: /'

task() {  # home id worktree
  fm_write_meta "$1/state/$2.meta" "window=fm-$2" "worktree=$3" "project=$1" 'kind=ship' \
    'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
}
in_home() {  # home -- run_pr_merge args
  local h=$1; shift
  FM_TEST_CODE_ROOT="$h" FM_TEST_HOME="$h" FM_TEST_STATE="$h/state" run_pr_merge "$case_dir" "$@"
}
git -C "$main" worktree add -q --detach "$case_dir/train4-copy" "$head"
git -C "$repair" worktree add -q --detach "$case_dir/repair-copy" "$head"
task "$main" train4 "$case_dir/train4-copy"
task "$repair" fix303 "$case_dir/repair-copy"

cat > "$case_dir/hold-merge" <<SH
#!/usr/bin/env bash
: > "$case_dir/merge-entered"
if [ -e "$main/state/.firstmate-landing.lock" ]; then echo held; else echo free; fi > "$case_dir/lock-at-merge"
while [ ! -e "$case_dir/release-merge" ]; do sleep 0.1; done
SH
chmod +x "$case_dir/hold-merge"
trap ': > "$case_dir/release-merge"; fm_test_cleanup' EXIT

step "S1 Main's green train 4 is landing (held inside its forge merge call)"
FM_TEST_AWAY_MUTATE_AT_MERGE="$case_dir/hold-merge" in_home "$main" train4 https://github.com/MrGTV-love/firstmate/pull/300 \
  > "$case_dir/t4.out" 2> "$case_dir/t4.err" &
t4=$!
fm_test_wait_until --while-alive "$t4" --progress-file "$case_dir/gh.log" -- test -e "$case_dir/merge-entered" \
  || { echo "train 4 never reached the forge"; cat "$case_dir/t4.err"; exit 1; }
echo "train 4 is inside forge merge; Main landing lock at that moment: $(cat "$case_dir/lock-at-merge")"

step "S2 Repair home tries to merge PR 303 while train 4 is landing (the incident)"
rc=0; in_home "$repair" fix303 https://github.com/MrGTV-love/firstmate/pull/303 > "$case_dir/r.out" 2> "$case_dir/r.err" || rc=$?
show "repair-home fm-pr-merge.sh fix303 .../pull/303" "$rc" "$case_dir/r.err"
if [ "$rc" -eq 1 ] && ! grep -q 'pr merge 303' "$case_dir/gh.log" && [ ! -e "$repair/state/fix303.check.sh" ] \
  && grep -q 'grants maintainer github.com/mrgtv-love/firstmate' "$case_dir/r.err" && ! grep -qF "$case_dir/" "$case_dir/r.err" \
  && grep -q 'spawn a landing-record task' "$case_dir/r.err"; then
  # A separate repair clone cannot prove where Main lives (Main 2260 ruling), so it names the grant, not a path.
  verdict S2 PASS; else verdict S2 FAIL; fi

step "S3 Main takes PR 303 as a landing-record task; it waits for train 4, then lands in order"
task "$main" land303 "$main"
in_home "$main" land303 https://github.com/MrGTV-love/firstmate/pull/303 > "$case_dir/l303.out" 2> "$case_dir/l303.err" &
l303=$!
main_lock_waiter() {
  local f
  for f in "$main"/state/.lock-monitor.wait.*; do
    [ -f "$f" ] && grep -qF "$main/state/.firstmate-landing.lock" "$f" && return 0
  done
  return 1
}
waiting=no
fm_test_wait_until --while-alive "$l303" --progress-file "$main/state/guard-events.jsonl" \
  -- main_lock_waiter && waiting=yes
echo "PR 303 landing is waiting on Main's landing lock: $waiting"
echo "forge merge calls so far:"; grep '^pr merge ' "$case_dir/gh.log" | sed 's/^/    /'
: > "$case_dir/release-merge"
rc4=0; wait "$t4" || rc4=$?
rc3=0; wait "$l303" || rc3=$?
echo "train 4 rc=$rc4; PR 303 landing rc=$rc3"
echo "forge merge order:"; grep '^pr merge ' "$case_dir/gh.log" | sed 's/^/    /'
order=$(grep '^pr merge ' "$case_dir/gh.log" | awk '{print $3}' | tr '\n' ' ')
if [ "$waiting" = yes ] && [ "$rc4" -eq 0 ] && [ "$rc3" -eq 0 ] && [ "$order" = "300 303 " ]; then
  verdict S3 PASS; else verdict S3 "FAIL (order=$order)"; fi
grep -E '^pr=' "$main/state/train4.meta" "$main/state/land303.meta" | sed 's/^/    meta: /'
echo "lock after both outcomes: $([ -e "$main/state/.firstmate-landing.lock" ] && echo present || echo released)"

step "S4 A single ready PR with no train lands normally in Main"
task "$main" solo304 "$main"
rc=0; in_home "$main" solo304 https://github.com/MrGTV-love/firstmate/pull/304 > "$case_dir/s.out" 2> "$case_dir/s.err" || rc=$?
show "Main fm-pr-merge.sh solo304 .../pull/304" "$rc" "$case_dir/s.out"
if [ "$rc" -eq 0 ] && grep -q '^pr merge 304 ' "$case_dir/gh.log"; then verdict S4 PASS; else verdict S4 FAIL; cat "$case_dir/s.err"; fi

step "S5 The repair home still lands an unrelated project (Vernant) itself, with no landing lock"
fm_git_init_commit "$case_dir/vernant"
vh=$(git -C "$case_dir/vernant" rev-parse HEAD)
git -C "$case_dir/vernant" update-ref refs/remotes/origin/fm/fixture "$vh"
printf '%s\n' "$vh" > "$case_dir/github-head"
write_github_live_json "$case_dir" "$vh"
git -C "$case_dir/vernant" rev-parse HEAD > "$case_dir/github-base"
task "$repair" vern11 "$case_dir/vernant"
rm -f "$case_dir/merge-entered" "$case_dir/lock-at-merge"
cat > "$case_dir/peek-lock" <<SH
#!/usr/bin/env bash
for s in "$main/state" "$repair/state"; do [ -e "\$s/.firstmate-landing.lock" ] && { echo held; exit 0; }; done
echo free
SH
chmod +x "$case_dir/peek-lock"
cat > "$case_dir/vern-hook" <<SH
#!/usr/bin/env bash
"$case_dir/peek-lock" > "$case_dir/lock-at-merge"
SH
chmod +x "$case_dir/vern-hook"
rc=0; FM_TEST_AWAY_MUTATE_AT_MERGE="$case_dir/vern-hook" in_home "$repair" vern11 https://github.com/acme/vernant/pull/11 \
  > "$case_dir/v.out" 2> "$case_dir/v.err" || rc=$?
show "repair-home fm-pr-merge.sh vern11 acme/vernant/pull/11" "$rc" "$case_dir/v.out"
echo "landing lock during Vernant forge call: $(cat "$case_dir/lock-at-merge" 2>/dev/null)"
if [ "$rc" -eq 0 ] && grep -q '^pr merge 11 ' "$case_dir/gh.log" && [ "$(cat "$case_dir/lock-at-merge")" = free ]; then
  verdict S5 PASS; else verdict S5 FAIL; cat "$case_dir/v.err"; fi
# restore the Firstmate head for later scenarios
printf '%s\n' "$head" > "$case_dir/github-head"; write_github_live_json "$case_dir" "$head"
git -C "$main" rev-parse HEAD~1 > "$case_dir/github-base"

step "S6 Adversarial: a plain 'git clone' home with only origin cannot become a second landing owner"
plain="$case_dir/plain-clone"
git -c advice.detachedHead=false clone -q "$main" "$plain"
git -C "$plain" remote set-url origin https://github.com/MrGTV-love/firstmate
mkdir -p "$plain/data" "$plain/state" "$plain/config"; fm_test_tasks_toml "$plain/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$plain/data/backlog.md"
task "$plain" p305 "$plain"
rc=0; in_home "$plain" p305 https://github.com/MrGTV-love/firstmate/pull/305 > "$case_dir/p.out" 2> "$case_dir/p.err" || rc=$?
show "origin-only clone fm-pr-merge.sh p305 .../pull/305" "$rc" "$case_dir/p.err"
if [ "$rc" -eq 1 ] && ! grep -q '^pr merge 305 ' "$case_dir/gh.log" \
  && grep -q 'grants maintainer github.com/mrgtv-love/firstmate' "$case_dir/p.err" && ! grep -qF "$case_dir/" "$case_dir/p.err"; then
  verdict S6 PASS; else verdict S6 FAIL; fi

step "S7 Adversarial: one-task --upstream-consent in an ungranted primary home cannot land"
printf 'upstream_consent=github.com/mrgtv-love/firstmate\n' >> "$plain/state/p305.meta"
rc=0; in_home "$plain" p305 https://github.com/MrGTV-love/firstmate/pull/305 > "$case_dir/c.out" 2> "$case_dir/c.err" || rc=$?
show "consent task fm-pr-merge.sh p305" "$rc" "$case_dir/c.err"
if [ "$rc" -eq 1 ] && ! grep -q '^pr merge 305 ' "$case_dir/gh.log" && grep -q 'outside its Main home, the home whose config/firstmate-role grants maintainer github.com/mrgtv-love/firstmate;' "$case_dir/c.err"; then
  # Refused for the missing maintainer grant even though the caller is its own primary home with a matching consent.
  verdict S7 PASS; else verdict S7 FAIL; fi

step "S8 Adversarial: a shallow task copy with no matching code-root remote refuses with the unshallow remedy"
noremote="$case_dir/noremote-root"
git -c advice.detachedHead=false clone -q "$main" "$noremote"; git -C "$noremote" remote remove origin
mkdir -p "$noremote/data" "$noremote/state" "$noremote/config"; fm_test_tasks_toml "$noremote/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$noremote/data/backlog.md"
git -c advice.detachedHead=false clone -q --depth 1 "file://$main" "$case_dir/shallow-copy"
git -C "$case_dir/shallow-copy" update-ref refs/remotes/origin/fm/fixture "$head"
task "$noremote" sh306 "$case_dir/shallow-copy"
rc=0; in_home "$noremote" sh306 https://github.com/MrGTV-love/firstmate/pull/306 > "$case_dir/sh.out" 2> "$case_dir/sh.err" || rc=$?
show "shallow task fm-pr-merge.sh sh306" "$rc" "$case_dir/sh.err"
if [ "$rc" -eq 1 ] && ! grep -q '^pr merge 306 ' "$case_dir/gh.log" && grep -q 'fetch --unshallow' "$case_dir/sh.err"; then
  verdict S8 PASS; else verdict S8 FAIL; fi

step "Final forge merge log (one stand-in forge shared by every home)"
grep '^pr merge ' "$case_dir/gh.log" | sed 's/^/    /'
step "Guard events in Main and repair state"
cat "$main/state/guard-events.jsonl" "$repair/state/guard-events.jsonl" 2>/dev/null | grep merge-single-owner | sed 's/^/    /'
