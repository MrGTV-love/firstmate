# S3b same path: origin starts tracking notes.local; the project ignores notes.local.
/tmp/fm-lab-driver/publish.sh "$1" notes.local 'tracked by origin' force
printf 'notes.local\n' >> "$1/project/.git/info/exclude"
