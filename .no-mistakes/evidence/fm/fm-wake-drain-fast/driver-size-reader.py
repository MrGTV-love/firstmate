import os, pathlib, subprocess, shutil, json
root=pathlib.Path.cwd(); base=root/'.live-validation/size-home'; evidence=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V'); log=[]
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION')}
env.update(FM_HOME=str(base),TMPDIR=str(base),PATH='/usr/bin:/bin:/opt/homebrew/bin:'+env['PATH'])
def run(label,extra={}):
 p=subprocess.run(['/bin/bash','bin/fm-wake-drain.sh'],env=dict(env,**extra),capture_output=True,text=True,timeout=120)
 log.append(f'### {label}\nexit={p.returncode}\n{p.stdout}\nSTDERR:\n{p.stderr}')
 assert p.returncode==0,p.stderr
 return p.stdout
try:
 for d in ('state','data','config','projects'): (base/d).mkdir(parents=True,exist_ok=True)
 (base/'config/supervision-host-off').touch()
 f=base/'state/task.status';f.write_text('note: previously presented\n')
 run('Prime valid presentation')
 with f.open('a') as s:s.write('note: appended before size fault\n')
 before=(base/'state/.status-presentation-cursor').read_bytes()
 reader=base/'failing-size-reader';reader.write_text('#!/bin/bash\nexit 1\n');reader.chmod(0o755)
 out=run('Inject FM_STATUS_SIZE_READER failure',{'FM_STATUS_SIZE_READER':str(reader)})
 assert 'STATUS PRESENTATION INCOMPLETE:' in out
 assert (base/'state/.status-presentation-cursor').read_bytes()==before
 out=run('Retry with real metadata reader')
 assert 'appended before size fault' in out and 'previously presented' not in out
 print('Size reader failure visibly deferred presentation, preserved persisted cursor, and recovered the pending note.',flush=True)
finally:
 (evidence/'size-reader-live-transcript.txt').write_text('\n\n'.join(log))
 shutil.rmtree(base)
