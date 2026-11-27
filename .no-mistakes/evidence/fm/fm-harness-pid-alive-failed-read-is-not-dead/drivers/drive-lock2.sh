#!/usr/bin/env bash
# drive-lock2.sh <repo-root> : adversarial holder cases against real bin/fm-lock.sh in a lab home
set -u
R=$1
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8DMW2J1VQGF3NPHWTC2G695
eval "$("$W/bin/fm-lab-home.sh" env 2>/tmp/fm-drv/lab2.err)"
echo "lab FM_HOME=$FM_HOME  repo=$R"
FB=$(mktemp -d /tmp/fm-drv/fb.XXXX)
ln -s /bin/bash "$FB/claude"
REAL_PS=$(command -v ps)
cat > "$FB/ps" <<SH
#!/usr/bin/env bash
# stand-in ps: for the pid in FAIL_PID exits FAIL_RC (2 = read error, 126 = confined-worker refusal); all else is real ps
for a in "\$@"; do
  if [ -n "\${FAIL_PID:-}" ] && [ "\$a" = "\$FAIL_PID" ]; then
    [ "\${FAIL_RC:-2}" = 126 ] || echo 'ps: operation not permitted' >&2
    exit "\${FAIL_RC:-2}"
  fi
done
"$REAL_PS" "\$@"; exit \$?
SH
chmod +x "$FB/ps"
REAL_PY=$(command -v python3)
cat > "$FB/python3" <<SH
#!/usr/bin/env bash
# stand-in python3: when FAIL_PY_PID is among the args (the proc-info fallback reading the holder), print nothing and exit 1
for a in "\$@"; do [ -n "\${FAIL_PY_PID:-}" ] && [ "\$a" = "\$FAIL_PY_PID" ] && exit 1; done
exec "$REAL_PY" "\$@"
SH
chmod +x "$FB/python3"
run_case() { # name holder failpid failrc failpypid
  local name=$1 holder=$2 failpid=${3:-} failrc=${4:-2} failpy=${5:-}
  mkdir -p "$FM_HOME/state"; rm -f "$FM_HOME/state/.lock"*
  printf '%s\n' "$holder" > "$FM_HOME/state/.lock"
  local before; before=$(shasum "$FM_HOME/state/.lock" | cut -d' ' -f1)
  echo "=== $name: holder pid $holder (kill -0: $(kill -0 "$holder" 2>/dev/null && echo alive || echo gone); real ps comm: $("$REAL_PS" -o comm= -p "$holder" 2>/dev/null || echo '<none>'))"
  env -u NO_MISTAKES_GATE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    FM_HOME="$FM_HOME" PATH="$FB:$PATH" FAIL_PID="$failpid" FAIL_RC="$failrc" FAIL_PY_PID="$failpy" FM_LOCK="$R/bin/fm-lock.sh" \
    "$FB/claude" -c '"$FM_LOCK"; echo "fm-lock.sh exit=$?"; echo "caller chain pid=$$"'
  local after; after=$(shasum "$FM_HOME/state/.lock" | cut -d' ' -f1)
  echo "lock now holds: $(head -1 "$FM_HOME/state/.lock")  lock unchanged: $([ "$before" = "$after" ] && echo yes || echo NO)"
}
"$FB/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 & H2=$!
/bin/sleep 120 >/dev/null 2>&1 & H1=$!
sleep 0.3
run_case "B2 live REAL-SHAPED harness holder whose ps read fails (exit 2)" "$H2" "$H2" 2
run_case "F1 confined-worker ps (exit 126) for a live harness holder; fallback reader works" "$H2" "$H2" 126
run_case "F2 confined-worker ps (exit 126) for a live non-harness holder; fallback reader works" "$H1" "$H1" 126
run_case "F3 confined-worker ps (exit 126) for a live harness holder AND the fallback reader fails" "$H2" "$H2" 126 "$H2"
kill $H1 $H2 2>/dev/null; wait 2>/dev/null
bash -c "$(grep -o '[^ ]*fm-lab-home.sh teardown.*' /tmp/fm-drv/lab2.err)" && echo "lab torn down"
