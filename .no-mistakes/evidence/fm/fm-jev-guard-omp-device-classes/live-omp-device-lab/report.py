import json, sys, pathlib
lab = pathlib.Path(sys.argv[1]); run = sys.argv[2]
scen = json.loads((lab/f'scen-{run.lower()}.json').read_text()) if (lab/f'scen-{run.lower()}.json').exists() else json.loads((lab/'scenario.json').read_text())
reqs = [json.loads(l) for l in (lab/'results'/run/'model.jsonl').read_text().splitlines()]
outs = {}
for r in reqs:
    for i in r.get('input', []):
        if i.get('type') == 'function_call_output': outs[i['call_id']] = i['output']
audit = [json.loads(l) for l in (lab/'results'/run/'jev-guard.jsonl').read_text().splitlines() if l.strip()]
tc = [a for a in audit if a.get('hook') == 'tool_call']
for n, (name, call) in enumerate(zip(scen['names'], scen['calls'])):
    out = outs.get(f'call_{n}', '<no output>')
    a = tc[n] if n < len(tc) else {}
    print(f"### [{n}] {name}\ncall: {call['tool']} {json.dumps(call['args'])}")
    print(f"audit: decision={a.get('decision')} branch={a.get('branch')} enforcement={a.get('enforcement')} request_started={a.get('request_started')}")
    print("result:", out.replace('\n', '\n        '))
    print()
