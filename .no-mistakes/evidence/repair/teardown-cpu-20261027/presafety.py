"""Per-invocation backend.end -> safety.start envelope from FM_TEARDOWN_CPU phase_boundary rows."""
import json, sys
for path in sys.argv[1:]:
    b = {}
    for line in open(path):
        if not line.startswith('FM_TEARDOWN_CPU '):
            continue
        r = json.loads(line.split(' ', 1)[1])
        if r['event'] != 'phase_boundary':
            continue
        f = r['mark'].split('|')
        if f[1] == 'product':
            b.setdefault(f[2], {})[f[4]] = r
    tot_cpu = tot_wall = 0.0
    n = 0
    print(path)
    for pid, m in b.items():
        s, e = m.get('backend.end'), m.get('safety.start')
        if not s or not e or s['cpu_seconds'] is None or e['cpu_seconds'] is None:
            print(f'  pid {pid}: missing endpoint'); continue
        cpu = e['cpu_seconds'] - s['cpu_seconds']; wall = (e['monotonic_ns'] - s['monotonic_ns']) / 1e9
        n += 1; tot_cpu += cpu; tot_wall += wall
        print(f'  pid {pid}: presafety cpu={cpu:.2f}s wall={wall:.3f}s')
    print(f'  TOTAL invocations={n} presafety_cpu={tot_cpu:.2f}s presafety_wall={tot_wall:.3f}s')
