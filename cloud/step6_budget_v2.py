"""Separate 200-run cohort; never overwrite the previous Step6 campaign."""
import concurrent.futures
import importlib.util
import inspect
import threading
import json
import os
import shutil
import time
from pathlib import Path

STAGE=int(os.environ.get('ORANGE_STAGE','6'))
ROOT=Path(os.environ.get('ORANGE_RESULT_ROOT','/opt/orange/results/step6_optimize_budget_v2_20261024'))
SOURCE=Path(os.environ.get('ORANGE_SOURCE','/opt/orange/source-optimize-budget-v2'))
CLAIMS='optimize-budget-v2/claims/' if STAGE==6 else 'optimize-budget-v2-step9/claims/'


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def execute(memory,worker,job,record,generation):
    try:
        dispatch=load_module('dispatch_'+job,SOURCE/'cloud/run_cloud_jobs.py')
        dispatch.subprocess=worker.OrangeSubprocess()
        instance=int(job.split('setA-')[1].split('_')[0]);run=int(job.rsplit('-',1)[1])
        options={'stop':threading.Event()} if 'stop' in inspect.signature(dispatch.execute_job).parameters else {'attempt':1}
        row=dispatch.execute_job(SOURCE,ROOT,(STAGE,instance,1800 if STAGE==6 else 3600,run),12,**options)
    except Exception as error:
        row=dict(job=job,completed=False,reason=type(error).__name__+': '+str(error))
    record.update(state='completed' if row.get('completed') else 'failed',finished_at=time.time(),
        reason=row.get('reason'),result_file=row.get('result_file'))
    for _ in range(5):
        try:
            if memory.put_object(CLAIMS+job+'.json',record,generation):
                break
        except Exception as error:
            print('Completion publish retry',job,str(error),flush=True)
        time.sleep(5)
    print(json.dumps(record),flush=True)
    return record


def main():
    memory=load_module('memory','/opt/orange/recovery/shared_memory.py')
    worker=load_module('worker','/opt/orange/recovery/adaptive_recovery.py')
    jobs=json.loads(Path(os.environ.get('ORANGE_JOB_LIST','/opt/orange/recovery/step6-budget-v2-jobs.json')).read_text())
    ROOT.mkdir(parents=True,exist_ok=True)
    attempted=set();futures={};done=set();vm=os.uname().nodename
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        while True:
            try:
                for future in list(futures):
                    if future.done():
                        record=future.result()
                        if record['state']=='completed':done.add(record['job'])
                        del futures[future]
                for job in jobs:
                    if len(futures)>=4:break
                    if job in attempted or job in done:continue
                    saved=worker.read(ROOT/job/'supervisor.json')
                    old,generation=memory.get_object(CLAIMS+job+'.json')
                    if saved.get('completed') or old and old.get('state')=='completed':
                        done.add(job);continue
                    interface_retry=bool(old and old.get("state")=="failed" and str(old.get("reason", "")).startswith("TypeError: execute_job() missing"))
                    if old and not interface_retry:continue
                    record=dict(job=job,vm=vm,state='running',seed=1000+int(job[-2:]),
                        optimize_limit_seconds=1800 if STAGE==6 else 3600,wall_policy='optimize_budget_only',claimed_at=time.time())
                    if old:record['previous_attempt']=old
                    claimed=memory.put_object(CLAIMS+job+'.json',record,generation if old else 0)
                    if claimed:
                        attempted.add(job)
                        futures[pool.submit(execute,memory,worker,job,record,claimed)]=record
                        print('BUDGET_V2_START',job,flush=True)
                state=dict(timestamp=time.time(),vm=vm,assigned=len(jobs),completed=len(done),
                    active=[x['job'] for x in futures.values()],failed=sorted(attempted-done-{x['job'] for x in futures.values()}),
                    wall_policy='optimize_budget_only',optimize_limit_seconds=1800 if STAGE==6 else 3600)
                worker.atomic_json(ROOT/'pool-status.json',state)
                memory.put_object(('optimize-budget-v2/' if STAGE==6 else 'optimize-budget-v2-step9/')+'snapshots/'+vm+'.json',state)
                time.sleep(15)
            except Exception as error:
                print('Admission deferred',type(error).__name__,str(error),flush=True)
                time.sleep(15)

if __name__=='__main__':main()
