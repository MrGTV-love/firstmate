#!/usr/bin/env bash
# Live drive of the home extension's live-model record, per the repo runbook:
# a disposable lab home (bin/fm-lab-home.sh), the installed omp started as the
# session command on the lab's private tmux socket (-L fm-lab), run from the
# gate worktree so omp discovers the tracked .omp/extensions by itself.
# The model providers are scripted local HTTP servers (no tokens spent).
# Then a parent home's bin/fm-crew-state.sh reads that lab home's record
# for a secondmate task, the way a supervisor reads a secondmate lane.
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4HZH01Q50QVT91QE6CCTFYA
SERVER=${FM_EV_SERVER:?path to server.py}
cd "$ROOT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
SIDE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ev-side.XXXXXX")
labtmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
SERVER_PIDS=()
FAILS=0
cleanup() {
  local pid
  labtmux kill-server 2>/dev/null || true
  for pid in "${SERVER_PIDS[@]:-}"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$LAB" "$SIDE"
}
trap cleanup EXIT
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
expect() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! has "$1" "$2"; }
show() { sed "s|$LAB|<lab-home>|g; s|$SIDE|<side>|g; s|$ROOT|<repo>|g"; }
wait_for() {
  local limit=$1 ticks=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    ticks=$((ticks + 1)); [ "$ticks" -le $((limit * 4)) ] || return 1; sleep 0.25
  done
}
serve() {
  local name=$1
  printf '%s\n' "$2" > "$SIDE/$name.behavior"; : > "$SIDE/$name.log"
  python3 -I "$SERVER" "$SIDE/$name.behavior" "$SIDE/$name.log" "$SIDE/$name.port" &
  SERVER_PIDS+=("$!")
  wait_for 20 test -s "$SIDE/$name.port" || { bad "the scripted $name provider did not start"; exit 1; }
  printf -v "${name}_PORT" '%s' "$(cat "$SIDE/$name.port")"
}
requests() { wc -l < "$SIDE/$1.log" | tr -d ' '; }
REC="$LAB/state/.omp-live-model"
rec_has() { grep -qF -- "$1" "$REC" 2>/dev/null; }

serve codex limit
serve weak ok
AGENT="$SIDE/agent"
mkdir -p "$AGENT"
cat > "$AGENT/config.yml" <<YML
setupVersion: 2
retry:
  maxRetries: 2
  baseDelayMs: 100
  maxDelayMs: 300000
  fallbackRevertPolicy: never
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - deepseek/deepseek-v4-pro
YML
# shellcheck disable=SC2154
cat > "$AGENT/models.yml" <<YML
providers:
  openai-codex: {baseUrl: http://127.0.0.1:${codex_PORT}/v1, apiKey: lab}
  deepseek: {baseUrl: http://127.0.0.1:${weak_PORT}/v1, apiKey: lab}
YML
printf 'omp: %s\n' "$(omp --version | head -1)"

say "H1. A secondmate-style primary on Sol stops and its home record carries the error"
printf 'model=deepseek/deepseek-v4-pro\nerror=402 old run\n' > "$REC"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" \
  tmux -L fm-lab new-session -d -s primary -x 180 -y 50 -c "$PWD" -e FM_HOME="$LAB" \
  -e PI_CODING_AGENT_DIR="$AGENT" -e OMP_SKIP_SETUP=1 -e FM_OMP_HARNESS=omp \
  "omp --config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --model openai-codex/gpt-6.1-sol --thinking off 'Reply with the single word ack.'"
wait_for 90 test -e "$LAB/state/.omp-turnend-extension-loaded" || bad "omp did not load the tracked turn-end extension"
expect "omp discovered the tracked home extension" test -e "$LAB/state/.omp-turnend-extension-loaded"
wait_for 120 rec_has "error=This request" || wait_for 60 rec_has "error=ChatGPT" || bad "the home record never carried the run error"
printf 'provider requests:\n  codex (Sol):\n'; sed 's/^/    /' "$SIDE/codex.log"
printf '  weak (deepseek, the global chain target): %s requests\n' "$(requests weak)"
printf 'home record <lab-home>/state/.omp-live-model:\n'; sed 's/^/  /' "$REC"
printf 'primary pane (tail):\n'
labtmux capture-pane -p -t primary | grep -v '^[[:space:]]*$' | tail -8 | show | sed 's/^/  | /'
expect "the Sol route received the request" test "$(requests codex)" -ge 1
expect "the weak model received no request" test "$(requests weak)" -eq 0
expect "the home record names the Sol model" rec_has "model=openai-codex/gpt-6.1-sol"
expect "the home record carries the run error" rec_has "error=ChatGPT rate limit exceeded"
expect "the publisher replaced the seeded stale content on its first event (this lab primary is not launched by fm-spawn)" bash -c "! grep -q '402 old run' '$REC'"

say "H2. The parent supervisor's crew-state shows the secondmate's stop"
P="$SIDE/parent"
mkdir -p "$P/state" "$P/stubs" "$SIDE/mate-wt"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P/stubs/no-mistakes"; cp "$P/stubs/no-mistakes" "$P/stubs/gh"; chmod +x "$P/stubs/"*
printf '%s\n' "window=fm:fm-mate" "worktree=$SIDE/mate-wt" "kind=secondmate" "harness=omp" "home=$LAB" \
  "model=openai-codex/gpt-6.1-sol:high" > "$P/state/mate.meta"
printf 'working: reconciling routed items\n' > "$P/state/mate.status"
line=$(PATH="$P/stubs:$PATH" FM_STATE_OVERRIDE="$P/state" NM_HOME="$SIDE/nm-unused" TMUX_TMPDIR="$SIDE/no-tmux" "$ROOT/bin/fm-crew-state.sh" mate 2>&1)
printf '$ bin/fm-crew-state.sh mate   (meta: kind=secondmate harness=omp home=<lab-home> model=openai-codex/gpt-6.1-sol:high)\n  %s\n' "$(printf '%s' "$line" | show)"
expect "the line carries the secondmate's run-error" has "$line" "run-error: ChatGPT rate limit exceeded"
expect "the line carries no model-drift (thinking suffix aside, same model)" lacks "$line" "model-drift"

labtmux kill-server 2>/dev/null || true
printf '\n### RESULT: %s failed checks\n' "$FAILS"
exit "$FAILS"
