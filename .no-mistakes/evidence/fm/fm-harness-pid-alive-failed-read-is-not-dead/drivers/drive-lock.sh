#!/usr/bin/env bash
# drive-lock.sh <repo-root> : drive real bin/fm-lock.sh against 4 holder kinds in a lab home
set -u
R=$1
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8DMW2J1VQGF3NPHWTC2G695
eval "$("$W/bin/fm-lab-home.sh" env 2>/tmp/fm-drv/lab.err)"
echo "lab FM_HOME=$FM_HOME  repo=$R"
FB=$(mktemp -d /tmp/fm-drv/fb.XXXX)
ln -s /bin/bash "$FB/claude"
REAL_PS=$(command -v ps)
cat > "$FB/ps" <<SH
#!/usr/bin/env bash
# stand-in ps: fails only for the holder pid named in FAIL_PID; all else is real ps
for a in "\$@"; do
  if [ -n "\${FAIL_PID:-}" ] && [ "\$a" = "\$FAIL_PID" ]; then echo 'ps: operation not permitted' >&2; exit 2; fi
done
"$REAL_PS" "\$@"; exit \$?
SH
chmod +x "$FB/ps"
run_case() { # name holder failpid
  local name=$1 holder=$2 failpid=${3:-}
  mkdir -p "$FM_HOME/state"; rm -f "$FM_HOME/state/.lock"*
  printf '%s\n' "$holder" > "$FM_HOME/state/.lock"
  local before; before=$(shasum "$FM_HOME/state/.lock" | cut -d' ' -f1)
  echo "=== $name: holder pid $holder (kill -0: $(kill -0 "$holder" 2>/dev/null && echo alive || echo gone); real ps comm: $("$REAL_PS" -o comm= -p "$holder" 2>/dev/null || echo '<none>'))"
  env -u NO_MISTAKES_GATE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    FM_HOME="$FM_HOME" PATH="$FB:$PATH" FAIL_PID="$failpid" FM_LOCK="$R/bin/fm-lock.sh" \
    "$FB/claude" -c '"$FM_LOCK"; echo "fm-lock.sh exit=$?"; echo "caller chain pid=$$"'
  local after; after=$(shasum "$FM_HOME/state/.lock" | cut -d' ' -f1)
  echo "lock now holds: $(head -1 "$FM_HOME/state/.lock")  lock unchanged: $([ "$before" = "$after" ] && echo yes || echo NO)"
}
/bin/sleep 300 >/dev/null 2>&1 & H1=$!
run_case "B unreadable live holder (kill -0 ok, ps fails for holder only)" "$H1" "$H1"
run_case "C live non-harness holder, working ps" "$H1"
"$FB/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 & H2=$!
sleep 0.3
run_case "D live verified-harness holder, working ps" "$H2"
/bin/sleep 300 & H3=$!; kill $H3; wait $H3 2>/dev/null
run_case "E gone holder (kill -0 fails)" "$H3"
kill $H1 $H2 2>/dev/null; wait 2>/dev/null
grep -o '[^ ]*fm-lab-home.sh teardown.*' /tmp/fm-drv/lab.err > /tmp/fm-drv/teardown.cmd
bash -c "$(cat /tmp/fm-drv/teardown.cmd)" && echo "lab torn down"
