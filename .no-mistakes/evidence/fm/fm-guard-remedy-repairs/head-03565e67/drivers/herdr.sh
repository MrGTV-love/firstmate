#!/usr/bin/env bash
set -u
cd "$1"; EV=$2; WT=$PWD
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$(cd "$FM_HOME"; pwd -P)
BASE=$(mktemp -d /tmp/nm-hd.XXXXXX); BASE=$(cd "$BASE"; pwd -P)
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g"; }
L=
cleanup() { [ -z "$L" ] || kill "$L" 2>/dev/null; chmod -R u+rwX "$LAB" "$BASE" 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"; }
trap cleanup EXIT
SES=$(bin/fm-herdr-lab.sh name remedyb)
mkdir -p "$BASE/bin"; : > "$BASE/client.log"
# Stand-in Herdr client: answers status per $BASE/mode, logs every call. Real helper and real backend code run unchanged.
cat > "$BASE/bin/herdr" <<C
#!/usr/bin/env bash
printf 'herdr %s\n' "\$*" >> "$BASE/client.log"
case "\$*" in
  *status*)
    case "\$(cat "$BASE/mode")" in
      fail) echo 'cannot reach socket' >&2; exit 7 ;;
      malformed) printf '{"server":{"running":"unknown"}}\n' ;;
      absent) printf '{"client":{"session":"$SES"},"server":{"running":false,"status":"not_running","socket":"$BASE/s.sock"}}\n' ;;
      live) printf '{"client":{"session":"$SES"},"server":{"running":true,"status":"running","socket":"$BASE/s.sock"}}\n' ;;
    esac ;;
  *server*) echo STARTED >> "$BASE/started"; exit 0 ;;
esac
C
chmod +x "$BASE/bin/herdr"
drive() { PATH="$BASE/bin:$PATH" bash -c '. bin/fm-backend.sh; . bin/backends/herdr.sh; fm_backend_herdr_server_ensure "$1"; rc=$?; printf "ensure exit=%s\n" "$rc"; printf "failure line: %s\n" "$(fm_backend_herdr_server_ensure_failure "$rc" "$1")"' _ "$SES" 2>&1 | san | sed "s/$SES/<session>/g"; }
{
echo "# firstmate code is real; the herdr client on PATH is a stand-in (no server is launched in this run)"
echo "## 1. status command fails (client/socket access broken)"; echo fail > "$BASE/mode"; drive
echo "started servers: $(cat "$BASE/started" 2>/dev/null | wc -l | tr -d " ")"
echo; echo "## 2. status is malformed"; echo malformed > "$BASE/mode"; drive
echo "started servers: $(cat "$BASE/started" 2>/dev/null | wc -l | tr -d " ")"
echo; echo "## 3. adversarial: status says not running, but a live listener holds the session socket"
echo absent > "$BASE/mode"
python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(8);time.sleep(240)' "$BASE/s.sock" & L=$!
sleep 1; drive
echo "started servers: $(cat "$BASE/started" 2>/dev/null | wc -l | tr -d " ")"
kill "$L" 2>/dev/null; L=
echo; echo "## 4. printed read-only inspect command against the REAL herdr client, through the lab helper (a session with no server)"
echo "\$ bin/fm-herdr-lab.sh run <session> status --json | jq -c '.server|{status,running}'"
bin/fm-herdr-lab.sh run "$SES" status --json 2>&1 | jq -c '.server|{status,running}'
echo "real client still reports no server for this name: $(bin/fm-herdr-lab.sh run "$SES" status --json 2>/dev/null | jq -r .server.running)"
echo; echo "## 5. retry once status is readable and the server is live: ensure accepts and starts nothing"
echo live > "$BASE/mode"; drive | head -1
echo "started servers: $(cat "$BASE/started" 2>/dev/null | wc -l | tr -d " ")"
echo; echo "## 6. lab provisioning attempt (would give a real server)"
echo "\$ bin/fm-herdr-lab.sh prepare <session>"; bin/fm-herdr-lab.sh prepare "$SES" 2>&1 | sed "s/$SES/<session>/g" | cut -c1-200; echo "exit=${PIPESTATUS[0]}"
} > "$EV/herdr-server-start-live-protection.txt" 2>&1
