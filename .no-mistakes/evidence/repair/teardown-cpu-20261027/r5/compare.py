"""Per-run selected totals and per-pair A-B deltas from FM_TEARDOWN_CPU rows (same fields as r4/comparison.txt)."""
import json, sys
ev = sys.argv[1]
O = 'test_local_only_force_overrides_unpushed'; D = 'test_docker_all_failure_channels_retain_forced_tasks_until_retry'
def load(label):
    rows = [json.loads(l.split(' ', 1)[1]) for l in open(f'{ev}/{label}/stdout.log') if l.startswith('FM_TEARDOWN_CPU ')]
    res = {'target_exit': next(r['returncode'] for r in rows if r['event'] == 'target_exit')}
    for r in rows:
        if r['event'] == 'interval' and r.get('region') in (O, D):
            res['ord' if r['region'] == O else 'dock'] = r['cpu_seconds']
    b = {}
    for r in rows:
        if r['event'] == 'phase_boundary':
            f = r['mark'].split('|')
            if f[1] == 'product': b.setdefault(f[2], {})[f[4]] = r
    pc = pw = 0.0; n = 0
    for m in b.values():
        s, e = m.get('backend.end'), m.get('safety.start')
        if s and e and s['cpu_seconds'] is not None and e['cpu_seconds'] is not None:
            n += 1; pc += e['cpu_seconds'] - s['cpu_seconds']; pw += (e['monotonic_ns'] - s['monotonic_ns']) / 1e9
    res.update(pre_n=n, pre_cpu=pc, pre_wall=pw)
    cli = [r for r in rows if r['event'] == 'phase_interval' and r.get('region') == 'cli' and r.get('valid')]
    res.update(cli_n=len(cli), cli_cpu=sum(r['cpu_seconds'] for r in cli), cli_wall=sum(r['wall_ns'] for r in cli) / 1e9)
    return res
R = {l: load(l) for l in ('p1-A', 'p1-B', 'p2-B', 'p2-A')}
print('run   target_exit pre_n presafety_cpu presafety_wall ordinary_case_cpu docker_case_cpu cli_n cli_cpu cli_wall')
for l, r in R.items():
    print(f"{l:5} {r['target_exit']:11} {r['pre_n']:5} {r['pre_cpu']:13.2f} {r['pre_wall']:14.3f} {r['ord']:17.2f} {r['dock']:15.2f} {r['cli_n']:5} {r['cli_cpu']:7.2f} {r['cli_wall']:8.3f}")
for name, a, b in (('pair1 (A then B)', 'p1-A', 'p1-B'), ('pair2 (B then A)', 'p2-A', 'p2-B')):
    A, B = R[a], R[b]
    print(f"{name} A-B: presafety_cpu {A['pre_cpu']-B['pre_cpu']:+.2f} s, presafety_wall {A['pre_wall']-B['pre_wall']:+.3f} s, ordinary_case_cpu {A['ord']-B['ord']:+.2f} s, docker_case_cpu {A['dock']-B['dock']:+.2f} s, cli_cpu {A['cli_cpu']-B['cli_cpu']:+.2f} s")
print("per-invocation presafety cpu (s), sorted, per run:")
