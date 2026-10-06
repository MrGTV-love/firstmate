import os,pathlib,subprocess,shutil,json
R=pathlib.Path.cwd();L=R/'.live-validation/socket-home';E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T');logs=[];sd=None
# The helper's ephemeral short socket directory is an incidental native-tool
# temp side effect; all home state and fixtures remain inside this worktree.
e={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','NO_MISTAKES_GATE')};e['TMPDIR']=str(R/'.live-validation/tmp')
def run(args,expected=0):
 p=subprocess.run(args,env=e,text=True,capture_output=True,timeout=20)
 logs.append({'command':args,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert p.returncode==expected,(args,p.returncode,p.stderr);return p
try:
 run(['bash','bin/fm-lab-home.sh','create',str(L)])
 sd=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(L)]).stdout.strip();e['TMUX_TMPDIR']=sd
 run(['tmux','-L','fm-lab','new-session','-d','-s','probe','-c',str(R),'sleep 120'])
 p=run(['bash','bin/fm-lab-home.sh','teardown',str(L)],expected=1)
 assert 'tmux probe exit=0' in p.stderr
 assert (L/'state/.fm-lab-tmux-dir').exists() and pathlib.Path(sd).is_dir()
 logs.append({'scenario':'live server refuses teardown with probe status','ownership_record_retained':True,'socket_directory_retained':True})
 run(['tmux','-L','fm-lab','kill-server'])
 run(['bash','bin/fm-lab-home.sh','teardown',str(L)])
 assert not pathlib.Path(sd).exists() and not (L/'state/.fm-lab-tmux-dir').exists()
 logs.append({'scenario':'confirmed stopped server permits teardown','socket_directory_removed':True,'ownership_record_removed':True})
 print(json.dumps(logs,indent=2))
finally:
 if sd and pathlib.Path(sd).exists():
  subprocess.run(['tmux','-L','fm-lab','kill-server'],env=e,capture_output=True)
  subprocess.run(['bash','bin/fm-lab-home.sh','teardown',str(L)],env=e,capture_output=True)
 (E/'lab-teardown-live-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
 shutil.rmtree(L,ignore_errors=True)
