"""Case intervals and per-region phase_interval CPU/wall totals from FM_TEARDOWN_CPU rows."""
import json, sys
from collections import defaultdict
for path in sys.argv[1:]:
    rows = [json.loads(l.split(' ', 1)[1]) for l in open(path) if l.startswith('FM_TEARDOWN_CPU ')]
    print(path)
    for r in rows:
        if r['event'] == 'interval':
            print(f"  interval {r.get('region')} {r.get('start_mark')}->{r.get('end_mark')} valid={r['valid']} cpu={r['cpu_seconds']} wall_s={None if r['wall_ns'] is None else r['wall_ns']/1e9:.3f}" if r['wall_ns'] is not None else f"  interval {r.get('region')} valid={r['valid']} cpu=None")
        if r['event'] == 'target_exit':
            print(f"  target_exit returncode={r['returncode']} boundaries_missing={r['boundaries_missing']}")
    agg = defaultdict(lambda: [0, 0.0, 0.0, 0])
    for r in rows:
        if r['event'] != 'phase_interval':
            continue
        k = (r.get('case'), r.get('scope'), r.get('region'))
        a = agg[k]
        if r.get('valid') and r.get('cpu_seconds') is not None:
            a[0] += 1; a[1] += r['cpu_seconds']; a[2] += r['wall_ns'] / 1e9
        else:
            a[3] += 1
    for k in sorted(agg, key=str):
        n, c, w, bad = agg[k]
        print(f"  phase {k[0]} {k[1]} {k[2]}: valid={n} cpu={c:.2f}s wall={w:.3f}s invalid={bad}")
