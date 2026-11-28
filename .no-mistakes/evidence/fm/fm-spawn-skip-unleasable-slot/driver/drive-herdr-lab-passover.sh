#!/usr/bin/env bash
# Live Herdr pass-over driver: the REAL bin/fm-spawn.sh on a REAL Herdr server in a named
# non-default fm-lab-* session (bin/fm-herdr-lab.sh), with a REAL Treehouse pool on a scratch
# TREEHOUSE_ROOT. Copy A carries another holder's lease (made by the real treehouse binary).
# Only `treehouse get` typed into the pane is a stand-in: it enters copy A every time (as a pool
# hands out a copy whose lease was kept), so the spawn passes A over, types get again, sees the
# pane still in A, and aborts. Every other treehouse call runs the real binary on the scratch pool.
# Usage: drive-herdr-lab-passover.sh <worktree> <log>
set -u
WT=$1 LOG=$2
REAL_TH=$(command -v treehouse) || { echo "treehouse not on PATH" >&2; exit 2; }
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-passover.XXXXXX"); S=$(cd -P "$S" && pwd -P)
LAB="$WT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name passover) || { echo "no lab name" >&2; exit 2; }
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$S/lab-home.stderr")"
cleanup() {
  "$LAB" teardown "$SESSION" >>"$LOG" 2>&1 || echo "lab teardown reported a problem" >>"$LOG"
  "$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 || true
  find "$S" "$FM_HOME" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$S" "$FM_HOME"
}
trap cleanup EXIT
say() { printf '\n===== %s =====\n' "$*" >>"$LOG"; }

# Scratch project with an origin.
P="$S/proj"; mkdir -p "$P"
git -C "$P" init -q -b main
printf '# scratch\n' >"$P/README.md"
git -C "$P" add README.md
git -C "$P" -c user.name=T -c user.email=t@example.invalid commit -qm initial
git clone -q --bare "$P" "$P.origin.git"
git -C "$P" remote add origin "file://$P.origin.git"
git -C "$P" fetch -q origin

export TREEHOUSE_ROOT="$S/th-root"
A=$(cd "$P" && "$REAL_TH" get --lease --lease-holder other-holder </dev/null 2>/dev/null | tail -n 1)
A=$(CDPATH='' cd -- "$A" && pwd -P) || { echo "no pool slot" >>"$LOG"; exit 1; }
STATE="$(dirname "$(dirname "$A")")/treehouse-state.json"
cp "$STATE" "$S/state.before"

# Stand-in: `get` enters copy A in a subshell; everything else is the real binary.
mkdir -p "$S/bin"
cat >"$S/bin/treehouse" <<SH
#!/usr/bin/env bash
export TREEHOUSE_ROOT='$TREEHOUSE_ROOT'
if [ "\${1:-}" = get ] && [ "\$#" = 1 ]; then
  printf '%s\n' "\$\$ get" >>'$S/get.log'
  cd '$A' && exec /bin/bash --noprofile --norc -i
fi
exec '$REAL_TH' "\$@"
SH
chmod +x "$S/bin/treehouse"
export PATH="$S/bin:$PATH"
# v2: pane shells must not reorder PATH from the user's rc files (try 1 showed the real get ran):
# give zsh an empty scratch startup folder. /etc/zprofile path_helper keeps $S/bin ahead of ~/.local/bin.
mkdir -p "$S/zdot"; : >"$S/zdot/.zshrc"; : >"$S/zdot/.zshenv"; : >"$S/zdot/.zprofile"; export ZDOTDIR="$S/zdot"

"$LAB" provision "$SESSION" >>"$LOG" 2>&1 || { echo "provision failed" >>"$LOG"; exit 1; }
say "lab session: $SESSION (non-default, provisioned with bin/fm-herdr-lab.sh)"

ID=hlpass1
mkdir -p "$FM_HOME/data/$ID" "$FM_HOME/projects"
printf '# Task\n## Captain'"'"'s intent\nLive Herdr pass-over check.\n\n## Firstmate spec\nAbort after a pass-over.\n' >"$FM_HOME/data/$ID/brief.md"

say "pool state BEFORE (path, leased, lease_holder)"
jq -r '.worktrees[] | [.path, (.leased|tostring), (.lease_holder // "-")] | @tsv' "$STATE" >>"$LOG"

say "\$ HERDR_SESSION=$SESSION bin/fm-spawn.sh $ID <proj> \"sh -c 'echo ok'\" --backend herdr --mode no-mistakes --yolo off"
LAUNCH_ENV=()
if [ "${PROJECTED:-0}" = 1 ]; then
  # v3: spawn as if Firstmate ran in a lab Herdr pane (the identity Herdr injects), so the spawn projects.
  ws=$("$LAB" run "$SESSION" workspace create --cwd "$S" --label launcher --no-focus 2>/dev/null)
  LPANE=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
  LSOCK=$("$LAB" run "$SESSION" session list --json 2>/dev/null | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .socket_path')
  say "launcher identity: HERDR_PANE_ID=$LPANE HERDR_SOCKET_PATH=$LSOCK"
  LAUNCH_ENV=(HERDR_ENV=1 HERDR_PANE_ID="$LPANE" HERDR_SOCKET_PATH="$LSOCK")
fi
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} \
  HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$WT" \
  FM_TEST_TICK_SECONDS=60 BASH_ENV="$WT/tests/skip-clock.sh" \
  "$WT/bin/fm-spawn.sh" "$ID" "$P" "sh -c 'echo ok'" --backend herdr --mode no-mistakes --yolo off >>"$LOG" 2>&1
echo "exit status: $?" >>"$LOG"

say "stand-in get calls typed into the real Herdr pane"; cat "$S/get.log" >>"$LOG" 2>&1
say "data/$ID/acquisition-pane.tsv"; cat "$FM_HOME/data/$ID/acquisition-pane.tsv" >>"$LOG" 2>&1
say "data/$ID/skipped-copies.tsv"; cat "$FM_HOME/data/$ID/skipped-copies.tsv" >>"$LOG" 2>&1
say "state/$ID.meta present?"; ls "$FM_HOME/state/$ID.meta" >>"$LOG" 2>&1
say "Herdr panes in the lab session after the run (pane_id, cwd as Herdr lists it; Herdr may list the start cwd, the spawn reads the live path)"
"$LAB" run "$SESSION" pane list >>"$S/panes.json" 2>&1
jq -r '.result.panes[]? | [.pane_id, (.cwd // .current_dir // "-")] | @tsv' "$S/panes.json" >>"$LOG" 2>&1 || cat "$S/panes.json" >>"$LOG"
say "pool state AFTER"; jq -r '.worktrees[] | [.path, (.leased|tostring), (.lease_holder // "-")] | @tsv' "$STATE" >>"$LOG"
if cmp -s "$STATE" "$S/state.before"; then echo "pool state file: byte-identical" >>"$LOG"; else echo "pool state file: CHANGED" >>"$LOG"; fi
