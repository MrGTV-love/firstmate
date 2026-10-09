import pathlib, subprocess, os, json, time, shutil, signal
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4F9B87M5A8ZB6B0YDWF5A7V')
selectors=['test_terminal_supersession_reaches_cached_drains','test_kind_changes_invalidate_folded_decisions','test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision','test_same_size_rewrite_is_detected_via_inode_identity','test_read_failure_preserves_state_for_retry','test_cursor_cache_read_failure_refolds_without_replaying_unread_status','test_buried_decision_survives_many_growing_drains_and_resolution_clears_it']
# Existing script has functions followed by an explicit invocation list; execute selected public-drain scenarios without the exhaustive helper offset matrix.
source=(root/'tests/fm-wake-drain-open-decisions-cursor.test.sh').read_text()
cut=source.index('\ntest_terminal_supersession_reaches_cached_drains\n')
driver=root/'tests/.live-cursor-selected.test.sh'
driver.write_text(source[:cut]+'\n'+ '\n'.join(selectors)+'\n')
tmp=root/'.live-validation/cursor-tmp';tmp.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env.update(TMPDIR=str(tmp),PATH='/usr/bin:/bin:/opt/homebrew/bin:'+env['PATH'])
t=time.monotonic(); p=None
try:
 p=subprocess.Popen(['/bin/bash',str(driver)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
 try:
  out,err=p.communicate(timeout=900);status=p.returncode
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try: out,err=p.communicate(timeout=15)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate()
  status='driver-timeout'
 data=dict(selectors=selectors,returncode=status,elapsed_seconds=time.monotonic()-t)
 (ev/'selected-cursor-regression.log').write_text(out+'\nSTDERR:\n'+err)
 (ev/'selected-cursor-regression-results.json').write_text(json.dumps(data,indent=2))
 print(json.dumps(data),flush=True);print(out+err,flush=True)
finally:
 driver.unlink(missing_ok=True);shutil.rmtree(tmp)
