#!/usr/bin/env python3
# Test rig only. Passes GitHub READS to the real gh. Refuses every write.
# `gh pr merge` is logged and never reaches GitHub.
import hashlib, json, os, re, subprocess, sys
REAL = '/opt/homebrew/bin/gh'
RIG = os.environ['RIG']; SCEN = os.environ.get('SCEN_DIR', '')
argv = sys.argv[1:]
def log(tag):
    if SCEN:
        with open(f'{SCEN}/gh.log', 'a') as f: f.write(tag + ' ' + ' '.join(a[:90] for a in argv) + '\n')
def env_real():
    e = dict(os.environ); e['HOME'] = os.environ['RIG_REAL_HOME']; return e
if argv[:2] == ['pr', 'merge']:
    log('BLOCKED-MERGE'); print('test rig: gh pr merge blocked; nothing was sent to GitHub', file=sys.stderr); sys.exit(1)
mutating = {'-X', '--method', '--input'}
api = argv[:1] == ['api']
ok = argv[:2] == ['pr', 'view'] or argv[:2] == ['auth', 'git-credential']
endpoint = next((a for a in argv[1:] if not a.startswith('-') and ('repos/' in a or a == 'graphql')), '') if api else ''
if api and not (mutating & set(argv)):
    if endpoint == 'graphql': ok = 'mutation' not in ' '.join(argv)
    else: ok = not ({'-f', '-F', '--field', '--raw-field'} & set(argv))
if not ok:
    log('REFUSED'); print('test rig: refused non-read gh call', file=sys.stderr); sys.exit(1)
log('READ')
def over(name):
    p = f'{SCEN}/{name}' if SCEN else ''
    return p if p and os.path.exists(p) else None
# compare override: Nth read uses compare.N, else compare.final.
if '/compare/' in endpoint and over('compare.final'):
    cf = f'{SCEN}/compare.count'; n = int(open(cf).read()) + 1 if os.path.exists(cf) else 1
    open(cf, 'w').write(str(n))
    p = over(f'compare.{n}') or over('compare.final')
    sys.stdout.write(open(p).read()); sys.exit(0)
if '/rules/branches/' in endpoint and over('rules.json'):
    sys.stdout.write(open(over('rules.json')).read()); sys.exit(0)
cacheable = api and re.search(r'/(actions/jobs/\d+|actions/runs/\d+/attempts/\d+|actions/runs/\d+/artifacts|commits/[0-9a-f]+/check-runs)$', endpoint.split('?')[0])
key = hashlib.sha256(' '.join(argv).encode()).hexdigest()
cpath = f'{RIG}/cache/{key}'
if cacheable and os.environ.get('RIG_CACHE') == '1' and os.path.exists(cpath):
    out = open(cpath).read(); rc = 0
else:
    r = subprocess.run([REAL] + argv, stdout=subprocess.PIPE, stdin=sys.stdin if argv[:2]==['auth','git-credential'] else None, env=env_real(), text=True)
    out, rc = r.stdout, r.returncode
    if cacheable and rc == 0:
        open(cpath, 'w').write(out)
if rc: sys.stdout.write(out); sys.exit(rc)
# Scenario edits of a real response, by endpoint kind.
script = None
if '/artifacts' in endpoint and over('artifacts.py'): script = over('artifacts.py')
if endpoint.split('?')[0].endswith('/check-runs') and over('checkruns.py'): script = over('checkruns.py')
if endpoint == 'graphql' and 'statusCheckRollup' in ' '.join(argv) and over('rollup.py'): script = over('rollup.py')
if script:
    dec = json.JSONDecoder(); docs = []; i = 0
    while i < len(out):
        while i < len(out) and out[i].isspace(): i += 1
        if i >= len(out): break
        d, i = dec.raw_decode(out, i); docs.append(d)
    multi = len(docs) == 1 and isinstance(docs[0], list)
    data = docs[0] if multi else docs
    ns = {'data': data, 'endpoint': endpoint}
    exec(open(script).read(), ns)
    out = json.dumps(ns['data']) if multi else '\n'.join(json.dumps(d) for d in ns['data'])
sys.stdout.write(out)
