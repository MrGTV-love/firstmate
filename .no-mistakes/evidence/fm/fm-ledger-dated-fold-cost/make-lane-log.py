#!/usr/bin/env python3
"""Build a synthetic lane status log shaped like the measured one: 1,953 lines, about 1.03 MB.

Wide notes with multibyte UTF-8 text, dated and undated stamps, keyed and keyless questions,
note-head keys, readable [at=10:30] stamps, and 40 questions left open at the end.
"""
import sys
out, lines, target_open = sys.argv[1], 1953, 40
pad = ("status café — naïve résumé ✓ " * 40)
rows, n, opened = [], 0, []
i = 0
while len(rows) < lines - target_open:
    i += 1
    t = 1780000000 + i * 37
    r = i % 6
    note = pad[: 385 + (i * 13) % 80]
    if r in (0, 3):
        rows.append(f"working [at={t}]: step {i} {note}")
    elif r == 1:
        n += 1; opened.append(n)
        rows.append(f"needs-decision [key=lane-q{n:04d}] [at={t}]: question {n} {note}")
    elif r == 2:
        n += 1; opened.append(n)
        rows.append(f"blocked: [key=lane-q{n:04d}] waiting on {n} {note}" if n % 3 else
                    f"blocked [at=10:30] [key=lane-q{n:04d}]: waiting on {n} {note}")
    elif r == 4 and opened:
        k = opened.pop(0)
        rows.append(f"resolved [key=lane-q{k:04d}] [at={t}]: answered {k} {note}")
    else:
        if opened:
            k = opened.pop(0)
            rows.append(f"captain-held [key=lane-q{k:04d}]: held {k} {note}")
        else:
            rows.append(f"continuation prose without a transition {note}")
# close everything still open, then leave exactly target_open fresh questions
tail = []
for k in opened:
    tail.append(f"resolved [key=lane-q{k:04d}]: swept {k}")
rows = rows[: lines - target_open - len(tail)] + tail
for j in range(target_open):
    t = 1791000000 + j
    rows.append(f"needs-decision [key=open-{j:02d}] [at={t}]: open question {j} {pad[:400]}")
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
