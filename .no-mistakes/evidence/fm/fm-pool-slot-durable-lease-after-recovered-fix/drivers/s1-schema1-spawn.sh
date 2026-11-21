#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh + the REAL installed treehouse (schema 1) in a private pool.
# Slot A = recovered lease holding task "holder"'s nested current copy (unlanded commit). Slot B free.
# Records: spawn output, every treehouse argv, state/copy sha256 before and after.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7W0RMHJX3TG89Q7TVS1Y7HQ
cd "$WT"
. tests/fixtures.sh
REAL=$(command -v treehouse)
TMP_ROOT=$(fm_test_tmproot s1-live)
fm_git_identity fmtest fmtest@example.invalid
OLD='recovered: state file was corrupt or truncated; verify before reuse'
echo "provider: $REAL"
echo "provider capabilities: $(cd / && TREEHOUSE_NO_UPDATE_CHECK=1 "$REAL" capabilities --json </dev/null)"
for start in old-holder schema2-style-holder; do
  C="$TMP_ROOT/$start"; H="$C/home"; P="$C/project"
  F=$(make_spawn_fakebin "$C/fake"); fm_test_fake_sleep_noop "$F"
  fm_test_spawn_home "$H" codex; fm_test_spawn_brief "$H" "new-task"
  mkdir -p "$H/user-home" "$C/real-home" "$C/real-xdg"
  fm_git_init_commit "$P"; fm_git_add_origin "$P" "$C/origin.git"
  fm_test_rooted_treehouse "$F/treehouse.real" "$REAL"
  cat > "$F/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$C/treehouse-argv.log"
exec "$F/treehouse.real" "\$@"
SH
  chmod +x "$F/treehouse"
  export HOME="$C/real-home" XDG_CONFIG_HOME="$C/real-xdg" TREEHOUSE_NO_UPDATE_CHECK=1 \
    TREEHOUSE_ROOT="$C/real-root" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  a=$(cd "$P" && "$F/treehouse.real" get --root "$C/real-root" --no-fetch --lease --lease-holder holder </dev/null 2>/dev/null)
  b=$(cd "$P" && "$F/treehouse.real" get --root "$C/real-root" --no-fetch --lease --lease-holder spare </dev/null 2>/dev/null)
  a=$(cd "$a" && pwd -P); b=$(cd "$b" && pwd -P)
  (cd "$P" && "$F/treehouse.real" return "$b" --if-lease-holder spare </dev/null >/dev/null 2>&1)
  state=${a%/*/*}/treehouse-state.json
  holder=$OLD; [ "$start" = old-holder ] || holder='recovered: persistent quarantine; verify before reuse'
  jq --arg r "$holder" --arg a "$a" '.worktrees |= map(if .path == $a then (.lease_holder = $r | del(.lease_id)) else . end)' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  nested="$a/.claude/worktrees/nested-$start"; mkdir -p "$a/.claude/worktrees"
  git -C "$P" worktree add --quiet -b "nested-$start" "$nested"
  echo work > "$nested/owned.txt"; git -C "$nested" add owned.txt; git -C "$nested" commit -qm unlanded
  fm_write_meta "$H/state/holder.meta" "window=fmses:fm-holder" "worktree=$nested" "project=$P" "kind=ship"
  : > "$C/treehouse-argv.log"
  s0=$(shasum -a 256 "$state" | cut -c1-16); n0=$(git -C "$nested" rev-parse HEAD); st0=$(git -C "$nested" status --porcelain | wc -l)
  echo; echo "=== case: slot A on $start ($holder) ==="
  echo "slot A: $a (recovered, holds nested copy $nested)"; echo "slot B: $b (free)"
  echo "slot A entry before: $(jq -c --arg a "$a" '.worktrees[]|select(.path==$a)' "$state")"
  echo "--- fm-spawn.sh new-task $P --scout output:"
  rc=0; out=$(FM_FAKE_PANE_LOG="$C/pane-log" FM_FAKE_LAUNCH_LOG="$C/launch-log" fm_test_run_spawn "$H" "$P" "$F" new-task "$P" --scout) || rc=$?
  printf '%s\n' "$out"; echo "--- exit code: $rc"
  echo "--- treehouse argv during spawn:"; cat "$C/treehouse-argv.log"
  s1=$(shasum -a 256 "$state" | cut -c1-16); n1=$(git -C "$nested" rev-parse HEAD); st1=$(git -C "$nested" status --porcelain | wc -l)
  echo "state sha before=$s0 after=$s1 $([ "$s0" = "$s1" ] && echo IDENTICAL || echo CHANGED)"
  echo "nested HEAD before=$n0 after=$n1 $([ "$n0" = "$n1" ] && echo IDENTICAL || echo CHANGED); dirty lines $st0 -> $st1"
  echo "new-task meta published: $([ -e "$H/state/new-task.meta" ] && echo YES || echo no)"
  echo "slot claimed (.fm-slot-owner): A=$([ -e "${a%/*}/.fm-slot-owner" ] && echo YES || echo no) B=$([ -e "${b%/*}/.fm-slot-owner" ] && echo YES || echo no)"
done
