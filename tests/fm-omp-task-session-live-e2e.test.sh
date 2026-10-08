#!/usr/bin/env bash
# Real standalone extension loading and current-session proof; no model calls.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_TASK_SESSION_LIVE omp python3
LAB=$(fm_test_tmproot fm-omp-task-session-live)
export FM_PROOF_LAB="$LAB" FM_PROOF_ROOT="$ROOT"
python3 <<'PY'
import json, os, pathlib, selectors, subprocess, time, uuid

lab = pathlib.Path(os.environ['FM_PROOF_LAB'])
root = pathlib.Path(os.environ['FM_PROOF_ROOT'])
home = lab / 'home'
state = lab / 'state'
project = lab / 'project'
for path in (home / '.omp/agent', state, project):
    path.mkdir(parents=True)
(state / 'demo.meta').write_text('spawn_gen=standalone-proof\n')
session = lab / 'task.jsonl'
session.write_text(json.dumps({'type': 'session', 'version': 3, 'id': str(uuid.uuid4()),
                               'timestamp': '2026-10-08T00:00:00Z', 'cwd': str(project)}) + '\n')
extension = lab / 'proof.ts'
extension.write_text(f'import {{ installTaskSessionProof }} from {json.dumps(str(root / ".omp/extensions/lib/fm-task-session.ts"))};\n'
                     f'export default function(pi) {{ installTaskSessionProof(pi, {json.dumps(str(state))}, "demo"); }}\n')
env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(home / '.omp/agent'),
           XDG_CONFIG_HOME=str(home / '.config'), XDG_DATA_HOME=str(home / '.local/share'),
           XDG_STATE_HOME=str(home / '.local/state'), XDG_CACHE_HOME=str(home / '.cache'),
           OMP_PROFILE='default', PI_PROFILE='default', OMP_SKIP_SETUP='1',
           OPENAI_API_KEY='non-submitting-fixture', FM_SPAWN_GEN='standalone-proof')
with (lab / 'stderr.log').open('w+') as errors:
    process = subprocess.Popen(['omp', '--mode', 'rpc', '--no-ui', '--no-extensions',
                                '--no-skills', '--no-rules', '--no-tools', '--no-lsp',
                                '--no-title', '--model', 'openai/gpt-4.1',
                                '--resume', str(session), '-e', str(extension)],
                               cwd=project, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=errors, text=True)
    try:
        process.stdin.write('{"id":"ready","type":"get_state"}\n')
        process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if not selector.select(timeout=0.2):
                continue
            line = process.stdout.readline()
            if not line:
                raise AssertionError('omp exited before startup')
            frame = json.loads(line)
            if frame.get('id') == 'ready':
                assert frame.get('success'), frame
                break
        else:
            raise AssertionError('omp did not answer get_state')
        proof_path = state / 'demo.omp-session.json'
        assert proof_path.exists(), 'standalone omp did not publish session ownership proof'
        proof = json.loads(proof_path.read_text())
        assert proof == {'version': 1, 'spawn_gen': 'standalone-proof', 'pid': process.pid,
                         'task_session_file': str(session.resolve()),
                         'current_session_file': str(session.resolve())}, proof
        attribution = subprocess.run(
            ['bash', '-c', '. "$1"; fm_launch_proof_pid "$2" "$3"', 'proof-live',
             str(root / 'bin/fm-launch-proof-lib.sh'), str(process.pid), 'standalone-proof'],
            env=dict(env, FM_STATE_OVERRIDE=str(state)), capture_output=True, text=True,
            timeout=10, check=True)
        assert attribution.stdout == 'managed', (attribution.stdout, attribution.stderr)
        print('ok - standalone omp loads production extension and proves its active task session')
    except Exception:
        errors.seek(0)
        print(errors.read())
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
PY
