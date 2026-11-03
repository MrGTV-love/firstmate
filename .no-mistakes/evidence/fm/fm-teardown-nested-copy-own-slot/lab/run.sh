#!/usr/bin/env bash
# run.sh '<bash commands>': run lab steps under bash with the lab env and helpers loaded.
set -u
. /Users/charlesabrooker/tmp/fm-lab-work.qADKuX/env.sh
. /Users/charlesabrooker/.no-mistakes/evidence/01M6GYA85H99BKCG23EW25BNTC/lab/lab-lib.sh
eval "$1"
