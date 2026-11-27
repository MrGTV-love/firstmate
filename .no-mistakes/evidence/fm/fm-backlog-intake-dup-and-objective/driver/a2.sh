. ~/tmp/fm-drv/lib.sh
say "A6b data/backlog-review.tsv with tabs shown (^I) and line ends (\$)"
run cat -et $LAB/data/backlog-review.tsv
say "A15 every add spelling needs an objective: create, task add, --title, --mint"
fm create sp-1 "Tune the foghorn reed pitch"
fm task add sp-1 "Tune the foghorn reed pitch"
fm add --title "Tune the foghorn reed pitch"
fm add --mint "Tune the foghorn reed pitch"
say "A16 the = form of --objective is checked the same way"
fm add sp-1 "Tune the foghorn reed pitch" --objective=O9
say "A17 every add spelling meets the duplicate check"
fm create sp-2 "Rotate the harbour lamp batteries weekly" --objective O7
fm task add sp-2 "Rotate the harbour lamp batteries weekly" --objective=O7
fm add --title "Rotate the harbour lamp batteries weekly" --objective O7
fm add --mint "Rotate the harbour lamp batteries weekly" --objective O7
say "A18 the --mint spelling files and records its minted id"
fm add --mint "Tune the foghorn reed pitch" --objective O6
run tail -1 $LAB/data/backlog-review.tsv
