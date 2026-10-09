import datetime as dt, hashlib, json, os, shutil, subprocess, time, traceback
from pathlib import Path
from api import Forge
ROOT = Path.cwd()
LAB = ROOT/'.conditional-live-validation'
EVIDENCE = Path('/Users/charlesabrooker/.no-mistakes/evidence/01M4FKQKCEVXQYBJPMP1A0C6BN')
forge = Forge(LAB)
BASE = {k:v for k,v in os.environ.items() if not k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI_')) and k not in ('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','NO_PROXY','NM_HOME','NO_MISTAKES_GATE')}
BASE.update(GH_TOKEN='disposable-local-api-token',GH_CONFIG_DIR=str(LAB/'gh-config'),
    GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',SSL_CERT_FILE=str(LAB/'cert.pem'),
    HTTPS_PROXY='http://127.0.0.1:'+str(forge.server.server_port),HTTP_PROXY='http://127.0.0.1:'+str(forge.server.server_port),NO_PROXY='',
    TMPDIR=str(LAB/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',NM_HOME=str(LAB/'nm'))
BASE.update(HOME=str(LAB/'user-home'),XDG_CACHE_HOME=str(LAB/'user-cache'),GH_TELEMETRY='false',DO_NOT_TRACK='1')
(LAB/'user-home').mkdir(exist_ok=True)
(LAB/'user-cache').mkdir(exist_ok=True)
A, B = 'a'*40, 'b'*40
transcript, results = [], []
active = None

def iso(): return dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def home(name):
    p = LAB/name
    for d in ('state','data','config','projects'): (p/d).mkdir(parents=True,exist_ok=True)
    (p/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
    return p

def env(p,**extra):
    return dict(BASE,FM_HOME=str(p),FM_ROOT_OVERRIDE=str(ROOT),FM_STATE_OVERRIDE=str(p/'state'),
        FM_DATA_OVERRIDE=str(p/'data'),FM_CONFIG_OVERRIDE=str(p/'config'),FM_PROJECTS_OVERRIDE=str(p/'projects'),**extra)

def record(command,done):
    transcript.append({'scenario':active,'command':command,'exit':done.returncode,'stdout':done.stdout,'stderr':done.stderr})
    print('$ '+' '.join(command)+'\n'+done.stdout+done.stderr+'exit='+str(done.returncode),flush=True)
    return done

def run(p,command,expected=0,**extra):
    command = [str(x) for x in command]
    done = record(command,subprocess.run(command,env=env(p,**extra),capture_output=True,text=True,timeout=60))
    assert done.returncode == expected,(command,done.returncode,done.stdout,done.stderr)
    return done

def get(p,path,*args,expected=0,**extra): return run(p,[ROOT/'bin/fm-gh-rest.sh','get',path,*args],expected,**extra)
def jsonout(done): return json.loads(done.stdout)
def cache(p,path):
    key = hashlib.sha256(('github.com\n'+path.lstrip('/')).encode()).hexdigest()
    return p/'state/gh-rest-cache'/(key+'.json')
def state(p): return json.loads((p/'state/gh-ratelimit.core.json').read_text())
def own(p,task,num,kind='pull'):
    with (p/'data/backlog.md').open('a') as out:
        out.write(f'- [ ] {task} - Lab contribution https://github.com/o/r/{kind}/{num} (repo: sample) (kind: ship)\n')
def saved(p,task): return json.loads((p/'data'/task/'contributions.json').read_text())
def poll(p,**extra): return run(p,[ROOT/'bin/fm-contributions.sh','poll'],**extra)
def snapshot(p):
    done = run(p,[ROOT/'bin/fm-fleet-snapshot.sh','--contribution-input'])
    path = p/'input.json'; path.write_text(done.stdout)
    return jsonout(run(p,[ROOT/'bin/fm-contributions.sh','snapshot',path,'--all']))
def persist(label,value):
    path=EVIDENCE/(label+'.json'); path.write_text(json.dumps(value,indent=2)+'\n'); return str(path)
def scenario(name,fn):
    global active
    active=name; start=len(forge.requests); begin=len(transcript)
    print('\nSCENARIO '+name,flush=True)
    try:
        details=fn()
        result={'name':name,'result':'pass','live':True,'reason':'','details':details}
    except Exception as exc:
        traceback.print_exc()
        result={'name':name,'result':'fail','live':True,'reason':str(exc),'traceback':traceback.format_exc()}
    result['commands']=transcript[begin:]; result['requests']=forge.requests[start:]
    result['evidence']=persist('live-'+str(len(results)+1),result)
    results.append(result)

PATH='/repos/o/r/items?per_page=2'
LINK='<https://api.github.com/repos/o/r/items?per_page=2&page=2>; rel="next"'

def conditional():
    p=home('conditional')
    forge.put(PATH,[{'id':1},{'id':2}])
    first=jsonout(get(p,PATH,'--paginate','--slurp'))
    second=jsonout(get(p,PATH,'--paginate','--slurp'))
    assert first == second == [[{'id':1},{'id':2}]]
    assert [r['status'] for r in forge.requests[-2:]] == [200,304]
    forge.put(PATH,[{'id':1},{'id':2}],headers={'Link':LINK})
    forge.put(PATH+'&page=2',[{'id':3}])
    expanded=jsonout(get(p,PATH,'--paginate','--slurp'))
    assert expanded == [[{'id':1},{'id':2}],[{'id':3}]]
    forge.put(PATH,[{'id':1},{'id':2}],omit_link_304=True)
    assert jsonout(get(p,PATH,'--paginate','--slurp')) == expanded
    forge.put(PATH,[{'id':1},{'id':2}],headers={'Link':'<https://api.github.com/repos/o/r/items?page=1>; rel="prev"'})
    assert jsonout(get(p,PATH,'--paginate','--slurp')) == first
    forge.put(PATH,[{'id':9}])
    assert jsonout(get(p,PATH)) == [{'id':9}]
    assert jsonout(get(p,PATH)) == [{'id':9}]
    entry=cache(p,PATH)
    for bad in ('not json',json.dumps({'etag':'"bad"','body':'{broken'})):
        entry.write_text(bad)
        assert jsonout(get(p,PATH)) == [{'id':9}]
        assert forge.requests[-1]['conditional'] is None
    entry.unlink()
    assert jsonout(get(p,PATH)) == [{'id':9}]
    query='/repos/o/r/commits?sha='+B+'&path=dir%2Fa%20b.ts&per_page=100'
    forge.put(query,[{'sha':A,'author':{'login':'carol'}}])
    assert jsonout(get(p,'/repos/o/r/commits','-f','sha='+B,'-f','path=dir/a b.ts','-f','per_page=100'))[0]['sha'] == A
    return {'cold_and_warm':first,'expanded':expanded,'final_cache':json.loads(entry.read_text()),'encoded_query':query}

def generations():
    details=[]
    for mode in ('supplied','omitted'):
        p=home('generation-'+mode)
        forge.put(PATH,[{'id':1}]); get(p,PATH)
        forge.put(PATH,[{'id':2}]); older=forge.pause(PATH)
        command=[str(ROOT/'bin/fm-gh-rest.sh'),'get',PATH]
        one=subprocess.Popen(command,env=env(p),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert older['ready'].wait(10)
        forge.put(PATH,[{'id':3}],headers={'Link':LINK} if mode=='omitted' else {})
        forge.put(PATH+'&page=2',[{'id':4}])
        get(p,PATH,'--paginate','--slurp')
        forge.put(PATH,[{'id':3}],headers={'Link':LINK},omit_link_304=(mode=='omitted'))
        current=forge.pause(PATH)
        two=subprocess.Popen(command+['--paginate','--slurp'],env=env(p),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert current['ready'].wait(10)
        older['release'].set(); out,err=one.communicate(timeout=15)
        record(command,subprocess.CompletedProcess(command,one.returncode,out,err)); assert one.returncode==0
        assert json.loads(cache(p,PATH).read_text())['body'].strip() == '[{"id": 2}]'
        current['release'].set(); out,err=two.communicate(timeout=15)
        record(command+['--paginate','--slurp'],subprocess.CompletedProcess(command,two.returncode,out,err))
        assert two.returncode==0 and json.loads(out)==[[{'id':3}],[{'id':4}]]
        replacement=json.loads(cache(p,PATH).read_text())
        assert json.loads(replacement['body'])==[{'id':2}] and replacement['next'] is None
        forge.put(PATH,[{'id':2}],omit_link_304=True)
        assert jsonout(get(p,PATH,'--paginate','--slurp'))==[[{'id':2}]]
        details.append({'links':mode,'validated_response':json.loads(out),'replacement_cache':replacement})
    return details

def errors_and_floor():
    p=home('floor')
    forge.put('/repos/o/r/error',{'message':'isolated service failure'},status=502,rate={'remaining':600})
    failure=get(p,'/repos/o/r/error',expected=1)
    assert '502' in failure.stderr and not cache(p,'/repos/o/r/error').exists()
    refusal=run(p,[ROOT/'bin/fm-gh-rest.sh','guard'],expected=75)
    assert '600 of 5000' in refusal.stdout
    before=len(forge.requests); get(p,PATH,'--floor',expected=75); assert len(forge.requests)==before
    run(p,[ROOT/'bin/fm-gh-rest.sh','guard'],FM_GH_RATE_FLOOR_PERCENT='10')
    run(p,[ROOT/'bin/fm-gh-rest.sh','guard'],expected=75,FM_GH_RATE_FLOOR_PERCENT='invalid')
    forge.put(PATH,[{'id':1}],headers={'Link':LINK},rate={'remaining':4000,'reset':forge.rate['reset']+3600})
    forge.put(PATH+'&page=2',[{'id':2}])
    get(p,PATH,'--paginate','--slurp')
    for mode in ('fresh','cached'):
        q=home('floor-page-'+mode)
        if mode=='cached': get(q,PATH,'--paginate','--slurp')
        forge.put(PATH,[{'id':1}],headers={'Link':LINK},rate={'remaining':500,'reset':forge.rate['reset']+3600})
        begin=len(forge.requests); done=get(q,PATH,'--floor','--paginate','--slurp',expected=75)
        assert done.stdout=='' and len(forge.requests)==begin+1
        assert '500 of 5000' in done.stderr
        forge.put(PATH,[{'id':1}],headers={'Link':LINK},rate={'remaining':4000,'reset':forge.rate['reset']+3600})
    expired=state(p); expired['reset']=int(time.time())-1
    (p/'state/gh-ratelimit.core.json').write_text(json.dumps(expired))
    get(p,PATH,'--floor')
    return {'http_error':failure.stderr,'quota_refusal':refusal.stdout,'recovered_quota':state(p)}

def quota_concurrency():
    p=home('quota-concurrency')
    forge.put('/repos/o/r/quota-seed',[],rate={'remaining':800}); get(p,'/repos/o/r/quota-seed')
    forge.put('/repos/o/r/quota-low',[],rate={'remaining':749})
    forge.put('/repos/o/r/quota-high',[],rate={'remaining':750})
    pauses=[forge.pause('/repos/o/r/quota-'+k) for k in ('low','high')]
    children=[]
    for key in ('low','high'):
        command=[str(ROOT/'bin/fm-gh-rest.sh'),'get','/repos/o/r/quota-'+key]
        children.append((command,subprocess.Popen(command,env=env(p),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)))
    assert all(b['ready'].wait(10) for b in pauses)
    for b in pauses: b['release'].set()
    for command,child in children:
        out,err=child.communicate(timeout=15); record(command,subprocess.CompletedProcess(command,child.returncode,out,err)); assert child.returncode==0
    assert state(p)['remaining']==749
    low=state(p)
    forge.put('/repos/o/r/old-window',[],rate={'remaining':4900,'reset':low['reset']-100})
    get(p,'/repos/o/r/old-window'); assert state(p)==low
    run(p,[ROOT/'bin/fm-gh-rest.sh','guard'],expected=75)
    forge.put('/repos/o/r/new-window',[],rate={'remaining':4000,'reset':low['reset']+3600})
    get(p,'/repos/o/r/new-window'); run(p,[ROOT/'bin/fm-gh-rest.sh','guard'])
    return {'lowest_concurrent':low,'new_window':state(p)}

if __name__ == '__main__':
    try:
        scenario('Read unchanged and changed paginated resources with safe cache fallback',conditional)
        scenario('Concurrent 304 serves its validated generation without rewriting another generation',generations)
        scenario('HTTP failure and fresh or cached pagination refuse safely below the quota floor',errors_and_floor)
        scenario('Concurrent quota responses retain the minimum and reject older windows',quota_concurrency)
    finally:
        forge.close(); persist('live-results',results); persist('live-transcript',transcript)
    assert all(x['result']=='pass' for x in results),results
