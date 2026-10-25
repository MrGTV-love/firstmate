FM_REPRO_DEPTH=$(( ${FM_REPRO_DEPTH:-0} + 1 )); export FM_REPRO_DEPTH
printf 'depth=%s cmd=%s\n' "$FM_REPRO_DEPTH" "$(/bin/ps -o args= -p $$)" >> "$FM_REPRO_LOG"
if builtin [ "$FM_REPRO_DEPTH" -gt 25 ]; then exit 98; fi
