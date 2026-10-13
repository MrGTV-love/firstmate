import re, sys, glob, json
FN = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{\s*(#.*)?$')
def parse(path):
    lines = open(path).read().split('\n')
    funcs, i, invocations, after_sel = {}, 0, [], False
    while i < len(lines):
        m = FN.match(lines[i])
        if m:
            j = i
            while lines[j] != '}': j += 1
            funcs[m.group(1)] = '\n'.join(lines[i:j+1]); i = j + 1; continue
        if lines[i].startswith('if [ -n "${FM_TEST_ONLY:-}" ]'): after_sel = True
        if after_sel and re.fullmatch(r'test_[A-Za-z0-9_]+', lines[i]): invocations.append(lines[i])
        i += 1
    return funcs, invocations
base = sys.argv[1]; new = sys.argv[2:]
bf, binv = parse(base)
nf_all, ninv_all, per = {}, [], {}
dups = []
for p in new:
    f, inv = parse(p)
    for k, v in f.items():
        if k in nf_all and nf_all[k] != v: dups.append(k)
        nf_all.setdefault(k, v)
    ninv_all += [(p, x) for x in inv]; per[p] = len(inv)
btests = [k for k in bf if k.startswith('test_')]
changed = [k for k in bf if k in nf_all and bf[k] != nf_all[k]]
missing = [k for k in bf if k not in nf_all]
added = [k for k in nf_all if k not in bf]
names = [x for _, x in ninv_all]
from collections import Counter
c = Counter(names)
print(json.dumps({
 'base_test_functions': len(btests), 'base_invocations': len(binv), 'base_invocations_unique': len(set(binv)),
 'new_invocations_total': len(names), 'new_invocations_per_file': per,
 'invoked_more_than_once': [k for k, v in c.items() if v > 1],
 'base_invoked_not_in_new': sorted(set(binv) - set(names)),
 'new_invoked_not_in_base': sorted(set(names) - set(binv)),
 'base_functions_total': len(bf), 'functions_missing_in_split': missing,
 'functions_with_changed_body': changed, 'functions_added_in_split': added,
 'conflicting_duplicate_definitions': dups,
 'invocation_order_preserved_within_files': all(
   [x for x in binv if x in set(n for q, n in ninv_all if q == p)] == [n for q, n in ninv_all if q == p] for p in new),
}, indent=1))
