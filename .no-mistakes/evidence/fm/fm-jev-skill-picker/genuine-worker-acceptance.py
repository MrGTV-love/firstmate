import pathlib,json,re,ast,decimal,hashlib,shutil
E=pathlib.Path('/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK')
rows=[json.loads(s) for s in (E/'genuine-worker-session-receipts.jsonl').read_text().splitlines()]
sessions=json.loads((E/'genuine-worker-sessions.json').read_text()); reads=[]; launches=[]
for r in rows:
 if r.get('role')=='user':
  txt='\n'.join(x.get('text','') for x in r.get('content',[]) if x.get('type')=='text')
  if 'FIRSTMATE_OP:' in txt: launches.append({'session':r['session'],'timestamp':r['timestamp'],'text':txt})
 if r.get('role')=='toolResult' and r.get('toolName')=='read':
  reads.append({'session':r['session'],'timestamp':r['timestamp'],'toolCallId':r.get('toolCallId'),'tool':'ordinary read','content':r['content'],'isError':r.get('isError')})
for p in sorted(E.glob('genuine-worker-*-*.eval.log')):
 for line in p.read_text().splitlines():
  try: obj=ast.literal_eval(line)
  except (ValueError,SyntaxError): continue
  if isinstance(obj,dict) and '/SKILL.md#' in obj.get('text',''):
   sid=next((s['id'] for s in sessions if s['id'] in p.name),None)
   reads.append({'session':sid,'tool':'ordinary read nested through eval','eval_receipt_file':str(p),'result':obj})
(E/'genuine-worker-body-read-receipts.json').write_text(json.dumps(reads,indent=2)+'\n')
(E/'genuine-worker-delivered-launch-inputs.json').write_text(json.dumps(launches,indent=2)+'\n')
verdict=json.loads((E/'genuine-worker-verdict.json').read_text()); wire=[json.loads(s) for s in (E/'genuine-worker-wire.jsonl').read_text().splitlines()]
expected={'record_count':'4','net_total':'10.21','positive_total':'12.31','negative_total':'-2.10','zero_count':'1'}
checks={k:verdict.get(k) for k in ['same_endpoint_worktree','original_task_exact','source_only_progress_appended','wire_model_all_jev','same_minimal_picker_task','no_exported_credential']}
checks['two_real_worker_sessions']=len(sessions)==2
checks['fresh_calls_both']=verdict.get('fresh_calls_initial',0)>0 and verdict.get('fresh_calls_relaunch',0)>0
checks['real_wire_success']=all(r['curl_exit']==0 and r['transfer'].startswith('200') and isinstance(r['response'].get('usage',{}).get('input_tokens'),int) for r in wire)
phases=[]
for n in (1,2):
 launch=(E/f'genuine-worker-launch-{n}.md').read_text(); report=(E/f'genuine-worker-report-{n}.md').read_text(); result=json.loads((E/f'genuine-worker-result-{n}.json').read_text())
 source=(E/f'genuine-worker-source-{n}.md').read_text()
 task=source.split('# Task\n',1)[1].split('\n# ',1)[0]
 suggestion_ids=re.findall(r'^Optional suggestion: ([\w-]+)',launch,re.M)
 sid=sessions[n-1]['id']; rr=[r for r in reads if r['session']==sid]
 text=json.dumps(rr)
 # These are actual result messages, not the assistant's stated intent to read.
 read_ids=[name for name in ('input-safety','money-json','boundary-checks','ledger-summary','schema-audit','captain-hold-lifecycle') if '/'+name+'/SKILL.md#' in text]
 ordinary_results='AGENTS.md#' in text and 'records.json#' in text
 output_match=all(decimal.Decimal(str(result[k]))==decimal.Decimal(v) for k,v in expected.items())
 checks[f'phase_{n}_monetary_expected']=output_match
 checks[f'phase_{n}_mandatory_reads']=all(x in read_ids for x in ('input-safety','captain-hold-lifecycle'))
 checks[f'phase_{n}_suggestion_bodies_read']=all(x in read_ids for x in suggestion_ids)
 checks[f'phase_{n}_index_and_records_read']=ordinary_results
 index_section=re.search(r'## Complete authoritative seven-item[^\n]*\n(.*?)(?=\n## |\Z)',report,re.S).group(1)
 expected_index=re.findall(r'^- ([\w-]+): .* — (.*)$',(E/'genuine-worker-fixture-index.md').read_text(),re.M)
 checks[f'phase_{n}_all_index_retained']=len(expected_index)==7 and all(name+'/SKILL.md' in index_section and description in index_section for name,description in expected_index)
 checks[f'phase_{n}_live_advice']='Advice source: live; model: jev-1.13.0.' in launch and 'jev-1.13.0' in report
 checks[f'phase_{n}_source_task_delivered']=task in launches[n-1]['text']
 phases.append({'phase':n,'session':sid,'suggestions':suggestion_ids,'actual_read_body_ids':read_ids,'totals':{k:result[k] for k in expected},'ordinary_read_receipt_count':len(rr)})
# POSIX shell command substitution removes trailing newlines from encoded argv.
checks['exact_emitted_launch_delivery']=all((E/f'genuine-worker-launch-{n}.md').read_text().rstrip('\n')==launches[n-1]['text'].split('FIRSTMATE_OP: v1 launch-brief: ',1)[1] for n in (1,2))
checks['supported_exit_success']=next(c.get('exit') for c in verdict['cleanup'] if c['operation']=='exit')==0
checks['private_server_stopped']=next(c.get('exit') for c in verdict['cleanup'] if c['operation']=='confirm-private-stopped')!=0
checks['helper_teardown_success']=next(c.get('exit') for c in verdict['cleanup'] if c['operation']=='helper-teardown')==0
acceptance={'verdict':'PASS' if all(checks.values()) else 'FAIL','checks':checks,'phases':phases,'limits':['Fixture-controlled acquisition: genuine isolated git worktree and actual production isolation checks, not a real Treehouse lifecycle proof.','Single representative local monetary task, two real omp sessions; no context-savings/performance/generalization claim.','Preliminary completed launch was retired before final scenario to improve fixture minimal-input heading boundary; retained separately.','Exact production source copies unmodified; no product fix, no build/lint/static analysis/full suite or pipeline commands exercised.']}
(E/'genuine-worker-acceptance.json').write_text(json.dumps(acceptance,indent=2)+'\n'); print(json.dumps(acceptance),flush=True)
ROOT=pathlib.Path('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK')
for name in ('worker-proof.py','worker-preliminary-cleanup.py','worker-relaunch.py','worker-acceptance.py'):
 p=ROOT/'.live-skill-validation'/name
 if p.exists(): shutil.copyfile(p,E/('genuine-'+name)); p.unlink()
