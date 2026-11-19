#!/usr/bin/env bash
# SP2: REAL fm-spawn.sh refusals with a diverged fm-pool-base, default and --base-branch spellings.
# Repo does NOT fetch: the origin default it refuses on must be one the repo did not hold before the spawn.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7RYMPD0Z8151S3VR02EHTSK
S=$(mktemp -d /tmp/pbdrive/sp2-case.XXXXXX)
export GIT_CONFIG_GLOBAL="$S/gitconfig" HOME="$S/home"
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
git config --global user.name Tester; git config --global user.email tester@example.invalid
git init -q -b main "$S/src"; echo a > "$S/src/f"; git -C "$S/src" add f; git -C "$S/src" commit -qm c1
git clone -q --bare "$S/src" "$S/origin.git"
git clone -q "$S/origin.git" "$S/repo"
printf 'base_branch = "fm-pool-base"\n' > "$S/repo/treehouse.toml"
git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm cfg
git -C "$S/repo" push -q origin main
C1=$(git -C "$S/repo" rev-parse origin/main)
echo "local-only" > "$S/repo/loc"; git -C "$S/repo" add loc; git -C "$S/repo" commit -qm local-ahead
git -C "$S/repo" checkout -q -b side "$C1"; echo s > "$S/repo/s"; git -C "$S/repo" add s; git -C "$S/repo" commit -qm side
SIDE=$(git -C "$S/repo" rev-parse HEAD)
git -C "$S/repo" checkout -q main; git -C "$S/repo" branch fm-pool-base "$SIDE"
# origin moves on AFTER the repo fetched: a feature branch and a new default commit the repo does not hold
git clone -q "$S/origin.git" "$S/pub"
git -C "$S/pub" checkout -q -b feature/hub; echo f > "$S/pub/feature-only.txt"; git -C "$S/pub" add feature-only.txt; git -C "$S/pub" commit -qm feature; git -C "$S/pub" push -q origin feature/hub
git -C "$S/pub" checkout -q main; echo n > "$S/pub/n"; git -C "$S/pub" add n; git -C "$S/pub" commit -qm c2; git -C "$S/pub" push -q origin main
C2=$(git --git-dir="$S/origin.git" rev-parse refs/heads/main)
echo "== repo before spawn: origin/main=$(git -C "$S/repo" rev-parse origin/main) (the repo has NOT fetched)  fm-pool-base=$SIDE  local main=$(git -C "$S/repo" rev-parse main)"
echo "== origin default the spawn must fetch: $C2 ; repo holds it before spawn? $(git -C "$S/repo" cat-file -e "$C2" 2>/dev/null && echo YES || echo NO)"
BEFORE=$(git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)')
export TREEHOUSE_ROOT="$S/pool"; mkdir -p "$S/pool"
run_case() { # <label> <id> [spawn args...]
  local label=$1 id=$2 OUT RC; shift 2
  local H="$S/$id-home"; mkdir -p "$H"
  mkdir -p "$FM_HOME/data/$id" "$FM_HOME/projects" "$FM_HOME/state" "$FM_HOME/config"
  printf 'codex\n' > "$FM_HOME/config/crew-harness"; touch "$FM_HOME/state/.last-watcher-beat"
  printf '# Task\n## Captain intent\nlive named-base refusal\n\n## Firstmate spec\nExercise the refusal.\n' > "$FM_HOME/data/$id/brief.md"
  if [ "$label" = named ]; then printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: feature/hub\n' >> "$FM_HOME/data/$id/brief.md"; fi
  OUT=$(cd "$S/repo" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$FM_HOME" TMUX_TMPDIR="$TMUX_TMPDIR" timeout 120 bash "$WT/bin/fm-spawn.sh" "$id" "$S/repo" "$@" </dev/null 2>&1); RC=$?
  echo "################ $label spawn ($*)"
  echo "$OUT" | tail -6
  echo "== exit $RC"
  echo "== origin default $C2 named in the refusal: $(echo "$OUT" | grep -q "$C2" && echo YES || echo NO)"
  echo "== refs byte-identical: $([ "$(git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)')" = "$BEFORE" ] && echo YES || echo NO)"
  echo "== pool entries: $(find "$S/pool" -mindepth 1 | wc -l | tr -d ' ')"
}
run_case default sp2-default --mode no-mistakes --yolo off
run_case named sp2-named --mode direct-PR --yolo off --base-branch feature/hub
echo "$S" > /tmp/pbdrive/sp2.case
