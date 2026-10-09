import os, pathlib, subprocess, shutil, json, time
root=pathlib.Path.cwd(); base=root/'.live-validation/checkpoint-home';ev=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V');log=[]
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(base),TMPDIR=str(base),PATH='/usr/bin:/bin:/opt/homebrew/bin:'+env['PATH'])
def run(label,extra={}):
 t=time.monotonic();p=subprocess.run(['/bin/bash','bin/fm-wake-drain.sh'],env=dict(env,**extra),capture_output=True,text=True,timeout=180)
 log.append(f'### {label}\nelapsed={time.monotonic()-t:.3f}s exit={p.returncode}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}')
 assert p.returncode==0,p.stderr
 return p.stdout
try:
 for d in ('state','data','config','projects'): (base/d).mkdir(parents=True,exist_ok=True)
 (base/'config/supervision-host-off').touch()
 f=base/'state/task.status';cursor=base/'state/.task.open-decisions-cursor'
 f.write_text('needs-decision [key=cache]: recover authoritative decision\nnote: already presented information\nworking: routine padding\n')
 a=run('Prime fold and presentation independently')
 assert 'recover authoritative decision' in a and 'already presented information' in a
 before=cursor.read_bytes();manifest=(base/'state/.status-presentation-cursor').read_bytes()
 with f.open('a') as s:s.write('working: appended before span failure\n')
 reader=base/'span-failure';reader.write_text('#!/bin/bash\nexit 1\n');reader.chmod(0o755)
 a=run('Inject FM_STATUS_SPAN_READER failure',{'FM_STATUS_SPAN_READER':str(reader)})
 assert cursor.read_bytes()==before and (base/'state/.status-presentation-cursor').read_bytes()==manifest
 a=run('Recover trusted open decision after span reads resume')
 assert 'recover authoritative decision' in a and 'already presented information' not in a
 with f.open('a') as s:s.write('working: appended before checkpoint-cat failure\n')
 fakebin=base/'fault-bin';fakebin.mkdir();cat=fakebin/'cat'
 cat.write_text('#!/bin/bash\nif [ "$#" -eq 1 ] && [ "$1" = '+repr(str(cursor))+' ]; then printf "checkpoint cat failure invoked\\n" >> '+repr(str(base/'fault-invocations'))+'; exit 1; fi\nexec /bin/cat "$@"\n');cat.chmod(0o755)
 probe=base/'read-probe';probe.touch()
 a=run('Inject checkpoint cat failure and refold authoritative status',{'PATH':str(fakebin)+':'+env['PATH'],'FM_OPEN_DECISIONS_READ_PROBE':str(probe)})
 assert (base/'fault-invocations').exists(),'fake-cat checkpoint seam was not invoked'
 assert 'recover authoritative decision' in a and 'already presented information' not in a
 rows=[r.split('\t') for r in probe.read_text().splitlines() if r.split('\t')[0]==str(f)]
 assert rows and int(rows[-1][1])==f.stat().st_size,(rows,f.stat().st_size)
 log.append('Checkpoint cat seam invocations:\n'+(base/'fault-invocations').read_text()+'Full-refold probe (status bytes='+str(f.stat().st_size)+'):\n'+probe.read_text())
 # Keep exactly the same byte length, with complete routine lines, but replace the inode and decision key.
 old=f.read_bytes();new=b'blocked [key=release]: new rotation blocker\n';remaining=len(old)-len(new)
 new+=b'working: '+b'x'*(remaining-len(b'working: \n'))+b'\n'
 assert len(new)==len(old)
 inode=f.stat().st_ino;replacement=base/'replacement';replacement.write_bytes(new);replacement.replace(f)
 assert f.stat().st_ino!=inode
 a=run('Rotate to an equally sized log with a different blocker')
 assert 'new rotation blocker' in a and 'recover authoritative decision' not in a
 log.append(f'Equal-sized rotation: before_bytes={len(old)} after_bytes={f.stat().st_size} old_inode={inode} new_inode={f.stat().st_ino}')
 print('PASS: span failure preserves both cursors; checkpoint cat failure performs full refold without informational replay; equal-sized inode rotation replaces decision state.',flush=True)
finally:
 (ev/'checkpoint-seams-live-transcript.txt').write_text('\n\n'.join(log))
 shutil.rmtree(base)
