"""Run one HiGHS instance in an isolated process with deadline and memory safeguards."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from measure_job_memory import process_memory, system_memory


def supervise(command, directory, solve_seconds, grace=10.0, setup_timeout=120.0, max_rss_gib=12.0):
    directory.mkdir(parents=True,exist_ok=False)
    started=time.monotonic();phase_deadline=started+setup_timeout
    hard_deadline=started+setup_timeout+solve_seconds+max(30.0,0.1*solve_seconds)+grace
    seen=None;reason=None;peak=0;red_count=0
    with (directory/'console.log').open('w') as stdout, (directory/'stderr.log').open('w') as stderr:
        child=subprocess.Popen(command,stdout=stdout,stderr=stderr,start_new_session=True)
        while child.poll() is None:
            now=time.monotonic()
            events=list((directory/'experiment').glob('*.event.json'))
            if events:
                latest=max(events,key=lambda path:path.stat().st_mtime_ns)
                event=json.loads(latest.read_text())
                if event['token'] != seen:
                    seen=event['token']
                    phase_deadline=now+(max(0,float(event['remaining_seconds']))+grace if event['event']=='start' else setup_timeout)
            memory=process_memory(child.pid);peak=max(peak,memory['process_tree_rss_bytes'])
            pressure=system_memory()['pressure_level']
            red_count=red_count+1 if pressure>=4 else 0
            if peak>max_rss_gib*1024**3: reason='EXTERNAL_MEMORY_LIMIT'
            elif red_count>=2: reason='EXTERNAL_MEMORY_PRESSURE'
            elif now>=min(phase_deadline,hard_deadline): reason='EXTERNAL_TIMEOUT'
            if reason:
                os.killpg(child.pid,signal.SIGINT)
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL);child.wait()
                break
            time.sleep(1)
        code=child.wait()
    checkpoints=list((directory/'experiment').glob('*_run-01.json'))
    solutions=list((directory/'experiment').glob('*_solution.json'))
    if checkpoints:
        result=json.loads(checkpoints[0].read_text())
    elif solutions:
        result=json.loads(solutions[0].read_text())
        result.update(objective=result.get('mlu'),status='Not Optimal',cpu_time_seconds=None)
    else:
        result=dict(status='Not Optimal',validated=False,objective=None,gap=None,
            mlu_target_met=False,quality_status='NO_FEASIBLE_SOLUTION',cpu_time_seconds=None)
    if reason:
        result.update(status='Not Optimal',termination=reason)
    elif code!=0:
        result.update(status='Not Optimal',termination='WORKER_ERROR')
    result['supervisor']=dict(returncode=code,stop_reason=reason,wall_seconds=time.monotonic()-started,
        peak_sampled_rss_bytes=peak,command=command,
        note='An external stop preserves only a previously validated checkpoint and its saved global bounds. No missing optimality proof is inferred.')
    (directory/'guarded_result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({key:result.get(key) for key in ['status','termination','objective','gap','quality_status']},indent=2))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance',type=int,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--time-limit',type=float,default=1800)
    parser.add_argument('--target-gap',type=float,default=.10)
    parser.add_argument('--formulation',choices=['auto','compact','routes'],default='auto')
    parser.add_argument('--profile',choices=['auto','default','incumbent','devex','lean'],default='auto')
    parser.add_argument('--grace',type=float,default=10)
    parser.add_argument('--setup-timeout',type=float,default=120)
    parser.add_argument('--max-rss-gib',type=float,default=12)
    args=parser.parse_args()
    if not 1<=args.instance<=20 or args.time_limit<=0 or not 0<=args.target_gap<1:
        parser.error('Invalid instance, time limit or gap')
    root=Path(__file__).resolve().parent.parent
    directory=args.output.resolve()
    command=['julia','--project='+str(root),str(root/'scripts/run_experiments.jl'),
        '--instances',str(args.instance),'--runs','1','--time-limit',str(args.time_limit),
        '--solver','highs','--threads','1','--splitting','ecmp','--target-gap',str(args.target_gap),
        '--formulation',args.formulation,'--highs-profile',args.profile,
        '--output',str(directory/'experiment')]
    supervise(command,directory,args.time_limit,args.grace,args.setup_timeout,args.max_rss_gib)
