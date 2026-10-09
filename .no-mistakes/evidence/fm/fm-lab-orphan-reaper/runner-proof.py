import os, pathlib, shutil, subprocess, time, signal
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path(__file__).resolve().parent/'runner-proof'
WORK.mkdir()
REPO=WORK/'repo'
(REPO/'tests').mkdir(parents=True)
shutil.copytree(ROOT/'bin',REPO/'bin')
for name in ('lib.sh','git-config-helpers.sh'): shutil.copy2(ROOT/'tests'/name,REPO/'tests'/name)
# Constrain only the scan boundary; execute the unchanged real reaper.
shutil.move(REPO/'bin/fm-test-reap-orphans.sh',REPO/'bin/fm-test-reap-fixture.sh')
(REPO/'bin/fm-test-reap-orphans.sh').write_text('''#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then set -- --tmpdir "${TMPDIR:?}"; fi
exec "$(dirname "${BASH_SOURCE[0]}")/fm-test-reap-fixture.sh" "$@"
''')
(REPO/'bin/fm-test-reap-orphans.sh').chmod(0o755)
leak=REPO/'tests/fm-live-leak.test.sh'
leak.write_text('''#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(fm_test_tmproot fm-live-leak)
cat > "$root/poll-publish-holder.sh" <<'SH'
#!/usr/bin/env bash
n=0
while [ "$n" -lt 4800 ]; do sleep .05; n=$((n+1)); done
SH
(
  pid=$(python3 -c 'import subprocess,sys; p=subprocess.Popen(["bash",sys.argv[1]],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); print(p.pid)' "$root/poll-publish-holder.sh")
  ready=false
  for i in $(seq 1 100); do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null)
    if [ "$cmd" = "bash $root/poll-publish-holder.sh" ]; then ready=true; break; fi
    sleep .05
  done
  [ "$ready" = true ] || exit 1
  fm_test_pid_identity "$pid" > "$FM_PROOF_DIR/original-identity"
  printf '%s\\n' "$pid" > "$FM_PROOF_DIR/pid"
) || exit 1
printf 'Fixture launched detached poll-publish-holder pid=%s mode=%s\\n' "$(cat "$FM_PROOF_DIR/pid")" "$FM_PROOF_MODE"
if [ "$FM_PROOF_MODE" = killed ]; then kill -KILL "$$"; fi
trap '' TERM
while true; do sleep .1; done
''')
leak.chmod(0o755)
observe=REPO/'tests/fm-live-observe.test.sh'
observe.write_text('''#!/usr/bin/env bash
set -u
pid=$(cat "$FM_PROOF_DIR/pid")
original=$(cat "$FM_PROOF_DIR/original-identity")
FM_STATE_OVERRIDE="$TMPDIR" . "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-wake-lib.sh"
current=$(fm_pid_identity "$pid" 2>/dev/null || true)
printf 'Next script observes orphan pid=%s same_identity=%s\\n' "$pid" "$([ "$original" = "$current" ] && echo true || echo false)"
[ "$original" != "$current" ]
''')
observe.chmod(0o755)
ENV=os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key in ('TMUX','BASH_ENV','STATE','NO_MISTAKES_GATE'): ENV.pop(key,None)
ENV.update(TMPDIR=str(WORK),FM_TEST_SKIP_ORPHAN_REAP='1',FM_CPU_PASS_HELD='0')
try:
    for mode in ('killed','timeout'):
        proof=WORK/mode; proof.mkdir()
        env={**ENV,'FM_PROOF_DIR':str(proof),'FM_PROOF_MODE':mode}
        args=[str(REPO/'bin/fm-test-run.sh'),'--jobs','1','--per-script-timeout-secs','60','tests/fm-live-leak.test.sh','tests/fm-live-observe.test.sh']
        print('$ FM_PROOF_MODE='+mode+' '+' '.join(args),flush=True)
        result=subprocess.run(args,cwd=REPO,env=env,capture_output=True,text=True,timeout=200)
        print(result.stdout, end='',flush=True); print(result.stderr,end='',flush=True)
        print('runner exit=',result.returncode,flush=True)
        assert result.returncode==1
        expected='137' if mode=='killed' else '124'
        assert 'tests/fm-live-leak.test.sh exit='+expected in result.stdout
        assert 'same_identity=false' in result.stdout
        assert 'reaped after tests/fm-live-leak.test.sh:' in result.stderr
        print('Runner preserved '+mode+' failure and next script saw no surviving owned orphan.',flush=True)
finally:
    for proof in (WORK/'killed',WORK/'timeout'):
        if not (proof/'pid').exists(): continue
        pid=int((proof/'pid').read_text())
        original=(proof/'original-identity').read_text().strip()
        current=subprocess.run(['ps','-p',str(pid),'-o','lstart=','-o','command='],env={**ENV,'LC_ALL':'C','COLUMNS':'10000'},capture_output=True,text=True).stdout.strip()
        if current==original:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
