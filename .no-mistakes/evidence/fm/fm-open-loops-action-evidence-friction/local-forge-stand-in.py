#!/usr/bin/env python3
# Disposable local forge stand-in: serves $FM_HOME/forge.json (PR, check runs) instead of api.github.com.
import json, os, sys
from pathlib import Path
f = json.loads((Path(os.environ['FM_HOME']) / 'forge.json').read_text())
url = sys.argv[2]
if '/reviews' in url: value = []
elif '/pulls?' in url: value = [f['pr']]
elif '/pulls/' in url: value = f['pr']
elif '/check-runs' in url: value = {'check_runs': f['checks']}
elif '/statuses?' in url: value = []
elif '/reviews' in url: value = []
else: raise SystemExit('unexpected forge read ' + url)
print(json.dumps([value]))
