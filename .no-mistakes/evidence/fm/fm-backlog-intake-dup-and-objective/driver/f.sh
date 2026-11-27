. ~/tmp/fm-drv/lib.sh
st() { run sh -c "bin/fm-tasks-axi.sh show $1 | grep -E 'state:|links:'"; }
fm add pf-ship "Fit the new bilge alarm sensor" --objective O7 --kind ship >/dev/null
fm add pf-ship2 "Mount the solar charge controller" --objective O7 --kind ship >/dev/null
fm add pf-scout "Survey the rigging wire fatigue" --objective O7 --kind scout >/dev/null
fm add pf-drop "Retire the old radar dome bracket" --objective O7 --kind ship >/dev/null
fm add pf-task "Stow the winter boat cover" --objective O7 >/dev/null
say "F1 a ship with no proof is refused (as before)"
fm done pf-ship; st pf-ship
say "F2 a ship with an open (unmerged) pull request is refused; real GitHub read"
fm done pf-ship --pr https://github.com/MrGTV-love/firstmate/pull/460; st pf-ship
say "F3 a report is not a ship's deliverable"
fm done pf-ship --report $LAB/data/nothing.md; st pf-ship
say "F4 a ship with a merged pull request closes; real GitHub read"
fm done pf-ship --pr https://github.com/MrGTV-love/firstmate/pull/451; st pf-ship
say "F5 a scout with a missing report is refused; a pull request is not a scout's deliverable"
fm done pf-scout --report $LAB/data/pf-scout/report.md
fm done pf-scout --pr https://github.com/MrGTV-love/firstmate/pull/451; st pf-scout
say "F6 a scout with a written report closes"
mkdir -p $LAB/data/pf-scout; printf 'Rigging survey: no fatigue found.\n' > $LAB/data/pf-scout/report.md
fm done pf-scout --report $LAB/data/pf-scout/report.md; st pf-scout
say "F7 --drop-file combined with --note is refused"
printf 'Drop it, the bracket is gone already.\n' > ~/tmp/fm-drv/drop.txt
fm done pf-drop --drop-file ~/tmp/fm-drv/drop.txt --note x; st pf-drop
say "F8 --drop-file with the owner's words closes; words kept in data/<id>/captain-drop.md, note 'dropped'"
fm done pf-drop --drop-file ~/tmp/fm-drv/drop.txt; st pf-drop
run cat $LAB/data/pf-drop/captain-drop.md
run grep -n -A2 '^- \[x\] pf-drop' $B
say "F9 a plain task closes with no proof (as before)"
fm done pf-task; st pf-task
run grep -E 'pf-(ship|scout|drop|task)' $LAB/state/fleet-ledger.jsonl
