#!/usr/bin/env bash
# SP1: the REAL bin/fm-spawn.sh, in a disposable lab home, refuses a diverged fm-pool-base before any copy is taken.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7RYMPD0Z8151S3VR02EHTSK
FM_HOME=$(sed -n 1p /tmp/pbdrive/sp1.lab)
TMUX_TMPDIR=$(sed -n 2p /tmp/pbdrive/sp1.lab)
unset TMUX
S=$(mktemp -d /tmp/pbdrive/sp1-case.XXXXXX)
export HOME="$S/home" GIT_CONFIG_GLOBAL="$S/gitconfig" TREEHOUSE_ROOT="$S/pool"
mkdir -p "$HOME" "$S/pool"; : > "$GIT_CONFIG_GLOBAL"
git config --global user.name Tester; git config --global user.email tester@example.invalid
git init -q -b main "$S/src"; echo a > "$S/src/f"; git -C "$S/src" add f; git -C "$S/src" commit -qm c1
git clone -q --bare "$S/src" "$S/origin.git"; git clone -q "$S/origin.git" "$S/repo"
printf 'base_branch = "fm-pool-base"\n' > "$S/repo/treehouse.toml"
git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm cfg
git -C "$S/repo" push -q origin main
git -C "$S/repo" checkout -q -b side origin/main; echo s > "$S/repo/s"; git -C "$S/repo" add s; git -C "$S/repo" commit -qm side
git -C "$S/repo" checkout -q main; git -C "$S/repo" branch fm-pool-base side
git clone -q "$S/origin.git" "$S/pub"; echo p > "$S/pub/p"; git -C "$S/pub" add p; git -C "$S/pub" commit -qm advance; git -C "$S/pub" push -q origin main
git -C "$S/repo" fetch -q origin
echo "== before: origin/main=$(git -C "$S/repo" rev-parse origin/main) main=$(git -C "$S/repo" rev-parse main) fm-pool-base=$(git -C "$S/repo" rev-parse fm-pool-base)"
BEFORE=$(git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)')
ID=sp1-diverged
mkdir -p "$FM_HOME/data/$ID" "$FM_HOME/projects" "$FM_HOME/state" "$FM_HOME/config"
printf 'codex\n' > "$FM_HOME/config/crew-harness"; touch "$FM_HOME/state/.last-watcher-beat"
printf '# Task\n## Captain intent\nlive diverged refusal\n\n## Firstmate spec\nExercise the refusal.\n' > "$FM_HOME/data/$ID/brief.md"
cd "$S/repo" || exit 1
OUT=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$FM_HOME" TMUX_TMPDIR="$TMUX_TMPDIR" timeout 120 bash "$WT/bin/fm-spawn.sh" "$ID" "$S/repo" --mode no-mistakes --yolo off </dev/null 2>&1)
RC=$?
echo "== real fm-spawn.sh output:"; echo "$OUT" | tail -15
echo "== spawn exit code: $RC"
echo "== refs byte-identical after spawn: $([ "$(git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)')" = "$BEFORE" ] && echo YES || echo NO)"
echo "== treehouse pool dir entries after refusal: $(find "$S/pool" -mindepth 1 | wc -l | tr -d ' ')"
echo "$S" > /tmp/pbdrive/sp1.case
