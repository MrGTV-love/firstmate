# S3b ancestor: origin starts tracking notes.local/entry.txt; the project ignores notes.local.
/tmp/fm-lab-driver/publish.sh "$1" notes.local/entry.txt 'tracked entry' force
printf 'notes.local\n' >> "$1/project/.git/info/exclude"
