#!/usr/bin/env bash
# drive.sh <log-name> : run stdin as a bash script in the lab env, tee to the evidence log.
ENVF=/Users/charlesabrooker/.no-mistakes/evidence/01M4J53Z7PV6VG61D4MCRBMMRQ/target-cb1f2a36-rerun/lab-env.sh
. "$ENVF"
cd "$WT" || exit 1
log="$EV/$1.log"
{ printf '. %s\n' "$ENVF"; cat; } | bash -s 2>&1 | sed -l -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | tee -a "$log"
