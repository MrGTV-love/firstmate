#!/usr/bin/env python3
"""Test-step check of raw FM_TEARDOWN_CPU phase_boundary rows (not a measurement parser).
For every product sender PID in a phase-eligible case: verify mark order, PID/PPID identity
against the open helper cli invocation, and print the three raw growth envelopes."""
import json, sys, collections
rows=[json.loads(l[16:]) for l in open(sys.argv[1]) if l.startswith('FM_TEARDOWN_CPU ')]
errs=[r for r in rows if r['event']=='instrumentation_error']
case=None; helpers={}; prods=collections.OrderedDict(); bad=[]
for r in rows:
    if r['event']=='phase_scope': case=r['case']
    if r['event']!='phase_boundary': continue
    p=r['mark'].split('|'); scope,pid,ppid,edge=p[1],p[2],p[3],p[4]
    if scope=='helper':
        if edge=='cli.start': helpers[pid]=case
        continue
    if edge=='entry':
        prods[(case,pid,len(prods))]=[]
        if ppid not in helpers: bad.append(('product parent not an open helper',r['mark']))
    key=[k for k in prods if k[1]==pid][-1]
    prods[key].append((edge,ppid,r['cpu_seconds'],r['monotonic_ns']))
order=['entry','startup.end','backend.start','backend.end','guard.end','routing.end','safety.start','safety.end','runtime.start','runtime.end','docker.start','docker.end']
reached=collections.Counter(); env=collections.defaultdict(list)
for (c,pid,_),m in prods.items():
    edges=[e for e,*_ in m]
    if len({pp for _,pp,_,_ in m})!=1: bad.append(('ppid changed',pid))
    if edges!=[e for e in order if e in edges] or edges!=order[:len(edges)]:
        bad.append(('order/prefix gap',c,pid,edges))
    reached[(c,edges[-1])]+=1
    d={e:(cpu,ns) for e,_,cpu,ns in m}
    for a,b in (('backend.end','guard.end'),('guard.end','routing.end'),('routing.end','safety.start')):
        if a in d and b in d: env[(a,b)].append((d[b][0]-d[a][0], (d[b][1]-d[a][1])/1e9))
        elif a in d and b not in d: env[(a,b,'entered_no_endpoint')].append(pid)
print('instrumentation_errors',len(errs),errs[:3])
print('product_invocations',len(prods))
for k,v in sorted(reached.items()): print('last_mark',k,v)
for k,v in env.items():
    if len(k)==2: print('envelope %s->%s n=%d cpu_s_sum=%.3f wall_s_sum=%.3f min_cpu=%.4f'%(k[0],k[1],len(v),sum(x for x,_ in v),sum(y for _,y in v),min(x for x,_ in v)))
    else: print('entered_without_endpoint',k,len(v))
print('violations',bad if bad else 'none')
sys.exit(1 if bad or errs else 0)
