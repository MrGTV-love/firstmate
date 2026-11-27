W=<worktree>
unset FM_HOME FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_DURATION_FILE TASKS_AXI_FILE FM_CPU_PASS_HELD
H=$(mktemp -d ~/tmp/fm-dur.XXXXXX); R=$(mktemp -d ~/tmp/fm-work.XXXXXX)
mkdir -p $H/data; printf '## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md; ln -s $W/bin $H/bin
git init -q $R && git -C $R remote add origin git@github.com:acme/widgets.git
export FM_DURATION_HOME=$H
clean() { sed "s#$H#<duration-home>#g; s#$R#<work-repo>#g; s#$W#<worktree>#g"; }
dur() { printf '$ (in <work-repo>) fm-duration.py %s\n' "$*"; (cd $R && python3 $W/bin/fm-duration.py "$@") 2>&1 | clean; echo "[exit ${PIPESTATUS[0]}]"; }
say() { printf '\n### %s\n' "$*"; }
raw() { (cd $H && TASKS_AXI_FILE=$H/data/backlog.md tasks-axi "$@" >/dev/null); }
say "H1 the second timeout for a key files one ship item that names objective O7"
dur timeout dr.lint 1200000 --event-id e1
dur timeout dr.lint 1200000 --event-id e2
dur timeout dr.lint 1200000 --event-id e3
grep '^- \[ \] fm-timeout-' $H/data/backlog.md | clean
cat -et $H/data/backlog-review.tsv
FIRST=$(grep -o 'fm-timeout-[0-9a-f]*' $H/data/backlog.md | head -1)
say "H2 after that item closes, a recurrence files the next item (its title overlaps the closed one, so the filer overrides with --not-dup)"
raw done $FIRST --note "limit repaired" --keep 5
dur timeout dr.lint 1300000 --event-id e4
dur timeout dr.lint 1300000 --event-id e5
grep -A2 "^- \[ \] $FIRST-2" $H/data/backlog.md | clean
tail -1 $H/data/backlog-review.tsv | cat -et
say "H3 an open fm-timeout- item under the same title (filed from another host) takes the occurrence through --dup-of; nothing new is filed"
raw add fm-timeout-otherhost "Measure and repair repeated timeout: acme/widgets dr.shared" --kind ship
N_BEFORE=$(grep -c '^- \[ \]' $H/data/backlog.md)
dur timeout dr.shared 1200000 --event-id s1
dur timeout dr.shared 1200000 --event-id s2
echo "open items before: $N_BEFORE, after: $(grep -c '^- \[ \]' $H/data/backlog.md)"
(cd $W && FM_HOME=$H bin/fm-tasks-axi.sh show fm-timeout-otherhost --full) | grep body: | clean
grep '"filed"' $H/data/command-durations.jsonl | grep dr.shared | clean
say "H4 a hand-filed neighbour for the same work goes to the operator; nothing is filed"
raw add hand-filed-timeout "Measure and repair repeated timeout: acme/widgets dr.hand" --kind ship
N_BEFORE=$(grep -c '^- \[ \]' $H/data/backlog.md)
dur timeout dr.hand 1200000 --event-id h1
dur timeout dr.hand 1200000 --event-id h2
echo "open items before: $N_BEFORE, after: $(grep -c '^- \[ \]' $H/data/backlog.md)"
echo "filed ledger rows for dr.hand: $(grep '"filed"' $H/data/command-durations.jsonl | grep -c dr.hand)"
rm -rf $H $R
