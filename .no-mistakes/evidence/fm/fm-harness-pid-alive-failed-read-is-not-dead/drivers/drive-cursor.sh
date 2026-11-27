#!/usr/bin/env bash
# drive-cursor.sh <repo-root>: real bin/fm-turnend-guard-cursor.sh in a throwaway primary checkout, caller = fake cursor-agent.
set -u
R=$1
T=$(mktemp -d /tmp/fm-drv/cu.XXXX)
FB=$T/fb; mkdir -p "$FB"
cat > "$T/fc.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) { int s; pid_t c; if (argc != 3 || strcmp(argv[1], "-c")) return 64;
  c = fork(); if (c == 0) { execl("/bin/bash", "bash", "-c", argv[2], (char *)0); _exit(127); }
  while (waitpid(c, &s, 0) < 0) if (errno != EINTR) return 71;
  return WIFEXITED(s) ? WEXITSTATUS(s) : 128 + WTERMSIG(s); }
C
cc -o "$FB/cursor-agent" "$T/fc.c" || { echo "no cc"; exit 1; }
REAL_PS=$(command -v ps)
cat > "$FB/ps" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ -n "\${FAIL_PID:-}" ] && [ "\$a" = "\$FAIL_PID" ]; then echo 'ps: operation not permitted' >&2; exit 2; fi
done
"$REAL_PS" "\$@"; exit \$?
SH
chmod +x "$FB/ps"
mk() { local d=$1 f; mkdir -p "$d/state" "$d/bin" "$d/docs"; git init -q "$d"; git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init; : > "$d/AGENTS.md"
  for f in fm-turnend-guard-cursor.sh fm-turnend-guard.sh fm-sessionstart-cursor.sh fm-sessionstart-run.sh fm-sessionstart-nudge.sh fm-arm-pretool-check.sh \
    fm-claude-stop-autoarm.sh fm-hook-host-lib.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-supervision-liveness-lib.sh fm-wake-lib.sh fm-path-lib.sh \
    fm-secondmate-parent-lib.sh fm-guard-event.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-dsh-lib.sh fm-operational-input.sh fm-supervision-instructions.sh \
    fm-harness.sh fm-lock.sh fm-gate-refuse-lib.sh fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh fm-supervision-engine-lib.sh fm-proc-info.py; do
    [ -e "$R/bin/$f" ] && cp "$R/bin/$f" "$d/bin/$f"; done
  cp "$R/bin/fm-arm-command-policy.mjs" "$d/bin/"; cp -R "$R/docs/supervision-protocols" "$d/docs/"; chmod +x "$d"/bin/*.sh
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$$" >> "$FM_HOME/state/arm-ran"\nprintf "watcher: started pid=%%s (beacon fresh)\\n" "$$"\nprintf "stale: fixture-win needs a look\\n"\nexit 0\n' > "$d/bin/fm-watch-arm.sh"; chmod +x "$d/bin/fm-watch-arm.sh"
}
PAY='{"session_id":"sess-cursor","generation_id":"gen-0","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"2026.08.11-e8db854"}'
"$FB/cursor-agent" -c 'while :; do sleep 1; done' >/dev/null 2>&1 & H=$!
/bin/sleep 5 & G=$!; kill $G; wait $G 2>/dev/null
sleep 0.3
for c in unreadable dead; do
  d=$T/$c; mk "$d"
  if [ $c = unreadable ]; then holder=$H; fp=$H; else holder=$G; fp=; fi
  printf '%s\n' "$holder" > "$d/state/.lock"
  echo "=== $c: recorded holder pid $holder (kill -0: $(kill -0 $holder 2>/dev/null && echo alive || echo gone)); ps for holder: $([ -n "$fp" ] && echo FAILS || echo real)"
  out=$(printf '%s' "$PAY" | env -u PI_CODING_AGENT FM_HOME="$d" FM_CURSOR_PARK_POLL=1 PATH="$FB:$PATH" FAIL_PID="$fp" \
    "$FB/cursor-agent" -c 'printf "%s\n" "$$" > "$FM_HOME/state/caller"; "$FM_HOME/bin/fm-turnend-guard-cursor.sh"' 2>/dev/null); st=$?
  echo "cursor park exit=$st"; echo "stdout: $(printf '%s' "$out" | head -c 160)"
  echo "lock now: $(cat "$d/state/.lock")  (caller cursor-agent pid $(cat "$d/state/caller"))"
  echo "watcher arm ran: $([ -e "$d/state/arm-ran" ] && echo yes || echo no)"
done
kill $H 2>/dev/null; wait 2>/dev/null
rm -rf "$T"; echo "fixture removed"
