#!/usr/bin/env bash
# Usage: driver.sh <worktree> <evidence-dir> <case>...   case := id|harness|model|effort|login|nologin
# Real fm-spawn + real tmux + real treehouse in a disposable lab home. Fake sentinels only.
set -u
WT=$1 EV=$2; shift 2
cd "$WT" || exit 1
eval "$(bin/fm-lab-home.sh env)" 2> /tmp/fm-env-live/lab-env.txt
LAB=$FM_HOME TDIR=$TMUX_TMPDIR
echo "lab=$LAB tmuxdir=$TDIR"
ROOT_ORIG=$PWD
teardown() {
  [ -z "${PROVIDER_PID:-}" ] || kill "$PROVIDER_PID" 2>/dev/null
  env -u TMUX TMUX_TMPDIR="$TDIR" tmux -L fm-lab kill-server 2>/dev/null
  env -u TMUX TMUX_TMPDIR="$TDIR" tmux kill-server 2>/dev/null
  sleep 2
  "$ROOT_ORIG/bin/fm-lab-home.sh" teardown "$LAB" && { chmod -R u+w "$LAB"; rm -rf "$LAB"; }
  echo "teardown rc=$? lab-exists=$([ -e "$LAB" ] && echo yes || echo no) leftover-procs=$(pgrep -f "$LAB" | wc -l | tr -d ' ')"
}
trap teardown EXIT
mkdir -p "$LAB/treehouse" "$LAB/claude" "$LAB/worktree-tmp"
printf 'tmux\n' > "$LAB/config/backend"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'teamclaude\n' > "$LAB/config/claude-launcher"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
printf '{"hasCompletedOnboarding":true,"theme":"dark","autoUpdates":false}\n' > "$LAB/claude/.claude.json"
printf '{"disabledMcpjsonServers":["graft"],"enableAllProjectMcpServers":false,"apiKeyHelper":"echo sk-ant-fm-lab-synthetic"}\n' > "$LAB/claude/settings.json"
[ -z "${DRIVER_ALLOWLIST:-}" ] || printf '%s\n' $DRIVER_ALLOWLIST > "$LAB/config/launch-env-allowlist"
# project with lab-private origin
seed=$(mktemp -d "$LAB/seed.XXXX"); git -C "$seed" init -q -b main
printf '# notes\nLab project.\n' > "$seed/README.md"; cp /tmp/fm-env-live/probe.py "$seed/probe.py"
git -C "$seed" add -A; git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$LAB/origin.git"; rm -rf "$seed"
git clone -q "$LAB/origin.git" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
# Clean base plus fake sentinels: the tmux server hands these to every pane.
base=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" PATH="$PATH" SHELL="${DRIVER_SHELL:-/bin/zsh}" TERM=xterm-256color
  LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" TMUX_TMPDIR="$TDIR" TREEHOUSE_ROOT="$LAB/treehouse" FM_BACKEND=tmux FM_HOME="$LAB" DISABLE_AUTOUPDATER=1
  CLAUDE_CONFIG_DIR="$LAB/claude" JAVA_HOME=/synthetic/jdk PYTHONPATH=/synthetic/pythonpath VIRTUAL_ENV=/synthetic/venv NODE_OPTIONS=--no-warnings)
fakes=(FM_TEST_FAKE_API_KEY=sentinel-not-a-secret FM_TEST_FAKE-BAD=sentinel-not-a-secret GEMINI_API_KEY=sentinel-not-a-secret
  LINEAR_API_KEY=sentinel-not-a-secret TAC_HMAC_KEY=sentinel-not-a-secret VERCEL_TOKEN=sentinel-not-a-secret _SECRETS_LOADED=1
  OPENAI_API_KEY=sentinel-not-a-secret ANTHROPIC_API_KEY=sentinel-not-a-secret ANTHROPIC_AUTH_TOKEN=sentinel-not-a-secret)
lab_run() { "$ROOT_ORIG/bin/fm-proc-budget.sh" --own-procs 128 -- env -i "${base[@]}" "${fakes[@]}" "$@"; }
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TDIR" tmux "$@"; }
if [ -n "${DRIVER_SYNTH_OMP:-}" ]; then
  mkdir -p "$LAB/os-home/.omp/run/daemons" "$LAB/os-home/.omp/agent" "$LAB/os-home/.omp/logs" "$LAB/agent"; chmod 700 "$LAB/os-home/.omp/run"; : > "$LAB/os-home/.zshrc"
  python3 /tmp/fm-env-live/provider.py "$LAB" > "$LAB/provider.out" 2>&1 &
  PROVIDER_PID=$!
  for _ in $(seq 1 50); do [ -s "$LAB/port" ] && break; sleep 0.2; done
  printf 'setupVersion: 2\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' > "$LAB/agent/config.yml"
  printf 'providers:\n  native:\n    baseUrl: http://127.0.0.1:%s/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: gpt-6.1-sol\n        contextWindow: 200000\n        maxTokens: 4096\n' "$(cat "$LAB/port")" > "$LAB/agent/models.yml"
  if [ "$DRIVER_SYNTH_OMP" = dotenv ]; then
    printf 'GEMINI_API_KEY=sentinel-not-a-secret\nFM_TEST_FAKE_HOME_DOTENV_KEY=sentinel-not-a-secret\n' > "$LAB/os-home/.env"
    printf 'FM_TEST_FAKE_AGENT_DOTENV_KEY=sentinel-not-a-secret\n' > "$LAB/agent/.env"
  fi
  base+=(HOME="$LAB/os-home" PI_CODING_AGENT_DIR="$LAB/agent")
fi
if [ -n "${DRIVER_SYNTH_DSH:-}" ]; then
  mkdir -p "$LAB/shim"
  python3 /tmp/fm-env-live/provider_anthropic.py "$LAB" > "$LAB/provider.out" 2>&1 &
  PROVIDER_PID=$!
  for _ in $(seq 1 50); do [ -s "$LAB/port" ] && break; sleep 0.2; done
  REAL_DSH_TUI=$(command -v dsh-tui)
  printf '#!/bin/sh\nDEEPSEEK_BASE_URL=http://127.0.0.1:%s/anthropic; export DEEPSEEK_BASE_URL\nexec %s "$@"\n' "$(cat "$LAB/port")" "$REAL_DSH_TUI" > "$LAB/shim/dsh-tui"
  chmod +x "$LAB/shim/dsh-tui"
  fakes+=(DEEPSEEK_API_KEY=sentinel-not-a-secret)
  base+=(PATH="$LAB/shim:$PATH")
fi
lab_run tmux -f /dev/null new-session -d -s firstmate -n lab -x 200 -y 50 -c "$LAB" || { echo "no tmux server"; exit 1; }
lab_tmux set-option -g default-shell "${DRIVER_SHELL:-/bin/zsh}" 2>/dev/null
overall=0
# Positive control: a plain lab pane with no fm-spawn boundary must hold the fakes.
ctl="$LAB/control-probe.json"
lab_tmux new-window -d -t firstmate: -n control -c "$LAB/projects/notes"
sleep 8
lab_tmux send-keys -t firstmate:control "python3 probe.py '$ctl' control nologin >/dev/null 2>&1" Enter
for _ in $(seq 1 30); do [ -s "$ctl" ] && break; sleep 1; done
if [ -s "$ctl" ]; then cp "$ctl" "$EV/live-control-unbounded-pane-probe.json"; echo "control: captured"; else echo "control: FAILED"; overall=1; fi
lab_tmux kill-window -t firstmate:control 2>/dev/null
for spec in "$@"; do
  IFS='|' read -r id harness model effort login <<<"$spec"
  id="lab${id}$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  label=${spec%%|*}
  result="$LAB/data/$id/probe-result.json"
  ( cd "$LAB" && lab_run "$ROOT_ORIG/bin/fm-brief.sh" "$id" notes --scout ) > "$EV/live-$label-brief.log" 2>&1 || { echo "$label: brief failed"; cat "$EV/live-$label-brief.log"; overall=1; continue; }
  TASK="Runtime verification only. Use your shell tool once without changing directory to run exactly this command from your current working directory, then stop: python3 probe.py '$result' '$id' $login" \
    python3 - "$LAB/data/$id/brief.md" <<'PY'
import os, sys
path = sys.argv[1]; t = open(path).read(); task = os.environ["TASK"]
t = t.replace("{TASK}", task, 1).replace("{FIRSTMATE_SPEC}", "Run the one command named in the task with your shell tool. Do not run any other command. Do not edit files. Do not delegate. When it prints that the probe finished, end your turn.", 1)
t = t.replace("\n### Out of scope\n", "\n### Out of scope\nEverything other than the one command.\n", 1)
for k, v in {"{DOD_CAPABILITY}": "The named command ran once.",
             "{DOD_MANDATORY_ITEMS}": "M1 Source: the task. Expected: the probe result file exists. Verify: the command prints that it finished. Edge/negative: no other command runs. Evidence place: the result file. Authority: agent",
             "{DOD_SUPPORTING_ITEMS}": "None.", "{DOD_HARD_GATES}": "Run only the named command.",
             "{DOD_HONESTY_RULE}": "Report what the command printed."}.items():
    t = t.replace(k, v, 1)
open(path, "w").write(t)
PY
  args=(--scout --harness "$harness"); [ -z "$model" ] || args+=(--model "$model"); [ -z "$effort" ] || args+=(--effort "$effort")
  case "$harness" in *'{RESULT}'*) h=${harness//\{RESULT\}/$result}; h=${h//\{ID\}/$id}; h=${h//\{LAB\}/$LAB}; args=(--scout --harness "$h") ;; esac
  if [ -n "${DRIVER_SYNTH_OMP:-}${DRIVER_SYNTH_DSH:-}" ]; then printf '%s probe.py %q %q nologin\n' "$(python3 -c 'import sys;print(sys.executable)')" "$result" "$id" > "$LAB/cmd.txt"; fi
  started=$(date +%s)
  ( cd "$LAB" && lab_run "$ROOT_ORIG/bin/fm-spawn.sh" "$id" "$LAB/projects/notes" "${args[@]}" ) > "$EV/live-$label-spawn.log" 2>&1
  rc=$?
  echo "$label: id=$id spawn rc=$rc after $(( $(date +%s) - started ))s"
  if [ "$rc" -ne 0 ]; then tail -5 "$EV/live-$label-spawn.log" | cut -c1-400; overall=1; continue; fi
  window=$(sed -n 's/^window=//p' "$LAB/state/$id.meta" 2>/dev/null)
  sed -n '/^kind=\|^harness=\|^launch_proof=\|^api_key=/p' "$LAB/state/$id.meta" | cut -c1-120
  deadline=$(( $(date +%s) + ${DRIVER_WAIT:-300} ))
  until [ -s "$result" ] || [ "$(date +%s)" -ge "$deadline" ]; do
    if lab_tmux capture-pane -p -t "${window:-firstmate:fm-$id}" 2>/dev/null | grep -q 'New MCP server found'; then lab_tmux send-keys -t "${window:-firstmate:fm-$id}" Enter; fi
    sleep 3
  done
  lab_tmux capture-pane -p -J -S -80 -t "${window:-firstmate:fm-$id}" > "$EV/live-$label-pane.txt" 2>&1
  [ -z "${DRIVER_SYNTH_OMP:-}${DRIVER_SYNTH_DSH:-}" ] || cp "$LAB/provider.log" "$EV/live-$label-provider.log" 2>/dev/null
  if [ -s "$result" ]; then
    cp "$result" "$EV/live-$label-probe.json"; echo "$label: probe result captured"
  else
    echo "$label: NO probe result within wait"; overall=1
  fi
  if grep -q 'sentinel-not-a-secret' "$EV/live-$label-pane.txt"; then echo "$label: SENTINEL IN PANE TEXT"; overall=1; fi
  tail -15 "$EV/live-$label-pane.txt" | cut -c1-150
  lab_tmux kill-window -t "${window:-firstmate:fm-$id}" 2>/dev/null
done
exit "$overall"
