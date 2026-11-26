#!/usr/bin/env bash
# Live Herdr-lab proof of the descendant walk (bin/backends/herdr.sh
# fm_backend_herdr_pane_process_state_sample) with real Herdr, real ps and real processes.
# Cases, each in its own lab pane with the pane shell in the foreground:
#   suspended-omp : the INSTALLED omp-promax Bun omp started then suspended with Ctrl-Z (alive descendant)
#   bun-then-agent: a Bun job on an absolute .../src/cli.ts (may be omp) started first, then a process named omp
#   bun-only      : only that Bun job
#   foreign-bun   : a Bun job on a non-cli.ts script (positively another program)
#   empty         : no descendants (agent-free shell)
# Usage: herdr-lab-descendant-walk.sh <worktree-root> <base-commit>
set -u
ROOT=$1 BASE=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_PATH=$PATH
SESSION=$("$HELPER" name walk) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-walk.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
OWNED=0 OWN_PIDS=
cleanup() {
  printf '\n=== teardown\n'
  [ "$OWNED" = 1 ] && PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" && echo "herdr lab $SESSION torn down"
  sleep 3; left=
  for p in $OWN_PIDS; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  echo "lab job PIDs recorded: ${OWN_PIDS:-none}; still alive after teardown:${left:- none}"
  rm -rf "$TMP" && echo "scratch removed"
}
trap cleanup EXIT
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE
"$HELPER" prepare "$SESSION" >/dev/null || exit 1; OWNED=1
"$HELPER" provision "$SESSION" >/dev/null || exit 1
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$TMP/base" "$TMP/x/src" "$TMP/home"; git -C "$ROOT" archive "$BASE" bin | tar -x -C "$TMP/base"
printf 'setInterval(() => {}, 1 << 30);\n' > "$TMP/x/src/cli.ts"; cp "$TMP/x/src/cli.ts" "$TMP/x/server.ts"
cp /bin/sleep "$TMP/omp"
export FM_LAB_REAL_PATH="$REAL_PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;; *) args+=("$1"); shift ;; esac
done
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP/fakebin/herdr"; export PATH="$TMP/fakebin:$REAL_PATH"
BUN="$HOME/.bun/bin/bun"
NENV="env HOME=$TMP/home OMP_SKIP_SETUP=1 OPENAI_API_KEY=fm-non-submitting-fixture"
sample() { # <rev-root> <pane>
  ( . "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_process_state_sample "$SESSION" "$2" )
}
for case in ${WALK_CASES:-bun-then-agent foreign-bun agent-only}; do
  ws=$(run workspace create --cwd "$TMP" --label "walk-$case" | jq -r '.result.workspace.workspace_id')
  pane=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
  for _ in $(seq 1 120); do
    run pane process-info --pane "$pane" | jq -e '.result.process_info | (.foreground_processes|length)==1 and .foreground_processes[0].pid==.shell_pid' >/dev/null 2>&1 && break
    sleep 0.5
  done
  sleep 2
  case "$case" in
    agent-only)
      run pane send-text "$pane" "$TMP/omp 600 &" >/dev/null; run pane send-keys "$pane" Enter >/dev/null; sleep 4 ;;
    suspended-omp)
      # A background job: the shell keeps the foreground and the Bun omp stays a live (tty-stopped) descendant.
      run pane send-text "$pane" "$NENV $HOME/.local/share/omp-promax-fix/omp-promax --no-session &" >/dev/null
      run pane send-keys "$pane" Enter >/dev/null; sleep 8 ;;
    bun-then-agent)
      run pane send-text "$pane" "$BUN $TMP/x/src/cli.ts & sleep 1; $TMP/omp 600 &" >/dev/null; run pane send-keys "$pane" Enter >/dev/null; sleep 6 ;;
    bun-only)
      run pane send-text "$pane" "$BUN $TMP/x/src/cli.ts &" >/dev/null; run pane send-keys "$pane" Enter >/dev/null; sleep 3 ;;
    foreign-bun)
      run pane send-text "$pane" "$BUN $TMP/x/server.ts &" >/dev/null; run pane send-keys "$pane" Enter >/dev/null; sleep 3 ;;
    empty) sleep 1 ;;
  esac
  info=$(run pane process-info --pane "$pane" | jq -c '.result.process_info')
  shell=$(printf '%s' "$info" | jq -r '.shell_pid')
  printf '\n=== %s (pane %s)\n' "$case" "$pane"
  echo "Herdr foreground: $(printf '%s' "$info" | jq -c '[.foreground_processes[] | {pid,name}]')"
  echo "real descendant tree of shell $shell (pid ppid stat comm):"
  ps -axo pid=,ppid=,stat=,comm= | awk -v s="$shell" '{p[$1]=$2; l[$1]=$0} END {for (k in p) {x=p[k]; while (x && x!=1) {if (x==s) {print l[k]; break}; x=p[x]}}}' | sort -n | cut -c1-160
  OWN_PIDS="$OWN_PIDS $(ps -axo pid=,ppid= | awk -v s="$shell" '{p[$1]=$2} END {for (k in p) {x=p[k]; while (x && x!=1) {if (x==s) {print k; break}; x=p[x]}}}' | tr '\n' ' ')"
  echo "pane screen tail:"; run pane read "$pane" --format text 2>/dev/null | grep -v '^\s*$' | tail -4 | cut -c1-160
  echo "BASE sample: $(sample "$TMP/base" "$pane")"
  echo "HEAD sample: $(sample "$ROOT" "$pane")"
done
