import copy
import consumers as c
from consumers import *

def ledger(p,**extra):
    return jsonout(run(p,[ROOT/'bin/fm-open-loops.sh','--heartbeat','--json'],**extra))

def setup_ledger():
    core=setup_pr(8)
    forge.put('/repos/o/r/pulls?state=open&per_page=100',[core])
    forge.put('/repos/o/r/commits/'+A+'/check-runs?per_page=100',{'check_runs':[
      {'name':'build','id':1,'app':{'id':10},'status':'completed','conclusion':'failure','completed_at':AT}]})
    return core

def ledger_quota():
    p=home('ledger-live'); own(p,'delivery',8); core=setup_ledger()
    first=ledger(p); assert first['complete'] and any(row['category']=='red_check' for row in first['rows'])
    begin=len(forge.requests); warm=ledger(p)
    assert warm['complete'] and len(forge.requests)>begin and all(r['status']==304 for r in forge.requests[begin:])
    forge.put('/repos/o/r',{'permissions':{'push':False}},rate={'remaining':500})
    get(p,'/repos/o/r'); begin=len(forge.requests)
    low=ledger(p,FM_OPEN_LOOPS_NOW=str(int(time.time())+60))
    assert len(forge.requests)==begin and not low['complete'] and low['stale']
    assert low['generated_epoch']==warm['generated_epoch'] and low['stale_until_epoch']==state(p)['reset']
    old={r['id']:r for r in warm['rows']}
    held={r['id']:r for r in low['rows'] if r['subject']!='ledger stale'}
    assert set(old)==set(held)
    assert all(held[k]==dict(row,stale=True) for k,row in old.items())
    assert json.loads((p/'state/open-loops.json').read_text())==low
    q=home('ledger-no-prior'); own(q,'delivery',8)
    forge.put('/repos/o/r',{'permissions':{'push':False}},rate={'remaining':500})
    get(q,'/repos/o/r'); begin=len(forge.requests); empty=ledger(q)
    assert len(forge.requests)==begin and not empty['complete'] and empty['stale']
    assert len(empty['rows'])==1 and empty['rows'][0]['subject']=='ledger degraded'
    for resource in forge.resources.values(): resource.pop('rate',None)
    quota=state(p); quota['reset']=int(time.time())-1
    (p/'state/gh-ratelimit.core.json').write_text(json.dumps(quota))
    begin=len(forge.requests); recovered=ledger(p)
    assert len(forge.requests)>begin and recovered['complete'] and 'stale' not in recovered
    path='/repos/o/r/pulls?state=open&per_page=100'
    forge.put(path,[core],headers={'Link':'<https://api.github.com'+path+'&page=2>; rel="next"'},rate={'remaining':500})
    forge.put(path+'&page=2',[dict(core,number=9,html_url='https://github.com/o/r/pull/9')])
    begin=len(forge.requests); interrupted=ledger(p)
    assert len(forge.requests)==begin+1 and interrupted['stale'] and not interrupted['complete']
    assert interrupted['generated_epoch']==recovered['generated_epoch']
    assert all('pull/9' not in row['subject'] for row in interrupted['rows'])
    return {'healthy':first,'warm':warm,'retained':low,'missing_prior':empty,'recovered':recovered,'midpage_retained':interrupted}

def advisory():
    p=home('advisories'); setup_pr()
    forge.pr['reviewDecision']='CHANGES_REQUESTED'
    reviews='/repos/o/r/pulls/8/reviews?per_page=100'
    old={'user':{'login':'oldreviewer'},'state':'CHANGES_REQUESTED','commit_id':B,'submitted_at':'2026-10-08T10:00:00Z'}
    current={'user':{'login':'maintainer'},'state':'CHANGES_REQUESTED','commit_id':A,'submitted_at':AT}
    forge.put(reviews,[old],headers={'Link':'<https://api.github.com'+reviews+'&page=2>; rel="next"'},rate={'remaining':500})
    forge.put(reviews+'&page=2',[current],rate={'remaining':500})
    first=run(p,[ROOT/'bin/fm-pr-state.sh','https://github.com/o/r/pull/8'])
    assert 'REVIEW: maintainer CHANGES_REQUESTED' in first.stdout
    assert 'STALE BLOCKING REVIEW: oldreviewer CHANGES_REQUESTED at '+B in first.stdout
    begin=len(forge.requests)
    second=run(p,[ROOT/'bin/fm-pr-state.sh','https://github.com/o/r/pull/8'])
    assert second.stdout==first.stdout
    assert [r['status'] for r in forge.requests[begin:] if r['method']=='GET']==[304,304]
    files='/repos/o/r/pulls/8/files?per_page=100'
    forge.put(files,[{'filename':'dir/a b.ts'}],headers={'Link':'<https://api.github.com'+files+'&page=2>; rel="next"'})
    forge.put(files+'&page=2',[{'filename':'b.ts'}])
    one=[{'sha':'1'*40,'author':{'login':'carol','type':'User'}},
      {'sha':'2'*40,'author':{'login':'carol','type':'User'}},
      {'sha':'3'*40,'author':{'login':'author','type':'User'}},
      {'sha':'4'*40,'author':{'login':'buildbot','type':'Bot'}}]
    two=[one[0],{'sha':'5'*40,'author':{'login':'bob','type':'User'}}]
    forge.put('/repos/o/r/commits?sha='+B+'&path=dir%2Fa%20b.ts&per_page=100',one)
    forge.put('/repos/o/r/commits?sha='+B+'&path=b.ts&per_page=100',two)
    candidate=run(p,[ROOT/'bin/fm-pr-reviewers.sh','https://github.com/o/r/pull/8'])
    assert 'carol\t2 recent commits' in candidate.stdout and 'bob\t1 recent commit' in candidate.stdout
    assert 'buildbot' not in candidate.stdout and 'author\t' not in candidate.stdout
    begin=len(forge.requests)
    cached=run(p,[ROOT/'bin/fm-pr-reviewers.sh','https://github.com/o/r/pull/8'])
    assert cached.stdout==candidate.stdout and all(r['status']==304 for r in forge.requests[begin:])
    run(p,[ROOT/'bin/fm-gh-rest.sh','guard'],expected=75)
    return {'state_output':first.stdout,'reviewer_output':candidate.stdout,'recorded_low_quota':state(p),'warm_reviewers_requests':forge.requests[begin:]}

if __name__=='__main__':
    try:
        scenario('Ledger keeps all published rows stale under quota refusal and refreshes after reset',ledger_quota)
        for resource in forge.resources.values(): resource.pop('rate',None)
        scenario('PR advisory readers report all paginated blockers and reviewer evidence even below the sweep floor',advisory)
    finally:
        forge.close(); persist('live-results',d.results); persist('live-transcript',d.transcript)
    assert all(x['result']=='pass' for x in d.results),[(x['name'],x['result']) for x in d.results]
