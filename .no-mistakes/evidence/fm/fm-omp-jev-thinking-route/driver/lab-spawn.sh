#!/usr/bin/env bash
# Run inside the lab primary pane: scaffold a scout brief and launch it with the
# real bin/fm-spawn.sh. Usage: lab-spawn.sh <work> <fm-root> <id> <project> [fm-spawn args...]
W=$1 FMR=$2 ID=$3 PROJ=$4; shift 4
cd "$FM_HOME" || exit 1
echo "spawn-$ID" > "$W/phase"
{
  "$FMR/bin/fm-brief.sh" "$ID" "$PROJ" --scout >/dev/null || exit 1
  TASK_TEXT="Lab scout for live validation: find the function that adds two numbers in counter.ts and report it." \
  SPEC_TEXT="Find the add function in counter.ts, then write a one-line report. Nothing else is in scope." \
  python3 - "$FM_HOME/data/$ID/brief.md" <<'PY' || exit 1
import os, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
open(p, "w", encoding="utf-8").write(t)
PY
  "$FMR/bin/fm-tasks-axi.sh" add "$ID" "lab scout $ID" --kind scout --repo "$PROJ" >/dev/null 2>&1 || true
  "$FMR/bin/fm-spawn.sh" "$ID" "$FM_HOME/projects/$PROJ" --scout --harness omp --model fixture/main "$@"
  echo "SPAWN_EXIT=$?"
} > "$W/spawn-$ID.log" 2>&1
echo "worker-$ID" > "$W/phase"
