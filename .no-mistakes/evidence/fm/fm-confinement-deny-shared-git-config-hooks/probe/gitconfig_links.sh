#!/bin/bash
# Usage: gitconfig_links.sh REPO ; builds the head profile with a hard-linked and then a symlinked ~/.gitconfig
R=$1; T=$(mktemp -d /private/tmp/nmlinks-XXXXXX); export HOME=$T/uhome NM_HOME=$T/nm PATH=/usr/bin:/bin:/usr/sbin:/sbin
H=$T/fmhome; P=$H/projects/proj; W=$P/.claude/worktrees/fm-task
mkdir -p $HOME $NM_HOME/repos $H/config $H/data/task $H/state $T/dotfiles
git init -q -b main $P && git -C $P -c user.name=x -c user.email=x@e.invalid commit -q --allow-empty -m init && git -C $P worktree add -q -b fm/task $W
printf 'window=fmtest:fm-task\nworktree=%s\nproject=fmtest\n' $W > $H/state/task.meta
build() { python3 $R/bin/fm-write-confinement.py --worktree $W --home $H --config $H/config --projects $H/projects --data $H/data/task --state $H/state --task task --branch fm/task --harness claude --claude-session 11111111-2222-4333-8444-555555555555 --profile $T/p.sb; }
printf '[user]\n\tname = x\n' > $T/dotfiles/gitconfig
ln $T/dotfiles/gitconfig $HOME/.gitconfig
echo "== hard-linked ~/.gitconfig (2 links):"; build; echo "build exit=$?"
rm $HOME/.gitconfig; ln -s $T/dotfiles/gitconfig $HOME/.gitconfig
echo "== symlinked ~/.gitconfig -> dotfiles/gitconfig:"; build; echo "build exit=$?"
for f in $HOME/.gitconfig $T/dotfiles/gitconfig; do
  /usr/bin/sandbox-exec -f $T/p.sb /bin/sh -c "printf '[core]\n\tfsmonitor = /tmp/x\n' >> $f" 2>&1 && echo "confined append via $f: SUCCEEDED" || echo "confined append via $f: refused"
done
/usr/bin/sandbox-exec -f $T/p.sb /bin/sh -c "rm $HOME/.gitconfig" 2>&1 && echo "confined unlink of the link: SUCCEEDED" || echo "confined unlink of the link: refused"
/usr/bin/sandbox-exec -f $T/p.sb /bin/sh -c "printf x > $T/dotfiles/new-allowed" && echo "control: confined write of an unrelated file in dotfiles: succeeded"
printf '\n#unconfined control\n' >> $T/dotfiles/gitconfig && echo "unconfined control append: succeeded"
rm -rf $T
