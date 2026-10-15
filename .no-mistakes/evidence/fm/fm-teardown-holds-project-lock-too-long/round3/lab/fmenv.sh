# usage: fmenv.sh <cmd...>  runs a firstmate command against the lab home
LAB=/Users/charlesabrooker/tmp/fm-lab.1pn2qL
exec env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="/Users/charlesabrooker/tmp/fm-lab.1pn2qL/tmux" TMUX="/Users/charlesabrooker/tmp/fm-lab.1pn2qL/tmux/tmux-501/fm-lab,1675,0" FM_HOME="/Users/charlesabrooker/tmp/fm-lab.1pn2qL" TREEHOUSE_ROOT="/Users/charlesabrooker/tmp/fm-lab.1pn2qL/work/pool" FM_BACKEND=tmux "$@"
