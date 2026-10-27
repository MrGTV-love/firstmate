#!/usr/bin/env bash
# Live: real fm-pr-ready-reconcile.sh pass (real read-only gh reads through a
# logging pass-through wrapper) in a disposable lab home. Covers the status
# grammar after the redundant event filter was removed, strict `PR <url>`
# reading, newest-declaration-wins, unreadable record/log skips, and the
# fm-spawn.sh capacity holder list before and after one pass.
# Usage: drive-live-grammar.sh <worktree>
set -u
cd "$1"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
trap 'chmod -R u+rwx "$LAB" 2>/dev/null; TMUX_TMPDIR="$TMUXD" tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
REAL_GH=$(command -v gh); mkdir -p "$LAB/fakebin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh.calls"\nexec "%s" "$@"\n' "$LAB" "$REAL_GH" > "$LAB/fakebin/gh"; chmod +x "$LAB/fakebin/gh"; : > "$LAB/gh.calls"
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$TMUXD" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" "$@"
}
P="$LAB/projects/firstmate"; git init -q "$P"
git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$P" remote add origin https://github.com/MrGTV-love/firstmate.git
S="$LAB/state"; G=https://github.com/MrGTV-love/firstmate/pull
meta() { printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/%s\n' "$P" "$P" "$1" > "$S/$1.meta"; chmod 600 "$S/$1.meta"; }
for id in notes-after unrelated-url newest-wins bad-log; do meta "$id"; done
printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/bad-meta\n' "$P" "$P" > "$LAB/real-bad.meta"; ln -s "$LAB/real-bad.meta" "$S/bad-meta.meta"
printf 'done: PR %s/265 checks green\n' "$G" > "$S/bad-meta.status"
printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/bad-meta\n' "$P" "$P" > /dev/null
{ printf 'working: x\ndone [at=%s]: PR %s/265 checks green\n' "$(date +%s)" "$G"
  printf 'note [at=%s]: model-matrix fallback served claude after codex failed\n' "$(date +%s)"
  printf 'note: captain asked a follow-up; nothing to do\n'; } > "$S/notes-after.status"
printf 'done: follows up %s/180 - PR %s/266 checks green\n' "$G" "$G" > "$S/unrelated-url.status"
printf 'done: PR %s/259 checks green\nworking: one more fix\ndone: PR %s/274 checks green\n' "$G" "$G" > "$S/newest-wins.status"
mkdir "$S/bad-log.status"
printf 'firstmate 4\n' > "$LAB/config/project-capacity"
for f in "$S"/*.status; do printf '%s ' "${f##*/}"; done; echo
echo "== status logs:"; for id in notes-after unrelated-url newest-wins bad-meta; do echo "-- $id.status"; cat "$S/$id.status"; done
echo "-- bad-log.status is a directory; bad-meta.meta is a symlink"
echo
h0=$(cat "$S"/notes-after.status "$S"/newest-wins.status "$S"/unrelated-url.status | shasum -a 256 | cut -c1-16)
echo "== BEFORE: fm-spawn.sh admission for a new firstmate ship (capacity 4)"
labenv bin/fm-spawn.sh new-item "$P" --mode no-mistakes --yolo off 2>&1 | grep -v '^●' | sed 's|'"$LAB"'|<lab>|g'
echo
echo "== ONE PASS of bin/fm-pr-ready-reconcile.sh (no supervisor command)"
out=$(labenv bash bin/fm-pr-ready-reconcile.sh 2>&1); echo "exit=$?"
printf '%s\n' "$out" | sed 's|'"$LAB"'|<lab>|g'
echo
echo "== registered records:"
for id in notes-after unrelated-url newest-wins bad-log; do printf '%-14s %s\n' "$id" "$(grep -E '^pr(_head)?=' "$S/$id.meta" | tr '\n' ' ' || true)"; done
printf '%-14s %s\n' bad-meta "$(grep -E '^pr=' "$LAB/real-bad.meta" || echo '(none)')"
echo "== gh forge reads by PR number:"; grep -oE 'pull/[0-9]+' "$LAB/gh.calls" | sort | uniq -c
echo "== status logs before: $h0 after:"; cat "$S/notes-after.status" "$S/newest-wins.status" "$S/unrelated-url.status" | shasum -a 256 | cut -c1-16
echo
echo "== AFTER: fm-spawn.sh admission for the same new ship"
labenv bin/fm-spawn.sh new-item "$P" --mode no-mistakes --yolo off 2>&1 | grep -v '^●' | sed 's|'"$LAB"'|<lab>|g'
