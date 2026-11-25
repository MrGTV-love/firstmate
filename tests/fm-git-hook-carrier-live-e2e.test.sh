#!/usr/bin/env bash
# Live guard for the task Git hook carrier inside a real harness's tool shell
# (live-harness-optin family).
#
# bin/fm-spawn.sh selects the config carrier (GIT_CONFIG_PARAMETERS hook rows)
# only for harnesses listed in GIT_HOOKS_CONFIG_HARNESSES, because a selector in
# the launch shell cannot see whether the harness later drops the variable when
# it builds a tool shell. This guard is the proof for one harness: the real
# launch text fm-spawn stages is replayed in a private tmux pane with the real
# harness binary first on PATH, and a private scripted provider on loopback
# makes the harness run one Bash tool call that drives git in the task
# worktree. The verdict is read from effects only: HEAD, the bare remote's refs,
# the commit body and git's GIT_TRACE of which hook commands ran.
#
# Cases, per installed harness this guard can drive offline (claude over the
# Anthropic Messages API; omp and codex over the OpenAI Responses API), each on the
# carrier fm-spawn must select for it (expected_carrier below):
#   carrier  - the worker's tool shell refuses a credential commit and a
#              --no-verify credential push, lands a clean commit and push, and
#              strips an AI trailer; GIT_TRACE shows the carrier's hooks.
#   control  - the same launch through a fixture wrapper that removes the
#              carrier's variables at the harness boundary: the credential
#              commit and the trailer land, so the carrier case is not vacuous.
# An absent harness is reported by name; a run that checked none fails.
# No model tokens are spent and no operator credential store is touched: the
# harness config directory is a scratch one with a throwaway key.
# Refresh docs/verification/runtime-backends.md ("Task Git hook carrier in the
# worker tool shell") from this guard's output after any harness upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

fm_live_gate opt-in FM_GIT_HOOK_CARRIER_LIVE tmux python3 jq curl

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS FM_GIT_HOOK_ROWS CLAUDECODE TMUX
REAL_TMUX=$(command -v tmux)
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=${NODE_DIR%/*}
LAB=$(fm_test_tmproot fm-git-hook-carrier-live) || fail "no lab directory"
SOCKET="fm-carrier-live-$$"
PROVIDER_PID=
live_cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || :
  [ -z "$PROVIDER_PID" ] || kill "$PROVIDER_PID" 2>/dev/null || :
  rm -rf /tmp/fm-carrier-live-*-"$$" /tmp/fm-carrier-live-*-"$$"+* 2>/dev/null || :
  chmod -R u+w "$LAB" 2>/dev/null || :
  fm_test_cleanup
}
trap live_cleanup EXIT

python3 -I "$ROOT/tests/fm-git-hook-carrier-live-provider.py" "$LAB" > "$LAB/provider.out" 2>&1 &
PROVIDER_PID=$!
fm_test_wait_until --while-alive "$PROVIDER_PID" -- test -s "$LAB/port" || fail "private provider did not start"
BASE_URL="http://127.0.0.1:$(cat "$LAB/port")"
KEY=sk-ant-fm-carrier-live-throwaway-key

# The probe the harness's Bash tool runs: <obs-dir> <worktree> <origin> <branch>.
cat > "$LAB/probe.sh" <<'SH'
#!/bin/sh
obs=$1 wt=$2 origin=$3 branch=$4
mkdir -p "$obs"
emit() { printf '%s=%s\n' "$1" "$2" >> "$obs/result"; }
cd "$wt" || exit 9
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
git checkout -q "$branch" 2>/dev/null || git checkout -q -b "$branch"
subject() { git log -1 --format=%s; }
landed() { if [ "$(subject)" = "$1" ]; then echo landed; else echo refused; fi; }
remote_has() { if git --git-dir="$origin" rev-parse -q --verify "refs/heads/$1" >/dev/null; then echo yes; else echo no; fi; }
emit confinement "${FM_WRITE_CONFINEMENT-none}"
emit gcp_rows "$(printf '%s' "${GIT_CONFIG_PARAMETERS-}" | grep -o "'hook.fm-scan-commit.event'" | wc -l | tr -d ' ')"
emit hookspath "$(git config --show-scope --get core.hooksPath | tr '\t' ' ')"
cred=$(printf 'AKIA%s' ZZZZZZZZZZZZZZZZ)
printf '%s\n' "$cred" > leak; git add leak
GIT_TRACE="$obs/trace.cred" git commit -q -m leak 2>/dev/null
emit cred_commit "$(landed leak)"
[ "$(subject)" != leak ] || git reset -q --hard HEAD~1
git reset -q --hard HEAD; git clean -qfd
printf 'w\n' > w; git add w
GIT_TRACE="$obs/trace.clean" git commit -q -m clean -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
emit clean_commit "$(landed clean)"
emit clean_trailer "$(git log -1 --format=%B | grep -ci co-authored-by)"
GIT_TRACE="$obs/trace.push" git push -q origin "HEAD:refs/heads/probe-clean" 2>/dev/null
emit clean_push "$(remote_has probe-clean)"
printf '%s\n' "$cred" > leak2; git add leak2; git commit -q --no-verify -m leak2
git push -q origin "HEAD:refs/heads/probe-credpush" 2>/dev/null
emit cred_push "$(remote_has probe-credpush)"
emit done yes
SH
chmod +x "$LAB/probe.sh"

# The carrier each harness must get, as recorded in
# docs/verification/runtime-backends.md. Admitting a harness to the config
# carrier changes both fm-spawn's list and this expectation, so the guard fails
# whenever spawn selects anything else.
expected_carrier() {
  case "$1" in
    claude) printf 'config\n' ;;
    *) printf 'legacy\n' ;;
  esac
}

# run_case <harness> <name> <extra-path-or-empty>: one real spawn's launch, replayed.
run_case() {
  local harness=$1 name=$2 extra_path=$3 dir home proj wt fakebin id cfg out status branch n pane_path
  local -a spawn_args=()
  PANE_EXTRA=()
  dir="$LAB/$harness-$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  cfg="$dir/claude"
  id="carrier-live-$harness-$name-$$"
  mkdir -p "$dir" "$cfg" "$dir/os-home"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "fixture-$harness-$name"
  case "$harness" in
    claude)
      # Trusted as an operator's store already trusts them: the task copy, and
      # the home and checkout the launch adds with --add-dir.
      jq -n --arg key "${KEY: -20}" --arg wt "$wt" --arg wtreal "$(cd "$wt" && pwd -P)" \
        --arg home "$home" --arg homereal "$(cd "$home" && pwd -P)" --arg root "$ROOT" \
        '{hasCompletedOnboarding:true,theme:"dark",numStartups:5,bypassPermissionsModeAccepted:true,
          customApiKeyResponses:{approved:[$key],rejected:[]},
          projects:{($wt):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
                    ($wtreal):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
                    ($home):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
                    ($homereal):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
                    ($root):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true}}}' > "$cfg/.claude.json"
      printf '{"skipDangerousModePermissionPrompt":true}\n' > "$cfg/settings.json"
      spawn_args=(--allow-api-key)
      ;;
    omp)
      # The launch pins the agent directory below the spawn-time HOME.
      mkdir -p "$home/user-home/.omp/agent"
      printf 'setupVersion: 2\nmodelRoles:\n  default: native/carrier-probe\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n' \
        > "$home/user-home/.omp/agent/config.yml"
      printf 'providers:\n  native:\n    baseUrl: %s/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: carrier-probe\n        contextWindow: 200000\n        maxTokens: 4096\n' \
        "$BASE_URL" > "$home/user-home/.omp/agent/models.yml"
      ;;
    codex)
      # A scratch CODEX_HOME whose only provider is the private loopback one,
      # with the task copy trusted so no dialog stands before the brief.
      mkdir -p "$dir/codex-home"
      printf 'model = "carrier-probe"\nmodel_provider = "fmprobe"\n[model_providers.fmprobe]\nname = "fmprobe"\nbase_url = "%s/v1"\nwire_api = "responses"\n[projects."%s"]\ntrust_level = "trusted"\n' \
        "$BASE_URL" "$wt" > "$dir/codex-home/config.toml"
      [ "$(cd "$wt" && pwd -P)" = "$wt" ] ||
        printf '[projects."%s"]\ntrust_level = "trusted"\n' "$(cd "$wt" && pwd -P)" >> "$dir/codex-home/config.toml"
      PANE_EXTRA=(CODEX_HOME="$dir/codex-home")
      ;;
  esac
  : > "$dir/launch.log"
  out=$(
    [ "$harness" != claude ] || export FM_TEST_CLAUDE_CONFIG_DIR="$cfg"
    # A launch may name the harness by the absolute path spawn resolved, so the
    # control's wrapper must come first on spawn's PATH as well as the pane's.
    FM_FAKE_LAUNCH_LOG="$dir/launch.log" PATH="${extra_path:+$extra_path:}${HARNESS_BIN%/*}:$PATH" fm_test_run_spawn \
      "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --harness "$harness" ${spawn_args[@]+"${spawn_args[@]}"}
  )
  status=$?
  [ "$status" -eq 0 ] || fail "$harness $name: spawn failed: $out"
  branch=$(fm_meta_get "$home/state/$id.meta" branch)
  [ -n "$branch" ] || fail "$harness $name: spawn recorded no branch"
  printf '%s' "sh '$LAB/probe.sh' '$dir/obs' '$wt' '$proj.origin.git' '$branch'" > "$LAB/command"
  printf '%s' "$home/state/$id.git-hooks" > "$dir/hooks-path"
  cp "$dir/launch.log" "$dir/launch.sh"
  # Node-based harnesses (codex) need node on the pane PATH, as on an operator's.
  pane_path="${extra_path:+$extra_path:}${HARNESS_BIN%/*}${NODE_DIR:+:$NODE_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
  "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s "$harness-$name" -x 200 -y 50 -c "$wt" -- \
    env -i HOME="$dir/os-home" PATH="$pane_path" TERM=xterm-256color LANG=en_US.UTF-8 \
    ANTHROPIC_BASE_URL="$BASE_URL" ANTHROPIC_API_KEY="$KEY" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    DISABLE_AUTOUPDATER=1 ${PANE_EXTRA[@]+"${PANE_EXTRA[@]}"} /bin/bash --noprofile --norc -i || fail "$harness $name: cannot start the private tmux pane"
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$harness-$name" ". '$dir/launch.sh'" Enter
  for n in $(seq 1 240); do
    grep -qx done=yes "$dir/obs/result" 2>/dev/null && break
    sleep 0.5
  done
  CASE_PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$harness-$name" -S -60 2>/dev/null || true)
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$harness-$name" >/dev/null 2>&1 || :
  CASE_DIR=$dir
  grep -qx done=yes "$dir/obs/result" 2>/dev/null || {
    printf '%s\n' "$CASE_PANE" >&2
    tail -n 5 "$LAB/requests.jsonl" >&2 2>/dev/null
    fail "$harness $name: the harness never ran the probe through its shell tool ($VERSION)"
  }
}

obs() { sed -n "s/^$2=//p" "$1/obs/result" | tail -n 1; }
trace_has() { grep -F "run_command:" "$1/obs/trace.$2" 2>/dev/null | grep -qF "$3"; }

CHECKED=0
for HARNESS in claude omp codex; do
  HARNESS_BIN=$(command -v "$HARNESS" 2>/dev/null) || { printf 'skip: live: %s absent\n' "$HARNESS"; continue; }
  case "$HARNESS_BIN" in /*) ;; *) printf 'skip: live: %s is not an executable on PATH\n' "$HARNESS"; continue ;; esac
  VERSION="$HARNESS $("$HARNESS_BIN" --version 2>&1 | head -n 1)"
  printf '# live %s\n' "$VERSION"
  CARRIER=$(expected_carrier "$HARNESS")
  # The sensitivity control's injected fault, never used outside this fixture:
  # a harness wrapper that drops the selected carrier's variables at the
  # harness boundary.
  mkdir -p "$LAB/strip-$HARNESS"
  printf '#!/bin/sh\nexec env -u GIT_CONFIG_PARAMETERS -u FM_GIT_HOOK_ROWS -u GIT_CONFIG_COUNT %s "$@"\n' "$HARNESS_BIN" > "$LAB/strip-$HARNESS/$HARNESS"
  chmod +x "$LAB/strip-$HARNESS/$HARNESS"
  : > "$LAB/requests.jsonl"

  run_case "$HARNESS" carrier ''
  # The fleet write-confines claude and omp workers on macOS, and no other.
  case "$(uname -s):$HARNESS" in
    Darwin:claude | Darwin:omp)
      assert_equals seatbelt-v1 "$(obs "$CASE_DIR" confinement)" "$VERSION: the probe did not run under the fleet's write confinement" ;;
  esac
  grep -q '"tool_result": true' "$LAB/requests.jsonl" || fail "$VERSION: the harness never returned a shell tool result to the provider"
  assert_equals refused "$(obs "$CASE_DIR" cred_commit)" "$VERSION $CARRIER: a credential commit landed through the harness's tool shell"
  assert_equals landed "$(obs "$CASE_DIR" clean_commit)" "$VERSION $CARRIER: a clean commit was refused"
  assert_equals 0 "$(obs "$CASE_DIR" clean_trailer)" "$VERSION $CARRIER: an AI trailer reached the commit object"
  assert_equals yes "$(obs "$CASE_DIR" clean_push)" "$VERSION $CARRIER: a clean push did not land"
  assert_equals no "$(obs "$CASE_DIR" cred_push)" "$VERSION $CARRIER: a --no-verify credential push landed"
  if [ "$CARRIER" = config ]; then
    case "$(obs "$CASE_DIR" hookspath)" in
      *git-hooks*) fail "$VERSION: the tool shell runs the legacy carrier, not the config carrier" ;;
    esac
    assert_equals 1 "$(obs "$CASE_DIR" gcp_rows)" "$VERSION: the tool shell lost the hook rows"
    trace_has "$CASE_DIR" clean fm-scan-commit || fail "$VERSION: git did not run fm-scan-commit at commit"
    trace_has "$CASE_DIR" clean fm-strip || fail "$VERSION: git did not run fm-strip at commit"
    trace_has "$CASE_DIR" push fm-scan-push || fail "$VERSION: git did not run fm-scan-push at push"
  else
    assert_equals "command $(cat "$CASE_DIR/hooks-path")" "$(obs "$CASE_DIR" hookspath)" "$VERSION: the tool shell lost the legacy carrier"
    trace_has "$CASE_DIR" clean "$(cat "$CASE_DIR/hooks-path")/pre-commit" || fail "$VERSION: git did not run the task pre-commit hook"
    trace_has "$CASE_DIR" push "$(cat "$CASE_DIR/hooks-path")/pre-push" || fail "$VERSION: git did not run the task pre-push hook"
  fi
  pass "$VERSION: the $CARRIER carrier survives into the harness's shell tool; credential commit and --no-verify push refused, clean commit and push land, AI trailer stripped"

  : > "$LAB/requests.jsonl"
  run_case "$HARNESS" control "$LAB/strip-$HARNESS"
  assert_equals 0 "$(obs "$CASE_DIR" gcp_rows)" "control $VERSION: the wrapper did not remove the config carrier"
  case "$(obs "$CASE_DIR" hookspath)" in
    *git-hooks*) fail "control $VERSION: the wrapper did not remove the legacy carrier" ;;
  esac
  assert_equals landed "$(obs "$CASE_DIR" cred_commit)" "control $VERSION: a credential commit was refused with the carrier removed, so the carrier case proves nothing"
  assert_equals 1 "$(obs "$CASE_DIR" clean_trailer)" "control $VERSION: the trailer was stripped with the carrier removed"
  pass "control $VERSION: with the carrier removed at the harness boundary the credential commit and AI trailer land"
  CHECKED=$((CHECKED + 1))
done
[ "$CHECKED" -gt 0 ] || fail "no harness this guard can drive is installed; nothing was checked"

echo "# all fm-git-hook-carrier-live tests passed"
