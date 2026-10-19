#!/usr/bin/env bash
# Portable routing, durable-state and structural identity regressions for dsh.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])
helper = root / 'bin/fm-dsh.py'
def call(*args, ok=True):
    result = subprocess.run([sys.executable, str(helper), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == ok, result.stderr
    return result.stdout.strip()
for model, provider, expected in [
    ('deepseek/deepseek-v4-flash', '', 'dsh'),
    ('v4-pro', 'deepseek', 'dsh'),
    ('claude-sonnet-4', '', 'claude'),
    ('openai-codex/gpt-6', '', 'omp'),
    ('my-deepseek/model', '', 'omp'),
    ('deepseekish/model', '', 'omp')]:
    assert call('route', model, provider) == expected
for harness, model, provider in [('omp','deepseek/v4',''), ('claude','v4','deepseek'), ('dsh','openai/gpt','')]:
    call('check', harness, model, provider, ok=False)
for harness in ('codex', 'pi', 'pi-signed', 'omp', 'claude'):
    call('check', harness, 'unchanged/model')
profiles = tmp / 'profiles.json'
profiles.write_text(json.dumps({'rules':[{'use':[{'harness':'dsh','provider':'deepseek','model':'v4','effort':'high'}]}]}))
call('normalize', profiles, profiles)
assert json.loads(profiles.read_text())['rules'][0]['use'][0]['model'] == 'deepseek/v4'
cwd = Path(tmp).resolve()
state = tmp / 'state'
state.mkdir()
runtime = state / 'task.dsh' / 's1'
store = runtime / 'dsh/sessions/workspace/session'
store.mkdir(parents=True)
header = {'type':'session','version':4,'id':'11111111-1111-4111-8111-111111111111','cwd':str(cwd),'delegationDepth':0}
log = store / 'session.v4.jsonl'
binding = {'root':str(runtime),'cwd':str(cwd),'generation':'s1','model':'v4','effort':'high'}
(state / 'task.dsh-session').write_text(json.dumps(binding))
def put(events, tail=''):
    log.write_text('\n'.join(json.dumps(event) for event in [header, *events]) + '\n' + tail)
start = {'type':'turn/start','seq':1}
end = {'type':'turn/end','seq':2}
put([start])
assert call('state', state, 'task') == 'busy'
put([start], '{"type":"turn/end","seq":2}')
assert call('state', state, 'task') == 'busy', 'torn append must not create idle'
put([start,end])
assert call('state', state, 'task') == 'idle'
assert call('session-file',state,'task') == str(log)
# The launch overlay replaces the stock profile patch's sessionId field, so
# resume must write it explicitly into the bound launch patch.
(runtime / 'launch.yml').write_text('[]\n')
assert call('resume',state,'task','deepseek/v4','high',cwd) == str(runtime)
overlay = json.loads((runtime / 'launch.yml').read_text())
assert overlay[0]['config']['sessionId'] == header['id']
assert call('resume',state,'task','deepseek/other','high',cwd) == '', 'a changed model must not resume'
assert call('resume',state,'task','deepseek/v4','xhigh',cwd) == '', 'a changed effort must not resume'
# Fallback: no binding means no recorded session id, and spawn prepares fresh.
missing_state = tmp / 'fresh-state'
missing_state.mkdir()
assert call('resume',missing_state,'task','deepseek/v4','high',cwd) == '', 'no binding must fall back quietly'
put([start, end, start])
assert call('state',state,'task') == 'unknown', 'nonmonotonic durable sequence is corrupt'
put([start,end])
child = runtime / 'dsh/sessions/workspace/child'
child.mkdir()
(child / 'session.v4.jsonl').write_text(json.dumps({**header,'delegationDepth':1,'id':'22222222-2222-4222-8222-222222222222'})+'\n')
assert call('state',state,'task') == 'idle', 'subagents do not own top-level activity'
# A relaunch opens a NEW depth-zero session in the same launch store, so the
# newest depth-zero log is the live one and the older one is history.
(child / 'session.v4.jsonl').write_text(json.dumps({**header,'id':'33333333-3333-4333-8333-333333333333'})+'\n'+json.dumps({**start,'seq':7})+'\n')
assert call('state',state,'task') == 'busy', 'a relaunched session owns activity'
assert call('session-file',state,'task') == str(child / 'session.v4.jsonl')
(child / 'session.v4.jsonl').unlink()
(store / 'session.v5.jsonl').write_text(json.dumps({**header,'version':5})+'\n')
assert call('state',state,'task') == 'unknown', 'new unsupported generation must not fall back'
print('ok - dsh route boundaries, contradiction refusal, provider normalization, durable transitions, torn append, relaunch-session selection and ambiguity')
PY
# shellcheck source=bin/fm-dsh-lib.sh
. "$ROOT/bin/fm-dsh-lib.sh"
fm_dsh_args_are_dsh 'node /opt/node_modules/@deepseek-ai/dsh/lib/bin.js --profile dsh-tui'
if fm_dsh_args_are_dsh 'node /tmp/unrelated.js /opt/node_modules/@deepseek-ai/dsh/lib/bin.js'; then
  echo 'the dsh script must occupy the interpreter argument slot' >&2
  exit 1
fi
if fm_dsh_args_are_dsh 'bash -c node /opt/node_modules/@deepseek-ai/dsh/lib/bin.js'; then
  echo 'a wrapped dsh script is not the pane foreground process' >&2
  exit 1
fi
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
dsh_frame_top="  ╭$(printf '─%.0s' $(seq 1 87))╮"
dsh_frame_bottom="  ╰$(printf '─%.0s' $(seq 1 87))╯"
dsh_row() {
  local text=" ❯ $1"
  printf '  ⌸%s%s⛶' "$text" "$(printf ' %.0s' $(seq 1 $((87 - ${#text}))))"
}
dsh_meter='   6.5k/1.0M 0.7%'
dsh_status="   deepseek-v4-fla… · hi… · cache 96.… ·  ≈\$0.0010 id ·  scratch-co…  ctx 0.7% (6.5k/1.0m)"
dsh_caps=$(printf 'styled=1\ncursor=0\nidentity=1')
dsh_verdict() { fm_composer_classify_screen "$dsh_caps" "$1" '' ''; }
dsh_empty=$(printf '%s\n' '  ❯ prior typed echo' "$dsh_frame_top" "$(dsh_row '')" "$dsh_frame_bottom" "$dsh_meter" "$dsh_status")
[ "$(dsh_verdict "$dsh_empty")" = empty ] || { echo "expected empty dsh composer, got $(dsh_verdict "$dsh_empty")" >&2; exit 1; }
dsh_draft=$(printf '%s\n' "$dsh_frame_top" "$(dsh_row 'fix the tests')" "$dsh_frame_bottom" "$dsh_meter" "$dsh_status")
[ "$(dsh_verdict "$dsh_draft")" = pending ] || { echo "expected pending dsh draft, got $(dsh_verdict "$dsh_draft")" >&2; exit 1; }
dsh_busy=$(printf '%s\n' "$dsh_empty" '   esc to interrupt')
[ "$(dsh_verdict "$dsh_busy")" = empty ] || { echo "expected empty dsh composer under its busy hint, got $(dsh_verdict "$dsh_busy")" >&2; exit 1; }
printf 'ok - dsh frame proves empty, typed draft, and busy-hint furniture\n'
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
[ "$(fm_control_interrupt_key dsh)" = Escape ]
[ "$(fm_control_exit_command dsh)" = /exit ]
printf 'ok - dsh executable-slot attribution and lifecycle capability contract\n'
