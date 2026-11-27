. ~/tmp/fm-drv/lib.sh
cat > $LAB/.tasks.toml <<'T'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
T
printf '## In flight\n\n## Queued\n\n## Done\n' > $B
: > $LAB/config/fleet-ledger
say "A1 add with no --objective is refused"
fm add ob-1 "Rotate the harbour lamp batteries" --kind ship
say "A2 unknown objective O9 is refused"
fm add ob-1 "Rotate the harbour lamp batteries" --objective O9
say "A3 objective none with no reason is refused"
fm add ob-1 "Rotate the harbour lamp batteries" --objective none
say "A4 objective O7 files the item (unrelated title, no prompt)"
fm add ob-1 "Rotate the harbour lamp batteries" --objective O7 --kind ship
say "A5 objective none with a reason files the item"
fm add ob-2 "Catalogue the pantry spice jars" --objective none --objective-reason "household chore, no objective"
say "A6 data/backlog-review.tsv holds one line per filed item"
run cat -A $LAB/data/backlog-review.tsv
say "A7 overlapping title is refused, neighbours and both overrides printed"
fm add ob-3 "Rotate the harbour lamp batteries again" --objective O7
fm add dup-a "Index fleet ledger rows by host" --objective O7 >/dev/null
fm add dup-b "Index fleet ledger rows by repo" --objective O7 --not-dup dup-a >/dev/null
fm add dup-c "Index fleet ledger rows by task" --objective O7 --not-dup dup-a >/dev/null
fm add dup-d "Index fleet ledger rows by date" --objective O7 --not-dup dup-a >/dev/null
say "A8 four neighbours exist; the refusal lists only the best three"
fm add dup-e "Index fleet ledger rows by kind" --objective O7
say "A9 --not-dup naming an item that is not a neighbour is refused"
fm add ob-3 "Rotate the harbour lamp batteries again" --objective O7 --not-dup ob-2
say "A10 --not-dup with a real neighbour files the item"
fm add ob-3 "Rotate the harbour lamp batteries again" --objective O7 --not-dup ob-1
say "A11 --dup-of appends to the kept item and files nothing"
fm add ob-4 "Rotate harbour lamp batteries monthly" --objective O7 --body "monthly cadence note" --dup-of ob-1
fm show ob-4
fm show ob-1 --full
say "A12 no flag or env bypass: --force, FM_SKIP_INTAKE=1, TASKS_AXI_FILE"
fm add ob-5 "Rotate the harbour lamp batteries twice" --objective O7 --force
run env FM_SKIP_INTAKE=1 FM_BACKLOG_INTAKE=off bin/fm-tasks-axi.sh add ob-5 "Rotate the harbour lamp batteries twice"
run env TASKS_AXI_FILE=/dev/null bin/fm-tasks-axi.sh add ob-5 "Rotate the harbour lamp batteries twice" --objective O7
say "A13 add answer hides the attribution token; stored body keeps it"
fm add tk-1 "Polish the brass compass housing" --objective O7 --json
fm add tk-2 "Sweep the chart room floorboards" --objective O7
fm add tk-3 "Oil the anchor winch gears" --objective O7 --body hello --json
run grep -n -A2 "tk-1\|tk-3" $B
say "A14 final review file"
run cat $LAB/data/backlog-review.tsv
