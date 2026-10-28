"""Pool presafety CPU pair deltas across r4, r5, r6 (each: p1 A-then-B, p2 B-then-A), all with the lifecycle repair in both trees."""
import statistics as st, subprocess, sys
ev = sys.argv[1]
rows = {}
for r in ('r4', 'r5', 'r6'):
    out = subprocess.run([sys.executable, f'{ev}/r5/compare.py', f'{ev}/{r}'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if f and f[0] in ('p1-A', 'p1-B', 'p2-B', 'p2-A'):
            rows[(r, f[0])] = float(f[3])
d = []
print('round pair  A_presafety B_presafety A-B')
for r in ('r4', 'r5', 'r6'):
    for p in ('p1', 'p2'):
        a, b = rows[(r, p + '-A')], rows[(r, p + '-B')]
        d.append(a - b)
        print(f'{r:5} {p:5} {a:11.2f} {b:11.2f} {a-b:+.2f}')
A = [v for (r, k), v in rows.items() if k.endswith('A')]; B = [v for (r, k), v in rows.items() if k.endswith('B')]
m, sd = st.mean(d), st.stdev(d); se = sd / len(d) ** 0.5
print(f'n_pairs={len(d)} mean(A-B)={m:+.3f} s sd={sd:.3f} se={se:.3f} t={m/se:.2f} (|t|<2.57 for df=5 at 95%: not distinguishable from 0)')
print(f'A mean {st.mean(A):.2f} s (range {min(A):.2f}-{max(A):.2f}); B mean {st.mean(B):.2f} s (range {min(B):.2f}-{max(B):.2f})')
print(f'pairs with A>B: {sum(x>0 for x in d)}/{len(d)}')
