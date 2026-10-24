import re,sys,glob,os
O=sys.argv[1]
def parse(p):
    fns={};cur=None;buf=[]
    for line in open(p,errors='replace'):
        m=re.match(r'^([A-Za-z_][A-Za-z0-9_:.-]*) \(\) $',line)
        if m and cur is None:
            cur=m.group(1);buf=[line];continue
        if cur is not None:
            buf.append(line)
            if line=='}\n':
                fns[cur]=''.join(buf);cur=None
    return fns
print("# Runtime function bodies (bash `declare -f` at the last case call (base) and at the selector or first case call (head)) compared base 07e31643 vs head")
for b,heads in [('fm-watch-triage-waits',['fm-watch-triage-waits','fm-watch-triage-waits-declared','fm-watch-triage-waits-pauses','fm-watch-triage-waits-away']),('fm-control-relaunch',['fm-control-relaunch','fm-control-relaunch-recovery','fm-control-relaunch-backends'])]:
    base=parse(f'{O}/base-{b}.fn')
    print(f'\n== {b} == base defines {len(base)} functions')
    union={}
    for h in heads:
        hf=parse(f'{O}/head-{h}.fn')
        diffbody=[n for n in hf if n in base and hf[n]!=base[n]]
        new=[n for n in hf if n not in base]
        print(f'{h}: {len(hf)} functions; body differs from base: {diffbody or "none"}; not in base: {new or "none"}')
        for n,v in hf.items(): union.setdefault(n,set()).add(v)
    conflicting=[n for n,v in union.items() if len(v)>1]
    missing=sorted(n for n in base if n not in union)
    print(f'union across groups: {len(union)} functions; same name with different bodies across groups: {conflicting or "none"}')
    print(f'base functions defined by no head group: {missing or "none"}')
