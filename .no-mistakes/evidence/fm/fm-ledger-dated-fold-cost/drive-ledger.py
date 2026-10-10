#!/usr/bin/env python3
"""drive-ledger.py <bin-dir> <label>: run the real fm-open-loops.sh --json against $FM_HOME and summarize it."""
import json, os, subprocess, sys, time, collections
bindir, label = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'}
load = subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip()
t = time.time()
p = subprocess.run([bindir + '/fm-open-loops.sh', '--json'], env=env, capture_output=True, text=True, errors='replace')
wall = time.time() - t
print(f'== {label} ({bindir})\n load: {load}\n exit={p.returncode} wall_seconds={wall:.1f}')
if p.stderr.strip(): print(' stderr:', p.stderr.strip()[:300])
r = json.loads(p.stdout)
print(' complete:', r['complete'])
print(' rows by category:', dict(collections.Counter(x['category'] for x in r['rows'])))
for x in r['rows']:
    if x['category'] in ('coverage', 'unlanded_commit'):
        print(' ', x['category'], '|', x['subject'], '|', x['evidence'][:260])
q = [x for x in r['rows'] if x['category'] == 'unanswered_question']
if q: print('  first question:', q[0]['subject'], '|', q[0]['evidence'][:90])
