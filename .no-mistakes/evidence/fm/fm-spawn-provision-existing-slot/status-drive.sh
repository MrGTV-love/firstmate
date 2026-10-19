#!/usr/bin/env bash
# Drives the REAL status parser with the blocked line copied out of a REAL generated brief.
set -u
ROOT=$1 BRIEF=$2 STATUS=$3
. "$ROOT/bin/fm-classify-lib.sh"
# Pull the line the brief tells a lane to write, then do what the brief says: swap <epoch> for date +%s.
tmpl=$(grep -o 'blocked \[at=<epoch>\] \[key=slot-manifest\]: [^`]*' "$BRIEF" | head -1)
echo "template from brief : $tmpl"
now=$(date +%s)
line=${tmpl//<epoch>/$now}
echo "line the lane writes: $line"
printf 'working [at=%s]: setup done\n' "$now" > "$STATUS"
printf '%s\n' "$line" >> "$STATUS"
last=$(tail -n 1 "$STATUS")
echo "verb                : $(status_line_verb "$last")"
echo "stamped epoch ok    : $(status_line_at_epoch "$last" && echo " (yes)" || echo "NO")"
echo "decision key        : $(_fm_decision_key "$last")"
status_prefix_unrecognized "$last" && echo "prefix unrecognized : YES (bad)" || echo "prefix unrecognized : no (good)"
status_is_terminal_verb "$last" && echo "terminal verb       : yes" || echo "terminal verb       : NO"
status_is_captain_relevant "$last" && echo "surfaces to firstmate: yes" || echo "surfaces to firstmate: NO"
echo "open decisions after blocked   : [$(status_open_decisions "$STATUS")]"
printf 'resolved [key=slot-manifest] [at=%s]: firstmate chose a route\n' "$((now+1))" >> "$STATUS"
echo "open decisions after resolved  : [$(status_open_decisions "$STATUS")]"
