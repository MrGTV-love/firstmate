#!/usr/bin/env bash
# Live drive of bin/fm-bootstrap.sh in a marked lab home with the real
# toolchain on PATH: once with the real installed treehouse (schema 1), once
# with a shim whose capabilities answer is schema 2 with a protected holder
# (every other treehouse command runs the real binary).
# Usage: drive-live-bootstrap.sh <out-dir>
set -u
OUT=$1
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7W0RMHJX3TG89Q7TVS1Y7HQ
REAL_TH=$HOME/.local/bin/treehouse
mkdir -p "$OUT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
for mode in real-schema1 shim-schema2; do
  eval "$("$REPO/bin/fm-lab-home.sh" env 2>"$OUT/lab-env-$mode.stderr")"
  SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-boot.XXXXXX")
  mkdir -p "$SCR/bin" "$SCR/home"
  printf '%s\n' manual > "$FM_HOME/config/backlog-backend"
  cat > "$SCR/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SCR/treehouse-calls.log"
if [ "$mode" = shim-schema2 ] && [ "\${1:-}" = capabilities ]; then
  printf '%s\n' '{"schema_version":2,"version":"v3.1.7-lab-shim","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined: persistent recovered lease"}'
  exit 0
fi
exec "$REAL_TH" "\$@"
SH
  chmod +x "$SCR/bin/treehouse"
  {
    echo "===== mode=$mode  FM_HOME=$FM_HOME"
    echo "--- treehouse capabilities --json (as bootstrap sees it):"
    (cd / && PATH="$SCR/bin:$PATH" treehouse capabilities --json)
    echo "--- fm-bootstrap.sh output (FM_BOOTSTRAP_NETWORK=skip):"
    (cd "$REPO" && HOME=$SCR/home FM_BOOTSTRAP_NETWORK=skip PATH="$SCR/bin:$PATH" "$REPO/bin/fm-bootstrap.sh" 2>&1; echo "rc=$?")
    echo "--- lines mentioning treehouse:"
    (cd "$REPO" && HOME=$SCR/home FM_BOOTSTRAP_NETWORK=skip PATH="$SCR/bin:$PATH" "$REPO/bin/fm-bootstrap.sh" 2>&1) | grep -i treehouse || echo "(none)"
    echo "--- treehouse commands bootstrap ran:"
    grep -v '^capabilities --json$' "$SCR/treehouse-calls.log" | sort | uniq -c || true
    sort "$SCR/treehouse-calls.log" | uniq -c
  } >> "$OUT/bootstrap-transcript.txt" 2>&1
  tmux -L fm-lab kill-server 2>/dev/null || true
  td=$(sed -n "s/^fm-lab-home: teardown: //p" "$OUT/lab-env-$mode.stderr" | tail -1)
  lab=${td##* }
  eval "${td%% && *}"; chmod -R u+w "$lab" 2>/dev/null; rm -rf "$lab"
  rm -rf "$SCR"
  echo "teardown $mode: $td" >> "$OUT/bootstrap-transcript.txt"
done
