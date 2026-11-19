# Shared helpers for the live pool-base checks. Everything lives under $S (scratch), never the operator's home.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7RYMPD0Z8151S3VR02EHTSK
LIB=$WT/bin/fm-pool-base-lib.sh
unset TREEHOUSE_ROOT TREEHOUSE_UNIQUE_LEAF
for v in $(env | sed -n 's/^\(TREEHOUSE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
snap() { # <repo>: every ref, every worktree HEAD
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^HEAD /{print "HEAD " p " " substr($0,6)}'
}
newscenario() { # <name>: fresh origin with 1 commit, repo with local main 1 ahead, publisher for advancing origin
  S=$(mktemp -d /tmp/pbdrive/$1.XXXXXX); export S
  export HOME="$S/home" GIT_CONFIG_GLOBAL="$S/gitconfig"
  mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
  git config --global user.name Tester; git config --global user.email tester@example.invalid
  git init -q -b main "$S/src"; echo a > "$S/src/f"; git -C "$S/src" add f; git -C "$S/src" commit -qm c1
  git clone -q --bare "$S/src" "$S/origin.git"
  git clone -q "$S/origin.git" "$S/repo"
  echo b > "$S/repo/g"; git -C "$S/repo" add g; git -C "$S/repo" commit -qm local-ahead
  git clone -q "$S/origin.git" "$S/pub"
  echo "$S"
}
advance_origin() { # <S>: one more commit on origin main, pushed from publisher; repo not told
  echo "c$RANDOM" > "$1/pub/h$RANDOM"; git -C "$1/pub" add -A; git -C "$1/pub" commit -qm c-advance; git -C "$1/pub" push -q origin main
}
step() { # <repo> <tip-or-empty> [why]: the exact call bin/fm-spawn.sh makes under the lock
  ( . "$LIB"; fm_pool_base_advance "$1" "$2" "${3:-}" ) 2>&1; return $?
}
