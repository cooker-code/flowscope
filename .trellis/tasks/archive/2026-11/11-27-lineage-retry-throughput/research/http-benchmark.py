"""Reproduction on this task's disposable 127.0.0.1:17687 Neo4j only."""
import json, os, socket, subprocess, tempfile, time, urllib.request
from pathlib import Path
from neo4j import GraphDatabase
ROOT = Path(__file__).resolve().parent
AUDIT = json.loads((ROOT/'audit-651353.json').read_text())['audit']['body']
ANALYSIS = json.loads(AUDIT['result_json']) if isinstance(AUDIT['result_json'],str) else AUDIT['result_json']
ADMIN = 'isolated-http-benchmark-admin-token-1127'
INDEXES = [('flowscope_fact_edge','LINEAGE_FACT','n.edge_key'),('flowscope_fact_scope_active','LINEAGE_FACT','n.scope_key,n.active'),('flowscope_scope_target','LINEAGE_SCOPE','n.target_key,n.withdrawn')]
assert b'flowscope_fact_scope_active' not in Path('/tmp/flowscope-before-1127').read_bytes(), 'baseline contains candidate storage'
assert b'neo4j_apply_timeout' in Path('/tmp/flowscope-after-1127').read_bytes(), 'candidate worker diagnostics missing'
RESULT = {'original':{},'indexed':[],'batched':[],'processCleanup':[]}

def api(base,path,token=ADMIN,body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base+path,data=data,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=10) as res:
        return json.load(res),dict(res.headers)

def reset(mode):
    with GraphDatabase.driver('bolt://127.0.0.1:17687',auth=None) as d:
        with d.session() as s:
            s.run('MATCH (n) WHERE NOT n:BENCH_BACKGROUND DETACH DELETE n').consume()
            s.run("UNWIND range(1,94555) AS i MERGE (f:LINEAGE_FACT:BENCH_BACKGROUND {fact_key:'background-'+toString(i)}) SET f.edge_key='background-'+toString(i),f.scope_key='background',f.active=false").consume()
            for name,label,keys in INDEXES:
                if mode=='original': s.run(f'DROP INDEX {name} IF EXISTS').consume()
                else: s.run(f'CREATE RANGE INDEX {name} IF NOT EXISTS FOR (n:{label}) ON ({keys})').consume()
            s.run('CALL db.awaitIndexes(60)').consume()

def run(mode,trial):
    reset(mode)
    with tempfile.TemporaryDirectory(prefix='flowscope-http-bench-1127-') as td:
        p=Path(td)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        base=f'http://127.0.0.1:{port}'
        config=p/'lineage.json'
        config.write_text(json.dumps({'stateDb':str(p/'state.db'),'adminTokenEnv':'FLOWSCOPE_BENCH_ADMIN','neo4j':{'uri':'127.0.0.1:17687','user':'neo4j','passwordEnv':'FLOWSCOPE_BENCH_PASSWORD','environment':'isolated-test'}}))
        env=os.environ.copy();env.update(FLOWSCOPE_BENCH_ADMIN=ADMIN,FLOWSCOPE_BENCH_PASSWORD='unused')
        binary='/tmp/flowscope-before-1127' if mode!='batched' else '/tmp/flowscope-after-1127'
        with open(p/'server.log','w+') as log:
            proc=subprocess.Popen([binary,'--serve','--dialect','hive','--host','127.0.0.1','--port',str(port),'--watch',td,'--audit-log',str(p/'state.db'),'--lineage-config',str(config)],env=env,stdout=log,stderr=log)
            try:
                for _ in range(100):
                    try:api(base,'/api/health');break
                    except OSError:time.sleep(.1)
                else:raise RuntimeError('server not ready')
                api(base,'/api/lineage/policies',body={'id':'bench','name':'bench','kind':'scheduler','action':'publish','enabled':True,'revision':0})
                token=api(base,'/api/lineage/tokens',body={'principalId':'bench'})[0]['token']
                schema={'tables':[{k:v for k,v in t.items() if k in ('catalog','schema','name','columns')} for t in ANALYSIS['resolvedSchema']['tables']]}
                def submit(version):
                    t=time.perf_counter()
                    value,headers=api(base,'/api/analyze',token,{'sql':AUDIT['sql_text'],'schema':schema,'lineage':{'sourceSystem':'change','sourceId':'100','sourceVersion':str(version),'environment':'isolated-test'}})
                    assert not value['summary']['hasErrors']
                    eid=next(v for k,v in headers.items() if k.lower()=='x-flowscope-event-id')
                    return {'version':version,'eventId':eid,'started':t,'acceptedMs':(time.perf_counter()-t)*1000}
                def status(item):return api(base,'/api/lineage/events/'+item['eventId'])[0]
                if mode=='original':
                    a=submit(1)
                    deadline=time.perf_counter()+40
                    while time.perf_counter()<deadline:
                        v=status(a)
                        if v['status']!='queued':break
                        time.sleep(.05)
                    assert v['status']=='committed',v
                    a['committedMs']=(time.perf_counter()-a.pop('started'))*1000
                    b=submit(2);deadline=time.perf_counter()+40
                    while time.perf_counter()<deadline:
                        v=status(b)
                        if v['attempts']>0 or v['status']!='queued':break
                        time.sleep(.05)
                    b['observedMs']=(time.perf_counter()-b.pop('started'))*1000;b['state']=v
                    assert v['status']=='queued' and v['attempts']>0,v
                    RESULT['original']={'first':a,'update':b}
                    print('HTTP_ORIGINAL',json.dumps(RESULT['original']),flush=True)
                else:
                    start=time.perf_counter();pending=[submit(v) for v in range(1,4)]
                    while any('committedMs' not in x for x in pending):
                        assert time.perf_counter()-start<45,'queue did not drain'
                        for item in pending:
                            if 'committedMs' in item:continue
                            state=status(item)
                            assert state['status'] in ('queued','committed'),state
                            assert state['attempts']==0,state
                            if state['status']=='committed':item['committedMs']=(time.perf_counter()-item['started'])*1000
                        time.sleep(.02)
                    elapsed=time.perf_counter()-start
                    for item in pending:del item['started']
                    result={'trial':trial,'events':pending,'queueWallMs':elapsed*1000,'eventsPerMinute':len(pending)/elapsed*60}
                    RESULT[mode].append(result);print('HTTP_QUEUE',mode,json.dumps(result),flush=True)
            except BaseException:
                log.seek(0);print(log.read()[-3000:]);raise
            finally:
                proc.terminate()
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
                RESULT['processCleanup'].append({'mode':mode,'trial':trial,'pid':proc.pid,'exitCode':proc.returncode,'reaped':proc.poll() is not None})
                (ROOT/'http-throughput.json').write_text(json.dumps(RESULT,indent=2))

run('original',0)
for mode in ('indexed','batched'):
    for trial in range(3):run(mode,trial)
