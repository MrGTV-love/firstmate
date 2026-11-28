S=/private/tmp/fm-wc-adv.Ldb4IA/home/state; W=/private/tmp/fm-wc-adv.Ldb4IA/wt; R=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M8FZW7C8EW8SYDZM4GY5TDVT
t() { name=$1; shift; if ( "$@" ) >/dev/null 2>&1; then echo "ALLOWED  $name"; else echo "REFUSED  $name"; fi; }
t "control: write own state/task.status"        sh -c "echo idle > $S/task.status"
t "control: write in task worktree"             sh -c "echo hi > $W/file.txt"
t "append forged row to review-records.jsonl"   sh -c "echo '{\"forged\":1}' >> $S/review-records.jsonl"
t "truncate review-records.jsonl"               sh -c ": > $S/review-records.jsonl"
t "rename forged file over review-records.jsonl" sh -c "mv $W/file.txt $S/review-records.jsonl"
t "rename review-records.jsonl away"            mv $S/review-records.jsonl $W/stolen.jsonl
t "delete review-records.jsonl"                 rm -f $S/review-records.jsonl
t "hard link review-records.jsonl into worktree" ln $S/review-records.jsonl $W/ledger-alias
t "symlink review-records.jsonl into worktree then write" sh -c "ln -s $S/review-records.jsonl $W/ledger-sym && echo x >> $W/ledger-sym"
t "mkdir new .review-carry-777-evil"            mkdir $S/.review-carry-777-evil
t "plant symlink .review-carry-778-evil"        ln -s /tmp $S/.review-carry-778-evil
t "tamper inside existing scratch proof.git"    sh -c "echo tampered > $S/.review-carry-4242-old/proof.git/config"
t "add hook file to existing scratch"           sh -c "mkdir -p $S/.review-carry-4242-old/proof.git/hooks && echo x > $S/.review-carry-4242-old/proof.git/hooks/post"
t "delete existing scratch dir"                 rm -rf $S/.review-carry-4242-old
t "rename existing scratch dir"                 mv $S/.review-carry-4242-old $S/renamed
t "forge row via real fm-review-record.py captain-word" env FM_HOME=/private/tmp/fm-wc-adv.Ldb4IA/home python3 $R/bin/fm-review-record.py captain-word --pr https://github.com/example/repo/pull/9 --head 1111111111111111111111111111111111111111 --words "ship it"
