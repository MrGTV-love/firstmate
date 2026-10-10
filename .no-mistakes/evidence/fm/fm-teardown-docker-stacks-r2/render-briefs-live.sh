#!/usr/bin/env bash
# Render real ship, scout and secondmate briefs in a disposable lab home and
# show the Docker marker rule each worker receives.
set -u
SRC=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
for m in "demo-ship alpha --mode no-mistakes" "demo-scout alpha --scout"; do
  # shellcheck disable=SC2086
  set -- $m
  FM_HOME="$LAB" "$SRC/bin/fm-brief.sh" "$@" >/dev/null 2>&1
  echo "fm-brief.sh $m -> exit $?"
  echo "--- <lab>/data/$1/brief.md, Docker rule as rendered ---"
  grep -A11 '^10\. Mark every Docker object' "$LAB/data/$1/brief.md"
  echo
done
FM_SECONDMATE_CHARTER=x FM_HOME="$LAB" "$SRC/bin/fm-brief.sh" demo-mate --secondmate alpha >/dev/null 2>&1
echo "fm-brief.sh demo-mate --secondmate alpha -> exit $?"
echo "secondmate charter lines mentioning fm.task: $(grep -c fm.task "$LAB/data/demo-mate/brief.md")"
