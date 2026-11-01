# Mint the lab home and a project with a real bare origin.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6ARTNJJE53FT9ETN002MAA0
EVID=/Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0
cd "$WT"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE bin/fm-lab-home.sh env > "$EVID/scripts/lab.env" 2> "$EVID/scripts/lab.teardown.txt"
. "$EVID/scripts/common.sh"
mkdir -p "$FM_HOME/pool" "$FM_HOME/nm" "$FM_HOME/projects"
git init -q --bare "$FM_HOME/origin.git"; git -C "$FM_HOME/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$FM_HOME/origin.git" "$FM_HOME/seed" 2>/dev/null
printf 'base\n' > "$FM_HOME/seed/README"; git -C "$FM_HOME/seed" add README; git -C "$FM_HOME/seed" commit -qm base; git -C "$FM_HOME/seed" push -q origin HEAD:main; rm -rf "$FM_HOME/seed"
git clone -q "$FM_HOME/origin.git" "$PROJ"; git -C "$PROJ" remote set-head origin main
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"
touch "$FM_HOME/state/.last-watcher-beat"
echo "FM_HOME=$FM_HOME"; echo "TMUX_TMPDIR=$TMUX_TMPDIR"
echo "pool-dir: $(cd "$PROJ" && treehouse pool-dir)"
tmux start-server 2>/dev/null; tmux new-session -d -s firstmate -n keep 'sleep 86400'; tmux display -p '#{socket_path}'
cat "$EVID/scripts/lab.teardown.txt"
