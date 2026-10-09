import os, pathlib, subprocess, tempfile, time, json, shutil
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4FA81EERMX11BSETH10XNDG')
log = (EVID / 'round2-real-timeout.log').open('w', buffering=1)
def note(text):
    print(text, flush=True); print(text, file=log, flush=True)
env = os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_IDLE_REAP_TEARDOWN_BIN','TMUX','TMUX_PANE']:
    env.pop(key, None)
lab = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-01M4FA81-',dir='/tmp'))
owner = sweep = None
try:
    create = subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],env=env,text=True,capture_output=True)
    note('fm-lab-home create: ' + create.stdout + create.stderr)
    assert create.returncode == 0
    env.update(FM_HOME=str(lab), TASKS_AXI_BACKEND='markdown')
    (lab / '.tasks.toml').write_text('backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n')
    state = lab / 'state'; data = lab / 'data'; now = int(time.time()); old = now-7200
    (state/'slow.meta').write_text(f'kind=scout\nharness=claude\nbackend=tmux\nwindow=primary:fm-slow\nspawn_gen=live-timeout-1\nproject={lab}/projects/notes\nworktree={lab}/scratch-slow\n')
    (state/'slow.busy-gen').write_text('g1.1.1\n')
    (state/'slow.busy-state').write_text(f'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts={now}\n')
    (state/'slow.status').write_text(f'done [at={old}]: completed disposable report\n')
    (data/'slow').mkdir(); (data/'slow/report.md').write_text('# Disposable report\nCompleted.\n')
    os.utime(data/'slow/report.md',(old,old))
    owner = subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; lock=$(fm_meta_lock_path "$FM_HOME/state/slow.meta"); fm_lock_try_acquire "$lock" || exit 1; trap \'fm_lock_release "$lock"\' EXIT; printf ready; while [ ! -e "$FM_HOME/release" ]; do sleep 1; done'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    deadline=time.monotonic()+10
    while not (state/'.meta-slow.lock/pid').exists() and time.monotonic()<deadline: time.sleep(.1)
    assert (state/'.meta-slow.lock/pid').exists()
    scan=subprocess.run(['bin/fm-idle-session-reap.sh','scan'],cwd=ROOT,env=env,text=True,capture_output=True)
    note('Before stalled teardown: '+scan.stdout+scan.stderr)
    assert scan.stdout.startswith('reap\tslow\t')
    start=time.monotonic()
    sweep=subprocess.Popen(['bin/fm-idle-session-reap.sh','reap'],cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+120
    while not (state/'.control-slow.lock/pid').exists() and time.monotonic()<deadline:
        if sweep.poll() is not None:
            note('Early reap exit: '+sweep.communicate()[0])
            break
        time.sleep(.1)
    assert (state/'.control-slow.lock/pid').exists(), 'real teardown never entered lifecycle admission'
    teardown_pid=int((state/'.control-slow.lock/pid').read_text())
    note('Real teardown acquired its control lock and waits on live metadata-lock owner '+str(owner.pid))
    note(subprocess.run(['ps','-p',str(teardown_pid),'-o','pid=,ppid=,command='],text=True,capture_output=True).stdout)
    overlap=subprocess.run(['bin/fm-idle-session-reap.sh','reap'],cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
    note('Overlapping sweep: exit='+str(overlap.returncode)+' output='+repr(overlap.stdout+overlap.stderr))
    assert overlap.returncode==0 and not overlap.stdout
    out,_=sweep.communicate(timeout=635)
    elapsed=time.monotonic()-start
    note(f'Elapsed real monotonic seconds: {elapsed:.3f}; sweep exit={sweep.returncode}')
    note('Reap result:\n'+out)
    note('Published report:\n'+(state/'idle-sessions.report').read_text())
    note('Refusal memo:\n'+(state/'.idle-reap/slow.refused').read_text())
    exists=(state/'slow.meta').exists()
    terminated=subprocess.run(['kill','-0',str(teardown_pid)],capture_output=True).returncode!=0
    note(f'Task retained={exists}; real teardown PID terminated={terminated}')
    assert 599 <= elapsed < 620, 'fixed bound not honored'
    assert sweep.returncode==0 and 'teardown-timeout\tslow\t' in out and exists and terminated
    note('PASS: actual fm-teardown was terminated at the unchanged 600-second bound; task and refusal evidence preserved.')
finally:
    if sweep is not None and sweep.poll() is None:
        sweep.terminate()
        try: sweep.wait(timeout=5)
        except subprocess.TimeoutExpired: sweep.kill(); sweep.wait()
    if owner is not None:
        (lab/'release').touch()
        try: owner.communicate(timeout=5)
        except subprocess.TimeoutExpired: owner.kill(); owner.communicate()
    shutil.rmtree(lab)
    note('Cleanup proof: '+str(lab)+' exists='+str(lab.exists()))
    log.close()
