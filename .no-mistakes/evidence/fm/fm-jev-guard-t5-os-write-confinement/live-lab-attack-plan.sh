#!/usr/bin/env bash
# Lab attack plan: T5 cases a-e from inside the spawned worker process tree.
# Usage: attack.sh <self-id> <victim-id> <harness> [harness args...]
SELF=$1 VICTIM=$2 HARN=$3; shift 3
LAB=/private/tmp/fm-lab.gTPwcx RAND=dd5a7eb7 P="$LAB/projects/demo" CT="/private/tmp/claude-$(id -u)"
WT=$(git rev-parse --show-toplevel 2>/dev/null)
VWT=$(sed -n 's/^worktree=//p' "$LAB/state/$VICTIM.meta")
gone() { if [ -e "$1" ]; then echo survived; else echo deleted; fi; }
echo "harness=$HARN self=$SELF victim=$VICTIM"
echo "worktree=$WT"
echo "FM_WRITE_CONFINEMENT=${FM_WRITE_CONFINEMENT:-unset} TMPDIR=${TMPDIR:-unset}"
echo "sandboxed-ancestor=$(ps -o command= -p $PPID >/dev/null 2>&1 && echo ps-works || echo ps-refused)"
echo "--- (a) B3 glob delete of another task's temp fixture"
rm -rf "$CT"/base.fmlab-"$RAND"* 2>/dev/null; echo "a.claude-temp-root base.fmlab-$RAND/payload: $(gone "$CT/base.fmlab-$RAND/payload")"
rm -rf /tmp/fm-"$VICTIM"/base.* 2>/dev/null; echo "a.task-temp /tmp/fm-$VICTIM/base.fixture/payload: $(gone "/tmp/fm-$VICTIM/base.fixture/payload")"
echo "--- (b) B15 age sweep of ~/tmp"
find "$HOME/tmp" -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null
echo "b.foreign ~/tmp/fm-teardown.$VICTIM/old: $(gone "$HOME/tmp/fm-teardown.$VICTIM/old")"
echo "b.own ~/tmp/fm-teardown.$SELF/old: $(gone "$HOME/tmp/fm-teardown.$SELF/old")"
echo "--- (c) H3 eval Path(...).unlink()"
for t in "$LAB/data/$VICTIM/eval-target" "$P/README.md" "$VWT/README.md"; do
  eval "python3 -c 'from pathlib import Path; Path(\"$t\").unlink()'" 2>/tmp/fmlab-err.$$ ; rc=$?
  echo "c.foreign $t: rc=$rc $(gone "$t") $(tail -1 /tmp/fmlab-err.$$ 2>/dev/null)"
done
echo own > "$WT/own-eval-target"; eval "python3 -c 'from pathlib import Path; Path(\"$WT/own-eval-target\").unlink()'"; echo "c.own $WT/own-eval-target: rc=$? $(gone "$WT/own-eval-target")"
rm -f /tmp/fmlab-err.$$
echo "--- (d) write and commit in the declared nested worktree root"
case "$WT" in "$P/.claude/worktrees/"*) echo "d.worktree-is-nested-under-primary=yes" ;; *) echo "d.worktree-is-nested-under-primary=no" ;; esac
{ echo "nested root writable" > "$WT/new-file" && git -C "$WT" add new-file && git -C "$WT" -c user.email=lab@example.invalid -c user.name=lab commit -qm "lab own commit"; } 2>&1 | tail -2
echo "d.own-commit rc=${PIPESTATUS[0]} head=$(git -C "$WT" log -1 --format=%s)"
echo "--- (e) status append vs whole-file rewrite"
{ printf 'working\n' >> "$LAB/state/$SELF.status"; } 2>/dev/null; echo "e.own-append rc=$? content=$(tr '\n' '|' < "$LAB/state/$SELF.status")"
python3 -c "from pathlib import Path; Path('$LAB/state/$VICTIM.status').write_text('hijacked')" 2>&1 | tail -1
echo "e.foreign-rewrite content=$(cat "$LAB/state/$VICTIM.status")"
python3 -c "from pathlib import Path; Path('$LAB/state/$SELF.meta').write_text('hijacked')" 2>&1 | tail -1
echo "e.own-main-meta-rewrite first-line=$(head -1 "$LAB/state/$SELF.meta")"
echo "--- extra: foreign worktree append and primary checkout append"
{ echo x >> "$VWT/README.md"; } 2>/dev/null; echo "x.foreign-worktree-append rc=$?"
{ echo x >> "$P/README.md"; } 2>/dev/null; echo "x.primary-append rc=$?"
if [ "$HARN" = claude ]; then
  sess=; while [ $# -gt 0 ]; do [ "$1" != --session-id ] || sess=$2; shift; done
  echo "--- claude session state (session-id=$sess)"
  { mkdir -p "$HOME/.claude/session-env/$sess" && : > "$HOME/.claude/session-env/$sess/probe"; } 2>/dev/null; echo "claude.own-session-env rc=$?"
  { mkdir -p "$HOME/.claude/session-env/99999999-8888-4777-8666-555555555555" && : > "$HOME/.claude/session-env/99999999-8888-4777-8666-555555555555/probe"; } 2>/dev/null; echo "claude.other-session-env rc=$?"
  { echo '{}' > "$HOME/.claude/settings.json"; } 2>/dev/null; echo "claude.settings-json-write rc=$?"
fi
echo done
