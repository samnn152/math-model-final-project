"""Deferred, exclusive Step 9 memory retries; existing solver services are read only."""
import base64,concurrent.futures,datetime,importlib.util,inspect,json,os,subprocess,tempfile,threading,time,urllib.error,urllib.parse,urllib.request
from pathlib import Path
BUCKET='orange-coordination-201187524024';PREFIX='memory-v1';VMS=['orange-seta-onepass','orange-step6-worker','orange-tenrun-02','orange-tenrun-03']
TOKEN=None;TOKEN_UNTIL=0;TOKEN_LOCK=threading.Lock()
def token():
 global TOKEN,TOKEN_UNTIL
 with TOKEN_LOCK:
  if TOKEN and time.time()<TOKEN_UNTIL:return TOKEN
  key=json.loads(Path('/etc/orange-memory/writer.json').read_text());enc=lambda x:base64.urlsafe_b64encode(x).rstrip(b'=');now=int(time.time())
  msg=enc(json.dumps({'alg':'RS256','typ':'JWT'}).encode())+b'.'+enc(json.dumps({'iss':key['client_email'],'scope':'https://www.googleapis.com/auth/devstorage.read_write','aud':'https://oauth2.googleapis.com/token','iat':now,'exp':now+3600}).encode())
  with tempfile.NamedTemporaryFile(mode='w') as f:
   f.write(key['private_key']);f.flush();sig=subprocess.check_output(['openssl','dgst','-sha256','-sign',f.name],input=msg)
  data=urllib.parse.urlencode({'grant_type':'urn:ietf:params:oauth:grant-type:jwt-bearer','assertion':(msg+b'.'+enc(sig)).decode()}).encode()
  value=json.load(urllib.request.urlopen(urllib.request.Request('https://oauth2.googleapis.com/token',data=data),timeout=20));TOKEN=value['access_token'];TOKEN_UNTIL=now+3000
  return TOKEN
def get_object(name):
 req=urllib.request.Request('https://storage.googleapis.com/'+BUCKET+'/'+PREFIX+'/'+name,headers={'Authorization':'Bearer '+token()})
 try:
  with urllib.request.urlopen(req,timeout=20) as r:return json.load(r),r.headers.get('x-goog-generation')
 except urllib.error.HTTPError as e:
  if e.code==404:return None,None
  raise
def put_object(name,data,generation=None):
 headers={'Authorization':'Bearer '+token(),'Content-Type':'application/json'}
 if generation is not None:headers['x-goog-if-generation-match']=str(generation)
 req=urllib.request.Request('https://storage.googleapis.com/'+BUCKET+'/'+PREFIX+'/'+name,headers=headers,data=json.dumps(data).encode(),method='PUT')
 try:
  with urllib.request.urlopen(req,timeout=20) as r:return r.headers.get('x-goog-generation')
 except urllib.error.HTTPError as e:
  if e.code in (409,412):return None
  raise
def read(path):
 try:return json.loads(path.read_text())
 except (OSError,ValueError):return {}
def processes():
 rows=[]
 for p in Path('/proc').glob('[0-9]*'):
  try:
   args=(p/'cmdline').read_bytes().decode().split('\0')
   if not args or Path(args[0]).name!='julia' or '--output' not in args:continue
   out=Path(args[args.index('--output')+1]);rows.append({'job':out.parent.name,'output':str(out),'pid':int(p.name)})
  except (OSError,ValueError,IndexError):pass
 return rows
def snapshot(cfg):
 completed=set();memory=set()
 for root in [Path(x) for x in cfg['roots']]+[Path(cfg['output'])]:
  files=list(root.glob('step*_setA-*/supervisor.json'))+list(root.glob('recovery-history/*/supervisor.json'))+list(root.glob('recovery_before*/*/supervisor.json'))
  for f in files:
   row=read(f);job=row.get('job','')
   if not job.startswith('step9_') and not job.startswith('step6_'):continue
   if row.get('completed') is True:completed.add(job)
   if job.startswith('step9_') and (row.get('reason') in ('RSS_GUARD','LOW_SYSTEM_MEMORY','OOM','OUT_OF_MEMORY') or row.get('termination') in ('MEMORY_LIMIT','OUT_OF_MEMORY')):memory.add(job)
 state=subprocess.run(['systemctl','is-active',cfg['normal_service']],capture_output=True,text=True).stdout.strip();procs=processes()
 normal_live=any(not p['output'].startswith(cfg['output']+'/') for p in procs)
 # Step 6 must really finish all 200 runs before this VM changes purpose.
 if cfg.get('stage')==6 and any(j not in completed for j in cfg['jobs']):normal_live=True
 return {'timestamp':time.time(),'vm':os.uname().nodename,'normal_active':state=='active' or normal_live,'normal_service':cfg['normal_service'],'normal_assigned':cfg['jobs'],'completed':sorted(completed),'memory_failed':sorted(memory-completed),'active_jobs':[p['job'] for p in procs],'memory_active':[p['job'] for p in procs if p['output'].startswith(cfg['output']+'/')]}
def load_snapshots():
 rows=[]
 for vm in VMS:
  value,_=get_object('snapshots/'+vm+'.json')
  if value is None or time.time()-value['timestamp']>180:return None
  rows.append(value)
 return rows
def candidates(rows):
 completed=set(j for s in rows for j in s['completed']);active=set(j for s in rows for j in s['active_jobs']);failed=set(j for s in rows for j in s['memory_failed'])
 result=[]
 for job in sorted(failed-completed-active):
  owners=[s for s in rows if job in s['normal_assigned']]
  # Original dispatchers may have queued retries. Never steal while an owner is active.
  if not owners or any(s['normal_active'] for s in owners):continue
  result.append(job)
 return result
def claim(job,vm):
 value={'job':job,'vm':vm,'state':'running','rss_gib':24,'claimed_at':time.time()}
 generation=put_object('claims/'+job+'.json',value,0)
 return (value,generation) if generation else (None,None)
def execute(cfg,job,record,generation):
 source=Path(cfg['source']);root=Path(cfg['output']);root.mkdir(exist_ok=True,parents=True)
 try:
  spec=importlib.util.spec_from_file_location('dispatch_'+job,source/'cloud/run_cloud_jobs.py');dispatch=importlib.util.module_from_spec(spec);spec.loader.exec_module(dispatch)
  instance=int(job.split('setA-')[1].split('_')[0]);run=int(job.rsplit('-',1)[1]);row=dispatch.execute_job(source,root,(9,instance,3600,run),24,**({'stop':threading.Event()} if 'stop' in inspect.signature(dispatch.execute_job).parameters else {'attempt':1}))
 except Exception as error:row={'job':job,'completed':False,'reason':type(error).__name__+': '+str(error)}
 record.update(state='completed' if row.get('completed') is True else 'failed',finished_at=time.time(),reason=row.get('reason'),termination=row.get('termination'),result_file=row.get('result_file'))
 # A claim is never deleted or automatically stolen, including after a crash.
 # This favors no duplicate execution; an abandoned claim requires manual review.
 for attempt in range(5):
  try:
   if put_object('claims/'+job+'.json',record,generation):break
  except Exception as error:print('claim completion upload retry',job,type(error).__name__,flush=True)
  time.sleep(10)
 print(json.dumps(record),flush=True)
 return record
def main():
 cfg=read(Path('/etc/orange-memory/config.json'));vm=os.uname().nodename;futures={};started=time.time();last_state=None
 Path(cfg['output']).mkdir(exist_ok=True,parents=True)
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  while time.time()-started<58*3600:
   try:
    for future in list(futures):
     if future.done():future.result();del futures[future]
    local=snapshot(cfg);put_object('snapshots/'+vm+'.json',local)
    rows=load_snapshots();phase='waiting_for_normal_jobs' if local['normal_active'] else 'memory_retry_ready'
    if rows is not None and not local['normal_active']:
     for job in candidates(rows):
      if len(futures)>=2:break
      record,generation=claim(job,vm)
      if record:
       futures[pool.submit(execute,cfg,job,record,generation)]=job
       print('exclusive claim',job,vm,'24 GiB',flush=True)
    state={'phase':phase,'workers':2,'rss_gib_per_job':24,'active_memory_jobs':list(futures.values()),'normal_active':local['normal_active'],'snapshots_fresh':rows is not None,'timestamp':time.time()}
    Path(cfg['output'],'pool-status.json').write_text(json.dumps(state))
    if phase!=last_state:print(json.dumps(state),flush=True);last_state=phase
    # Stop after all original queues and all memory retry workers are drained.
    if rows and not futures and all(not s['normal_active'] and not s['memory_active'] for s in rows):
     remaining=False
     for job in candidates(rows):
      value,_=get_object('claims/'+job+'.json')
      if value is None or value.get('state')=='running':remaining=True;break
     if not remaining:
      print('All normal queues finished; shared memory retry queue drained.',flush=True);break
   except Exception as error:print('coordination unavailable; no new jobs claimed:',type(error).__name__,str(error),flush=True)
   time.sleep(30)
if __name__=='__main__':main()
