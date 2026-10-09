# Test driver used from /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4EXCFFXV5ZVRXQ95RXK339W/.validation; not a product stub.
import os, pathlib, subprocess, json, shlex, time, html, shutil, signal
ROOT = pathlib.Path(__file__).resolve().parent.parent
EVIDENCE = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4EXCFFXV5ZVRXQ95RXK339W')
LAB = ROOT / '.validation' / 'runtime'
SOCKET = 'fm-lab-nested-proof-' + str(os.getpid())
(ROOT/'.validation/live-socket.txt').write_text(SOCKET)
def interrupted(sig, frame):
    raise KeyboardInterrupt('Live driver interrupted')
signal.signal(signal.SIGTERM, interrupted)
env = os.environ.copy()
for name in list(env):
    if name.startswith('CLAUDE') or name.startswith('ANTHROPIC') or name.startswith('FM_') or name in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_ENV'):
        env.pop(name, None)
env.update(DISABLE_AUTOUPDATER='1', TMPDIR=str(ROOT/'.validation/tmp'))
KEY = 'sk-ant-fm-nested-home-throwaway'
CFG = LAB/'cfg'
results = []
screens = []

def run(args, **kw):
    return subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, **kw)

def tmux(*args):
    return run(['tmux','-L',SOCKET,*args])

def excludes(path):
    out = run(['bash','-c','. "$1"; fm_claude_md_excludes_json "$2"','_',str(ROOT/'bin/fm-claude-memory-lib.sh'),str(path)])
    if out.returncode: raise RuntimeError(out.stderr)
    # The public fragment is a shell-safe single-quoted settings interface.
    return json.loads(shlex.split("'{" + out.stdout.lstrip(',') + "}'")[0]) if out.stdout else {}

def git_init(path):
    path.mkdir(parents=True)
    out=run(['git','-C',str(path),'init','-q'])
    if out.returncode: raise RuntimeError(out.stderr)

def ancestor(path):
    # Disposable scenery copied from the project's existing supervisor contract,
    # never a change to project memory.
    (path/'bin').mkdir(parents=True)
    shutil.copyfile(ROOT/'AGENTS.md',path/'AGENTS.md')
    shutil.copyfile(ROOT/'CLAUDE.md',path/'CLAUDE.md')
    (path/'bin/fm-spawn.sh').touch()

def launch(name, path, settings, expected, raw=None):
    config_dir = LAB / ('cfg-' + name)
    config_dir.mkdir()
    trusted = [path, *path.parents, path.resolve(), *path.resolve().parents]
    cfg = {'hasCompletedOnboarding':True,'theme':'dark','numStartups':5,
           'customApiKeyResponses':{'approved':[KEY[-20:]],'rejected':[]},
           'projects':{str(p):{'hasTrustDialogAccepted':True,'hasCompletedProjectOnboarding':True} for p in trusted}}
    (config_dir/'.claude.json').write_text(json.dumps(cfg))
    args = ['claude','--setting-sources','project,local']
    if raw is None:
        args += ['--settings',json.dumps(settings)]
    else:
        args = ['bash',str(ROOT/'bin/fm-claude-memory-lib.sh'),json.dumps(settings),*args,*raw]
    command = shlex.join(['env',f'CLAUDE_CONFIG_DIR={config_dir}',f'ANTHROPIC_API_KEY={KEY}','DISABLE_AUTOUPDATER=1',*args])
    out = tmux('new-session','-d','-s',name,'-x','160','-y','48','-c',str(path),command)
    if out.returncode: raise RuntimeError(out.stderr)
    pane = ''
    for _ in range(150):
        pane = tmux('capture-pane','-p','-t',name).stdout
        if 'Allow external CLAUDE.md file imports?' in pane or 'Claude Code v' in pane or 'Do you want to use this API key?' in pane or 'Quick safety check:' in pane:
            time.sleep(1)
            pane=tmux('capture-pane','-p','-t',name).stdout
            break
        time.sleep(.2)
    history=tmux('capture-pane','-p','-t',name,'-S','-120').stdout
    (EVIDENCE/(name+'.txt')).write_text('COMMAND: '+command+'\n\n'+history)
    screens.append((name,pane))
    if expected=='composer':
        ok = 'Claude Code v' in pane and 'Allow external CLAUDE.md file imports?' not in pane and 'Do you want to use this API key?' not in pane
    else:
        ok = 'Allow external CLAUDE.md file imports?' in pane and expected in pane
    results.append({'name':name,'passed':ok,'expected':expected,'command':command,'settings':settings})
    print(name, 'PASS' if ok else 'FAIL', flush=True)
    if not ok: print(pane,flush=True)
    # Run the shipped busy-state protocol against the genuinely rendered dialog.
    if expected!='composer':
        state=LAB/(name+'-state'); state.mkdir()
        out=run([str(ROOT/'bin/fm-busy-event.sh'),'arm',str(state),'probe'])
        judged=run(['bash','-c','. "$1"; fm_busy_classify tmux "$2" claude probe "$3" "$(cat "$4")"','_',str(ROOT/'bin/fm-busy-lib.sh'),name,str(state),str(EVIDENCE/(name+'.txt'))])
        (EVIDENCE/(name+'-classification.txt')).write_text(judged.stdout+judged.stderr)
        results[-1]['classification']=judged.stdout.strip()
        print('  real dialog classifier:',judged.stdout.strip(),flush=True)
    tmux('kill-session','-t',name)

try:
    CFG.mkdir(parents=True)
    plain=LAB/'plain'; git_init(plain)
    home=LAB/'home'; ancestor(home)
    nested=home/'projects/proj/.claude/worktrees/task'; git_init(nested)
    odd=LAB/"R&D [home] it's {x}"; ancestor(odd)
    odd_nested=odd/'projects/proj/.claude/worktrees/task'; git_init(odd_nested)
    baseline=excludes(plain)
    launch('control',plain,baseline,'composer')
    launch('reproduction',nested,baseline,str(home/'AGENTS.md'))
    launch('canonical-fixed',nested,excludes(nested),'composer')
    launch('special-path-fixed',odd_nested,excludes(odd_nested),'composer')
    launch('raw-fixed',odd_nested,excludes(odd_nested),'composer',raw=[])
    launch('raw-inline-fixed',odd_nested,excludes(odd_nested),'composer',raw=['--settings='+json.dumps({'feedbackDrafts':'off','claudeMdExcludes':['project/**']})])
    settings_file=LAB/'caller-settings.json'; settings_file.write_text(json.dumps({'feedbackDrafts':'off','claudeMdExcludes':['project/**']}))
    launch('raw-file-fixed',odd_nested,excludes(odd_nested),'composer',raw=['--settings',str(settings_file)])
    # A legitimate external project import must remain a consent choice.
    legitimate=home/'projects/proj/.claude/worktrees/legitimate.md'; legitimate.write_text('Legitimate project import fixture.\n')
    (nested/'CLAUDE.md').write_text('@../legitimate.md\n')
    launch('project-import-preserved',nested,excludes(nested),'legitimate.md')
    # Root memory remains meaningful: the same exclusion computation at the home
    # directory must not suppress its own root CLAUDE.md.
    owned=home/'own-external.md'; owned.write_text('Root-owned import fixture.\n')
    (home/'CLAUDE.md').write_text('@../root-external.md\n')
    (LAB/'root-external.md').write_text('Root supervisor external import fixture.\n')
    launch('home-root-preserved',home,excludes(home),'root-external.md')
finally:
    tmux('kill-server')
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2))
    (EVIDENCE/'claude-startup-surfaces.html').write_text('<!doctype html><meta charset="utf-8"><title>Real Claude startup captures</title><style>body{background:#121212;color:#eee;font:15px monospace;margin:24px}pre{background:#191919;padding:20px;overflow:auto;white-space:pre}h2{color:#d99c7e}</style>'+''.join('<h2>'+html.escape(n)+'</h2><pre>'+html.escape(s)+'</pre>' for n,s in screens))
    shutil.rmtree(LAB,ignore_errors=True)
if any(not x['passed'] for x in results): raise SystemExit(1)
