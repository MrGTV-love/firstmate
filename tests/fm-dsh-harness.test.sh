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
    ('DeepSeek/deepseek-v4-flash', '', 'dsh'),
    (' DeepSeek / model ', '', 'dsh'),
    ('v4-pro', 'deepseek', 'dsh'),
    ('v4-pro', ' DeepSeek ', 'dsh'),
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
# omp's own provider normalization decides the route, so these spellings run
# on dsh and never on omp.
for model in ('DeepSeek/deepseek-v4-flash', ' DeepSeek / model '):
    call('check', 'dsh', model)
    call('check', 'omp', model, ok=False)
# Every DeepSeek spelling has one identity; the model id keeps its own case.
for model, provider, expected in [(' DeepSeek / v4 ', '', 'deepseek/v4'), ('deepseek/v4', '', 'deepseek/v4'),
                                  ('v4', ' DeepSeek ', 'deepseek/v4'), ('DeepSeek/V4-Pro', '', 'deepseek/V4-Pro')]:
    assert call('canonical', model, provider) == expected
for model in ('openai/gpt', 'deepseek/a/b', 'deepseek/', ''):
    call('canonical', model, ok=False)
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
profiles.write_text(json.dumps({'rules':[{'use':[{'harness':'dsh','model':' DeepSeek / v4 ','effort':'high'}]}]}))
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
assert json.loads(where)[:2] == [str(log), 2]
assert json.loads(where)[2] == log.stat().st_size, 'the position carries the committed byte offset'
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
assert call('resume',state,'task',' DeepSeek / v4 ','high',cwd) == str(runtime), 'any DeepSeek spelling of the bound id must resume'
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
assert json.loads(call('position',state,'task'))[:2] == [str(log), 7]
assert call('state',state,'task','--since',where) == 'busy', 'an oversized new turn passes the start proof'
put([start,end,second,*body], '{"type":"tool","seq":8,"payload":"' + big * 2)
assert call('state',state,'task') == 'busy', 'an oversized incomplete append is not committed'
assert json.loads(call('position',state,'task'))[:2] == [str(log), 7]
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
assert json.loads(call('position',state,'task'))[:2] == [str(v5), 2]
for torn in ('', '{"type":"session","version":5,"id":"'):
    v5.write_text(torn)
    assert json.loads(call('position',state,'task'))[:2] == [str(log), 2], 'an uncommitted newer header must leave the older log live'
    assert call('state',state,'task') == 'idle', 'an uncommitted newer header must not hide the older log'
v5.write_text(json.dumps({'type':'snapshot','version':5})+'\n')
unknown(state,'task', check='does not open with a session header')
call('position',state,'task',ok=False)
v5.write_text(json.dumps({**header,'version':5})+'\n'+json.dumps({'type':'turn/start','seq':3})+'\n'+json.dumps({'type':'turn/end','seq':3})+'\n')
unknown(state,'task', check='non-monotonic sequence: seq 3 after 3')
v5.unlink()
# A subagent log whose header line is not yet committed opens no session, so it
# neither fails the store nor displaces the live depth-zero log.
(child / 'session.v4.jsonl').write_text('{"type":"session","version":4,"id":"')
assert json.loads(call('position',state,'task'))[0] == str(log), 'an uncommitted header must not fail the store'
assert call('session-file',state,'task') == str(log)
(child / 'session.v4.jsonl').unlink()
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
spelled = Path(call('prepare',launches,'spelled','g1',source,'DeepSeek/v4','high',cwd))
assert json.loads((launches / 'spelled.dsh-session').read_text())['model'] == 'v4', 'prepare must bind the bare DeepSeek id'
assert json.loads((spelled / 'home/.dsh-tui/model.json').read_text())['model'] == 'v4'
# Every launch retains linked operator CLI state, while DSH preferences and
# its runtime remain private to the launch.
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
(operator / '.config/gh').mkdir()
(operator / '.config/gh/hosts.yml').write_text('github.com:\n    user: fixture-operator\n')
for kind in ('ship', 'scout'):
    launch = Path(call('prepare', launches, kind, 'g1', source, 'deepseek/v4', 'high', cwd, env=primary_env))
    gh_config = launch / 'home/.config/gh/hosts.yml'
    assert gh_config.resolve() == (operator / '.config/gh/hosts.yml').resolve(), f'{kind} must resolve the operator gh configuration without copying it'
    assert gh_config.read_text() == 'github.com:\n    user: fixture-operator\n'
    assert not (launch / 'home/.dsh-tui').is_symlink(), f'{kind} DSH preferences must stay private'
    assert (launch / 'home/.dsh').resolve() == launch / 'dsh', f'{kind} DSH runtime must stay private'
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
# Real `tmux capture-pane -e` screens of dsh-tui 0.16.1 before any usage
# sample: no meter row, and a status row without the ctx cell. The fresh
# captures had no opening prompt (the 45- and 30-column ones truncate or wrap
# every cell); the launch captures ran the fm-spawn launch shape with a one-line
# opening prompt, read while bin/fm-dsh.py state reported busy and then idle,
# where the API rejected the model id so the turn ended without usage. Each
# starts below the banner rows that carry home paths. The configured effort was
# `xhigh` (that route renders `high`) or none (dsh still rendered `high`).
dsh_fx() { cat "$ROOT/tests/fixtures/dsh-tui-0.16.1-$1.ansi"; }
# The start proof judges the FIRST turn beyond the launch position. The real
# launch's turn-error log fails with the provider's text; a real accepted first
# step (trimmed to event types, seq, time and its assistant/message usage and
# finish) is busy; the completed log is that step plus a synthetic step/end and
# completed turn/end. The busy classifier's own `state` still reads the newest
# turn and is unchanged.
dsh_start_log() {  # <events-file> [since-json] -> prints start-state and state for it
  local dir=$TMP/start-$RANDOM log
  mkdir -p "$dir/root/dsh/sessions/workspace/session" "$dir/state"
  printf '{"root": "%s", "cwd": "/w", "generation": "g1", "model": "m", "effort": ""}' "$dir/root" > "$dir/state/t.dsh-session"
  log=$dir/root/dsh/sessions/workspace/session/session.v4.jsonl
  { printf '{"type": "session", "version": 4, "id": "8578f75e-697c-461f-b778-227432316ca2", "cwd": "/w", "delegationDepth": 0}\n'; cat "$1"; } > "$log"
  python3 "$ROOT/bin/fm-dsh.py" start-state "$dir/state" t ${2:+--since "${2//@LOG@/$log}"}
  python3 "$ROOT/bin/fm-dsh.py" state "$dir/state" t
}
dsh_start_expect() {  # <label> <want-start-state> <want-state> <events-file> [since-json]
  local got
  got=$(dsh_start_log "$4" "${5:-}")
  [ "$got" = "$(printf '%s\n%s' "$2" "$3")" ] || { echo "$1: expected '$2' / '$3', got: $got" >&2; exit 1; }
}
dsh_turn_error="$ROOT/tests/fixtures/dsh-session-turn-error.jsonl"
dsh_accepted="$ROOT/tests/fixtures/dsh-session-accepted-busy.jsonl"
dsh_completed="$ROOT/tests/fixtures/dsh-session-completed-synthetic.jsonl"
dsh_error_text='The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed deepseek-v4.1-flash-1017. (request_id: 15009da4-da63-49a1-9307-efa3a7e9675a)'
dsh_start_expect 'a turn-error first turn' "failed: $dsh_error_text" idle "$dsh_turn_error"
# A running first turn counts only once the provider accepted the request: the
# real rejected turn's opening events (up to its failed attempt) are
# `unaccepted`, and the real accepted step is `busy`.
head -n 4 "$dsh_turn_error" > "$TMP/start-busy.jsonl"
dsh_start_expect 'a running first turn the provider has not accepted' unaccepted busy "$TMP/start-busy.jsonl"
dsh_start_expect 'a running first turn with an assistant/message' busy busy "$dsh_accepted"
dsh_start_expect 'a completed first turn after an assistant/message' idle idle "$dsh_completed"
# Any turn/end with reason error fails the first turn, whatever its attempts:
# with no assistant/attempt at all, or after the provider already answered.
grep -v '"assistant/attempt"' "$dsh_turn_error" > "$TMP/start-no-attempt.jsonl"
dsh_start_expect 'an error turn/end with no errored attempt' "failed: $dsh_error_text" idle "$TMP/start-no-attempt.jsonl"
{ cat "$dsh_accepted"
  printf '%s\n' '{"type": "turn/end", "seq": 20, "data": {"turn": 1, "reason": {"kind": "error", "error": {"message": "stream reset by peer"}}}}'; } > "$TMP/start-accepted-error.jsonl"
dsh_start_expect 'an error turn/end after an assistant/message' 'failed: stream reset by peer' idle "$TMP/start-accepted-error.jsonl"
{ cat "$dsh_accepted"
  printf '%s\n' '{"type": "turn/end", "seq": 20, "data": {"turn": 1, "reason": {"kind": "error"}}}'; } > "$TMP/start-silent-error.jsonl"
dsh_start_expect 'an error turn/end with no provider text' failed idle "$TMP/start-silent-error.jsonl"
# A first turn that ends any other way without an assistant/message was never
# accepted, so it cannot admit the launch.
{ head -n 2 "$dsh_turn_error"
  printf '%s\n' '{"type": "turn/end", "seq": 18, "data": {"turn": 1, "reason": {"kind": "aborted"}}}'; } > "$TMP/start-aborted.jsonl"
dsh_start_expect 'an aborted first turn without acceptance' 'ended-unaccepted: aborted' idle "$TMP/start-aborted.jsonl"
# The first turn beyond the launch position is judged, never a later one: a
# later accepted turn cannot hide the first turn's error or its lack of
# acceptance, while `state` follows the newest turn.
{ cat "$dsh_turn_error"
  printf '%s\n' '{"type": "turn/start", "seq": 19, "data": {"turn": 2}}' '{"type": "assistant/message", "seq": 20, "data": {"turn": 2, "step": 1}}'; } > "$TMP/start-later-accepted.jsonl"
dsh_start_expect 'a later accepted turn after a failed first turn' "failed: $dsh_error_text" busy "$TMP/start-later-accepted.jsonl"
{ head -n 2 "$dsh_turn_error"
  printf '%s\n' '{"type": "turn/start", "seq": 19, "data": {"turn": 2}}' '{"type": "assistant/message", "seq": 20, "data": {"turn": 2, "step": 1}}'; } > "$TMP/start-superseded.jsonl"
dsh_start_expect 'a later accepted turn after an unaccepted first turn' 'ended-unaccepted: superseded' busy "$TMP/start-superseded.jsonl"
# A launch position from an earlier conversation in the same log scopes the
# proof to what came after it: the earlier failed turn is history, by seq alone
# or by seq and committed byte offset.
{ cat "$dsh_turn_error"
  printf '%s\n' '{"type": "turn/start", "seq": 19, "data": {"turn": 2}}'; } > "$TMP/start-resumed.jsonl"
dsh_start_expect 'a resumed launch past an earlier failed turn' unaccepted busy "$TMP/start-resumed.jsonl" '["@LOG@", 18]'
dsh_offset=$(($(wc -c < "$dsh_turn_error") + $(printf '%s\n' '{"type": "session", "version": 4, "id": "8578f75e-697c-461f-b778-227432316ca2", "cwd": "/w", "delegationDepth": 0}' | wc -c)))
dsh_start_expect 'a resumed launch read from its byte offset' unaccepted busy "$TMP/start-resumed.jsonl" "[\"@LOG@\", 18, $dsh_offset]"
dsh_start_expect 'no turn yet beyond the launch position' 'unknown: no turn started beyond the launch position' \
  idle "$dsh_turn_error" '["@LOG@", 18]'
# fm-spawn reads the launch identity from the binding prepare recorded.
mkdir -p "$TMP/identity"
printf '{"root": "/r", "cwd": "/w/fm/plaindir", "generation": "g1", "model": "deepseek-v4.1-flash-1017", "effort": "xhigh"}' > "$TMP/identity/t.dsh-session"
[ "$(python3 "$ROOT/bin/fm-dsh.py" status-identity "$TMP/identity" t)" = "$(printf 'deepseek-v4.1-flash-1017\txhigh\tplaindir')" ] \
  || { echo 'status-identity must print the bound model, effort and cwd basename' >&2; exit 1; }
printf '{"root": "/r", "cwd": "/w/fm/plaindir", "generation": "g1", "model": "deepseek-v4.1-flash-1017", "effort": ""}' > "$TMP/identity/d.dsh-session"
[ "$(python3 "$ROOT/bin/fm-dsh.py" status-identity "$TMP/identity" d)" = "$(printf 'deepseek-v4.1-flash-1017\t\tplaindir')" ] \
  || { echo 'status-identity must print an empty effort when none was configured' >&2; exit 1; }
dsh_id_plain=$(printf 'deepseek-v4.1-flash-1017\txhigh\tplaindir')
dsh_id_git=$(printf 'deepseek-v4.1-flash-1017\txhigh\t%s' 'gitdir')
dsh_id_launch=$(printf 'deepseek-v4.1-flash-1017\txhigh\tfmcapwt')
dsh_id_default=$(printf 'deepseek-v4.1-flash-1017\t\tfmcapwt')
dsh_id_verdict() {  # <identity> <screen>
  fm_composer_classify_screen "$(printf '%s\ndsh-status=%s' "$dsh_caps" "$1")" "$2" '' ''
}
dsh_expect() {  # <want> <label> <identity> <screen>
  local got
  got=$(dsh_id_verdict "$3" "$4")
  [ "$got" = "$1" ] || { echo "$2: expected $1, got $got" >&2; exit 1; }
  fm_composer_dsh_screen_check "$4" "$3" || { echo "$2: the launch check must accept" >&2; exit 1; }
}
dsh_refuse() {  # <label> <identity> <screen>
  local got
  got=$(dsh_id_verdict "$2" "$3")
  case "$got" in empty | pending) echo "$1: must not be accepted, got $got" >&2; exit 1 ;; esac
  if fm_composer_dsh_screen_check "$3" "$2" 2>/dev/null; then echo "$1: the launch check must refuse" >&2; exit 1; fi
}
dsh_expect empty 'fresh dsh screen' "$dsh_id_plain" "$(dsh_fx fresh-empty)"
dsh_expect pending 'fresh dsh screen with a typed draft' "$dsh_id_plain" "$(dsh_fx fresh-pending)"
dsh_expect empty 'narrow fresh dsh screen' "$dsh_id_git" "$(dsh_fx fresh-45col-empty)"
dsh_expect empty 'busy first turn of an xhigh launch' "$dsh_id_launch" "$(dsh_fx launch-xhigh-busy)"
dsh_expect empty 'idle turn-error screen of an xhigh launch' "$dsh_id_launch" "$(dsh_fx launch-xhigh-turn-error-idle)"
dsh_expect empty 'busy first turn of a default-effort launch' "$dsh_id_default" "$(dsh_fx launch-default-busy)"
dsh_expect empty 'idle turn-error screen of a default-effort launch' "$dsh_id_default" "$(dsh_fx launch-default-turn-error-idle)"
# A 30-column pane wraps the row's separators onto their own line; that real
# capture is not the proven shape and stays refused.
dsh_refuse 'wrapped 30-column fresh dsh screen' "$dsh_id_git" "$(dsh_fx fresh-30col-wrapped)"
# The row is furniture only for the launch identity the caller supplies: with
# no identity, or another launch's, every real capture stays unproven, and a
# same-named variable in the environment supplies nothing.
for fx in fresh-empty launch-xhigh-busy launch-default-turn-error-idle; do
  got=$(fm_composer_classify_screen "$dsh_caps" "$(dsh_fx "$fx")" '' '')
  [ "$got" = unknown ] || { echo "$fx without a launch identity: expected unknown, got $got" >&2; exit 1; }
  got=$(_fm_composer_dsh_expect=$dsh_id_launch fm_composer_classify_screen "$dsh_caps" "$(dsh_fx "$fx")" '' '')
  [ "$got" = unknown ] || { echo "$fx with only an inherited identity variable: expected unknown, got $got" >&2; exit 1; }
  if fm_composer_dsh_screen_check "$(dsh_fx "$fx")" 2>/dev/null; then echo "$fx: the launch check needs the identity" >&2; exit 1; fi
done
dsh_refuse 'another model in the status row' "$(printf 'deepseek-flash\txhigh\tfmcapwt')" "$(dsh_fx launch-xhigh-busy)"
dsh_refuse 'another directory in the status row' "$(printf 'deepseek-v4.1-flash-1017\txhigh\tvernant')" "$(dsh_fx launch-xhigh-busy)"
dsh_refuse 'an effort above the configured one' "$(printf 'deepseek-v4.1-flash-1017\tmedium\tfmcapwt')" "$(dsh_fx launch-xhigh-busy)"
# An identity without its three tab-separated fields is refused even when a
# row happens to fit the one way it could be misread.
dsh_refuse 'a malformed launch identity' "$(printf 'deepseek-v4.1-flash-1017\thigh')" \
  "$(printf '%s\n' "$dsh_frame_top" "$(dsh_row '')" "$dsh_frame_bottom" '   deepseek-v4.1-flash-1017 · high · high')"
dsh_fresh_row='   deepseek-v4.1-flash-1017 · high · plaindir'
dsh_fresh_box=$(printf '%s\n' "$dsh_frame_top" "$(dsh_row '')" "$dsh_frame_bottom")
dsh_expect pending 'typed draft above the fresh dsh row' "$dsh_id_plain" \
  "$(printf '%s\n' "$dsh_frame_top" "$(dsh_row 'fix the tests')" "$dsh_frame_bottom" "$dsh_fresh_row")"
# Without a configured effort dsh may omit the effort cell; with one it must not.
dsh_expect empty 'two-cell row of a launch with no effort' "$(printf 'deepseek-v4.1-flash-1017\t\tplaindir')" \
  "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-v4.1-flash-1017 · plaindir')"
dsh_refuse 'two-cell row of a launch with an effort' "$dsh_id_plain" \
  "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-v4.1-flash-1017 · plaindir')"
# The row is furniture only flush under the frame and as the screen's last
# furniture apart from dsh's whole busy-hint row; anything else below the box
# stays a lower live surface.
dsh_refuse 'plain text flush under a dsh box' "$dsh_id_plain" "$(printf '%s\n' "$dsh_fresh_box" '   fix the tests')"
dsh_refuse 'fresh dsh row with text below it' "$dsh_id_plain" "$(printf '%s\n' "$dsh_fresh_box" "$dsh_fresh_row" '   fix the tests')"
dsh_refuse 'busy hint followed by a shell prompt' "$dsh_id_plain" \
  "$(printf '%s\n' "$dsh_fresh_box" "$dsh_fresh_row" '   esc to interrupt user@host % echo hello')"
# Once the pre-usage row is present its rule alone decides, and its busy-hint
# tail is dsh's own constant: an override matching both that row and the text
# below it cannot turn either into furniture.
FM_BUSY_REGEX='deepseek|fix the tests' dsh_refuse 'fresh dsh row with text below it under a busy-regex override' "$dsh_id_plain" \
  "$(printf '%s\n' "$dsh_fresh_box" "$dsh_fresh_row" '   fix the tests')"
dsh_refuse 'fresh dsh row, a blank row, then text' "$dsh_id_plain" "$(printf '%s\n' "$dsh_fresh_box" "$dsh_fresh_row" '' 'user@host plaindir %')"
dsh_refuse 'fresh dsh row with an empty cell' "$dsh_id_plain" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-v4.1-flash-1017 ·  · plaindir')"
dsh_refuse 'four-cell row under a dsh box' "$dsh_id_plain" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-v4.1-flash-1017 · high · main · plaindir')"
# A stale dsh frame above a shell prompt holding a draft is not a dsh composer,
# whatever its prompt imitates, whether it is the only frame or sits below a
# complete earlier dsh screen.
dsh_stale_box=$(printf '%s\n' '  ╭─────────────────────╮' '  ⌸ ❯                   ⛶' '  ╰─────────────────────╯')
for line in 'alice · ~/work · % echo hello' 'alice · high · λ echo hello' 'deepseek-v4.1-flash-1017 · high · λ echo hello'; do
  dsh_refuse "stale dsh frame above the shell prompt '$line'" "$dsh_id_plain" "$(printf '%s\n' "$dsh_stale_box" "$line")"
  dsh_refuse "second stale dsh frame above the shell prompt '$line'" "$dsh_id_plain" \
    "$(printf '%s\n' "$dsh_fresh_box" "$dsh_fresh_row" '' "$dsh_stale_box" "$line")"
done
# A generic rounded composer the classifier proves empty is still not dsh-tui.
dsh_generic=$(printf '%s\n' "  ╭$(printf '─%.0s' $(seq 1 40))╮" "  │ ❯$(printf ' %.0s' $(seq 1 38))│" "  ╰$(printf '─%.0s' $(seq 1 40))╯")
got=$(dsh_verdict "$dsh_generic")
[ "$got" = empty ] || { echo "the generic composer fixture must classify empty, got $got" >&2; exit 1; }
if fm_composer_dsh_screen_check "$dsh_generic" "$dsh_id_plain" 2>/dev/null; then
  echo 'an empty composer without the dsh frame must fail the dsh launch check' >&2; exit 1
fi
# A dsh box is held to its whole screen: past its furniture, any text further
# down, even after blank rows, is a lower live surface. This holds with no
# launch identity (the shared classifier every consumer reads) and with one.
for tail in 'esc to interrupt' '6.5k/1.0M 0.7%' "$dsh_status"; do
  got=$(dsh_verdict "$(printf '%s\n' "$dsh_stale_box" "   $tail" '' 'user@host work % echo hello')")
  [ "$got" = unknown ] || { echo "a shell row after a blank below dsh furniture '$tail' must not be a composer, got $got" >&2; exit 1; }
done
got=$(dsh_verdict "$(printf '%s\n' "$dsh_stale_box" '' '' 'user@host work % echo hello')")
[ "$got" = unknown ] || { echo "a shell row after blank rows below a dsh box must not be a composer, got $got" >&2; exit 1; }
got=$(dsh_verdict "$(printf '%s\n' "$dsh_stale_box" '   esc to interrupt' '' '')")
[ "$got" = empty ] || { echo "dsh furniture followed only by blank rows must stay empty, got $got" >&2; exit 1; }
# The cwd cell is the bound basename taken literally, as dsh-tui renders it,
# whole or cut by its `…`; another directory still refuses.
dsh_id_spaced=$(printf 'deepseek-flash\thigh\tmy project')
dsh_expect empty 'a cwd basename with a space' "$dsh_id_spaced" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · high · my project')"
dsh_expect empty 'a truncated cwd basename with a space' "$dsh_id_spaced" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · high · my pro…')"
dsh_expect empty 'a Unicode cwd basename holding a middle dot' "$(printf 'deepseek-flash\thigh\tprojé · 日本')" \
  "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · high · projé · 日本')"
dsh_expect empty 'a two-cell row with a spaced cwd and no effort' "$(printf 'deepseek-flash\t\tmy project')" \
  "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · my project')"
dsh_refuse 'another directory than the spaced cwd' "$dsh_id_spaced" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · high · my projects')"
dsh_refuse 'a truncation that is not a prefix of the cwd' "$dsh_id_spaced" "$(printf '%s\n' "$dsh_fresh_box" '   deepseek-flash · high · other…')"
printf 'ok - real fresh and launch dsh-tui screens prove empty or typed draft through the launch-identity status row, which is accepted only as flush last furniture\n'
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
S=$TMP/scrub
mkdir -p "$S/task/state/t.dsh/g1/dsh" "$S/task/state/t.dsh/g1/home" "$S/operator/o.dsh/g1/dsh" "$S/outside/state/t.dsh/g1/dsh"
printf 'sentinel\n' > "$S/task/state/t.dsh/g1/dsh/.credentials.yaml"
printf 'evidence\n' > "$S/task/state/t.dsh/g1/dsh/session.jsonl"
printf 'sentinel\n' > "$S/operator/o.dsh/g1/dsh/.credentials.yaml"
printf 'sentinel\n' > "$S/outside/state/t.dsh/g1/dsh/.credentials.yaml"
ln -s "$S/operator" "$S/task/state/t.dsh/g1/home/operator"
out=$(fm_dsh_live_cleanup 0 session "$TMP/teardown-fail" "$PATH" "$S/task" '' "$S/absent") && rc=0 || rc=$?
[ "$rc" -ne 0 ] || { echo 'a failed teardown must stay fatal when it also scrubs' >&2; exit 1; }
[ ! -e "$S/task/state/t.dsh/g1/dsh/.credentials.yaml" ] || { echo 'cleanup must scrub a staged credential copy even after a failed teardown' >&2; exit 1; }
[ -s "$S/task/state/t.dsh/g1/dsh/session.jsonl" ] || { echo 'cleanup must keep non-secret evidence' >&2; exit 1; }
[ -s "$S/operator/o.dsh/g1/dsh/.credentials.yaml" ] || { echo 'cleanup must not follow a private-home link to the operator install' >&2; exit 1; }
[ -s "$S/outside/state/t.dsh/g1/dsh/.credentials.yaml" ] || { echo 'cleanup must touch only the named task homes' >&2; exit 1; }
printf 'ok - dsh executable-slot attribution, lifecycle capability, fatal cleanup contract and task-home credential scrub\n'
