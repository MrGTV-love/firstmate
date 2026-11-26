#!/usr/bin/env bash
# r3-s13-identity.sh: fresh lab; renewals that name a different copy or branch, and a worker actor, are refused; one shell.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
cd "$W"
eval "$(bin/fm-lab-home.sh env 2>"$EV/.s13-env.err")"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.s13-env.err"); rm -f "$EV/.s13-env.err"
echo "# lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
tmux() { case "${TMUX_TMPDIR:-}" in /tmp/fml.*) ;; *) echo "GUARD: bad TMUX_TMPDIR" >&2; return 99 ;; esac
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir missing; refusing tmux $*" >&2; return 99; }; command tmux "$@"; }
tmux new-session -d -s keep -c "$FM_HOME" bash
mkdir -p "$FM_HOME/state"; bin/fm-lock.sh
bash "$EV/lab-setup.sh" "$W" >/dev/null 2>&1 && echo "# fixture task rrt built"
. "$FM_HOME/projects/ids.env"
C=bin/fm-control.sh; META=$FM_HOME/state/rrt.meta
g() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid "${@:2}"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
renew() { # <worktree> <branch> <owner>
  mv "$MAN" "$FM_HOME/projects/manifests/moved-aside.$RANDOM.json"
  FM_TEST_PROVISION_CALLED=$SENT FM_TEST_SLOT_RECORD=$MAN python3 "$P/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$P" --worktree-path "$1" --owner-id "$3" --branch "$2" --base-sha "$M1" --owned-path src --owned-path lib --owned-path tools/x.sh >/dev/null
  : > "$SENT"; echo "renewed: worktree=$1 branch=$2 owner=$3 base=$M1"; }
run() { echo "\$ ${RUNPFX:-}fm-control.sh $*"; "$C" "$@" 2>&1 | grep -v '^fm-gate-refuse:' | grep -vE '^(added_|rule_c|scope_split)'; echo "rc=${PIPESTATUS[0]}"; }
write() { run rrt rerecord-slot --manifest-sha "$(sha "$MAN")" --note "Lab ruling: re-record after the slot renewal"; }
b=$(sha "$META")
echo "## A: the manifest names a replacement copy (wt2), not the copy the task record names"
g "$P" worktree add -q -b fm/rrt-replacement "$FM_HOME/projects/wt2" "$H"
renew "$FM_HOME/projects/wt2" fm/rrt rrt; write
echo "## B: the manifest names another branch"
renew "$WT" fm/other-branch rrt; write
echo "## C: a worker (FM_TASK_ID set) runs the write against a good renewal"
renew "$WT" fm/rrt rrt
RUNPFX='FM_TASK_ID=rrt ' FM_TASK_ID=rrt run rrt rerecord-slot --manifest-sha "$(sha "$MAN")" --note "Lab ruling: re-record after the slot renewal"
[ "$(sha "$META")" = "$b" ] && echo "task record sha unchanged across A-C: $b"
echo "# audit dir after A-C: $(ls -la "$FM_HOME/data/rrt/slot-rerecord" 2>&1)"
echo "## D: control: the same good renewal as main is accepted"
write; echo "task record sha $b -> $(sha "$META")"; grep ^slot_ "$META"
echo "# audit dir after D:"; ls -la "$FM_HOME/data/rrt/slot-rerecord"; ls -a "$FM_HOME/state" | grep -i rerecord || echo "no rerecord staging files in state/"
tmux kill-server; echo "# lab tmux server stopped"
echo "# teardown: $TEARDOWN"; bin/fm-lab-home.sh teardown "$FM_HOME"; echo "tmux teardown rc=$?"
chmod -R u+w "$FM_HOME" && rm -rf "$FM_HOME"; [ -e "$FM_HOME" ] && echo "lab still present" || echo "lab removed"
