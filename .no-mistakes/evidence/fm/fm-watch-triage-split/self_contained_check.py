import re, sys, importlib.util
spec = importlib.util.spec_from_file_location('c', sys.argv[1]); c = importlib.util.module_from_spec(spec)
sys.argv_saved = sys.argv; 
exec(open(sys.argv[1]).read().split('base = sys.argv[1]')[0], c.__dict__)
helpers = c.parse(sys.argv[2])[0]
ok = True
for p in sys.argv[3:]:
    f, inv = c.parse(p)
    src = open(p).read()
    sources_helpers = 'fm-watch-triage-helpers.sh' in src
    missing = [x for x in inv if x not in f and x not in helpers]
    print(p, 'cases', len(inv), 'defined_locally', sum(x in f for x in inv), 'sources_helpers', sources_helpers, 'undefined', missing)
    ok &= not missing and sources_helpers
print('ALL_SELF_CONTAINED' if ok else 'PROBLEM')
