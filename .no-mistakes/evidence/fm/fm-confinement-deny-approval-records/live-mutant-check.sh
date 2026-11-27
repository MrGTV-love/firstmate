#!/usr/bin/env bash
# Independent mutant check: head profile vs head profile minus one record-folder rule.
set -u
ROOT=$1
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-mutant.XXXXXX"); S=$(cd "$S" && pwd -P); trap 'rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@example.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@example.invalid OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp
f=$S/fx; mkdir -p $f/home/{state,data/task,config,projects} $f/nm/repos $f/user-home
git init -q -b main $f/home/projects/proj; mkdir -p $f/home/projects/proj/scripts/git_management; echo x > $f/home/projects/proj/scripts/git_management/worktree_lifecycle.py
git -C $f/home/projects/proj add -A; git -C $f/home/projects/proj commit -qm i; git -C $f/home/projects/proj worktree add -q -b fm/task $f/wt
printf 'worktree=%s\nproject=fmtest\n' $f/wt > $f/home/state/task.meta
HOME=$f/user-home NM_HOME=$f/nm python3 $ROOT/bin/fm-write-confinement.py --worktree $f/wt --project $f/home/projects/proj --home $f/home --config $f/home/config --projects $f/home/projects --data $f/home/data/task --state $f/home/state --task task --branch fm/task --harness omp --profile $f/head.sb
L=$f/home/projects/proj/.git/vernant-worktree-lifecycle
echo "head profile rules naming the record folders:"; grep -n "owned-paths-approvals\|captain-drop" $f/head.sb | sed "s#$S#<S>#g"
for rec in owned-paths-approvals captain-drop; do
  rm -rf $L/$rec; mkdir -p $L/$rec
  grep -v "subpath \"[^\"]*/$rec\"" $f/head.sb > $f/mut-$rec.sb
  for prof in head mut-$rec; do
    out=$(cd $f/wt && HOME=$f/user-home /usr/bin/sandbox-exec -f $f/$prof.sb /bin/sh -c "mkdir -p '$L/$rec/task' && echo forged > '$L/$rec/task/record.json' && echo WROTE" 2>&1 | sed "s#$S#<S>#g")
    printf '  %-28s %-24s -> %s\n' "$rec" "$prof.sb" "$out"
    rm -rf $L/$rec/task
  done
done
