#!/bin/bash
# Live: fm-afk-launch's Herdr start failure log names its cause (refusal / exit 127 / exit 4)
# against a REAL Herdr lab session (bin/fm-herdr-lab.sh), never starting a second server.
# Usage: live-start-failure-messages.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 2
LABH="$WT/bin/fm-herdr-lab.sh"
REAL=$(command -v herdr)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-msg.XXXXXX")
LAB=$("$LABH" name msgproof)
PREPARED=0
FAILS=0
say() { printf '%s\n' "$*"; }
check() { if [ "$2" -eq 0 ]; then say "PASS - $1"; else say "FAIL - $1"; FAILS=$((FAILS + 1)); fi; }
servers() { ps -axww -o pid=,command= | grep -E "herdr server --session $LAB\$" | grep -v grep; }
nservers() { servers | grep -c . ; }
cleanup() {
  chmod 700 "$T/locked" 2>/dev/null
  if [ "$PREPARED" = 1 ]; then "$LABH" teardown "$LAB"; say "teardown rc=$?"; fi
  [ "$(nservers)" = 0 ] || { say "LEFTOVER lab server: $(servers)"; FAILS=$((FAILS + 1)); }
  rm -rf "$T"
  say "== default session: $("$REAL" session list --json | jq -c '.sessions[] | select(.name=="default") | {name,running}')"
  say "== RESULT: $FAILS failing checks"
}
trap cleanup EXIT

"$LABH" prepare "$LAB" || exit 1
PREPARED=1
"$LABH" provision "$LAB" || exit 1
say "lab $LAB server: $(servers)"

mkdir -p "$T/bin" "$T/tools" "$T/locked" "$T/home/state" "$T/home/data" "$T/home/config" "$T/home/projects"
cat > "$T/bin/herdr" <<EOF
#!/bin/bash
case "\${SHIM_MODE:-pass}:\$1" in
  fail:status) exit 1 ;;
  lie:status) "$REAL" "\$@" | jq -c '.server.running = false' ; exit 0 ;;
  lockdir:status) "$REAL" "\$@" | jq -c --arg s "$T/locked/herdr.sock" '.server.socket = \$s' ; exit 0 ;;
esac
exec "$REAL" "\$@"
EOF
chmod +x "$T/bin/herdr"
for tool in bash jq ps cat head sed awk grep tr dirname basename mkdir rm env sh date printf sort cut wc uname id mktemp seq sleep; do
  f=$(command -v "$tool") && ln -s "$f" "$T/tools/$tool"
done

launch() { # <mode> <PATH>
  env -u HERDR_SESSION SHIM_MODE="$1" PATH="$2" FM_HOME="$T/home" FM_ROOT_OVERRIDE="$WT" \
    FM_STATE_OVERRIDE="$T/home/state" FM_DATA_OVERRIDE="$T/home/data" FM_CONFIG_OVERRIDE="$T/home/config" \
    FM_PROJECTS_OVERRIDE="$T/home/projects" \
    "$T/tools/bash" -c '. "$1/bin/fm-afk-launch.sh"; fm_afk_launch_create_herdr "$2:w1:p1" herdr; echo "rc=$?"' x "$WT" "$LAB" 2>&1
}

out=$(launch fail "$T/bin:$PATH")
say "[live server, failed status] $out"
check "refusal is named as protecting a live or unknown server" "$(printf '%s' "$out" | grep -q "refused to start the herdr server for session $LAB to protect a live or unknown server"; echo $?)"
check "still one lab server" "$([ "$(nservers)" = 1 ]; echo $?)"

out=$(launch lie "$T/bin:$T/tools")
say "[stopped status, python3 absent from PATH] $out"
check "missing python3 is named as start helper failure exit 127" "$(printf '%s' "$out" | grep -q "the server start helper failed (exit 127) for session $LAB"; echo $?)"
check "still one lab server" "$([ "$(nservers)" = 1 ]; echo $?)"

"$LABH" stop "$LAB" >/dev/null; say "helper stop rc=$?"
chmod 500 "$T/locked"
out=$(launch lockdir "$T/bin:$PATH")
chmod 700 "$T/locked"
say "[proven-absent session, unwritable start-lock dir] $out"
check "lock preparation failure is named as start helper failure exit 4" "$(printf '%s' "$out" | grep -q "the server start helper failed (exit 4) for session $LAB"; echo $?)"
check "no server was launched" "$([ "$(nservers)" = 0 ]; echo $?)"
exit 0
