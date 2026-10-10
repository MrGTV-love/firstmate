#!/usr/bin/env bash
# Long-lived lab owner: mints the lab home (so its marker names this live process) and stays alive until told to stop.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4KAY4TDSEXMSMA5ZX7ZS3ZA
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
echo "$LAB" > "$1"
while [ ! -e "$LAB/.stop-owner" ] && [ -d "$LAB" ]; do sleep 5; done
