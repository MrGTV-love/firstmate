# Live T4 smoke: real installed omp host, real fm-jev-guard extension, private scripted model provider.
# A downstream stop handler blocks any admitted call so no paid search, report upload or eval code runs.
import json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-t4-omp.'))
for name in ('agent', 'home/config', 'home/state', 'home/data', 'worktree', 'tmp'):
    (lab / name).mkdir(parents=True, exist_ok=True)
(lab / 'jev.jsonl').write_text(''); (lab / 'model.jsonl').write_text('')
server_log = (lab / 'server.log').open('w')
server = subprocess.Popen(['python3', '-I', str(root / 'tests/fm-jev-guard-native-fixture.py'), str(lab), 'omp'], stdout=server_log, stderr=server_log)
report = []
def say(line):
    print(line, flush=True); report.append(line)
try:
    while not (lab / 'port').exists():
        assert server.poll() is None, 'fixture exited'
        time.sleep(.05)
    port = (lab / 'port').read_text().strip()
    (lab / 'agent/config.yml').write_text('setupVersion: 2\nfind:\n  enabled: on\nmodelRoles:\n  default: native/gpt-6.1-sol\nretry:\n  maxRetries: 0\n  fallbackChains: {}\n')
    (lab / 'agent/models.yml').write_text(f'providers:\n  native:\n    baseUrl: http://127.0.0.1:{port}/v1\n    apiKey: synthetic-local-only\n    api: openai-responses\n    models:\n      - id: gpt-6.1-sol\n        contextWindow: 200000\n        maxTokens: 4096\n')
    ctx = {'home': str(lab/'home'), 'config': str(lab/'home/config'), 'state': str(lab/'home/state'), 'task': 'native',
           'data': str(lab/'home/data'), 'worktree': str(lab/'worktree'), 'project': 'firstmate', 'policy': 'FIRSTMATE_JEV_GUARD_V1'}
    (lab / 'extension.ts').write_text('import { writeFileSync } from "node:fs";\n'
        + f'import {{ installJevGuard }} from {json.dumps(str(root / "bin/fm-jev-guard.ts"))};\n'
        + 'export default function(pi: any) {\n'
        + f'  installJevGuard(pi, {json.dumps(ctx)});\n'
        + '  pi.registerTool({ name: "new_paid_host_tool", label: "New paid host tool", description: "Synthetic unlisted host tool.",\n'
        + '    parameters: { type: "object", properties: { q: { type: "string" } } },\n'
        + f'    async execute() {{ writeFileSync({json.dumps(str(lab/"unlisted-executed"))}, "ran"); return {{ content: [{{ type: "text", text: "unlisted ran" }}], details: {{}} }}; }} }});\n'
        + '  pi.on("tool_call", (event: any) => {\n'
        + f'    writeFileSync({json.dumps(str(lab/"downstream-reached"))}, event.toolName);\n'
        + '    return { block: true, reason: "Synthetic downstream stop: admitted by jev-guard; nothing executed." };\n'
        + '  });\n}\n')
    env = {k: v for k, v in os.environ.items() if k not in ('FM_GUARD_EVENT_LOG', 'TYPESAFE_API_KEY', 'OPENROUTER_API_KEY')}
    env.update(PI_CODING_AGENT_DIR=str(lab/'agent'), OMP_SKIP_SETUP='1', HOME=str(lab/'os-home'), TMPDIR=str(lab/'tmp'),
               FM_TEST_SEAM='1', FM_JEV_GUARD_BASE_URL=f'http://127.0.0.1:{port}/v1/systemone')
    (lab/'os-home').mkdir(exist_ok=True)
    allc = ["semantic-search","web","browser","provider","subagent","remote-storage"]
    cases = [
        ('T4(b) find, no grant', 'find', {'i':'probe','query':'private-query-canary','grep_keywords':[],'path':'.'}, None, 'block'),
        ('T4(b) find, egress=["semantic-search"]', 'find', {'i':'probe','query':'private-query-canary','grep_keywords':[],'path':'.'}, ['semantic-search'], 'allow'),
        ('T4(a) write xd://report_issue, no grant', 'write', {'i':'probe','path':'xd://report_issue','content':'private-report-canary'}, None, 'block'),
        ('T4(a) write xd://report_issue, all six egress classes granted', 'write', {'i':'probe','path':'xd://report_issue','content':'private-report-canary'}, allc, 'block'),
        ('T4 web_search, no grant', 'web_search', {'query':'private-query-canary'}, None, 'block'),
        ('T4(c) eval, no grant', 'eval', {'title':'probe','language':'py','code':'print("private-eval-canary")'}, None, 'allow'),
        ('T4(d) extension-registered unlisted tool, all grants', 'new_paid_host_tool', {'q':'private-query-canary'}, allc, 'block'),
    ]
    events_path = lab/'home/state/guard-events.jsonl'
    audit_path = lab/'home/state/jev-guard.jsonl'
    def lines(p):
        return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
    failures = 0
    for name, tool, args, grant, expect in cases:
        for f in ('downstream-reached', 'home/state/native.meta'):
            (lab/f).unlink(missing_ok=True)
        if grant is not None:
            (lab/'home/state/native.meta').write_text('egress=' + json.dumps(grant) + '\n')
        (lab/'scenario.json').write_text(json.dumps({'phase':'normal','tool':tool,'args':args}))
        subprocess.run(['curl','-fsS','-X','POST','-d','{}',f'http://127.0.0.1:{port}/reset'], check=True, stdout=subprocess.DEVNULL)
        ev0, au0 = len(lines(events_path)), len(lines(audit_path))
        (lab/'model.jsonl').write_text('')
        log = lab/f'{tool}.log'
        r = subprocess.run(['omp','-p','Run the one synthetic tool call, then stop.','--model','native/gpt-6.1-sol','--thinking','off','--no-session',
            '--no-extensions','-e',str(lab/'extension.ts'),'--config',str(root/'.omp/fm-worker-overlay.yml'),'--no-skills','--no-rules','--no-title','--no-lsp','--tools',tool],
            cwd=lab/'worktree', env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        reqs = (lab/'model.jsonl').read_text().splitlines()
        last = reqs[-1] if reqs else ''
        # The tool_result text the host fed back to the model on turn 2.
        outputs = [i.get('output') for i in json.loads(last).get('input', []) if isinstance(i, dict) and i.get('type') == 'function_call_output'] if last else []
        new_events = [[e['guard'], e['decision'], e['session'], e['source_ok']] for e in lines(events_path)[ev0:]]
        new_audit = lines(audit_path)[au0:]
        reached = (lab/'downstream-reached').exists()
        decision = new_audit[-1]['decision'] if new_audit else ('allow' if reached else '?')
        canary_leak = any('canary' in json.dumps(x) for x in new_audit) or any('canary' in json.dumps(x) for x in lines(events_path)[ev0:])
        ok = r.returncode == 0 and ((expect == 'allow') == reached) and decision == expect and not canary_leak and not (lab/'unlisted-executed').exists()
        failures += not ok
        say(f'{"PASS" if ok else "FAIL"} {name}: omp exit={r.returncode} guard={decision} branch={new_audit[-1].get("branch") if new_audit else None} '
            f'dest={new_audit[-1].get("destination_class") if new_audit else None} owner={new_audit[-1].get("confinement_owner") if new_audit else None} '
            f'downstream_reached={reached} canary_in_logs={canary_leak}')
        say(f'    central events: {json.dumps(new_events)}')
        say(f'    tool result seen by model: {json.dumps(outputs)[:400]}')
    say(f'Jev model requests during T4 decisions: {len((lab/"jev.jsonl").read_text().splitlines())}')
    say(f'omp version: {subprocess.run(["omp","--version"],capture_output=True,text=True).stdout.strip()}')
    say(f'RESULT failures={failures}')
finally:
    server.terminate(); server.wait(); server_log.close()
    out.write_text('\n'.join(report) + '\n')
    subprocess.run(['rm','-rf',str(lab)])
