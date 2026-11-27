#!/usr/bin/env bash
# in-lab.sh <lab-dir> <bash snippet>: run the snippet with the lab env and lib loaded.
set -u
. "$1/env.sh"; . "$(dirname "$0")/lib.sh"
[ ! -f "$LAB/row.sh" ] || . "$LAB/row.sh"
eval "$2"
