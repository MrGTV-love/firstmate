#!/usr/bin/env python3
"""Compare the pre-split teardown suite with the split files.

Checks:
1. Registered case lists: union of the three group arrays equals the base
   array as a set, with no duplicates, no additions, no drops.
2. Every top-level function (cases and helpers) in the base file appears
   byte-for-byte in exactly one of the split files, and the split files add
   no new top-level function.
3. Reports top-level non-function lines that differ (headers, sourcing).
"""
import re
import sys
from collections import Counter

base_path, *new_paths = sys.argv[1:]
FUNC = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{')


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read().split('\n')


def cases(lines):
    out, inside = [], False
    for ln in lines:
        if ln.startswith('teardown_test_cases=('):
            inside = True
            continue
        if inside:
            if ln == ')':
                break
            s = ln.strip()
            if s and not s.startswith('#'):
                out.append(s)
    return out


def functions(lines):
    """Return {name: text} for top-level functions and residual top-level lines."""
    funcs, residual, i = {}, [], 0
    while i < len(lines):
        m = FUNC.match(lines[i])
        if m:
            name, start = m.group(1), i
            # one-line function
            if lines[i].rstrip().endswith('}') and lines[i].count('{') == lines[i].count('}'):
                funcs.setdefault(name, []).append(lines[i])
                i += 1
                continue
            i += 1
            while i < len(lines) and lines[i] != '}':
                i += 1
            funcs.setdefault(name, []).append('\n'.join(lines[start:i + 1]))
            i += 1
            continue
        residual.append(lines[i])
        i += 1
    return funcs, residual


base = read(base_path)
base_cases = cases(base)
base_funcs, base_res = functions(base)
ok = True

print(f'base file: {base_path}')
print(f'base registered cases: {len(base_cases)} (unique {len(set(base_cases))})')

union = []
new_funcs = {}
new_res = {}
for p in new_paths:
    ls = read(p)
    c = cases(ls)
    f, r = functions(ls)
    new_res[p] = r
    print(f'{p}: registered cases {len(c)}, top-level functions {sum(len(v) for v in f.values())}')
    union += c
    for k, v in f.items():
        new_funcs.setdefault(k, []).extend((p, t) for t in v)

dups = [k for k, n in Counter(union).items() if n > 1]
drops = sorted(set(base_cases) - set(union))
adds = sorted(set(union) - set(base_cases))
print(f'union registered: {len(union)}; duplicates {len(dups)}; drops {len(drops)}; additions {len(adds)}')
for label, items in (('DUPLICATE', dups), ('DROPPED', drops), ('ADDED', adds)):
    for x in items:
        ok = False
        print(f'  {label}: {x}')

# Function byte equality.
dup_defs_base = [k for k, v in base_funcs.items() if len(v) > 1]
moved_same = moved_diff = missing = 0
for name, texts in base_funcs.items():
    got = new_funcs.get(name, [])
    if not got:
        missing += 1
        ok = False
        print(f'  MISSING FUNCTION: {name}')
        continue
    if len(got) != len(texts):
        ok = False
        print(f'  DEFINITION COUNT CHANGED: {name} base={len(texts)} new={len(got)} in {[p for p, _ in got]}')
    if sorted(t for _, t in got) == sorted(texts):
        moved_same += 1
    else:
        moved_diff += 1
        ok = False
        print(f'  BODY CHANGED: {name} in {[p for p, _ in got]}')
extra = sorted(set(new_funcs) - set(base_funcs))
for x in extra:
    ok = False
    print(f'  NEW FUNCTION: {x}')
print(f'base top-level function names: {len(base_funcs)} (multi-defined: {dup_defs_base})')
print(f'functions byte-identical after move: {moved_same}; changed: {moved_diff}; missing: {missing}; new: {len(extra)}')

# Residual top-level text.
base_res_set = Counter(l for l in base_res if l.strip())
new_res_all = Counter(l for r in new_res.values() for l in r if l.strip())
only_base = base_res_set - new_res_all
only_new = new_res_all - base_res_set
print(f'residual non-function lines only in base: {sum(only_base.values())}; only in split files: {sum(only_new.values())}')
for l, n in only_base.items():
    print(f'  -base x{n}: {l}')
for l, n in only_new.items():
    print(f'  +split x{n}: {l}')

print('RESULT:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
