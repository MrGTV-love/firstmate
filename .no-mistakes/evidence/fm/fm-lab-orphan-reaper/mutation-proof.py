import os, pathlib, subprocess, time, shutil, hashlib, signal
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path(__file__).resolve().parent/'mutation-proof'; WORK.mkdir()
BIN=ROOT/'bin'
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('STATE','TMUX','BASH_ENV','NO_MISTAKES_GATE'): ENV.pop(k,None)
ENV['TMPDIR']=str(WORK)
HOLDER=subprocess.Popen(['sleep','240'],env=ENV)
CHILDREN=[]
def run(args,state,extra=None,expected=0):
    result=subprocess.run(list(map(str,args)),env={**ENV,'FM_STATE_OVERRIDE':str(state),**(extra or {})},capture_output=True,text=True,timeout=30)
    assert result.returncode==expected, (args,result)
    return result.stdout.strip()
def lib(state,code,*args):
    return run(['bash','-c','. "$1"; '+code,'_',BIN/'fm-wake-lib.sh',*args],state)
def wait_until(fn,seconds=20):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if fn(): return
        time.sleep(.025)
    raise AssertionError('worker did not reach lock acquisition')
def fingerprints(paths):
    return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
try:
    wait_until(lambda: subprocess.run(['ps','-p',str(HOLDER.pid),'-o','command='],capture_output=True,text=True).stdout.strip()=='sleep 240')
    for action in ('append','keys','drain-first','drain-second','link','followups','clear'):
        folder=WORK/action; folder.mkdir(); state=folder/'state'; state.mkdir()
        fail_at=2 if action=='drain-second' else 1
        if action in ('link','followups','clear'):
            meta=state/'task.meta'
            meta.write_text('kind=worker\nx_request=original\nx_request_ts=1\nx_followups=2\n')
            lock=pathlib.Path(lib(state,'fm_meta_lock_path "$2"',meta))
            code={ 'link':'fmx_meta_link_set "$2" replacement 10', 'followups':'fmx_meta_followups_set "$2" 3', 'clear':'fmx_meta_link_clear "$2"'}[action]
            args=['bash','-c','. "$1/fm-wake-lib.sh"; . "$1/fm-x-lib.sh"; if [ -n "${BASH_ENV:-}" ]; then . "$BASH_ENV"; printf ready > "$PROOF_READY"; fi; '+code,'_',BIN,meta]
            public_files=[meta]
        else:
            lib(state,'fm_wake_append signal existing payload')
            run([BIN/'fm-wake-grant.sh','activate',HOLDER.pid,'original'],state)
            run([BIN/'fm-wake-grant.sh','publish','original','1'],state)
            generation=lib(state,'fm_recovery_marker_read "$STATE/.watcher-down"; printf "%s\\n" "${FM_RECOVERY_MARKER_TOKEN##*:}"')
            lock=state/'.wake-queue.lock'
            if action in ('drain-first','drain-second'):
                args=[BIN/'fm-wake-drain.sh','--ack-through','1','--recovery-generation',generation]
            elif action=='append': args=['bash','-c','. "$1"; if [ -n "${BASH_ENV:-}" ]; then . "$BASH_ENV"; printf ready > "$PROOF_READY"; fi; fm_wake_append signal new payload','_',BIN/'fm-wake-lib.sh']
            elif action=='keys': args=['bash','-c','. "$1"; if [ -n "${BASH_ENV:-}" ]; then . "$BASH_ENV"; printf ready > "$PROOF_READY"; fi; fm_wake_queued_keys signal','_',BIN/'fm-wake-lib.sh']
            else:
                tail={'activate':['activate',HOLDER.pid,'replacement'],'publish':['publish','original','1'],'release':['release','original'],'deactivate':['deactivate',HOLDER.pid,'original']}[action]
                args=[BIN/'fm-wake-grant.sh',*tail]
            public_files=[state/p for p in ('.wake-queue','.wake-queue.seq','.watcher-down','.branch-eligible-owner','.branch-eligible-rows')]
        before=fingerprints(public_files)
        if fail_at==1:
            lock.mkdir(); (lock/'pid').write_text(str(HOLDER.pid)+'\n')
        hook=folder/'observe-entry.sh'
        hook.write_text('''set -T
proof_calls=0
trap '
case "$BASH_COMMAND" in
  fm_lock_acquire_wait\\ *)
    proof_calls=$((proof_calls+1))
    if [ "$proof_calls" -eq "$PROOF_FAIL_AT" ]; then
      if [ "$PROOF_FAIL_AT" = 2 ]; then
        mkdir "$PROOF_LOCK"
        printf "%s\\n" "$PROOF_HOLDER" > "$PROOF_LOCK/pid"
      fi
      printf ready > "$PROOF_READY"
    fi ;;
esac
if [ "$BASH_COMMAND" = "return 1" ] && [ "${FUNCNAME[0]:-}" = fm_lock_acquire_wait ] && [ -d "$FM_STATE_OVERRIDE.gone" ]; then
  command mv "$FM_STATE_OVERRIDE.gone" "$FM_STATE_OVERRIDE"
  printf restored > "$PROOF_RESTORED"
fi
' DEBUG
''')
        env={**ENV,'FM_STATE_OVERRIDE':str(state),'FM_SUPERVISION_ACTOR':'branch','BASH_ENV':str(hook),'PROOF_FAIL_AT':str(fail_at),'PROOF_LOCK':str(lock),'PROOF_HOLDER':str(HOLDER.pid),'PROOF_READY':str(folder/'ready'),'PROOF_RESTORED':str(folder/'restored')}
        print('$ '+action+': '+' '.join(map(str,args)),flush=True)
        child=subprocess.Popen(list(map(str,args)),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        CHILDREN.append(child)
        wait_until(lambda:(folder/'ready').exists())
        state.rename(folder/'state.gone')
        started=time.monotonic()
        out,err=child.communicate(timeout=15)
        restored=(folder/'restored').exists()
        unchanged=fingerprints(public_files)==before if restored else False
        foreign_lock=(lock/'pid').read_text().strip()==str(HOLDER.pid) if restored else False
        print(f'{action}: real_wait={time.monotonic()-started:.2f}s exit={child.returncode} restored_before_failure_return={restored} public_state_unchanged={unchanged} foreign_lock_retained={foreign_lock} stdout={out!r} stderr={err!r}',flush=True)
        assert child.returncode==1 and out=='' and err=='' and restored and unchanged and foreign_lock
        shutil.rmtree(lock)
        result=run(args,state,{'FM_SUPERVISION_ACTOR':'branch'})
        print(f'{action}: retry after genuine unlock exit=0 output={result!r}',flush=True)
    print('REAL LOCK FAILURE MATRIX COMPLETE',flush=True)
finally:
    for child in CHILDREN:
        if child.poll() is None: child.kill(); child.wait()
    if HOLDER.poll() is None: HOLDER.kill(); HOLDER.wait()
