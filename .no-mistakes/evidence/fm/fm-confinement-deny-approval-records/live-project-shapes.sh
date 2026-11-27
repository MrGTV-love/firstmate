#!/usr/bin/env bash
# Head builder: --project spellings that real launches may pass must still build;
# plus the drop-record files inside a supervisor-made captain-drop/<task>/ folder.
set -u
ROOT=$1
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-shapes.XXXXXX"); S=$(cd "$S" && pwd -P); trap 'rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@example.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@example.invalid OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp
f=$S/fx; mkdir -p $f/home/{state,data/task,config,projects} $f/nm/repos $f/user-home
P=$f/home/projects/proj
git init -q -b main $P; mkdir -p $P/scripts/git_management; echo x > $P/scripts/git_management/worktree_lifecycle.py
git -C $P add -A; git -C $P commit -qm i; git -C $P worktree add -q -b fm/task $f/wt
git -C $P worktree add -q -b fm/linked-home $f/linked-project-home
ln -s $P $f/proj-link
printf 'worktree=%s\nproject=fmtest\n' $f/wt > $f/home/state/task.meta
b() { HOME=$f/user-home NM_HOME=$f/nm python3 $ROOT/bin/fm-write-confinement.py --worktree "$2" --project "$1" --home $f/home --config $f/home/config --projects $f/home/projects --data $f/home/data/task --state $f/home/state --task task --branch fm/task --harness claude --claude-session 11111111-2222-4333-8444-555555555555 --profile $f/p.sb 2>&1; }
show() { out=$(b "$2" "$3"); rc=$?; printf '  %-48s exit=%s %s\n' "$1" "$rc" "$(printf '%s' "$out" | sed "s#$S#<S>#g" | tr '\n' ' ' | cut -c1-200)"; }
upper=$(printf '%s' "$P" | sed 's#/home/projects/proj$#/HOME/PROJECTS/PROJ#')
echo "=== --project spellings (head builder must build) ==="
show "--project physical path"                    "$P" "$f/wt"
show "--project via symlink to project"           "$f/proj-link" "$f/wt"
show "--project with different letter case"       "$upper" "$f/wt"
show "--project as a linked worktree of same repo" "$f/linked-project-home" "$f/wt"
show "--project logical path with /./ and trailing /" "$f/home/./projects/proj/" "$f/wt"
show "--worktree via symlink"                     "$P" "$(ln -s $f/wt $f/wt-link; echo $f/wt-link)"
echo "=== --project naming a different repository (head builder must refuse) ==="
git init -q -b main $f/other; git -C $f/other commit -q --allow-empty -m o
show "--project is another repository"            "$f/other" "$f/wt"
echo "=== drop-record files inside a supervisor-made captain-drop/<task>/ folder ==="
b "$P" "$f/wt" >/dev/null; L=$P/.git/vernant-worktree-lifecycle
mkdir -p $L/captain-drop/task $L/owned-paths-approvals   # supervisor, unconfined
for name in record.json captain-words.txt; do
  out=$(cd $f/wt && HOME=$f/user-home /usr/bin/sandbox-exec -f $f/p.sb /bin/sh -c "echo forged > '$L/captain-drop/task/$name' && echo WROTE" 2>&1 | sed "s#$S#<S>#g")
  printf '  confined create captain-drop/task/%-18s -> %s ; file exists after: %s\n' "$name" "$out" "$([ -e $L/captain-drop/task/$name ] && echo yes || echo no)"
done
out=$( (echo s > $L/captain-drop/task/record.json && echo s > $L/captain-drop/task/captain-words.txt && echo WROTE) 2>&1 ); echo "  unconfined supervisor writes both files -> $out"
