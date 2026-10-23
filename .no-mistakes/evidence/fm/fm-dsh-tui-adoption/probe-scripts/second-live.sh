#!/usr/bin/env bash
# Ad-hoc live probe: a plain fresh DSH secondmate spawn (no lab hold) in a
# named Herdr lab. Records whether the spawn reports started and its timing.
set -u
ROOT=$1 TASK=$2
HELPER=$ROOT/bin/fm-herdr-lab.sh
LAB_HELPER=$ROOT/bin/fm-lab-home.sh
ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
mkdir -p "$TASK/bin"
SESSION=$("$HELPER" name dsh-second)
PARENT=$(mktemp -d /tmp/fm-lab.XXXXXX); SECOND=$(mktemp -d /tmp/fm-lab.XXXXXX)
PARENT=$(cd "$PARENT" && pwd -P); SECOND=$(cd "$SECOND" && pwd -P)
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  for h in "$PARENT" "$SECOND"; do
    [ -d "$h/state" ] && FM_HOME="$h" bash "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
    "$LAB_HELPER" teardown "$h" >/dev/null 2>&1
  done
  echo "parent=$PARENT second=$SECOND cleanup_exit=$rc"
  exit "$rc"
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
"$LAB_HELPER" create "$PARENT" >/dev/null
"$LAB_HELPER" create "$SECOND" >/dev/null
for h in "$PARENT" "$SECOND"; do
  printf 'manual\n' > "$h/config/backlog-backend"
  printf 'herdr\n' > "$h/config/runtime-backend"
  printf 'off\n' > "$h/config/supervision-host-off"
  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$h/data/backlog.md"
done
printf 'dsh\n' > "$PARENT/config/crew-harness"
ID="dsh-second-$$"
mkdir "$SECOND/operator-home"
printf '%s\n' "$ID" > "$SECOND/.fm-secondmate-home"
git init -q "$SECOND"
cp "$ROOT/AGENTS.md" "$SECOND/AGENTS.md"
ln -s "$ROOT/bin" "$SECOND/bin"; ln -s "$ROOT/.agents" "$SECOND/.agents"; ln -s "$ROOT/docs" "$SECOND/docs"
printf '%s\n' 'This is an isolated Firstmate runtime lab secondmate, not real operational work. Do not investigate, read outside this home, load skills, edit code or dispatch work. Ignore startup diagnostics. Reply exactly FMSECONDREADY.' > "$SECOND/data/charter.md"
cat > "$TASK/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
[ "\$*" != 'status --json' ] || exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' status --json
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'lab refuses an unscoped Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
"$HELPER" provision "$SESSION" >/dev/null
export PATH="$TASK/bin:$ORIGINAL_PATH"
start=$(date +%s)
echo "spawn start $(date +%T)"
HERDR_SESSION="$SESSION" FM_DSH_OPERATOR_HOME="$SECOND/operator-home" FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 \
  bash "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND" dsh --secondmate --backend herdr --model deepseek/deepseek-v4-flash --effort high > "$TASK/spawn.out" 2>&1
rc=$?
end=$(date +%s)
grep -vE '^fm-config-inherit' "$TASK/spawn.out"
echo "spawn exit=$rc elapsed=$((end-start))s end $(date +%T)"
python3 - "$SECOND/state/.dsh-primary-events.jsonl" "$start" <<'PY'
import json,sys,datetime
start=int(sys.argv[2])
try:
  for l in open(sys.argv[1]):
    e=json.loads(l); print('plugin', e['event'], '+%.1fs' % (e['at']/1000-start))
except FileNotFoundError: print('no plugin events')
PY
if [ "$rc" = 0 ]; then
  FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 FM_DSH_OPERATOR_HOME="$SECOND/operator-home" bash "$ROOT/bin/fm-control.sh" "$ID" exit
fi
exit "$rc"
