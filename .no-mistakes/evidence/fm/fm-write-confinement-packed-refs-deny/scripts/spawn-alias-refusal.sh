#!/usr/bin/env bash
# Drive real bin/fm-spawn.sh (fake tmux/treehouse, model-free fake harness) for
# a confined omp/claude worker while a hard link to <common>/packed-refs sits in
# the task worktree; then remove it and spawn the same id again.
# Usage: spawn-alias-refusal.sh <repo> <harness>
set -u
ROOT=$1 harness=$2
. "$ROOT/tests/fixtures.sh"
eval "$(sed -n '/^SPAWN=/,/^# A single stale first read/p' "$ROOT/tests/fm-spawn-worktree-settle.test.sh" | sed '$d')"
id=alias-$harness-z9
rec=$(make_settle_case "alias-$harness" "$id" 0); read_settle_record "$rec"
printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
export FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
probe="$HOME_DIR/data/$id/probe"
version='omp/18.12.4'; [ "$harness" = omp ] || version='2.1.310 (Claude Code)'
C="$PROJ_DIR/.git"
cat > "$FAKEBIN_DIR/$harness" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '%s\\n' '$version'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
{
  if { printf 'forged\\n' >> '$C/packed-refs'; } 2>/dev/null; then echo packed-refs=written; else echo packed-refs=refused; fi
  if ln '$C/packed-refs' '$WT_DIR/late-alias' 2>/dev/null; then echo new-link=created; else echo new-link=refused; fi
  echo "confinement=\$FM_WRITE_CONFINEMENT"
  echo "fetch-prune=\$(git config --get fetch.prune)"
} > '$probe'
SH
chmod +x "$FAKEBIN_DIR/$harness"
git -C "$PROJ_DIR" branch fm/other
git -C "$PROJ_DIR" pack-refs --all
git -C "$PROJ_DIR" config fetch.prune true
real=$(git -C "$PROJ_DIR" rev-parse fm/other)
ln "$C/packed-refs" "$HOME_DIR/data/$id/packed-refs-alias"
echo "== $harness: spawn with pre-existing hard link $HOME_DIR/data/$id/packed-refs-alias (links=$(stat -f %l "$C/packed-refs"))"
out=$(run_settle_spawn "$id"); rc=$?
printf '%s\n' "$out" | grep -E '^error:|^repair:' | sed "s|$TMP_ROOT|<tmp>|g"
echo "spawn exit=$rc"
echo "state/$id.meta present: $([ -e "$HOME_DIR/state/$id.meta" ] && echo yes || echo no)"
echo "launch delivered to pane: $([ -e "$FM_COMPAT_LAUNCH_LOG" ] && echo yes || echo no)"
echo "guard deny event: $(grep -F '"guard":"spawn-write-confinement"' "$HOME_DIR/state/guard-events.jsonl" 2>/dev/null | grep -cF '"decision":"deny"')"
rm "$HOME_DIR/data/$id/packed-refs-alias"
echo "== $harness: same id after removing the alias"
out=$(run_settle_spawn "$id"); rc=$?
echo "spawn exit=$rc"
grep -o 'write_confinement=[a-z0-9-]*' "$HOME_DIR/state/$id.meta"
[ -e "$FM_COMPAT_LAUNCH_LOG" ] && PATH="$FAKEBIN_DIR:$PATH" bash -c "$(cat "$FM_COMPAT_LAUNCH_LOG")" >/dev/null 2>&1
echo "-- confined harness probe:"; cat "$probe" 2>/dev/null || echo "(no probe)"
echo "primary fm/other: $([ "$(git -C "$PROJ_DIR" rev-parse fm/other)" = "$real" ] && echo real-sha || echo CHANGED); packed-refs links=$(stat -f %l "$C/packed-refs")"
