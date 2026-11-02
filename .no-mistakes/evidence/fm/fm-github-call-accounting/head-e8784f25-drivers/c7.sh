. "$(dirname "$0")/common.sh"
banner
echo "### fake ps logs each launch with argv; /bin/ps reads what is alive"
R=$(mktemp -d "$(dirname "$0")/c7.XXXX"); export FM_STATE_OVERRIDE="$R/state"; mkdir -p "$R/state" "$R/bin"
export PATH="$R/bin:$PATH" FIXTURE_ROOT="$R"
printf "#!/bin/sh\nprintf 'api_response:\\\\n  body: used=11 reset=1794000000 limit=5000 remaining=4989\\\\n'\n" > "$R/bin/gh-axi"
cat > "$R/bin/ps" <<'F'
#!/bin/sh
printf '%s %s\n' "$$" "$*" >> "$FIXTURE_ROOT/ps-log"
exec sleep 900
F
chmod +x "$R/bin"/*
"$PY" "$OWNER" start > "$R/s"; OP=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$R/s")
for t in 3 12 15 15 15; do sleep $t
 launches=$(wc -l < "$R/ps-log" | tr -d ' ')
 live=0; while read -r p rest; do kill -0 "$p" 2>/dev/null && live=$((live+1)); done < "$R/ps-log"
 children=$(/bin/ps -axo ppid=,command= | awk -v o="$OP" '$1==o && $2=="sleep" && $3=="900"' | wc -l | tr -d ' ')
 echo "t+$t launches=$launches live=$live owner_children_sleep900=$children owner_threads=$(/bin/ps -M -p "$OP" | tail -n +2 | wc -l | tr -d ' ')"
done
echo "--- argv shapes, first 6 and counts"; cut -d' ' -f2- "$R/ps-log" | sort | uniq -c
"$PY" "$OWNER" stop; sleep 1
live=0; while read -r p rest; do kill -0 "$p" 2>/dev/null && live=$((live+1)); done < "$R/ps-log"; echo "live after stop=$live"
