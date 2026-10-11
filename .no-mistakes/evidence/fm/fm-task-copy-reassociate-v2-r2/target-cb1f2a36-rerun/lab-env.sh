# Lab environment for this evidence run (sourced by each driver step).
export LAB=/Users/charlesabrooker/tmp/fm-lab.FXbqdc W=/Users/charlesabrooker/tmp/fm-labw.tS1h2j EV=/Users/charlesabrooker/.no-mistakes/evidence/01M4J53Z7PV6VG61D4MCRBMMRQ/target-cb1f2a36-rerun WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4J53Z7PV6VG61D4MCRBMMRQ TD=/tmp/fml.BOhYxP
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.FXbqdc TMUX_TMPDIR=/tmp/fml.BOhYxP TREEHOUSE_ROOT=/Users/charlesabrooker/tmp/fm-labw.tS1h2j/pool FM_BACKEND=tmux DISABLE_AUTOUPDATER=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_SUPERVISION_ACTOR TMUX
labtmux() { tmux -L fm-lab "$@"; }
export TMUX='/private/tmp/fml.BOhYxP/tmux-501/fm-lab,15083,0'
S=/Users/charlesabrooker/tmp/fm-labw.tS1h2j/pool/.treehouse
# mkbrief <id> <ship|scout> : scaffold a "do nothing, reply idle" brief and a backlog item.
mkbrief() {
  local id=$1 kind=$2
  if [ "$kind" = scout ]; then bin/fm-brief.sh "$id" proj --scout >/dev/null; else bin/fm-brief.sh "$id" proj --mode local-only >/dev/null; fi || return 1
  python3 - "$LAB/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('{TASK}','Lab fixture for live validation of copy reassociation. Do nothing. Reply with the single word idle and wait.')
s=s.replace('{FIRSTMATE_SPEC}','Do not edit files, do not run commands, do not commit. Reply idle and wait for instructions.')
open(p,'w').write(s)
PY
  bin/fm-tasks-axi.sh add "$id" "Lab $kind $id for copy reassociation" --kind "$kind" >/dev/null
}
export S1=/Users/charlesabrooker/tmp/fm-labw.tS1h2j/pool/.treehouse/proj-6cf95d/1/proj
export SL3=/Users/charlesabrooker/tmp/fm-labw.tS1h2j/pool/.treehouse/proj-6cf95d/1/proj
