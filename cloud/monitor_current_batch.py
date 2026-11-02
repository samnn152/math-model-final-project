import base64,datetime,json,math,os,re,statistics,subprocess,tempfile,time,urllib.parse,urllib.request
from pathlib import Path
P='gen-lang-client-0358915784'
cfg=json.loads(Path('/etc/orange-monitor/current.json').read_text());roots=[Path(x) for x in cfg['roots']]+[Path('/opt/orange/results/memory_retry_20261023')]
def read(p):
 try:return json.loads(p.read_text())
 except (OSError,ValueError):return {}
def finite(x):return isinstance(x,(int,float)) and not isinstance(x,bool) and math.isfinite(x)
def main():
 planned=sorted(set(cfg['jobs'])|{p.name for root in roots for p in root.glob('step9_setA-*')});known={};paths={}
 for root in roots:
  for directory in root.glob('step*_setA-*'):
   if directory.name not in planned:continue
   row=read(directory/'supervisor.json')
   if row and (directory.name not in known or row.get('completed') or not known[directory.name].get('completed')):
    known[directory.name]=row;paths[directory.name]=directory
 completed=[j for j in planned if known.get(j,{}).get('completed') is True]
 failures=[j for j in planned if j in known and j not in completed];active=[]
 for proc in Path('/proc').glob('[0-9]*'):
  try:
   args=(proc/'cmdline').read_bytes().decode().split('\0')
   if not args or Path(args[0]).name!='julia' or '--output' not in args:continue
   out=Path(args[args.index('--output')+1]);job=out.parent.name
   if job not in planned:continue
   rss=next((int(x.split()[1])*1024 for x in (proc/'status').read_text().splitlines() if x.startswith('VmRSS:')),0)
   active.append({'job':job,'pid':int(proc.name),'tree_rss_bytes':rss})
  except (OSError,ValueError,IndexError,StopIteration):pass
 state=subprocess.run(['systemctl','is-active',cfg['service']],capture_output=True,text=True).stdout.strip()
 done=len(completed)==len(planned)
 pool_state=subprocess.run(['systemctl','is-active','orange-memory-retry.service'],capture_output=True,text=True).stdout.strip()
 outcome='running' if active or state=='active' or pool_state=='active' else ('completed' if done else 'stopped_or_failed')
 by_instance=[];result_lines={6:[],9:[]};valid=0;target=0;lex=0
 for stage in (6,9):
  for instance in range(1,21):
   prefix=f'step{stage}_setA-{instance:02d}_run-';assigned=[j for j in planned if j.startswith(prefix)]
   if not assigned:continue
   finished=[j for j in completed if j.startswith(prefix)]
   by_instance.append(f'Step {stage} SetA-{instance:02d}: {len(finished)}/{len(assigned)} lượt hoàn tất')
   objs=[];gaps=[]
   for j in finished:
    s=known[j];r=read(paths[j]/'experiment'/f'setA-{instance:02d}_run-{s.get("run",int(j[-2:])):02d}.json')
    ok=r.get('validated') is True;valid+=ok
    if ok and finite(r.get('objective')):objs.append(r['objective'])
    if ok and finite(r.get('gap')):gaps.append(r['gap']);target+=0<=r['gap']<=.1
    lex+=bool(ok and r.get('status')=='Optimal' and r.get('lex_total_stages',0)>0 and r.get('lex_completed_stages')==r.get('lex_total_stages'))
   if finished:
    result_lines[stage].append(f'SetA-{instance:02d} n={len(objs)}: MLU={statistics.mean(objs):.7g} +/- {statistics.stdev(objs) if len(objs)>1 else 0:.3g}; mean gap={100*statistics.mean(gaps):.4g}%' if objs and gaps else f'SetA-{instance:02d}: {len(finished)} hoàn tất; chưa đủ số liệu chất lượng')
 now=datetime.datetime.now(datetime.timezone.utc).isoformat();vm=os.uname().nodename
 report={'timestamp':now,'vm':vm,'campaign':cfg['campaign'],'service_state':state,'outcome':outcome,'completed':len(completed),'total':len(planned),'step6_completed':sum(j.startswith('step6_') for j in completed),'step9_completed':sum(j.startswith('step9_') for j in completed),'active':active,'failures':failures,'dataset_run_progress_text':'\n'.join(by_instance),'interpretation':f'Nghiệm hợp lệ: {valid}/{len(completed)}; MLU gap <=10%: {target}; chứng nhận toàn bộ từ điển: {lex}. Job lỗi được đếm riêng; hoàn tất không đồng nghĩa tối ưu từ điển.','eta':'Chưa có ETA tổng hợp toàn cụm; không suy ra ETA từ hàng đợi cũ.','active_analysis':'; '.join(f'{x["job"]}: PID={x["pid"]}, RSS={x["tree_rss_bytes"]/1024**3:.2f} GiB' for x in active) or 'Không có tiến trình solver đang chạy trên VM này.'}
 for stage in (6,9):
  for part in (0,1):report[f'results{stage}_{part+1}']='\n'.join(result_lines[stage][part*10:(part+1)*10]) or 'Chưa có kết quả.'
 report['summary']=f'INFO | {now} | vm={vm} | {outcome} | completed={len(completed)}/{len(planned)} | active={len(active)} | failed_or_interrupted={len(failures)}'
 try:
  import importlib.util
  spec=importlib.util.spec_from_file_location('memory_queue','/opt/orange/recovery/shared_memory.py');queue=importlib.util.module_from_spec(spec);spec.loader.exec_module(queue)
  snapshots=queue.load_snapshots()
  if snapshots:
   global_done=set(j for item in snapshots for j in item['completed'])
   report['global_completed']=len(global_done);report['global_total']=400
   report['summary']+=f' | global_unique_completed={len(global_done)}/400'
 except Exception as error:report['global_snapshot_error']=type(error).__name__

 # STEP6_OPT_BUDGET_V2_REPORT
 try:
  import importlib.util
  v2spec=importlib.util.spec_from_file_location('v2_memory','/opt/orange/recovery/shared_memory.py');v2m=importlib.util.module_from_spec(v2spec);v2spec.loader.exec_module(v2m)
  v2rows=[v2m.get_object('optimize-budget-v2/snapshots/'+vm+'.json')[0] for vm in v2m.VMS]
  v2done=sum(row.get('completed',0) for row in v2rows if row)
  report['step6_v2_completed']=v2done;report['step6_v2_total']=200
  report['summary']+=f' | Step6 new optimize-only cohort={v2done}/200 (old Step6 results retained separately)'
  report['interpretation']+=' Step6 optimize-only rerun is a separate 200-run cohort; old Step6 completion does not mean the new cohort is finished.'
 except Exception as error:report['step6_v2_monitor_error']=type(error).__name__

 dest=Path('/opt/orange/results/monitor');dest.mkdir(exist_ok=True,parents=True);(dest/'latest.json').write_text(json.dumps(report,ensure_ascii=False))
 key=read(Path('/etc/orange-monitor/writer.json'));b64=lambda x:base64.urlsafe_b64encode(x).rstrip(b'=')
 header=b64(json.dumps({'alg':'RS256','typ':'JWT'}).encode());iat=int(time.time())
 claims=b64(json.dumps({'iss':key['client_email'],'scope':'https://www.googleapis.com/auth/logging.write','aud':'https://oauth2.googleapis.com/token','iat':iat,'exp':iat+3600}).encode());message=header+b'.'+claims
 with tempfile.NamedTemporaryFile(mode='w') as f:
  f.write(key['private_key']);f.flush();signature=subprocess.check_output(['openssl','dgst','-sha256','-sign',f.name],input=message)
 token=json.load(urllib.request.urlopen(urllib.request.Request('https://oauth2.googleapis.com/token',data=urllib.parse.urlencode({'grant_type':'urn:ietf:params:oauth:grant-type:jwt-bearer','assertion':(message+b'.'+b64(signature)).decode()}).encode()),timeout=20))['access_token']
 payload={'logName':f'projects/{P}/logs/orange-batch-monitor','resource':{'type':'global','labels':{'project_id':P}},'entries':[{'jsonPayload':report,'severity':'INFO','timestamp':now}]}
 with urllib.request.urlopen(urllib.request.Request('https://logging.googleapis.com/v2/entries:write',headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},data=json.dumps(payload).encode()),timeout=20) as r:r.read()
 print(report['summary']);print('Cloud Logging delivery accepted')
if __name__=='__main__':main()
