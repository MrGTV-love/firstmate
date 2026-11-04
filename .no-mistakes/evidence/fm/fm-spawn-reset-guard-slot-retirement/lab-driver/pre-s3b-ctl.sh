# S3b control: origin advances with an unrelated file; the project ignores private.local.
/tmp/fm-lab-driver/publish.sh "$1" advanced.txt 'advanced before spawn'
printf 'private.local\n' >> "$1/project/.git/info/exclude"
