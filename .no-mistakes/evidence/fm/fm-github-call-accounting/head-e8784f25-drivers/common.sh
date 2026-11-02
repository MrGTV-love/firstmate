WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6BS0VSGYCH01N7E7CZ2GY8H
OWNER="$WT/bin/fm-github-accounting.py"
PY=$(python3 -c 'import sys; print(sys.executable)')
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M6BS0VSGYCH01N7E7CZ2GY8H
banner() { printf '### head %s host %s %s\n' "$(git -C "$WT" rev-parse HEAD)" "$(hostname)" "$(date -u +%FT%TZ)"; }
run() { printf '$ %s\n' "$*" | sed "s#$WT/##g; s#$PY#python3#g"; "$@"; printf 'exit=%s\n' "$?"; }
clean_env() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE "$@"; }
