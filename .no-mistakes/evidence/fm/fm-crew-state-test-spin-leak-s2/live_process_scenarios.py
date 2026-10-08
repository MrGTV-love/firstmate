import json, os, pathlib, signal, subprocess, sys, time
ROOT=pathlib.Path.cwd()
SCRATCH=ROOT/'.live-timeout-validation'
EVIDENCE=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4D23NV25Q1M1CFJV1KQS7TG')
BASH=sys.argv[1]
env=dict(os.environ)
for key in ['FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX','HERDR_ENV','HERDR_SESSION']:
    env.pop(key,None)
env['PATH']=str(pathlib.Path(BASH).parent)+':'+env['PATH']
env['TMPDIR']=str(SCRATCH/'tmp')
env['FM_TEST_SKIP_ORPHAN_REAP']='1'
results=[]
def alive(pid):
    p=subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
    return p.returncode==0 and p.stdout.strip() and not p.stdout.strip().startswith('Z')
def wait_file(path,owner=None):
    limit=time.monotonic()+25
    while time.monotonic()<limit:
        if path.exists() and path.stat().st_size: return
        if owner is not None and owner.poll() is not None: raise RuntimeError('owner exited before '+str(path))
        time.sleep(.05)
    raise RuntimeError('file never appeared: '+str(path))
def gone(pids):
    limit=time.monotonic()+8
    while time.monotonic()<limit:
        if not any(alive(p) for p in pids): return True
        time.sleep(.05)
    return False
def run(name,script,timeout=30):
    start=time.monotonic()
    p=subprocess.run([BASH,'-c',script],env=env,cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    row={'name':name,'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,3),'stdout':p.stdout,'stderr':p.stderr}
    results.append(row)
    (EVIDENCE/(name+'.json')).write_text(json.dumps(row,indent=2)+'\n')
    print(json.dumps(row))
    if p.returncode: raise RuntimeError(name+' failed')

run('public-bound-contract',r'''
. bin/fm-timeout-lib.sh
. bin/fm-nm-run-lib.sh
mkdir -p "$TMPDIR/perl-only"
for cmd in bash perl sleep cat; do ln -sf "$(command -v "$cmd")" "$TMPDIR/perl-only/$cmd"; done
export PATH="$TMPDIR/perl-only"
rc=0
out=$(printf 'input-from-user\n' | fm_run_timed 5 bash -c 'cat; echo command-stderr >&2; exit 7') || rc=$?
printf 'fm_run_timed status=%s stdout=%s\n' "$rc" "$out"
[ "$rc" = 7 ] && [ "$out" = input-from-user ] || exit 11
rc=0
out=$(printf 'nm-input\n' | fm_nm_bounded "$TMPDIR" 5 bash -c 'cat; echo nm-stderr >&2; exit 9') || rc=$?
printf 'fm_nm_bounded status=%s stdout=%s\n' "$rc" "$out"
[ "$rc" = 9 ] && [ "$out" = nm-input ] || exit 12
rc=0
fm_nm_bounded "$TMPDIR" 5 bash -c 'kill -TERM $$' || rc=$?
printf 'signal-killed command status=%s\n' "$rc"
[ "$rc" = 143 ] || exit 13
''')

run('repeated-no-timeout-leak-check',r'''
. bin/fm-timeout-lib.sh
. bin/fm-nm-run-lib.sh
export PATH="$TMPDIR/perl-only"
pids=()
for i in {1..12}; do
  (
    rc=0
    fm_nm_bounded "$TMPDIR" 1 bash -c 'trap "" TERM; echo $$ > "$1"; exec sleep 20' _ "$TMPDIR/repeat-$i.pid" || rc=$?
    printf 'call=%s deadline_status=%s\n' "$i" "$rc"
    [ "$rc" = 124 ]
  ) &
  pids+=("$!")
done
bad=0
for pid in "${pids[@]}"; do wait "$pid" || bad=1; done
for i in {1..12}; do
  read -r pid < "$TMPDIR/repeat-$i.pid"
  if kill -0 "$pid" 2>/dev/null; then printf 'SURVIVOR pid=%s\n' "$pid"; bad=1; fi
done
printf 'surviving_bounded_commands=%s\n' "$bad"
[ "$bad" = 0 ]
''')

for ending in ['TERM','KILL']:
    case=SCRATCH/('owner-'+ending)
    case.mkdir(exist_ok=True)
    (case/'child.pid').unlink(missing_ok=True)
    script=r'''
. bin/fm-nm-run-lib.sh
PATH="$TMPDIR/perl-only" fm_nm_bounded "$1" 30 bash -c 'trap "" TERM; echo $$ > "$1/child.pid"; echo child-started; exec sleep 20' _ "$1"
'''
    owner=subprocess.Popen([BASH,'-c',script,'_',str(case)],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        wait_file(case/'child.pid',owner)
        pid=int((case/'child.pid').read_text())
        pre=subprocess.run(['/bin/ps','-o','pid=,ppid=,pgid=,stat=,command=','-p',str(pid)],capture_output=True,text=True).stdout
        bound=int(subprocess.check_output(['/bin/ps','-o','ppid=','-p',str(pid)],text=True).strip())
        target=bound if ending=='TERM' else int(subprocess.check_output(['/bin/ps','-o','ppid=','-p',str(bound)],text=True).strip())
        os.kill(target,getattr(signal,'SIG'+ending))
        start=time.monotonic()
        out,err=owner.communicate(timeout=8)
        cleaned=gone([pid])
        row={'name':'bound-TERM' if ending=='TERM' else 'owner-KILL','owner_pid':owner.pid,'signaled_pid':target,'child_before':pre,'owner_exit':owner.returncode,'stdout':out,'stderr':err,'elapsed_after_signal':round(time.monotonic()-start,3),'child_survived':not cleaned}
        results.append(row)
        (EVIDENCE/('owner-'+ending+'.json')).write_text(json.dumps(row,indent=2)+'\n')
        print(json.dumps(row))
        if not cleaned: raise RuntimeError('owner death leaked child')
    finally:
        if owner.poll() is None: owner.kill(); owner.wait()
        if 'pid' in locals() and alive(pid): os.kill(pid,signal.SIGKILL)
(EVIDENCE/'live-process-summary.json').write_text(json.dumps(results,indent=2)+'\n')
