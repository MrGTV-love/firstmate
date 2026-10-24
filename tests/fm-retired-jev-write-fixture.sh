#!/usr/bin/env bash
# Shared fixture for the retirement tests of the removed Jev write-content
# decisions. Source it after tests/lib.sh, then call rjw_setup.
#
# rjw_setup <tmp-prefix> [up|down|label-only] starts a loopback TypeSafe fake
# that would refuse every judged action (every Noul 0.99, every Choice its most
# dangerous key with confidence 1), or that answers HTTP 503 when down.
# label-only scores the write credential Noul 0.05, so only a Choice label can
# refuse a write. It creates a
# Firstmate-scoped home whose key reaches that fake and a task repository with
# the per-task Git hooks installed, as a fleet launch would.
#
# rjw_hook <payload> runs the Claude pre-tool hook, setting rjw_out and
# rjw_status. rjw_write <path> <content-file> sends a Write payload.
# rjw_requests prints how many judgments reached the fake.
# rjw_commit <message> commits through the task hooks, setting rjw_out and
# rjw_status.

rjw_setup() {
  local mode=${2:-up}
  unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND JEV_LEVEL_CONFIG
  unset FM_JEV_GUARD_BASE_URL GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
  unset FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
  export FM_FRICTION_EXECUTION_KIND=test
  RJW_TMP=$(fm_test_tmproot "$1")
  export FM_GUARD_EVENT_LOG="$RJW_TMP/guard-events.jsonl"
  RJW_HOME="$RJW_TMP/home"
  RJW_WT="$RJW_TMP/worktree"
  RJW_HOOKS="$RJW_TMP/task.git-hooks"
  mkdir -p "$RJW_HOME/config" "$RJW_HOME/state" "$RJW_HOME/data/t1"
  printf 'TYPESAFE_API_KEY=%s\n' fm-retired-jev-write-test-key >"$RJW_HOME/.env"
  RJW_HOOK_ARGS=("$RJW_HOME" "$RJW_HOME/config" "$RJW_HOME/state" t1 "$RJW_WT" "$RJW_HOME/data/t1" firstmate FIRSTMATE_JEV_GUARD_V1)
  fm_git_identity 'Retirement Tests' 'fixture@example.invalid'
  fm_git_init_commit "$RJW_WT"
  "$ROOT/bin/fm-git-strip-ai-trailers.sh" install "$RJW_HOOKS" "$RJW_WT" || fail "task hooks did not install"

  cat >"$RJW_TMP/fake.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile, mode] = process.argv.slice(2);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    appendFileSync(log, 'request\n');
    if (mode === 'down') { res.statusCode = 503; res.end('unavailable'); return; }
    const request = JSON.parse(body);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') { answers[id] = { type: 'noul', noul: mode === 'label-only' && id === 'contains_secret' ? 0.05 : 0.99 }; continue; }
      const keys = Object.keys(q.criteria);
      const pick = ['secrets', 'irreversible'].find(k => keys.includes(k)) ?? keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])) };
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
JS
  RJW_REQUESTS="$RJW_TMP/requests.log"
  : >"$RJW_REQUESTS"
  node "$RJW_TMP/fake.mjs" "$RJW_REQUESTS" "$RJW_TMP/port" "$mode" &
  RJW_FAKE_PID=$!
  trap 'kill "$RJW_FAKE_PID" 2>/dev/null; fm_test_cleanup' EXIT
  for _ in $(seq 1 100); do [ -s "$RJW_TMP/port" ] && break; sleep 0.05; done
  [ -s "$RJW_TMP/port" ] || fail "fake TypeSafe endpoint did not start"
  FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$RJW_TMP/port")/v1/systemone"
  export FM_JEV_GUARD_BASE_URL
}

rjw_hook() {  # <payload>
  rjw_out=$(printf '%s' "$1" | "$ROOT/bin/fm-jev-guard-hook.sh" "${RJW_HOOK_ARGS[@]}" 2>"$RJW_TMP/hook.err")
  rjw_status=$?
}

rjw_write() {  # <path> <content-file>
  rjw_hook "$(jq -cn --arg cwd "$RJW_WT" --arg path "$1" --rawfile content "$2" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:$path,content:$content},tool_use_id:"retired-write"}')"
}

rjw_shell() {  # <command>
  rjw_hook "$(jq -cn --arg cwd "$RJW_WT" --arg command "$1" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command},tool_use_id:"retired-shell"}')"
}

rjw_denied() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$rjw_out" >/dev/null 2>&1; }

rjw_requests() { wc -l <"$RJW_REQUESTS" | tr -d ' '; }

rjw_commit() {  # <message>
  rjw_out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$RJW_HOOKS" \
    git -C "$RJW_WT" commit -qm "$1" 2>&1)
  rjw_status=$?
}

# The admitted write must leave the hook silent, start no judgment, and leave
# the shell judge (the control below) as the only thing that reached the fake.
rjw_assert_admitted() {  # <label>
  [ "$rjw_status" -eq 0 ] || fail "$1: hook exited $rjw_status"
  [ -z "$rjw_out" ] || fail "$1: hook still refused or commented: $rjw_out"
  [ "$(rjw_requests)" -eq 0 ] || fail "$1: write content reached the model judge"
}

# Control: the same fake still refuses a shell command, so the zero-request
# write admissions above were not a dead endpoint or an inactive service.
rjw_assert_shell_judge_live() {
  rjw_shell 'rm -rf retired-fixture'
  [ "$rjw_status" -eq 0 ] || fail "shell control exited $rjw_status"
  rjw_denied || fail "shell control was not refused by the same fake judge: $rjw_out"
  [ "$(rjw_requests)" -ge 1 ] || fail "shell control never reached the fake judge"
}
