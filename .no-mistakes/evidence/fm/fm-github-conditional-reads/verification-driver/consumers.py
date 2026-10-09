import copy
import drive as d
from drive import *
d.results.extend(json.loads((EVIDENCE/'live-results.json').read_text()))
d.transcript.extend(json.loads((EVIDENCE/'live-transcript.json').read_text()))
RATE_RESET=forge.rate['reset']
AT=iso()

def setup_pr(number=8):
    core={'number':number,'html_url':f'https://github.com/o/r/pull/{number}',
      'state':'open','user':{'login':'author'},'head':{'sha':A,'ref':'fm/lab'},'base':{'sha':B},
      'draft':False,'mergeable':True,'merged_at':None,'updated_at':AT,'requested_reviewers':[],'requested_teams':[]}
    forge.put(f'/repos/o/r/pulls/{number}',core)
    for suffix in (f'/issues/{number}/comments',f'/pulls/{number}/reviews',f'/pulls/{number}/comments'):
        forge.put('/repos/o/r'+suffix+'?per_page=100',[])
    forge.put('/repos/o/r/commits/'+A+'/check-runs?filter=all&per_page=100',{'check_runs':[
      {'name':'build','id':1,'status':'completed','conclusion':'success','started_at':AT}]})
    forge.put('/repos/o/r/commits/'+A+'/statuses?per_page=100',[])
    forge.put('/repos/o/r',{'permissions':{'push':False}})
    return core

def repeated_poll():
    p=home('poll-repeat'); own(p,'delivery',8); setup_pr()
    begin=len(forge.requests); poll(p)
    first=copy.deepcopy(saved(p,'delivery')); cold=forge.requests[begin:]
    assert len([r for r in cold if r['method']=='GET'])==7
    assert first['records'][0]['error'] is None and first['records'][0]['observation']['head']==A
    begin=len(forge.requests); poll(p)
    warm=forge.requests[begin:]
    assert len([r for r in warm if r['status']==304])==7 and len([r for r in warm if r['path']=='/graphql'])==1
    comments='/repos/o/r/issues/8/comments?per_page=100'
    comment={'id':12,'user':{'login':'maintainer'},'author_association':'OWNER','body':'Please clarify the contract',
      'html_url':'https://github.com/o/r/pull/8#issuecomment-12','updated_at':AT}
    forge.put(comments,[],headers={'Link':'<https://api.github.com'+comments+'&page=2>; rel="next"'})
    forge.put(comments+'&page=2',[comment])
    changed=poll(p)
    row=saved(p,'delivery')['records'][0]
    assert len(row['pending'])==1 and row['pending'][0]['source']==comment['html_url']
    assert (p/'state/.wake-queue').exists() and 'contribution-' in (p/'state/.wake-queue').read_text()
    assert 'contribution-wake:' in changed.stdout
    view=snapshot(p)
    return {'cold_requests':len(cold),'warm_statuses':[r['status'] for r in warm],
      'changed_pending':row['pending'],'durable_wake':(p/'state/.wake-queue').read_text(),'snapshot':view}

def quota_episode():
    p=home('poll-quota'); own(p,'delivery',8); setup_pr(); poll(p)
    original=copy.deepcopy(saved(p,'delivery')['records'][0])
    forge.put('/repos/o/r',{'permissions':{'push':False}},rate={'remaining':500,'reset':RATE_RESET})
    get(p,'/repos/o/r')
    begin=len(forge.requests); low=poll(p); assert len(forge.requests)==begin
    assert low.stdout.count('quota low')==1
    stale=saved(p,'delivery')['records'][0]
    assert {k:v for k,v in stale.items() if k!='error'}=={k:v for k,v in original.items() if k!='error'}
    own(p,'aaa',8); own(p,'tail',9); setup_pr(9)
    silent=poll(p); assert silent.stdout=='' and len(forge.requests)==begin
    assert saved(p,'aaa')['records'][0]['observation'] is None
    assert 'quota low' in saved(p,'tail')['records'][0]['error']
    forge.put('/repos/o/r',{'permissions':{'push':False}},rate={'remaining':400,'reset':RATE_RESET})
    get(p,'/repos/o/r'); begin=len(forge.requests)
    silent=poll(p); assert silent.stdout=='' and len(forge.requests)==begin
    assert '400 of 5000' in saved(p,'delivery')['records'][0]['error']
    marked=snapshot(p); assert marked['complete'] is False and marked['checked']==0
    forge.put('/repos/o/r',{'permissions':{'push':False}},rate={'remaining':300,'reset':RATE_RESET+3600})
    get(p,'/repos/o/r'); new=poll(p); assert new.stdout.count('quota low')==1
    quota=state(p); quota['reset']=int(time.time())-1
    (p/'state/gh-ratelimit.core.json').write_text(json.dumps(quota))
    setup_pr(8); setup_pr(9)
    begin=len(forge.requests); poll(p); assert len(forge.requests)>begin
    for task in ('delivery','aaa','tail'): assert saved(p,task)['records'][0]['error'] is None
    return {'first_announcement':low.stdout,'same_window_late_owner_output':silent.stdout,
      'marked_snapshot':marked,'new_window_announcement':new.stdout,
      'resumed_rows':{task:saved(p,task) for task in ('delivery','aaa','tail')}}

def wave_tail(kind):
    for resource in forge.resources.values():
        resource.pop('delay',None); resource.pop('rate',None)
    p=home('poll-wave-corrected-'+kind)
    fixed='2026-10-09T00:00:00Z' # even five-minute bucket starts with first sorted URL
    if kind=='issue':
        own(p,'filed',9,'issues')
        core={'state':'open','user':{'login':'author'},'labels':[],'html_url':'https://github.com/o/r/issues/9'}
        forge.put('/repos/o/r/issues/9',core)
        forge.put('/repos/o/r/issues/9/comments?per_page=100',[])
        forge.put('/repos/o/r/issues/9/events?per_page=100',[])
    else: own(p,'delivery',8); setup_pr(8)
    own(p,'tail',9 if kind=='pr' else 10); setup_pr(9 if kind=='pr' else 10)
    poll(p,FM_CONTRIBUTIONS_NOW=fixed,FM_CONTRIBUTIONS_BUDGET='25')
    if kind=='pr': own(p,'duplicate',8)
    before={t:saved(p,t)['records'][0] for t in (('tail','delivery') if kind=='pr' else ('tail','filed'))}
    if kind=='issue':
        forge.put('/repos/o/r/issues/9',core,delay=2.5)
        for suffix in ('comments','events'):
            forge.put('/repos/o/r/issues/9/'+suffix+'?per_page=100',[],delay=3.2,rate={'remaining':500})
    else:
        core=setup_pr(8)
        forge.put('/repos/o/r/pulls/8',core,delay=2.5)
        paths=[f'/repos/o/r/issues/8/comments?per_page=100',f'/repos/o/r/pulls/8/reviews?per_page=100',
          f'/repos/o/r/pulls/8/comments?per_page=100','/repos/o/r/commits/'+A+'/check-runs?filter=all&per_page=100',
          '/repos/o/r/commits/'+A+'/statuses?per_page=100','/repos/o/r']
        for path in paths:
            resource=copy.deepcopy(forge.resources[path]); resource['delay']=3.2; resource['rate']={'remaining':500}
            forge.put(path,**resource)
    begin=len(forge.requests); started=time.monotonic()
    done=poll(p,FM_CONTRIBUTIONS_NOW='2026-10-09T00:01:00Z',FM_CONTRIBUTIONS_BUDGET='20')
    elapsed=time.monotonic()-started; requests=forge.requests[begin:]
    assert elapsed>5 and 'quota low' in done.stdout
    assert len(requests)==(3 if kind=='issue' else 7) and all(r['path']!='/graphql' for r in requests)
    assert all(('/pulls/9' if kind=='pr' else '/pulls/10') not in r['path'] for r in requests)
    tail=saved(p,'tail')['records'][0]
    assert 'quota low' in tail['error'] and dict(tail,error=None)==dict(before['tail'],error=None)
    first=saved(p,'filed' if kind=='issue' else 'delivery')['records'][0]
    if kind=='issue': assert first['error'] is None and first['checked_at']=='2026-10-09T00:01:00Z'
    else:
        assert 'quota low' in first['error'] and dict(first,error=None)==dict(before['delivery'],error=None)
        assert 'quota low' in saved(p,'duplicate')['records'][0]['error']
    details={'duration_seconds':elapsed,'announcement':done.stdout,'first_row':first,'tail_row':tail,
      'snapshot':snapshot(p),'requests_at_transition':requests}
    # Remove service-side low quota and delays for subsequent independent scenarios.
    forge.rate['reset']=RATE_RESET
    for resource in forge.resources.values(): resource.pop('delay',None); resource.pop('rate',None)
    return details

if __name__=='__main__':
    try:
        persist('live-initial-setups',d.results[6:])
        del d.results[6:]
        scenario('A successful low-quota PR wave blocks GraphQL and marks every unmeasured tail owner',lambda:wave_tail('pr'))
        scenario('A completed low-quota issue remains measured while budget-skipped tail owners become stale',lambda:wave_tail('issue'))
    finally:
        forge.close(); persist('live-results',d.results); persist('live-transcript',d.transcript)
    assert all(x['result']=='pass' for x in d.results),[(x['name'],x['result']) for x in d.results]
