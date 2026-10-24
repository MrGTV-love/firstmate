#!/usr/bin/env python3
"""Default-policy contrast for the summary refresh (old 60 s kill) and the fleet
snapshot per-task read (old 40 s kill).

The bin tree is copied into a disposable home so one internal producer can be
replaced by a CPU-busy stand-in that runs past the old wall-clock limit:
  - summary: bin/fm-fleet-snapshot.sh burns 65 s of CPU, then prints a valid
    summary document (d2-custody 10-21: "the failed attempt ran 61s").
  - fleet: bin/fm-crew-state.sh burns 45 s of CPU, then prints its row.
No timeout overrides are set: both scripts run under their shipped defaults.

usage: live-default-bounds.py <bin-dir> <label> [summary|fleet ...]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SRC = Path(sys.argv[1]).resolve()
LABEL = sys.argv[2]
ONLY = set(sys.argv[3:])


def busy(seconds):
    return (f"python3 - <<'SLOW'\nimport time\nuntil = time.monotonic() + {seconds}\n"
            "while time.monotonic() < until:\n    sum(i*i for i in range(1000))\n")


def home():
    d = Path(tempfile.mkdtemp(prefix='fm-bounds.', dir=os.environ.get('TMPDIR', '/tmp'))).resolve()
    for c in ('state', 'data', 'config', 'projects', 'fakebin'):
        (d / c).mkdir()
    shutil.copytree(SRC, d / 'bin')
    env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
    env.update(FM_HOME=str(d), FM_ROOT_OVERRIDE=str(d), FM_STATE_OVERRIDE=str(d / 'state'),
               FM_DATA_OVERRIDE=str(d / 'data'), FM_CONFIG_OVERRIDE=str(d / 'config'),
               FM_PROJECTS_OVERRIDE=str(d / 'projects'), FM_DURATION_FILE='off', FM_GATE_REFUSE_BYPASS='1',
               PATH=str(d / 'fakebin') + ':' + os.environ['PATH'])
    return d, env


def write(path, body):
    path.write_text('#!/usr/bin/env bash\n' + body)
    path.chmod(0o755)


def summary():
    d, env = home()
    doc = dict(schema='fm-secondmate-home-summary.v1', hold_classifier_schema='fm-captain-hold-buckets.v1',
               home=str(d), generated='2026-10-23T00:00:00Z', generated_epoch=1792713600, valid=True,
               state='working', invalidity={}, active_children=[], decisions_open=[], holds=[], queued=[],
               landed=[], endpoints=[], counts={}, omitted=[])
    write(d / 'bin/fm-fleet-snapshot.sh', busy(65) + f'print({json.dumps(doc)!r})\nSLOW\n')
    t0 = time.monotonic()
    r = subprocess.run(['bash', str(d / 'bin/fm-home-summary-refresh.sh')], env=env, capture_output=True, text=True)
    took = time.monotonic() - t0
    out = d / 'state/home-summary.json'
    published = out.exists() and json.loads(out.read_text()) == doc
    print(f'[{LABEL}] {"PASS" if r.returncode == 0 and published else "FAIL"} summary_65s_producer_publishes :: '
          f'{took:.1f}s rc={r.returncode} published={published} stderr={r.stderr.strip()[-240:]!r}', flush=True)
    shutil.rmtree(d, ignore_errors=True)


def fleet():
    d, env = home()
    (d / 'state/slow.meta').write_text('window=fm:fm-slow\nkind=scout\nharness=claude\n')
    (d / 'data/backlog.md').write_text('## In flight\n- [ ] slow - Slow task (repo: firstmate) (kind: scout)\n\n'
                                       '## Queued\n\n## Done\n')
    write(d / 'bin/fm-crew-state.sh', busy(45) + "print('state: working · source: pane · productive 45s read completed')\nSLOW\n")
    write(d / 'fakebin/tmux', "printf 'fm-slow\\n'\n")
    t0 = time.monotonic()
    r = subprocess.run(['bash', str(d / 'bin/fm-fleet-snapshot.sh'), '--home-input'], env=env,
                       capture_output=True, text=True)
    took = time.monotonic() - t0
    seen = 'productive 45s read completed' in r.stdout
    endpoints = ''
    try:
        endpoints = json.dumps(json.loads(r.stdout).get('endpoints', ''))[:300]
    except Exception:
        endpoints = r.stdout[-300:]
    print(f'[{LABEL}] {"PASS" if r.returncode == 0 and seen else "FAIL"} fleet_45s_task_read_is_included :: '
          f'{took:.1f}s rc={r.returncode} observation-included={seen} endpoints={endpoints!r} '
          f'stderr={r.stderr.strip()[-200:]!r}', flush=True)
    shutil.rmtree(d, ignore_errors=True)


for key, fn in (('summary', summary), ('fleet', fleet)):
    if not ONLY or key in ONLY:
        fn()
