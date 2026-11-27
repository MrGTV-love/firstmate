#!/usr/bin/env bash
# Manual live drive of bin/fm-review-record.py verify: new (target) vs old (base) code.
set -u
ROOT=$1; W=$2
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
URL=https://github.com/example/repo/pull/9
NEW=$ROOT/bin/fm-review-record.py
mkdir -p $W/oldbin; git -C $ROOT archive c89e6a5977f60f3aca41c983c5410dabd3cf14f2 bin | tar -x -C $W/oldbin
OLD=$W/oldbin/bin/fm-review-record.py
NM=$W/nm; mkdir -p $NM
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' $NM/state.sqlite
g() { local d=$1; shift; git -C "$d/wt" -c user.name=T -c user.email=t@example.invalid "$@"; }
mk() { # name -> case dir with pr (R) and trunk
  local c=$W/$1; mkdir -p $c/home/state $c/wt
  git -C $c/wt init -q -b main; echo '# x' > $c/wt/README.md; g $c add README.md; g $c commit -qm initial
  BASE=$(g $c rev-parse HEAD)
  printf 'worktree=%s\nkind=ship\nmodel=gpt-5.1\nbranch=fm/fixture\nmode=direct-PR\n' $c/wt > $c/home/state/task-x1.meta
  g $c checkout -q -b pr; printf 'one\ntwo\nthree\n' > $c/wt/app.txt; g $c add app.txt; g $c commit -qm 'ship change'
  g $c checkout -q -b trunk $BASE; echo other > $c/wt/other.txt; g $c add other.txt; g $c commit -qm 'base moves'
  echo $c
}
rec() { # case head reader
  printf 'VERDICT: PASS head=%s\nreader evidence\n' $2 > $1/report.md
  FM_HOME=$1/home $NEW review --pr $URL --head $2 --verdict PASS --reader-model $3 --author-groups '{"ship":["gpt-5.1"]}' \
    --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report $1/report.md >/dev/null || echo "RECORD FAILED"
}
ver() { # script case head base [env...]
  local s=$1 c=$2 h=$3 b=$4; shift 4
  env "$@" NM_HOME=$NM FM_HOME=$c/home $s verify --pr $URL --head $h --task task-x1 --base $b --json 2>&1; echo "  exit=$?"
}
both() { # label case head base [env...]
  local l=$1; shift
  echo "### $l"
  echo "  NEW: $(ver $NEW "$@" | tr '\n' ' ')"
  echo "  OLD: $(ver $OLD "$@" | tr '\n' ' ')"
}
merge_up() { g $1 checkout -q pr; g $1 merge -q --no-edit trunk; g $1 rev-parse HEAD; }

c=$(mk clean); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet; L=$(merge_up $c)
both "1 clean merge of base into reviewed head (expect carry)" $c $L $T
echo "  NEW text: $(NM_HOME=$NM FM_HOME=$c/home $NEW verify --pr $URL --head $L --task task-x1 --base $T | tr '\n' '|')"

c=$(mk rebase); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet
g $c checkout -q -b rb $R; g $c rebase -q trunk; L=$(g $c rev-parse HEAD)
both "2 clean rebase (expect carry)" $c $L $T

c=$(mk unread); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet
g $c checkout -q pr; g $c merge -q --no-commit --no-ff trunk >/dev/null 2>&1; echo unread >> $c/wt/app.txt; g $c add app.txt; g $c commit -qm "Merge trunk"; L=$(g $c rev-parse HEAD)
both "3 merge hiding one unread line (expect refuse)" $c $L $T

c=$(mk rewrite); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet
g $c checkout -q pr; g $c commit -q --amend -m 'reworded'; L=$(merge_up $c)
both "4 same-tree rewrite of R, unread, then base merged (expect carry from R)" $c $L $T

for order in rewrite-last original-last; do
  c=$(mk rw-$order); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet
  g $c checkout -q pr; g $c commit -q --amend -m 'reworded'; RW=$(g $c rev-parse HEAD); rec $c $RW sonnet
  [ $order = original-last ] && rec $c $R gemini-3-pro
  L=$(merge_up $c)
  both "5-$order rewrite itself read, then base merged (expect refuse)" $c $L $T
done

c=$(mk offbase); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet
g $c checkout -q -b side main; echo side > $c/wt/side.txt; g $c add side.txt; g $c commit -qm side
g $c checkout -q pr; g $c merge -q --no-edit side; L=$(g $c rev-parse HEAD)
both "6 clean merge of a branch not on the base (expect refuse)" $c $L $T

c=$(mk globaldrv); R=$(g $c rev-parse pr); rec $c $R sonnet
g $c checkout -q trunk; echo 'base version' > $c/wt/app.txt; g $c add app.txt; g $c commit -qm 'base edits same file'; T=$(g $c rev-parse HEAD)
F=$c/fakehome; mkdir -p $F; echo 'app.txt merge=forge' > $F/attrs
git config --file $F/.gitconfig merge.forge.driver "printf 'unread driver bytes\\n' > %A"; git config --file $F/.gitconfig core.attributesFile $F/attrs
g $c checkout -q pr; env -u GIT_CONFIG_GLOBAL HOME=$F git -C $c/wt -c user.name=T -c user.email=t@example.invalid merge -q --no-edit trunk >/dev/null 2>&1 && echo "  (fixture: global driver resolved the conflict, app.txt=$(cat $c/wt/app.txt))"
L=$(g $c rev-parse HEAD)
both "7 conflict resolved by a global ~/.gitconfig merge driver (expect refuse)" $c $L $T -u GIT_CONFIG_GLOBAL HOME=$F

c=$(mk scratchplace); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet; L=$(merge_up $c)
mkdir -p $W/shim $W/sharedtmp; RG=$(command -v git)
printf '#!/usr/bin/env bash\n[ "$1" != init ] || printf "%%s\\n" "${@: -1}" >> %s/init.log\nexec %s "$@"\n' $W $RG > $W/shim/git; chmod +x $W/shim/git
echo "### 8 where the proof's scratch repository is made (git init path)"
: > $W/init.log; PATH=$W/shim:$PATH TMPDIR=$W/sharedtmp ver $NEW $c $L $T >/dev/null; echo "  NEW git init at: $(cat $W/init.log | sed "s#$W#<lab>#")"
echo "  NEW leftover .review-carry-* in state/: $(ls -a $c/home/state | grep -c '^.review-carry-')"
: > $W/init.log; PATH=$W/shim:$PATH TMPDIR=$W/sharedtmp ver $OLD $c $L $T >/dev/null; echo "  OLD git init at: $(cat $W/init.log | sed "s#$W#<lab>#")"

c=$(mk unwritable); R=$(g $c rev-parse pr); T=$(g $c rev-parse trunk); rec $c $R sonnet; L=$(merge_up $c)
chmod 500 $c/home/state
both "9 state directory not writable (NEW expect typed refusal; OLD carried)" $c $L $T
chmod 700 $c/home/state
