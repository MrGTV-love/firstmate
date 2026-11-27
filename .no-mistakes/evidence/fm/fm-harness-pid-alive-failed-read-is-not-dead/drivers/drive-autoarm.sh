#!/usr/bin/env bash
# drive-autoarm.sh <repo-root>: real bin/fm-claude-stop-autoarm.sh in a throwaway primary checkout,
# recorded lock holder = live process; case "unreadable" fails ps only for that holder, case "dead" uses a gone pid.
set -u
R=$1
T=$(mktemp -d /tmp/fm-drv/aa.XXXX)
FB=$T/fb; mkdir -p "$FB"; ln -s /bin/bash "$FB/claude"
REAL_PS=$(command -v ps)
cat > "$FB/ps" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ -n "\${FAIL_PID:-}" ] && [ "\$a" = "\$FAIL_PID" ]; then echo 'ps: operation not permitted' >&2; exit 2; fi
done
"$REAL_PS" "\$@"; exit \$?
SH
chmod +x "$FB/ps"
mk() { local d=$1; mkdir -p "$d/state" "$d/config" "$d/bin"; git init -q "$d"; git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  : > "$d/AGENTS.md"; : > "$d/config/supervision-host-off"; : > "$d/state/task.meta"
  for f in fm-claude-stop-autoarm.sh fm-claude-hold-release.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-secondmate-parent-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-dsh-lib.sh fm-hook-host-lib.sh fm-lock.sh fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh fm-supervision-engine-lib.sh fm-gate-refuse-lib.sh fm-proc-info.py; do [ -e "$R/bin/$f" ] && cp "$R/bin/$f" "$d/bin/$f"; done
  chmod +x "$d"/bin/*.sh
  printf '#!/usr/bin/env bash\necho "$$" >> "$FM_HOME/state/arm-ran"\nprintf "watcher: started pid=%%s (beacon fresh)\\n" "$$"\nexit 0\n' > "$d/bin/fm-watch-arm.sh"; chmod +x "$d/bin/fm-watch-arm.sh"
}
"$FB/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 & H=$!
/bin/sleep 5 & G=$!; kill $G; wait $G 2>/dev/null
sleep 0.3
for c in unreadable dead; do
  d=$T/$c; mk "$d"
  if [ $c = unreadable ]; then holder=$H; fp=$H; else holder=$G; fp=; fi
  printf '%s\n' "$holder" > "$d/state/.lock"
  echo "=== $c: recorded holder pid $holder (kill -0: $(kill -0 $holder 2>/dev/null && echo alive || echo gone)); ps for holder: $([ -n "$fp" ] && echo FAILS || echo real)"
  out=$(printf '%s\n' '{"session_id":"lab"}' | FM_HOME="$d" PATH="$FB:$PATH" FAIL_PID="$fp" "$FB/claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/caller"; "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); st=$?
  echo "autoarm exit=$st"; [ -n "$out" ] && printf 'output: %s\n' "$out" | head -5
  echo "lock now: $(cat "$d/state/.lock")  (caller chain pid $(cat "$d/state/caller"))"
  echo "watcher arm ran: $([ -e "$d/state/arm-ran" ] && echo yes || echo no)"
done
kill $H 2>/dev/null; wait 2>/dev/null
rm -rf "$T"; echo "fixture removed"
