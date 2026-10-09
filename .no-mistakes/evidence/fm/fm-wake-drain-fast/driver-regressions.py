import pathlib, os, subprocess, json, time, shutil
root=pathlib.Path.cwd(); temp=root/'.live-validation/regression-tmp';temp.mkdir(parents=True,exist_ok=True)
evidence=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env['TMPDIR']=str(temp);env['PATH']='/usr/bin:/bin:/opt/homebrew/bin:'+env['PATH']
results=[]
try:
 for name in ['fm-wake-drain-unread-status','fm-wake-drain-outcome-backstop','fm-wake-drain-open-decisions-cursor']:
  t=time.monotonic()
  p=subprocess.run(['/bin/bash',f'tests/{name}.test.sh'],env=env,capture_output=True,text=True,timeout=900)
  output=p.stdout+'\nSTDERR:\n'+p.stderr
  (evidence/f'{name}-regression.log').write_text(output)
  row=dict(command=f'/bin/bash tests/{name}.test.sh',returncode=p.returncode,elapsed_seconds=time.monotonic()-t,output=output)
  results.append(row);print(json.dumps(row),flush=True)
  (evidence/'focused-regression-results.json').write_text(json.dumps(results,indent=2))
finally:
 shutil.rmtree(temp)
