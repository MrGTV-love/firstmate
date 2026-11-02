. "$(dirname "$0")/common.sh"
banner
BASEPATH=$PATH
fresh() { R=$(mktemp -d "$(dirname "$0")/f.XXXX"); export FM_STATE_OVERRIDE="$R/state"; mkdir -p "$R/state" "$R/bin"; export PATH="$R/bin:$BASEPATH" FIXTURE_ROOT="$R"; }
echo "=== F1 transport boundary: every gh and gh-axi launch by the owner, logged by labelled fakes"
fresh
cat > "$R/bin/gh-axi" <<'F'
#!/bin/sh
printf 'gh-axi' >> "$FIXTURE_ROOT/calls"; for a in "$@"; do printf ' [%s]' "$a" >> "$FIXTURE_ROOT/calls"; done; echo >> "$FIXTURE_ROOT/calls"
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
cat > "$R/bin/gh" <<'F'
#!/bin/sh
echo "gh $*" >> "$FIXTURE_ROOT/raw-gh-calls"
F
chmod +x "$R/bin"/*
"$PY" "$OWNER" run --duration 17; echo "  run exit=$?"
sort "$R/calls" | uniq -c | sed 's/^/  /'
[ -e "$R/raw-gh-calls" ] && echo "  raw gh calls: $(cat "$R/raw-gh-calls")" || echo "  raw gh calls: 0"
echo "=== F2 disclosed limit: SIGKILL of the owner while a quota child hangs"
fresh
printf '#!/bin/sh\necho $$ >> "$FIXTURE_ROOT/kids"\nsleep 600 &\necho $! >> "$FIXTURE_ROOT/kids"\nwait\n' > "$R/bin/gh-axi"; chmod +x "$R/bin/gh-axi"
cnt() { pgrep -f "$R/bin/gh-axi" | wc -l | tr -d ' '; }
"$PY" "$OWNER" start > "$R/s"; OP=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$R/s"); sleep 1; kill -9 "$OP"; sleep 0.5; echo "  after SIGKILL hung children=$(cnt)"
"$PY" "$OWNER" start >/dev/null; sleep 1; echo "  new owner overlap children=$(cnt)"; "$PY" "$OWNER" stop; sleep 0.5; echo "  after normal stop children=$(cnt) (the crashed owner's child stays until it exits)"
while read -r k; do kill -9 "$k" 2>/dev/null; done < "$R/kids"; sleep 0.3; echo "  after driver cleanup children=$(cnt)"
echo "=== F3 bad arguments are refused before any state change"
fresh
"$PY" "$OWNER" run --duration 0 2>&1 | tail -1 | cut -c1-80; "$PY" "$OWNER" run --duration inf 2>&1 | tail -1 | cut -c1-80; "$PY" "$OWNER" start --duration 5 2>&1 | tail -1 | cut -c1-80; "$PY" "$OWNER" status --kind x 2>&1 | tail -1 | cut -c1-80; ls "$R/state" | wc -l | sed 's/^ */  state entries: /'
