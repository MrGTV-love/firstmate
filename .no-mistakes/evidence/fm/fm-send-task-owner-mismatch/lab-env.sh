# Sourced by the live-validation driver. Lab paths only.
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.uy9qUf
export TMUX_TMPDIR=/tmp/fml.sesCDy
export TMUX="/private/tmp/fml.sesCDy/tmux-501/fm-lab,77679,0"
S=$FM_HOME/state; CHILD=$FM_HOME/data/mini-home
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M75QTTCF611NRYJ2BYGJEH79
BASE=/Users/charlesabrooker/tmp/fm-base.TBrCsI
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M75QTTCF611NRYJ2BYGJEH79
cd "$WT"
# Run the real product with gate vars removed; drop the watcher-down banner noise.
RUN() { local out rc; out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$@" 2>&1); rc=$?; printf '%s\n' "$out" | grep -v -E '^●|^fm-gate-refuse|^WARNING: watcher still down'; echo "exit=$rc"; }
pane() { tmux -L fm-lab capture-pane -p -t "lab:$1" | grep -v '^[[:space:]]*$' || echo '(pane empty)'; }
