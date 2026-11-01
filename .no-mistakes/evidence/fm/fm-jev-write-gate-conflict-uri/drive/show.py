import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l); c=r["call"]; a=c["args"]
    target=a.get("path",a.get("command",""))
    print("--- step %d: %s %r"%(r["step"],c["tool"],target))
    o=r["result"]; o=o if isinstance(o,str) else json.dumps(o)
    print(o)
