import os,json,pathlib,subprocess,shutil,time
ROOT=pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK'); E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK'); B=ROOT/'.live-skill-validation/worker-lab'; H=B/'home'; C=B/'code'; W=B/'wrappers'
env={k:v for k,v in os.environ.items() if not(k.startswith('FM_') and k.endswith('_OVERRIDE')) and k not in ('TMUX','TMUX_PANE','FM_GATE_REFUSE_BYPASS','TYPESAFE_API_KEY','TYPESAFE_API_KEY_PRIVATE')}; env.update(FM_HOME=str(H),PATH=str(W)+':'+env['PATH'],TMUX_TMPDIR=json.loads((E/'genuine-worker-isolation.json').read_text())['tmux_tmpdir'],LIVE_WIRE=str(E/'genuine-worker-wire.jsonl'))
try:
 deadline=time.monotonic()+600
 while time.monotonic()<deadline:
  status=H/'state/genuine-worker.status'
  if status.exists() and 'done [at=' in status.read_text(): break
  time.sleep(2)
 else: raise RuntimeError('initial worker did not finish within 600s')
finally:
 P=E/'genuine-worker-preliminary'; P.mkdir(exist_ok=True)
 for p in E.glob('genuine-worker-*'):
  if p.is_file(): shutil.copyfile(p,P/p.name)
 for label,p in [('report.md',H/'data/genuine-worker/report.md'),('result.json',B/'worktree/result-1.json'),('status.txt',H/'state/genuine-worker.status')]:
  if p.exists(): shutil.copyfile(p,P/label)
 for action,args in [('exit',[C/'bin/fm-control.sh','genuine-worker','exit']),('pane',[W/'tmux','capture-pane','-p','-S','-500','-t','firstmate:fm-genuine-worker']),('kill',[W/'tmux','kill-server']),('teardown',[C/'bin/fm-lab-home.sh','teardown',H])]:
  p=subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,timeout=90); (P/(action+'.txt')).write_text(p.stdout+p.stderr+f'\nexit={p.returncode}\n')
 if (B/'sessions').exists(): shutil.copytree(B/'sessions',P/'sessions',dirs_exist_ok=True)
 for p in pathlib.Path('/tmp').glob('fm-genuine-worker*'):
  if p.is_dir() and p.owner()==pathlib.Path.home().name: shutil.rmtree(p)
 shutil.rmtree(B)
 print('Preliminary fixture completed and cleaned; evidence retained. Final fixture will terminate minimal selection input before progress-note boundary.',flush=True)
