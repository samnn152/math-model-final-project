"""One original SetA instance, full optimize-call budgets, sequential local runs."""
import datetime
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO=Path(__file__).resolve().parents[1]
ROOT=REPO/'results/local_setA05_real_budget_20261024'
JULIA=Path.home()/'.juliaup/bin/julia'


def atomic(path,value):
    temp=path.with_suffix('.tmp')
    temp.write_text(json.dumps(value,indent=2))
    temp.replace(path)


def tree_rss(pid):
    result=subprocess.run(['ps','-axo','pid=,ppid=,rss='],capture_output=True,text=True)
    rows={}
    for line in result.stdout.splitlines():
        fields=line.split()
        if len(fields)==3:rows[int(fields[0])]=(int(fields[1]),int(fields[2])*1024)
    included={pid}
    while True:
        more=included|{p for p,(parent,_) in rows.items() if parent in included}
        if more==included:break
        included=more
    return sum(rows[p][1] for p in included if p in rows)


def stage_command(stage,output):
    runner='run_experiments.jl' if stage==6 else 'run_time01_experiments.jl'
    command=[str(JULIA),'--project=.',str(REPO/'scripts'/runner),'--instances','5','--runs','1',
        '--run-start','1','--time-limit',str(1800 if stage==6 else 3600),'--solver','highs',
        '--threads','1','--seed-base','1000','--output',str(output)]
    command+=['--formulation','routes','--highs-profile','default'] if stage==6 else [
        '--formulation','paired','--pair-pricing','dynamic','--pricing-slice','2',
        '--max-columns','100000','--max-variables','2200000','--max-pricing-variables','2200000']
    return command


def run_stage(stage):
    folder=ROOT/f'step{stage}';folder.mkdir(parents=True,exist_ok=True)
    output=folder/'experiment';metadata=folder/'supervisor.json'
    if metadata.exists():
        saved=json.loads(metadata.read_text())
        if saved.get('completed'):return saved
        raise RuntimeError('Existing unfinished pilot metadata; review before retry')
    command=stage_command(stage,output)
    env=dict(os.environ,JULIA_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',OMP_NUM_THREADS='1',
        MKL_NUM_THREADS='1',VECLIB_MAXIMUM_THREADS='1')
    start=time.monotonic();peak=0;reason=None
    with (folder/'console.log').open('w') as log,(folder/'memory.jsonl').open('w') as memory:
        child=subprocess.Popen(['/usr/bin/time','-l']+command,cwd=REPO,env=env,
            stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        while child.poll() is None:
            rss=tree_rss(child.pid);peak=max(peak,rss)
            sample=dict(elapsed_seconds=time.monotonic()-start,rss_bytes=rss)
            memory.write(json.dumps(sample)+'\n');memory.flush()
            atomic(ROOT/'status.json',dict(state='running',stage=stage,instance='setA-05',
                process_id=child.pid,**sample,peak_rss_bytes=peak,
                optimize_limit_seconds=1800 if stage==6 else 3600,wall_time_policy='optimize_budget_only'))
            if rss>8*2**30:
                reason='LOCAL_RSS_GUARD'
                os.killpg(child.pid,signal.SIGINT)
                try:child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL);child.wait()
                break
            time.sleep(2)
    result_file=output/'setA-05_run-01.json'
    result=json.loads(result_file.read_text()) if result_file.exists() else {}
    budget=1800 if stage==6 else 3600
    valid=result.get('validated') is True and not result.get('error')
    full=result.get('status')=='Optimal' and result.get('lex_completed_stages')==result.get('lex_total_stages')
    spent=result.get('cpu_time_seconds',0)>=.99*budget
    row=dict(stage=stage,command=command,returncode=child.returncode,reason=reason,
        completed=child.returncode==0 and valid and reason is None,wall_seconds=time.monotonic()-start,
        sampled_peak_rss_bytes=peak,result_file=str(result_file),validated=valid,
        full_lex_optimal=full,budget_used_or_optimal=spent or full,result=result)
    atomic(metadata,row)
    return row


def main():
    ROOT.mkdir(parents=True,exist_ok=True)
    lock=ROOT/'supervisor.lock'
    import fcntl
    with lock.open('w') as file:
        fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB)
        notebook=REPO/'Project_Orange.jl'
        atomic(ROOT/'manifest.json',dict(instance='setA-05',seed=1001,
            notebook_sha256=hashlib.sha256(notebook.read_bytes()).hexdigest(),
            started_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            stage_budgets={'6':1800,'9':3600},wall_time_policy='optimize_budget_only',
            cloud_release_requires='both validated, full lexicographic Optimal; not MLU gap alone'))
        keep_awake=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())])
        try:
            rows=[]
            for stage in (6,9):
                row=run_stage(stage);rows.append(row)
                if row.get('reason')=='LOCAL_RSS_GUARD':break
            passed=len(rows)==2 and all(x['completed'] and x['full_lex_optimal'] for x in rows)
            state=dict(state='passed' if passed else 'needs_review',stages=rows,
                cloud_release_allowed=passed,completed_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
            atomic(ROOT/'summary.json',state);atomic(ROOT/'status.json',state)
            if passed:
                action=REPO/'scripts/release_verified_budget_campaign.py'
                if not action.exists():raise RuntimeError('Verified pilot needs the cloud release script')
                subprocess.run([sys.executable,str(action),'--verified-pilot',str(ROOT/'summary.json')],check=True)
        finally:
            keep_awake.terminate()

if __name__=='__main__':main()
