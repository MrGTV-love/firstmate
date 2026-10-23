#!/usr/bin/env bash
# Portable routing, durable-state and structural identity regressions for dsh.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])
helper = root / 'bin/fm-dsh.py'
def call(*args, ok=True, env=None):
    result = subprocess.run([sys.executable, str(helper), *map(str, args)], capture_output=True, text=True, env=env)
    assert (result.returncode == 0) == ok, result.stderr
    return result.stdout.strip()
def unknown(*args, check):
    out = call('state', *args)
    assert out.startswith('unknown: ') and check in out, f'expected unknown naming {check!r}, got {out!r}'
for model, provider, expected in [
    ('deepseek/deepseek-v4-flash', '', 'dsh'),
    ('v4-pro', 'deepseek', 'dsh'),
    ('claude-sonnet-4', '', 'claude'),
    ('openai-codex/gpt-6', '', 'omp'),
    ('my-deepseek/model', '', 'omp'),
    ('deepseekish/model', '', 'omp')]:
    assert call('route', model, provider) == expected
# DeepSeek is exclusive to dsh, including explicitly selected adapters.
for model, provider in [('', ''), ('openai/gpt', '')]:
    call('check', 'dsh', model, provider, ok=False)
call('check', 'dsh', 'deepseek/deepseek-v4-flash')
call('check', 'dsh', 'v4', 'deepseek')
# check admits exactly the models prepare accepts, so a relaunch is refused
# before the running agent stops rather than after.
for model, provider in [('deepseek/a/b', ''), ('deepseek/ ', ''), ('deepseek/', ''), ('', 'deepseek'), ('a b', 'deepseek'), ('x/y', 'deepseek')]:
    call('check', 'dsh', model, provider, ok=False)
for harness in ('codex', 'pi', 'pi-signed', 'omp', 'claude'):
    call('check', harness, 'unchanged/model')
    for model, provider in [('deepseek/deepseek-v4-flash', ''), ('v4', 'deepseek')]:
        call('check', harness, model, provider, ok=False)
fallback_profiles = tmp / 'fallback-profiles.json'
fallback_profiles.write_text(json.dumps({'rules':[{'fallback':[{'harness':'dsh','model':'deepseek/deepseek-v4-flash','effort':'high'}]}]}))
call('normalize', fallback_profiles, fallback_profiles)
assert json.loads(fallback_profiles.read_text())['rules'][0]['fallback'][0]['harness'] == 'dsh'
for harness in ('omp', 'opencode'):
    for model, provider in [('deepseek/deepseek-v4-flash', ''), ('v4', 'deepseek')]:
        contradictory = {'rules': [{'use': {'harness': harness, 'model': model, 'provider': provider}}]}
        fallback_profiles.write_text(json.dumps(contradictory))
        call('normalize', fallback_profiles, fallback_profiles, ok=False)
        assert json.loads(fallback_profiles.read_text()) == contradictory, 'refusal must not rewrite the profile'
# A malformed model or provider is left for the rules validator to report, and
# a model-less dsh profile is refused rather than normalized.
malformed = tmp / 'malformed-profiles.json'
raw = {'rules':[{'use':{'harness':'dsh','model':None},'fallback':[{'harness':'omp','model':7,'provider':['deepseek']}]}]}
malformed.write_text(json.dumps(raw))
call('normalize', malformed, malformed)
assert json.loads(malformed.read_text()) == raw
modelless = tmp / 'modelless-profiles.json'
modelless.write_text(json.dumps({'rules':[{'use':{'harness':'dsh','provider':'deepseek','model':''}}]}))
call('normalize', modelless, modelless, ok=False)
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
unknown(state, 'task', check='no depth-zero dsh session log yet')
log.write_text(json.dumps(header) + '\n')
unknown(state, 'task', check='no turn/start or turn/end yet')
put([start])
assert call('state', state, 'task') == 'busy'
put([start], '{"type":"turn/end","seq":2}')
assert call('state', state, 'task') == 'busy', 'torn append must not create idle'
put([start,end])
assert call('state', state, 'task') == 'idle'
assert call('session-file',state,'task') == str(log)
# A resumed launch already holds the earlier conversation, so the start proof
# is a turn that began beyond the position taken before launch.
where = call('position',state,'task')
assert json.loads(where) == [str(log), 2]
unknown(state,'task','--since',where, check='no turn started beyond the launch position')
put([start,end,{'type':'turn/start','seq':3}])
assert call('state',state,'task','--since',where) == 'busy'
put([start,end,{'type':'turn/start','seq':3},{'type':'turn/end','seq':4}])
assert call('state',state,'task','--since',where) == 'idle', 'a turn that already finished still proves the brief ran'
assert call('state',state,'task','--since','{').startswith('unknown: '), 'an unreadable position must not pass'
put([start,end])
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
unknown(state,'task', check='non-monotonic sequence: seq 1 after 2')
put([start, {'type':'tool'}])
unknown(state,'task', check='tool event without an integer seq')
put([start, {'seq':2}])
unknown(state,'task', check='event without a type')
put([start], '{"type":\n')
unknown(state,'task', check='unparseable event')
# A turn that wrote more than the read window still reads busy: the fold starts
# at its opening turn/start, found by a bounded backward scan, and an incomplete
# append larger than one chunk does not hide the committed events before it.
big = 'x' * 700000
second = {'type':'turn/start','seq':3}
body = [{'type':'tool','seq':4 + n,'payload':big} for n in range(4)]
put([start,end,second,*body])
assert call('state',state,'task') == 'busy', 'an oversized turn is still busy'
assert json.loads(call('position',state,'task')) == [str(log), 7]
assert call('state',state,'task','--since',where) == 'busy', 'an oversized new turn passes the start proof'
put([start,end,second,*body], '{"type":"tool","seq":8,"payload":"' + big * 2)
assert call('state',state,'task') == 'busy', 'an oversized incomplete append is not committed'
assert json.loads(call('position',state,'task')) == [str(log), 7]
put([start,end,second,*body,{'type':'turn/end','seq':8}])
assert call('state',state,'task') == 'idle'
assert call('state',state,'task','--since',where) == 'idle'
unknown(state,'task','--since',json.dumps([str(log), 3]), check='no turn started beyond the launch position')
put([start,end])
child = runtime / 'dsh/sessions/workspace/child'
child.mkdir()
(child / 'session.v4.jsonl').write_text(json.dumps({**header,'delegationDepth':1,'id':'22222222-2222-4222-8222-222222222222'})+'\n')
assert call('state',state,'task') == 'idle', 'subagents do not own top-level activity'
# The newest depth-zero log in a launch store is the live one; an older one is
# history, and a position taken on another log does not gate the newer one.
(child / 'session.v4.jsonl').write_text(json.dumps({**header,'id':'33333333-3333-4333-8333-333333333333'})+'\n'+json.dumps({**start,'seq':7})+'\n')
assert call('state',state,'task') == 'busy', 'the newest depth-zero session owns activity'
assert call('state',state,'task','--since',where) == 'busy', 'a position on another log is history'
assert call('session-file',state,'task') == str(child / 'session.v4.jsonl')
(child / 'session.v4.jsonl').unlink()
# The highest-numbered log is read whatever its number; behavior, not schema
# number, admits it.
v5 = store / 'session.v5.jsonl'
v5.write_text(json.dumps({**header,'version':5})+'\n'+json.dumps({'type':'turn/start','seq':1,'data':{'turn':1}})+'\n')
assert call('state',state,'task') == 'busy', 'a well-formed newer log generation is read'
assert call('session-file',state,'task') == str(v5)
v5.write_text(v5.read_text()+json.dumps({'type':'turn/end','seq':2,'data':{'turn':1}})+'\n')
assert call('state',state,'task') == 'idle'
assert json.loads(call('position',state,'task')) == [str(v5), 2]
v5.write_text(json.dumps({'type':'snapshot','version':5})+'\n')
unknown(state,'task', check='does not open with a session header')
call('position',state,'task',ok=False)
v5.write_text(json.dumps({**header,'version':5})+'\n'+json.dumps({'type':'turn/start','seq':3})+'\n'+json.dumps({'type':'turn/end','seq':3})+'\n')
unknown(state,'task', check='non-monotonic sequence: seq 3 after 3')
v5.unlink()
# A launch with no log yet has no position, so its first turn is the proof.
no_log = tmp / 'no-log-state'
no_log.mkdir()
(no_log / 'task.dsh-session').write_text(json.dumps({**binding,'root':str(tmp / 'no-launch-yet')}))
assert call('position',no_log,'task') == ''
# prepare retires the generation its new binding replaces, so a changed route
# does not strand the old credentials copy and session logs, but it never
# removes a directory that is not one of this task's own generations.
source = tmp / 'installed-dsh'
installed = source / 'profiles/dsh-tui'
package = installed / 'node_modules/@deepseek-harness-tui/dsh-tui'
package.mkdir(parents=True)
(installed / 'package.json').write_text('{}')
(package / 'package.json').write_text(json.dumps({'version':'99.1.0'}))
(source / '.credentials.yaml').write_text('secret\n')
launches = tmp / 'launches'
launches.mkdir()
def prepare(generation):
    return Path(call('prepare',launches,'task',generation,source,'deepseek/v4','high',cwd))
for model, effort in [('deepseek/a/b', 'high'), ('deepseek/ ', 'high'), ('deepseek/', 'high'), ('deepseek/v4', 'off'), ('deepseek/v4', 'ultra')]:
    call('prepare',launches,'refused','g0',source,model,effort,cwd,ok=False)
    assert not (launches / 'refused.dsh').exists() and not (launches / 'refused.dsh-session').exists(), 'a refused prepare must stage nothing'
first = prepare('g1')
assert (first / 'dsh/.credentials.yaml').read_text() == 'secret\n'
second = prepare('g2')
assert not first.exists(), 'a replaced launch generation must be retired'
assert json.loads((launches / 'task.dsh-session').read_text())['root'] == str(second)
outside = tmp / 'outside'
outside.mkdir()
(outside / 'keep').write_text('x')
(launches / 'task.dsh-session').write_text(json.dumps({'root':str(outside),'cwd':str(cwd)}))
worker = prepare('g3')
assert (outside / 'keep').exists(), 'prepare must not remove a root outside the task generations'
# Primaries retain operator CLI state, while DSH preferences and credentials
# remain private. Worker HOME must not gain that primary-only access.
operator = tmp / 'operator-home'
(operator / '.config').mkdir(parents=True)
(operator / '.config/token').write_text('operator-token')
(operator / '.dsh').mkdir()
(operator / '.dsh-tui').mkdir()
(operator / '.dsh-tui/model.json').write_text('operator-model')
primary_env = {**os.environ, 'FM_DSH_OPERATOR_HOME': str(operator)}
primary = Path(call('prepare-primary', launches, 'primary', 'g1', source, 'deepseek/v4', 'high', cwd, root, env=primary_env))
assert (primary / 'home/.config/token').read_text() == 'operator-token'
(primary / 'home/.config/token').write_text('refreshed-token')
assert (operator / '.config/token').read_text() == 'refreshed-token', 'primary CLI state must retain the operator identity'
(primary / 'home/.dsh-tui/model.json').write_text('private-model')
assert (operator / '.dsh-tui/model.json').read_text() == 'operator-model', 'DSH preferences must never reach the operator home'
assert (primary / 'home/.dsh').resolve() == primary / 'dsh'
assert not (worker / 'home/.config').exists(), 'workers must retain their isolated HOME contract'
primary_log = primary / 'dsh/sessions/2026-01-01' / header['id'] / 'session.v1.jsonl'
primary_log.parent.mkdir(parents=True)
primary_log.write_text(json.dumps(header) + '\n' + json.dumps(start) + '\n' + json.dumps(end) + '\n')
assert call('resume', launches, 'primary', 'deepseek/v4', 'high', cwd, '--primary-root', root) == str(primary)
assert (primary / 'home/.config/token').read_text() == 'refreshed-token', 'resume must retain operator CLI identity'
call('prepare-primary', launches, 'missing-primary', 'g1', source, 'deepseek/v4', 'high', cwd, tmp / 'absent-code-root', env=primary_env, ok=False)
assert not (launches / 'missing-primary.dsh').exists(), 'missing native plugin must refuse before staging a runtime'
print('ok - dsh route boundaries, launchable-model admission, provider normalization, durable transitions, torn append, oversized turns, start-position proof, newest-session selection, any log generation admitted by behavior, named unknown checks and generation retirement')
PY
# shellcheck source=bin/fm-dsh-lib.sh
. "$ROOT/bin/fm-dsh-lib.sh"
# Probe exits, not release strings, decide admission. The probed CLI must be
# the PATH-selected one even when a different CLI sits beside the launcher.
mkdir -p "$TMP/launcher" "$TMP/cli"
cat > "$TMP/launcher/dsh-tui" <<'SH'
#!/bin/sh
printf "launcher arbitrary-release\n"
exit "${FM_FAKE_DSH_TUI_STATUS:-0}"
SH
printf '#!/bin/sh\nexit 9\n' > "$TMP/launcher/dsh"
cat > "$TMP/cli/dsh" <<'SH'
#!/bin/sh
printf "cli next-release\n"
exit "${FM_FAKE_DSH_CLI_STATUS:-0}"
SH
chmod +x "$TMP/launcher/dsh-tui" "$TMP/launcher/dsh" "$TMP/cli/dsh"
[ "$(PATH="$TMP/cli:$TMP/launcher:$PATH" fm_dsh_executable)" = "$TMP/launcher/dsh-tui" ]
[ "$(PATH="$TMP/cli:$TMP/launcher:$PATH" fm_dsh_cli)" = "$TMP/cli/dsh" ]
PATH="$TMP/cli:$TMP/launcher:$PATH" fm_dsh_launch_check
if out=$(FM_FAKE_DSH_TUI_STATUS=3 PATH="$TMP/cli:$TMP/launcher:$PATH" fm_dsh_launch_check 2>&1); then
  echo 'a failed launcher probe must refuse' >&2; exit 1
fi
case "$out" in *'dsh-tui version failed'*) ;; *) echo "$out" >&2; exit 1 ;; esac
if out=$(FM_FAKE_DSH_CLI_STATUS=4 PATH="$TMP/cli:$TMP/launcher:$PATH" fm_dsh_launch_check 2>&1); then
  echo 'a failed CLI probe must refuse even when it printed a version' >&2; exit 1
fi
case "$out" in *'dsh --version failed'*) ;; *) echo "$out" >&2; exit 1 ;; esac
if out=$(PATH="$TMP/cli" fm_dsh_launch_check 2>&1); then
  echo 'an absent launcher must refuse' >&2; exit 1
fi
case "$out" in *'dsh-tui executable not found on PATH'*) ;; *) echo "$out" >&2; exit 1 ;; esac
PATH="$TMP/cli:$TMP/launcher" fm_dsh_launch_check "$TMP/launcher/dsh-tui" ship
for role in primary secondmate; do
  if out=$(PATH="$TMP/cli:$TMP/launcher" fm_dsh_launch_check "$TMP/launcher/dsh-tui" "$role" 2>&1); then
    echo "a $role without owner-death cleanup must refuse" >&2; exit 1
  fi
  case "$out" in *'requires perl for owner-bound supervision cleanup'*) ;; *) echo "$out" >&2; exit 1 ;; esac
done
printf 'ok - PATH-selected DSH probes accept arbitrary releases, refuse failed commands and require ownership cleanup only for primaries\n'
# The primary launcher must resume the recorded conversation with its bound
# model and effort, and never retire a generation it cannot resume or that a
# live DSH session still owns.
P=$TMP/primary
mkdir -p "$P/home/bin" "$P/home/state" "$P/fake" "$P/user" "$P/operator" "$P/user/.dsh/profiles/dsh-tui/node_modules" "$P/live"
printf '{}\n' > "$P/user/.dsh/profiles/dsh-tui/package.json"
printf '# fixture\n' > "$P/home/AGENTS.md"
git init -q "$P/home"
cat > "$P/fake/dsh-tui" <<'SH'
#!/bin/sh
[ "${1:-}" = version ] && exit 0
printf '%s\n' "$@" > "$FM_FAKE_DSH_LOG"
SH
printf '#!/bin/sh\nexit 0\n' > "$P/fake/dsh"
chmod +x "$P/fake/dsh-tui" "$P/fake/dsh"
primary_launch() {
  FM_HOME="$P/home" HOME="$P/user" DSH_HOME='' FM_DSH_SOURCE_HOME='' FM_DSH_OPERATOR_HOME="$P/operator" \
    FM_FAKE_DSH_LOG="$P/launch" PATH="$P/fake:$PATH" bash "$ROOT/bin/fm-dsh-primary.sh" "$@"
}
primary_launch --model deepseek/deepseek-v4-pro --effort max -- 'fixture opening'
[ "$(sed -n 1p "$P/launch")" = --patch ] && [ "$(sed -n 3,4p "$P/launch")" = "--
fixture opening" ] || { echo "dsh-tui must receive the opening prompt positionally: $(cat "$P/launch")" >&2; exit 1; }
GEN=$(dirname "$(sed -n 2p "$P/launch")")
python3 - "$GEN" "$P/home" <<'PY2'
import json, sys, uuid
from pathlib import Path
log = Path(sys.argv[1]) / 'dsh/sessions/workspace/s/session.v4.jsonl'
log.parent.mkdir(parents=True)
log.write_text(json.dumps({'type': 'session', 'version': 4, 'id': str(uuid.uuid4()), 'cwd': str(Path(sys.argv[2]).resolve()), 'delegationDepth': 0}) + '\n' + json.dumps({'type': 'turn/start', 'seq': 1}) + '\n')
PY2
primary_launch --resume
[ "$(sed -n 2p "$P/launch")" = "$GEN/launch.yml" ] || { echo 'resume must continue the bound generation' >&2; exit 1; }
python3 - "$GEN/launch.yml" <<'PY2'
import json, sys
row = json.load(open(sys.argv[1]))[0]['config']
assert row['model'] == 'deepseek-v4-pro' and row['effort'] == 'max' and row.get('sessionId'), row
PY2
if out=$(primary_launch --resume --model deepseek/deepseek-v4-flash 2>&1); then
  echo 'an unprovable resume must refuse' >&2; exit 1
fi
case "$out" in *'cannot resume the conversation bound in'*) ;; *) echo "$out" >&2; exit 1 ;; esac
ln -sf /bin/bash "$P/live/dsh-tui"
"$P/live/dsh-tui" -c 'sleep 30; :' &
LIVE=$!
printf '%s\n' "$LIVE" > "$P/home/state/.lock"
if out=$(primary_launch 2>&1); then
  kill "$LIVE"; echo 'a fresh primary must not replace a live DSH session' >&2; exit 1
fi
kill "$LIVE"
wait "$LIVE" 2>/dev/null || true
case "$out" in *"live DSH session pid $LIVE"*) ;; *) echo "$out" >&2; exit 1 ;; esac
[ -s "$GEN/dsh/sessions/workspace/s/session.v4.jsonl" ] || { echo 'refusals must keep the bound conversation' >&2; exit 1; }
printf 'ok - the DSH primary resumes its bound model and effort and refuses to replace an unresumable or live conversation\n'
# With no --model and no binding to resume, the launcher takes the operator's
# dsh-tui /model choice at run time and refuses when it names no DeepSeek model.
rm -f "$P/home/state/.lock"
mkdir -p "$P/operator/.dsh-tui"
for preference in absent '{"provider":"openrouter","model":"deepseek/deepseek-v4-pro"}' '{"provider":"deepseek-official","model":""}'; do
  if [ "$preference" = absent ]; then
    rm -f "$P/operator/.dsh-tui/model.json"
  else
    printf '%s\n' "$preference" > "$P/operator/.dsh-tui/model.json"
  fi
  : > "$P/launch"
  if out=$(primary_launch 2>&1); then
    echo "a primary with no --model and preference $preference must refuse" >&2; exit 1
  fi
  case "$out" in *'pass --model deepseek/<id>'*) ;; *) echo "$out" >&2; exit 1 ;; esac
  [ ! -s "$P/launch" ] || { echo "a refused primary must not start dsh-tui: $(cat "$P/launch")" >&2; exit 1; }
done
printf '{"provider":"deepseek-official","model":"operator-choice"}\n' > "$P/operator/.dsh-tui/model.json"
cp "$P/operator/.dsh-tui/model.json" "$TMP/operator-preference"
primary_launch
python3 - "$(sed -n 2p "$P/launch")" "$P/home/state/dsh-primary.dsh-session" <<'PY2'
import json, sys
row = json.load(open(sys.argv[1]))[0]['config']
assert row['model'] == 'operator-choice' and row['effort'] == 'high', row
assert json.load(open(sys.argv[2]))['model'] == 'operator-choice'
PY2
cmp -s "$TMP/operator-preference" "$P/operator/.dsh-tui/model.json" || { echo 'the launch must not change the operator preference' >&2; exit 1; }
printf 'ok - a DSH primary with no --model reads the operator /model preference at launch and refuses when it names no DeepSeek model\n'
for args in \
  'node /opt/homebrew/bin/dsh-tui --patch /state/t.dsh/g1/launch.yml -- brief' \
  'node /opt/homebrew/lib/node_modules/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js --patch x' \
  'node /state/t.dsh/g1/dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js --patch x' \
  'node /state/t.dsh/g1/dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui/lib/relaid/entry.js'; do
  fm_dsh_args_are_dsh "$args" || { echo "a dsh-tui launcher or package script must match: $args" >&2; exit 1; }
done
for args in \
  'node /tmp/unrelated.js /opt/homebrew/bin/dsh-tui' \
  'bash -c node /opt/homebrew/bin/dsh-tui' \
  'node /opt/homebrew/bin/dsh web --no-open' \
  'node /opt/homebrew/bin/dsh-tuix' \
  'node /opt/lib/node_modules/@deepseek-harness-tui/dsh-tui-extra/bin/x.js'; do
  if fm_dsh_args_are_dsh "$args"; then
    echo "only a dsh-tui launcher or package script in the interpreter slot may match: $args" >&2
    exit 1
  fi
done
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
fm_composer_dsh_screen_check "$dsh_empty"
fm_composer_dsh_screen_check "$dsh_draft"
fm_composer_dsh_screen_check "$dsh_busy"
if out=$(fm_composer_dsh_screen_check 'new frontend without a recognized composer' 2>&1); then
  echo 'an unrecognized composer must refuse' >&2; exit 1
fi
case "$out" in *'could not parse the composer frame or its input content'*) ;; *) echo "$out" >&2; exit 1 ;; esac
printf 'ok - dsh frame proves empty, typed draft, and busy-hint furniture; incompatible screens refuse with a parser diagnostic\n'
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
[ "$(fm_control_interrupt_key dsh)" = Escape ]
[ "$(fm_control_exit_command dsh)" = /exit ]
# shellcheck source=tests/fm-dsh-live-cleanup.sh
. "$ROOT/tests/fm-dsh-live-cleanup.sh"
printf '#!/bin/sh\nexit 1\n' > "$TMP/teardown-fail"
printf '#!/bin/sh\nexit 0\n' > "$TMP/teardown-ok"
chmod +x "$TMP/teardown-fail" "$TMP/teardown-ok"
out=$(fm_dsh_live_cleanup 0 session "$TMP/teardown-fail" "$PATH") && rc=0 || rc=$?
[ "$rc" -ne 0 ] || { echo 'a failed teardown must stay fatal' >&2; exit 1; }
case "$out" in *cleanup_exit=1*) ;; *) echo "failed teardown lost its report: $out" >&2; exit 1 ;; esac
fm_dsh_live_cleanup 0 session "$TMP/teardown-ok" "$PATH" >/dev/null || { echo 'a clean teardown must pass' >&2; exit 1; }
printf 'ok - dsh executable-slot attribution, lifecycle capability and fatal cleanup contract\n'
