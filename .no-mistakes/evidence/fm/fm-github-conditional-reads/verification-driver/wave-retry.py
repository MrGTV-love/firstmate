import copy
import consumers as c
from consumers import *

def seeded_wave():
    p=home('poll-wave-seeded-pr')
    donor=json.loads((LAB/'poll-repeat/data/delivery/contributions.json').read_text())
    for task,num in (('delivery',8),('duplicate',8),('tail',9)):
        own(p,task,num)
        fixture=copy.deepcopy(donor); fixture['task']=task
        row=fixture['records'][0]; row.update(url=f'https://github.com/o/r/pull/{num}',checked_at='2026-10-09T00:00:00Z',seen=[],pending=[],notified=[],error=None)
        row['observation']['events']=[]
        (p/'data'/task).mkdir(); (p/'data'/task/'contributions.json').write_text(json.dumps(fixture))
    core=setup_pr(8); setup_pr(9)
    old={t:copy.deepcopy(saved(p,t)['records'][0]) for t in ('delivery','duplicate','tail')}
    forge.put('/repos/o/r/pulls/8',core,delay=3.5)
    paths=['/repos/o/r/issues/8/comments?per_page=100','/repos/o/r/pulls/8/reviews?per_page=100',
      '/repos/o/r/pulls/8/comments?per_page=100','/repos/o/r/commits/'+A+'/check-runs?filter=all&per_page=100',
      '/repos/o/r/commits/'+A+'/statuses?per_page=100','/repos/o/r']
    for path in paths:
        resource=copy.deepcopy(forge.resources[path]); resource.update(delay=2,rate={'remaining':500})
        forge.put(path,**resource)
    begin=len(forge.requests); started=time.monotonic()
    done=poll(p,FM_CONTRIBUTIONS_NOW='2026-10-09T00:01:00Z',FM_CONTRIBUTIONS_BUDGET='20')
    elapsed=time.monotonic()-started; requests=forge.requests[begin:]
    assert elapsed>5 and len(requests)==7 and all(r['path']!='/graphql' for r in requests)
    assert all('/pulls/9' not in r['path'] for r in requests)
    current={t:saved(p,t)['records'][0] for t in old}
    for task,row in current.items():
        assert 'quota low' in row['error'] and dict(row,error=None)==dict(old[task],error=None)
    return {'duration_seconds':elapsed,'announcement':done.stdout,'unchanged_rows_except_error':current,
      'before':old,'quota':state(p),'requests_after_crossing':requests}

try:
    persist('live-pr-wave-setup-history',[x for x in d.results if x['name'].startswith('A successful')])
    d.results[:]=[x for x in d.results if not x['name'].startswith('A successful')]
    scenario('A low-quota PR wave blocks GraphQL and marks every unmeasured tail owner',seeded_wave)
finally:
    forge.close(); persist('live-results',d.results); persist('live-transcript',d.transcript)
assert all(x['result']=='pass' for x in d.results),[(x['name'],x['result']) for x in d.results]
