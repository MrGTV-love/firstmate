#!/usr/bin/env bash
# 9e alone: the only neighbours are fm-timeout- items, so the filer overrides with --not-dup and files.
set -u; WT=$1; cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE FM_DURATION_HOME FM_DURATION_FILE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; A=$FM_HOME; BL=$A/data/backlog.md
printf '## In flight\n\n## Queued\n\n## Done\n' > "$BL"
for r in "lab.ka 5" "lab.ka 6" "lab.kd 5" "lab.kd 6"; do echo "\$ python3 bin/fm-duration.py record $r 124 --timed-out"; python3 bin/fm-duration.py record $r 124 --timed-out 2>&1 | cut -c1-300 | sed 's/^/  | /'; echo "  rc=${PIPESTATUS[0]}"; done
grep -E '^- \[.\] ' "$BL" | sed 's/^/  backlog| /'
grep -E '^fm-timeout-' "$A/data/backlog-review.tsv" | cut -f1-4 | sed 's/^/  tsv| /'
n=$(grep -cE '^- \[ \] fm-timeout-' "$BL"); [ "$n" = 2 ] && echo "  FACT ok: two keys filed two items" || echo "  FACT FAILED: $n items"
bin/fm-lab-home.sh teardown "$A" >/dev/null 2>&1; rm -rf "$A"; [ ! -d "$A" ] && echo "labs removed"
