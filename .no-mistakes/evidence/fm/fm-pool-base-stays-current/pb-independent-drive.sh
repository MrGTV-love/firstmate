#!/usr/bin/env bash
# Independent drive of fm-pool-base upkeep against scratch repos and the real treehouse binary.
set -u
WT=$1; S=$(mktemp -d /tmp/pbdrv/scn.XXXX)
g() { git -c user.name=T -c user.email=t@x.invalid "$@"; }
say() { printf '\n== %s\n' "$*"; }
refs() { git -C "$1" for-each-ref --format='%(refname) %(objectname)' | sort; }
. "$WT/bin/fm-pool-base-lib.sh"
mk() { # <dir>: origin.git + repo; origin has c1,c2; repo main = c2 + local L1 (ahead); fm-pool-base at c1
  local d=$1; mkdir -p "$d"; git init -q -b main "$d/seed"; echo 1>"$d/seed/a"; g -C "$d/seed" add a; g -C "$d/seed" commit -qm c1
  git clone -q --bare "$d/seed" "$d/origin.git"; git clone -q "file://$d/origin.git" "$d/repo"
  g -C "$d/repo" branch --no-track fm-pool-base main
  echo 2>"$d/seed/b"; g -C "$d/seed" add b; g -C "$d/seed" commit -qm c2; git -C "$d/seed" push -q "file://$d/origin.git" main
  git -C "$d/repo" fetch -q origin; git -C "$d/repo" merge -q --ff-only origin/main
  echo L>"$d/repo/l"; g -C "$d/repo" add l; g -C "$d/repo" commit -qm local-ahead
  printf 'base_branch = "fm-pool-base"\n' > "$d/repo/treehouse.toml"; echo treehouse.toml >> "$d/repo/.git/info/exclude"
}
export HOME=$S/userhome; mkdir -p $HOME
say "PB1/PB2 happy path: local main ahead of origin/main, fm-pool-base behind"
mk $S/a; R=$S/a/repo
O=$(git -C $R rev-parse origin/main); M=$(git -C $R rev-parse main); B=$(git -C $R rev-parse fm-pool-base)
echo "origin/main=$O local main=$M fm-pool-base(before)=$B"
git -C $R merge-base --is-ancestor $O $M && [ $O != $M ] && echo "fixture: local main strictly ahead of origin/main: yes"
say "control: real treehouse get BEFORE the step (shows the bug the change fixes)"
export TREEHOUSE_ROOT=$S/a/pool; for v in $(env | sed -n 's/^\(TREEHOUSE_[A-Z_]*\)=.*/\1/p'); do [ $v = TREEHOUSE_ROOT ] || unset $v; done
c0=$(cd $R && treehouse get --lease --lease-holder pbdrv-ctl 2>/dev/null); echo "copy=$c0 HEAD=$(git -C $c0 rev-parse HEAD) (stale fm-pool-base=$B, origin=$O)"
treehouse return "$c0" >/dev/null 2>&1 || true
before=$(refs $R)
fm_pool_base_advance $R $O; echo "rc=$?"
after=$(refs $R); echo "ref diff after step:"; diff <(echo "$before") <(echo "$after")
echo "fm-pool-base(after)=$(git -C $R rev-parse fm-pool-base) expected=$O"; echo "reflog:"; git -C $R reflog show --format='%H %gs' fm-pool-base
say "PB2 second step with nothing new"
fm_pool_base_advance $R $O; echo "rc=$?"; diff <(echo "$after") <(refs $R) && echo "no ref changed"
say "PB1 real treehouse get AFTER the step"
c1=$(cd $R && treehouse get --lease --lease-holder pbdrv-1 2>/dev/null); h=$(git -C $c1 rev-parse HEAD)
echo "copy=$c1 HEAD=$h"; [ "$h" = "$O" ] && echo "PASS copy HEAD == origin/main" || echo "FAIL copy HEAD != origin/main"
[ "$(git -C $R rev-parse main)" = $M ] && echo "local main untouched"
treehouse return "$c1" >/dev/null 2>&1 || true
say "PB3 adversarial cases (each must refuse, rc=1, refs byte-identical)"
chk() { local name=$1 R=$2 tip=$3; local b a rc; b=$(refs $R); fm_pool_base_advance $R "$tip" 2>$S/err; rc=$?; a=$(refs $R)
  printf '%-14s rc=%s refs-identical=%s msg=%s\n' "$name" $rc "$([ "$b" = "$a" ] && echo yes || echo NO)" "$(cat $S/err)"; }
mk $S/ah; R=$S/ah/repo; g -C $R branch -q -f fm-pool-base main; chk ahead $R $(git -C $R rev-parse origin/main)
mk $S/dv; R=$S/dv/repo; git -C $R checkout -q fm-pool-base; echo D>$R/d; g -C $R add d; g -C $R commit -qm div; git -C $R checkout -q main; chk diverged $R $(git -C $R rev-parse origin/main)
mk $S/ab; R=$S/ab/repo; git -C $R branch -q -D fm-pool-base; chk absent $R $(git -C $R rev-parse origin/main); git -C $R show-ref --verify -q refs/heads/fm-pool-base && echo "  absent: CREATED (bad)" || echo "  absent: not created"
mk $S/om; R=$S/om/repo; git -C $R remote remove origin; chk origin_missing $R ""
mk $S/ou; R=$S/ou/repo; chk origin_unread $R "" ; chk origin_notcommit $R deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
mk $S/co; R=$S/co/repo; git -C $R worktree add -q $S/co/wt fm-pool-base; chk checked_out $R $(git -C $R rev-parse origin/main)
mk $S/cu; R=$S/cu/repo; echo 'base_branch = [' > $R/treehouse.toml; chk config_bad $R $(git -C $R rev-parse origin/main)
say "PB4 home whose config does not name fm-pool-base: step does nothing"
mk $S/nn; R=$S/nn/repo; printf 'base_branch = "main"\n' > $R/treehouse.toml; chk not_named $R $(git -C $R rev-parse origin/main)
mk $S/nc; R=$S/nc/repo; rm $R/treehouse.toml; chk no_config $R $(git -C $R rev-parse origin/main)
say "cleanup"; rm -rf "$S"; echo removed $S
