. ~/tmp/fm-drv/lib.sh
LAB=~/tmp/fm-lab.BDGqxx; export FM_HOME=$LAB; B=$LAB/data/backlog.md
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > $LAB/.tasks.toml
hit() { case $1 in 3) echo "Calibrate the sextant mirror alignment";; 30) echo "Varnish the tiller handle grip";; 50) echo "Splice the mooring line eyes";; 51) echo "Tar the keel seam caulking";; *) echo "Filler row ${1}aaa ${1}bbb ${1}ccc";; esac; }
{ printf '## In flight\n\n## Queued\n\n## Done\n'; for i in $(seq 1 60); do printf -- '- [x] done-%s - %s (done 2026-11-01)\n' $i "$(hit $i)"; done; } > $B
say "B0 seed: 60 Done rows written newest first (done-1 newest); the real tasks-axi prune then moves all but the newest 10 to the archive"
fm prune
run grep -c '^- \[x\]' $B
run grep -c '^- \[x\]' $LAB/data/done-archive.md
run grep -n 'done-3 \|done-30 \|done-50 \|done-51 ' $B $LAB/data/done-archive.md
say "B1 a title that overlaps a Done row still in the backlog (done-3) is refused"
fm add w-1 "Calibrate the sextant mirror alignment again" --objective O7
say "B2 a title that overlaps a Done row pruned to the archive (done-30) is refused"
fm add w-2 "Varnish the tiller handle grip again" --objective O7
say "B3 edge: done-50, the 50th newest Done row (in the archive), still stops the add"
fm add w-3 "Splice the mooring line eyes again" --objective O7
say "B4 edge: done-51, the 51st newest Done row, does not stop the add"
fm add w-4 "Tar the keel seam caulking again" --objective O7
say "B5 --dup-of an item that is only in the done archive is refused with a pointer to --not-dup"
fm add w-2 "Varnish the tiller handle grip again" --objective O7 --dup-of done-30
say "B6 --not-dup naming the archived neighbour files the item"
fm add w-2 "Varnish the tiller handle grip again" --objective O7 --not-dup done-30
run cat -et $LAB/data/backlog-review.tsv
