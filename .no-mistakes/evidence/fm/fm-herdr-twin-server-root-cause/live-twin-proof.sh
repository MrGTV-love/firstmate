#!/bin/bash
# Live proof against REAL Herdr in a guarded named fm-lab-* session (bin/fm-herdr-lab.sh).
# Root cause under test: a failed/timed-out/garbled/lying `herdr status` while the
# session server is ALIVE must never make firstmate start a second server.
# Usage: live-twin-proof.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 2
LABH="$WT/bin/fm-herdr-lab.sh"
REAL=$(command -v herdr)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-twin.XXXXXX")
LAB=$("$LABH" name twinproof)
PREPARED=0
FAILS=0
FAKEPIDS=

say() { printf '%s\n' "$*"; }
check() { # <description> <condition-rc>
  if [ "$2" -eq 0 ]; then say "PASS - $1"; else say "FAIL - $1"; FAILS=$((FAILS + 1)); fi
}
servers() { ps -axww -o pid=,lstart=,command= | grep -E "herdr server --session $LAB\$" | grep -v grep; }
nservers() { servers | grep -c . ; }
server_pids() { servers | awk '{print $1}' | tr '\n' ' '; }
rc0() { case "$1" in *rc=0*) return 0 ;; *) return 1 ;; esac; }

cleanup() {
  local p
  for p in $FAKEPIDS; do kill "$p" 2>/dev/null; done
  [ -n "${GUARD:-}" ] && kill "$GUARD" 2>/dev/null
  if [ "$PREPARED" = 1 ]; then
    say "== teardown via helper"
    "$LABH" teardown "$LAB"; say "teardown rc=$?"
  fi
  if [ "$(nservers)" != 0 ]; then
    say "LEFTOVER lab servers after teardown (a twin): $(server_pids) - killing"
    for p in $(server_pids); do kill "$p"; done
    FAILS=$((FAILS + 1))
  fi
  rm -rf "$T"
  say "== default session still running: $("$REAL" session list --json | jq -c '.sessions[] | select(.name=="default") | {name,running}')"
  say "== RESULT: $FAILS failing checks"
}
trap cleanup EXIT

say "== herdr $("$REAL" --version) lab session $LAB ($(date))"
"$LABH" prepare "$LAB" || exit 1
PREPARED=1
"$LABH" provision "$LAB" || exit 1
SOCK=$("$REAL" status --json --session "$LAB" | jq -r .server.socket)
"$LABH" run "$LAB" workspace create --cwd /tmp --label twinproof --no-focus >/dev/null || exit 1
PANE=$("$LABH" run "$LAB" pane list | jq -r '[.. | objects | .pane_id? // empty][0]')
TARGET="$LAB:$PANE"
ORIG=$(server_pids)
say "lab server pid(s): $ORIG socket: $SOCK target: $TARGET"
check "provisioned lab has exactly one server" "$([ "$(nservers)" = 1 ]; echo $?)"

# --- first-on-PATH shim: real herdr except for the overridden calls -----------
mkdir -p "$T/bin"
cat > "$T/bin/herdr" <<EOF
#!/bin/bash
case "\${SHIM_MODE:-pass}:\$1" in
  fail:status|overload:status) exit 1 ;;
  timeout:status) /bin/sleep 2; exit 124 ;;
  empty:status) exit 0 ;;
  garbage:status) echo 'not json'; exit 0 ;;
  lie:status|lieoverload:status) "$REAL" "\$@" | jq -c '.server.running = false' ; exit 0 ;;
  overload:pane|overload:agent|lieoverload:pane|lieoverload:agent) exit 1 ;;
esac
exec "$REAL" "\$@"
EOF
chmod +x "$T/bin/herdr"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/no-mistakes"; chmod +x "$T/bin/no-mistakes"
SHIMPATH="$T/bin:$PATH"

adapter() { # <mode> <bash snippet>
  env -u HERDR_SESSION SHIM_MODE="$1" PATH="$SHIMPATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr || exit 9; eval "$2"' x "$WT" "$2" 2>&1
}

say ""
say "== Phase A: live server, broken status - nothing may start a second server"
for mode in fail timeout empty garbage lie; do
  out=$(adapter "$mode" 'fm_backend_herdr_server_ensure "'"$LAB"'"; echo "rc=$?"')
  say "[$mode] ensure: $(printf '%s' "$out" | tr '\n' ' ')"
  if rc0 "$out"; then r=1; else r=0; fi
  check "[$mode] server_ensure refuses (nonzero) while the real server is alive" "$r"
  st=$(adapter "$mode" 'fm_backend_agent_state herdr "'"$TARGET"'"')
  say "[$mode] agent_state(real agent-free pane) = $st"
  check "[$mode] still exactly the original server ($ORIG) after ensure + agent_state" "$([ "$(server_pids)" = "$ORIG" ]; echo $?)"
done
for mode in overload lieoverload; do
  st=$(adapter "$mode" 'fm_backend_agent_state herdr "'"$TARGET"'"')
  say "[$mode] agent_state with pane/agent reads failing too = $st"
  check "[$mode] passive state reads unreadable, never missing/start" "$([ "$st" = unreadable ]; echo $?)"
  check "[$mode] still exactly the original server ($ORIG)" "$([ "$(server_pids)" = "$ORIG" ]; echo $?)"
done

# The incident's exact entry point: fm-crew-state.sh -> fm_backend_agent_state.
H="$T/home"; mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
printf 'backend=herdr\nwindow=%s\nkind=scout\nharness=claude\nworktree=%s\n' "$TARGET" "$WT" > "$H/state/twinproof.meta"
for mode in overload lieoverload fail; do
  out=$(env -u HERDR_SESSION -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE SHIM_MODE="$mode" PATH="$SHIMPATH" \
    FM_HOME="$H" FM_ROOT_OVERRIDE="$WT" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    FM_CONFIG_OVERRIDE="$H/config" FM_PROJECTS_OVERRIDE="$H/projects" FM_MODEL_FRESHNESS=0 FM_CREW_STATE_NO_FORGE=1 \
    bash "$WT/bin/fm-crew-state.sh" twinproof 2>&1; echo "rc=$?")
  say "[$mode] fm-crew-state.sh twinproof: $(printf '%s' "$out" | grep -iE 'backend|rc=' | tr '\n' ' ' | cut -c1-300)"
  check "[$mode] fm-crew-state left exactly the original server ($ORIG)" "$([ "$(server_pids)" = "$ORIG" ]; echo $?)"
done

# fm-remote launch-agent guard with failing status against the live lab server.
SHIM_MODE=fail "$WT/bin/fm-remote-herdr-guard.sh" "$T/bin/herdr" "$LAB" > "$T/guard.log" 2>&1 &
GUARD=$!
"$REAL" --version >/dev/null; python3 -c 'import time; time.sleep(6)'
kill "$GUARD" 2>/dev/null; wait "$GUARD" 2>/dev/null; GUARD=
say "[guard fail] log: $(tr '\n' ' ' < "$T/guard.log")"
check "[guard fail] guard waited and started nothing; still original server ($ORIG)" "$([ "$(server_pids)" = "$ORIG" ] && ! grep -q 'starting the herdr server' "$T/guard.log"; echo $?)"

say ""
say "== Phase B: proven absence (server stopped via helper)"
"$LABH" stop "$LAB" >/dev/null; say "helper stop rc=$?"
check "stopped lab has no server process" "$([ "$(nservers)" = 0 ]; echo $?)"
st=$(adapter pass 'fm_backend_agent_state herdr "'"$TARGET"'"')
say "[stopped] agent_state = $st ; servers now: $(nservers)"
check "[stopped] passive state reads missing and starts nothing" "$([ "$st" = missing ] && [ "$(nservers)" = 0 ]; echo $?)"

# An unscoped server process that inherited this session (inert python fake) blocks start.
printf '#!%s\nimport time\nwhile True: time.sleep(60)\n' "$(python3 -c 'import sys; print(sys.executable)')" > "$T/bin/fakeherdr-dir-herdr"
mkdir -p "$T/fake"; mv "$T/bin/fakeherdr-dir-herdr" "$T/fake/herdr"; chmod +x "$T/fake/herdr"
HERDR_SESSION="$LAB" "$WT/bin/fm-proc-budget.sh" -- "$T/fake/herdr" server & FAKEPIDS="$FAKEPIDS $!"
python3 -c 'import time; time.sleep(0.5)'
out=$(adapter pass 'fm_backend_herdr_server_ensure "'"$LAB"'"; echo "rc=$?"')
say "[unscoped twin-shaped process] ensure: $(printf '%s' "$out" | tr '\n' ' ')"
check "[unscoped process inheriting $LAB] ensure refuses and starts nothing" "$(! rc0 "$out" && [ "$(nservers)" = 0 ]; echo $?)"
st=$(adapter pass 'fm_backend_agent_state herdr "'"$TARGET"'"')
check "[unscoped process inheriting $LAB] passive state is unreadable, not missing ($st)" "$([ "$st" = unreadable ]; echo $?)"
for p in $FAKEPIDS; do kill "$p" 2>/dev/null; done; FAKEPIDS=

# Concurrent cold starts through the real adapter: exactly one real server.
for i in 1 2 3 4 5 6; do
  ( adapter pass 'fm_backend_herdr_server_ensure "'"$LAB"'"; echo "rc=$?"' > "$T/ensure.$i" ) &
done
wait
rcs=$(cat "$T"/ensure.* | grep -o 'rc=[0-9]*' | sort | uniq -c | tr '\n' ' ')
say "[6 concurrent ensures] exit codes: $rcs ; servers: $(servers | tr '\n' ' ')"
check "[6 concurrent ensures] all succeed" "$([ "$(cat "$T"/ensure.* | grep -c 'rc=0')" = 6 ]; echo $?)"
check "[6 concurrent ensures] exactly ONE real herdr server" "$([ "$(nservers)" = 1 ]; echo $?)"
FIRST=$(server_pids)
out=$(adapter pass 'fm_backend_herdr_server_ensure "'"$LAB"'"; echo "rc=$?"')
check "[re-ensure] reuses the running server ($FIRST)" "$(rc0 "$out" && [ "$(server_pids)" = "$FIRST" ]; echo $?)"
st=$(adapter pass 'fm_backend_agent_state herdr "'"$TARGET"'"')
say "[restarted] agent_state(saved agent-free pane) = $st"

# fm-remote guard cold start on a proven-absent session: hold-for-exec, one server.
"$LABH" stop "$LAB" >/dev/null; say "helper stop rc=$?"
"$WT/bin/fm-remote-herdr-guard.sh" "$REAL" "$LAB" > "$T/guard2.log" 2>&1 &
GUARD=$!
for i in $(seq 1 100); do [ "$(nservers)" = 1 ] && break; python3 -c 'import time; time.sleep(0.1)'; done
python3 -c 'import time; time.sleep(1)'
out=$(adapter pass 'fm_backend_herdr_server_ensure "'"$LAB"'"; echo "rc=$?"')
say "[guard cold start] log: $(tr '\n' ' ' < "$T/guard2.log") ; servers: $(servers | tr '\n' ' ') ; adapter ensure after: $(printf '%s' "$out" | tr '\n' ' ')"
check "[guard cold start] guard exec'd exactly one server as itself (pid $GUARD) and an adapter ensure reused it" \
  "$([ "$(server_pids)" = "$GUARD " ] && rc0 "$out"; echo $?)"
GUARD=
exit 0
