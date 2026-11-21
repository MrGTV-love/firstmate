#!/usr/bin/env bash
# Live drive of bin/fm-spawn.sh in a marked lab home, on the lab's private tmux
# socket, against the REAL installed treehouse and a throwaway pool.
# MODE=unproven : the real treehouse answers its own capabilities (schema 1);
#                 slot A carries the old recovered-state holder.
# MODE=proven   : a shim answers capabilities with schema 2 and a protected
#                 holder; every other command runs the real treehouse. Slot A
#                 carries that protected holder.
# MODE=proven-old: the same shim, but slot A stays on the OLD recovered holder.
# Usage: drive-live-spawn.sh <unproven|proven|proven-old> <out-dir>
set -u
MODE=$1 OUT=$2
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7W0RMHJX3TG89Q7TVS1Y7HQ
REAL_TH=$HOME/.local/bin/treehouse
OLD='recovered: state file was corrupt or truncated; verify before reuse'
PROT='quarantined: persistent recovered lease'
mkdir -p "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }
: > "$OUT/transcript.txt"

unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
eval "$("$REPO/bin/fm-lab-home.sh" env 2>"$OUT/lab-env.stderr")"
log "lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"

SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-scr.XXXXXX")
SCR=$(cd "$SCR" && pwd -P)
mkdir -p "$SCR/home" "$SCR/xdg" "$SCR/bin"
export HOME=$SCR/home XDG_CONFIG_HOME=$SCR/xdg TREEHOUSE_ROOT=$SCR/root TREEHOUSE_NO_UPDATE_CHECK=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
cat > "$SCR/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$SCR/treehouse-calls.log"
if [ "$MODE" != unproven ] && [ "\${1:-}" = capabilities ]; then
  printf '%s\n' '{"schema_version":2,"version":"v3.1.7-lab-shim","persistent_recovered_leases":true,"recovered_quarantine_holder":"$PROT"}'
  exit 0
fi
exec "$REAL_TH" "\$@"
SH
chmod +x "$SCR/bin/treehouse"
export PATH="$SCR/bin:$PATH"

# Throwaway project with an origin.
git init -q -b main "$SCR/project" && printf 'hello\n' > "$SCR/project/README.md"
git -C "$SCR/project" add README.md && git -C "$SCR/project" commit -qm init
git init -q --bare -b main "$SCR/origin.git"
git -C "$SCR/project" remote add origin "$SCR/origin.git"
git -C "$SCR/project" push -q origin main && git -C "$SCR/project" remote set-head origin main

# Real pool: lease slot A and B with the real binary, then free B.
a=$(cd "$SCR/project" && "$REAL_TH" get --root "$SCR/root" --no-fetch --lease --lease-holder holder </dev/null 2>>"$OUT/setup.stderr") || { log "cannot lease A"; exit 1; }
b=$(cd "$SCR/project" && "$REAL_TH" get --root "$SCR/root" --no-fetch --lease --lease-holder spare </dev/null 2>>"$OUT/setup.stderr") || { log "cannot lease B"; exit 1; }
a=$(cd "$a" && pwd -P); b=$(cd "$b" && pwd -P)
(cd "$SCR/project" && "$REAL_TH" return "$b" --if-lease-holder spare </dev/null >/dev/null 2>>"$OUT/setup.stderr") || { log "cannot free B"; exit 1; }
pool=${a%/*/*}; state=$pool/treehouse-state.json
holder=$OLD; [ "$MODE" = proven ] && holder=$PROT
jq --arg r "$holder" --arg a "$a" '.worktrees |= map(if .path == $a then (.lease_holder = $r | del(.lease_id)) else . end)' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
log "slot A (recovered, holder '$holder') = $a"
log "slot B (free) = $b"

# Slot A holds another task's current, unlanded nested copy.
nested=$a/.claude/worktrees/nested-holder
mkdir -p "$a/.claude/worktrees"
git -C "$SCR/project" worktree add -q -b nested-holder "$nested"
printf 'unlanded work\n' > "$nested/owned.txt"; git -C "$nested" add owned.txt; git -C "$nested" commit -qm unlanded
printf '%s\n' "window=primary:fm-holder" "worktree=$nested" "project=$SCR/project" "kind=ship" > "$FM_HOME/state/holder.meta"
mkdir -p "$FM_HOME/data/new-live"
printf '# Task\n## Captain'"'"'s intent\nRead the README and report its first line.\n\n## Firstmate spec\nLive lab scout for the recovered-slot guard.\n' > "$FM_HOME/data/new-live/brief.md"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"

snap() {  # <label>
  { echo "== $1"; shasum -a 256 "$state" | cut -d' ' -f1
    jq -c --arg p "$a" '.worktrees[] | select(.path == $p)' "$state"
    git -C "$nested" rev-parse HEAD; git -C "$nested" status --porcelain --untracked-files=all
    git -C "$a" status --porcelain --untracked-files=all; ls -A "$a" ; } > "$OUT/snap-$1.txt"
}
snap before
cp "$state" "$OUT/state-before.json"
: > "$SCR/treehouse-calls.log"

harness_args=()
[ "$MODE" != unproven ] && harness_args=(--harness "sleep 900")
printf '%q ' "$REPO/bin/fm-spawn.sh" new-live "$SCR/project" --scout ${harness_args[@]+"${harness_args[@]}"} > "$SCR/cmd"
cat > "$SCR/run.sh" <<SH
#!/usr/bin/env bash
cd "$REPO"
$(cat "$SCR/cmd") > "$SCR/spawn.out" 2>&1
echo "rc=\$?" >> "$SCR/spawn.out"
touch "$SCR/spawn.done"
exec sleep 1200
SH
chmod +x "$SCR/run.sh"
log "spawn command: $(cat "$SCR/cmd")"
tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$REPO" -e FM_HOME="$FM_HOME" "bash $SCR/run.sh"
n=0; while [ ! -e "$SCR/spawn.done" ] && [ $n -lt 300 ]; do n=$((n+1)); sleep 1; done
log "---- fm-spawn.sh output ----"; cat "$SCR/spawn.out" | tee -a "$OUT/transcript.txt"
log "---- treehouse calls (cwd<TAB>argv) ----"; cat "$SCR/treehouse-calls.log" | tee -a "$OUT/transcript.txt"
sleep 3
snap after
cp "$state" "$OUT/state-after.json"
log "---- slot A snapshot diff (before vs after) ----"
diff "$OUT/snap-before.txt" "$OUT/snap-after.txt" | sed 's/^/  /' | tee -a "$OUT/transcript.txt" || true
log "---- new task record ----"; cat "$FM_HOME/state/new-live.meta" 2>/dev/null | tee -a "$OUT/transcript.txt" || log "(no new-live.meta)"
log "---- slot B claim file ${b%/*}/.fm-slot-owner ----"; if [ -e "${b%/*}/.fm-slot-owner" ]; then cat "${b%/*}/.fm-slot-owner" | tee -a "$OUT/transcript.txt"; else log "(no claim file in B)"; fi
log "---- slot A claim file ----"; if [ -e "${a%/*}/.fm-slot-owner" ]; then cat "${a%/*}/.fm-slot-owner" | tee -a "$OUT/transcript.txt"; else log "(no claim file in A)"; fi
log "---- tmux windows on fm-lab ----"; tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} #{pane_current_path} #{pane_current_command}' | tee -a "$OUT/transcript.txt"
for w in $(tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_index}'); do
  { echo "== pane $w"; tmux -L fm-lab capture-pane -p -t "$w"; } >> "$OUT/panes.txt" 2>&1
done
log "---- final state entries ----"; jq -c '.worktrees[] | {path, leased, lease_holder}' "$state" | tee -a "$OUT/transcript.txt"

# Teardown of everything this script made.
tmux -L fm-lab kill-server 2>/dev/null || true
sleep 1
td=$(sed -n "s/^fm-lab-home: teardown: //p" "$OUT/lab-env.stderr" | tail -1)
log "teardown: $td"
lab=${td##* }; eval "${td%% && *}" || log "lab teardown failed"; chmod -R u+w "$lab" 2>/dev/null; rm -rf "$lab"
git -C "$SCR/project" worktree remove --force "$nested" 2>/dev/null || true
chmod -R u+w "$SCR" 2>/dev/null; rm -rf "$SCR"
chmod -R u+w /tmp/fm-new-live /tmp/fm-new-live+* 2>/dev/null; rm -rf /tmp/fm-new-live /tmp/fm-new-live+*
log "scratch removed: $SCR"
