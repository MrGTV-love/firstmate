import sys
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(src).read()
anchor = "    samples += 1\n"
assert t.count(anchor) == 1
if mode.startswith('gap'):
    secs = mode[3:]
    inj = anchor + "    if groups and not globals().get('_inj'):\n        _inj = True\n        time.sleep(%s)  # INJECTED one-time sampler pause\n" % secs
    t = t.replace(anchor, inj)
elif mode == 'nocheck':
    a = "    sampler_saw_every_worker(case, seen, ['%s.%d' % (group, pid) for group, pid, _ in began], label)\n"
    assert t.count(a) == 1
    t = t.replace(a, "    pass  # MUTANT: H3abc no longer checks for missed workers\n")
open(dst, 'w').write(t)
