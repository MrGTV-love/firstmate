import os, pathlib, subprocess, json, time, shutil
ROOT = pathlib.Path.cwd()
BASE = ROOT / '.fm-live-validation'
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4D34BGQE483Q5806J9GM9AX')
BASE.mkdir(exist_ok=True)
EVIDENCE.mkdir(parents=True, exist_ok=True)
home = BASE / 'home'
project = BASE / 'project'
for p in (home/'config', project): p.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','NODE_OPTIONS','TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE','OPENROUTER_API_KEY','OPENROUTER_API_KEY_PRIVATE'):
        env.pop(k, None)
env['FM_HOME'] = str(home)
results = []
def run(args, timeout=60, **kwargs):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=kwargs.pop('env',env), text=True, capture_output=True, timeout=timeout, **kwargs)
    return p

def save(name, value):
    (EVIDENCE / name).write_text(value if isinstance(value,str) else json.dumps(value, indent=2)+'\n')

def check(name, assertions, evidence):
    ok = all(assertions)
    results.append({'name':name, 'pass':ok, 'evidence':evidence})
    print(json.dumps(results[-1]), flush=True)

help_result = run([ROOT/'bin/fm-skill-pick.sh', '--help'])
save('picker-help.txt', help_result.stdout + help_result.stderr)
check('direct executable CLI help', [help_result.returncode == 0, 'Usage:' in help_result.stdout], 'picker-help.txt')
run(['git','init','-q','-b','main',project])
for i in range(1,301):
    name = f'skill-{i:03}'
    p = project/'.agents/skills'/name/'SKILL.md'
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(f'---\nname: {name}\ndescription: Use for synthetic task {i}.\n---\n# Procedure\nRead the inputs for synthetic task {i}.\n')
for name in ('skill-001','claude-only'):
    p = project/'.claude/skills'/name/'SKILL.md'
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(f'---\nname: {name}\ndescription: CLAUDE COPY {name}.\n---\nDo a synthetic check.\n')
run(['git','-C',project,'add','.agents','.claude'])
run(['git','-C',project,'-c','user.name=Live Validation','-c','user.email=validation@example.invalid','commit','-qm','synthetic catalog'])
for name in ('untracked','linked-target'):
    p = project/name/'SKILL.md' if name == 'linked-target' else project/'.agents/skills'/name/'SKILL.md'
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(f'---\nname: {name}\ndescription: NEVER-SEND-LINKED-CONTENTS\n---\nPrivate synthetic procedure.\n')
(project/'non-skill-target').mkdir()
(project/'.agents/skills/linked-skill').symlink_to(project/'linked-target',target_is_directory=True)
(project/'.agents/skills/claude-only').symlink_to(project/'non-skill-target',target_is_directory=True)
roster_result = run(['node',ROOT/'bin/fm-skill-pick.mjs','roster',project/'.agents/skills',project/'.claude/skills'])
roster = json.loads(roster_result.stdout)
save('project-roster.json',roster)
by_name = {x['name']:x for x in roster['skills']}
check('full project roster and excluded links', [len(by_name)==301, by_name['skill-001']['description']=='Use for synthetic task 1.', 'claude-only' in by_name, {x['name'] for x in roster['not_judged']}=={'untracked','linked-skill'}, 'NEVER-SEND-LINKED-CONTENTS' not in roster_result.stdout], 'project-roster.json')
brief = BASE/'brief.md'
brief.write_text("# Task\n## Captain's intent\nValidate synthetic task 300 with its documented procedure.\n\n## Firstmate spec\nRead the skill and report one result.\n\n## Boilerplate\nDO-NOT-SEND-BOILERPLATE\n")
record = BASE/'record'
args = [ROOT/'bin/fm-skill-pick.sh','--brief',brief,'--catalog',project/'.agents/skills','--catalog',project/'.claude/skills','--record',record]
r = run(args)
save('picker-no-key.txt',r.stdout+'\n--- persisted selection ---\n'+record.read_text())
check('missing keys gives actionable selection instructions', [r.returncode==0, 'no TypeSafe or OpenRouter key' in r.stdout, 'check your skill index' in r.stdout, 'status=unavailable' in record.read_text()], 'picker-no-key.txt')
(home/'.env').write_text('TYPESAFE_API_KEY=synthetic-invalid-live-validation\nOPENROUTER_API_KEY=synthetic-invalid-live-validation\n')
observer=BASE/'observe-fetch.mjs'
observer.write_text("import { appendFileSync } from 'node:fs';\nconst original = globalThis.fetch;\nglobalThis.fetch = async (url, init) => {\n appendFileSync(process.env.LIVE_FETCH_LOG, JSON.stringify({url:String(url), body:JSON.parse(init.body)})+'\\n');\n return original(url,init);\n};\n")
fetchlog=BASE/'network.jsonl'
observed_env=dict(env,NODE_OPTIONS='--import='+str(observer),LIVE_FETCH_LOG=str(fetchlog))
(home/'config/dispatch-never-send').write_text('synthetic task 300\n')
fetchlog.write_text('')
r=run(args,env=observed_env)
save('privacy-task-refusal.txt',r.stdout+'\n--- selection ---\n'+record.read_text()+'\n--- observed real fetch calls ---\n'+fetchlog.read_text())
check('never-send task literal stops network delivery', ['status=unavailable' in record.read_text(),'withheld by dispatch-never-send policy' in r.stdout,fetchlog.read_text()==''], 'privacy-task-refusal.txt')
(home/'config/dispatch-never-send').write_text('Use for synthetic task 1.\n')
fetchlog.write_text('')
r=run(args,env=observed_env)
save('privacy-description-refusal.txt',r.stdout+'\n--- observed real fetch calls ---\n'+fetchlog.read_text())
check('never-send skill description stops network delivery', ['status=unavailable' in record.read_text(),'withheld by dispatch-never-send policy' in r.stdout,fetchlog.read_text()==''], 'privacy-description-refusal.txt')
(home/'config/dispatch-never-send').write_text('# dispatch-never-send marked-sections\n')
promoted=BASE/'promoted.md'
promoted.write_text('# Task\n[captain] Investigate synthetic task 300.\nSuperseded scout instructions.\n```\n[captain] FENCED-FAKE-INTENT\n```\n<!-- dispatch-never-send:start -->\n[captain] HIDDEN-INTENT\n<!-- dispatch-never-send:end -->\n\n# Current ship Firstmate spec\nFollow the current ship procedure.\n')
private=BASE/'private-task'
private.write_text(''); private.chmod(0o600)
shell = 'umask 022; . "$1/bin/fm-typesafe-lib.sh"; fm_typesafe_brief_task "$2" "$3" "$4" ship; stat -f "%Lp" "$4"; cat "$4"'
r=run(['bash','-c',shell,'_',ROOT,promoted,home/'config/dispatch-never-send',private])
save('promoted-private-task.txt',r.stdout+r.stderr)
check('promoted legacy intent is sanitized and owner-only', [r.returncode==0, r.stdout.startswith('600\n'), 'Investigate synthetic task 300.' in r.stdout, 'Follow the current ship procedure.' in r.stdout, all(s not in r.stdout for s in ('Superseded','FENCED','HIDDEN','[captain]'))], 'promoted-private-task.txt')
(home/'config/dispatch-never-send').write_text('')
fetchlog.write_text('')
started=time.monotonic()
r=run(args,env=observed_env,timeout=40)
elapsed=time.monotonic()-started
requests=[json.loads(x) for x in fetchlog.read_text().splitlines()]
save('real-provider-failure.txt',r.stdout+'\n--- persisted selection ---\n'+record.read_text()+f'\nElapsed: {elapsed:.2f}s\n')
save('real-provider-requests.json',requests)
check('real failed provider calls remain bounded', [r.returncode==0,'status=unavailable' in record.read_text(),elapsed<30, any('typesafe' in x['url'] for x in requests)], 'real-provider-failure.txt; real-provider-requests.json')
check('direct failure tries real OpenRouter fallback', [any('openrouter' in x['url'] for x in requests),'TypeSafe direct failed' in record.read_text()], 'real-provider-failure.txt; real-provider-requests.json')
# Remove credentials before worker launch scenarios.
(home/'.env').unlink()
save('standalone-results.json',results)
print('BASE='+str(BASE),flush=True)
