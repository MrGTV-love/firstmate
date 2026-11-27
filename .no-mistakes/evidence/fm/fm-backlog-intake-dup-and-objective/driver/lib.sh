# Driver helpers. Every call is the real wrapper against the lab home.
W=<worktree>
LAB=~/tmp/fm-lab.dSaq3V
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
B=$LAB/data/backlog.md
say() { printf '\n### %s\n' "$*"; }
run() {  # show a command, its output and exit status
  { printf '$ '; printf '%q ' "$@"; printf '\n'; } | sed "s#$W#<worktree>#g; s#$LAB#<lab>#g"
  local out rc
  out=$(cd "$W" && "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed "s#$W#<worktree>#g; s#$LAB#<lab>#g"
  printf '[exit %s]\n' "$rc"
  return $rc
}
fm() { run bin/fm-tasks-axi.sh "$@"; }
