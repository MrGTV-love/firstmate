#!/usr/bin/env python3
"""r3-ledger-questions.py <bin-dir> <label>: run the real ledger and print its coverage and question rows."""
import json, os, subprocess, sys
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'}
p = subprocess.run([sys.argv[1] + '/fm-open-loops.sh', '--json'], env=env, capture_output=True, text=True, errors='replace')
r = json.loads(p.stdout)
print(f'== {sys.argv[2]} (LC_ALL={os.environ.get("LC_ALL")}) exit={p.returncode} complete={r["complete"]}')
for x in r['rows']:
    if x['category'] == 'coverage': print('   coverage |', x['subject'], '|', x['evidence'][:200])
    if x['category'] == 'unanswered_question': print('   question |', x['subject'], '|', repr(x['evidence']))
