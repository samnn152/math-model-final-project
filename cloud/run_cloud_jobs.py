"""One-pass SetA dispatcher. Planning is the default; --run is Linux-only."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Event


def write_json(path, value):
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value,indent=2))
    temporary.replace(path)


def tasks(mode):
    if mode=='pilot':
        return [(9,20,60)]
    return [(stage,instance,1800 if stage==6 else 3600)
            for stage in (9,6) for instance in range(20,0,-1)]


def job_command(source, output, stage, instance, limit):
    common=['--instances',str(instance),'--runs','1','--time-limit',str(limit),
            '--solver','highs','--threads','1','--seed-base','1000','--output',str(output)]
    if stage==6:
        extra=['--splitting','ecmp','--formulation','routes','--highs-profile','default',
               '--target-gap','0.10','--deadline-callback','true','--max-routes','16',
               '--pricing-rounds','40','--pricing-time','30','--warm-start-seconds','3',
               '--proof-tolerance','1e-7','--lock-tolerance','1e-7',
               '--max-binary-variables','2000000']
        runner='run_experiments.jl'
    else:
        extra=['--formulation','paired','--pricing-slice','2','--max-columns','100000',
               '--max-variables','2200000','--max-pricing-variables','2200000']
        runner='run_time01_experiments.jl'
    return ['julia','--project=.',str(source/'scripts'/runner)]+common+extra


def linux_memory(root_pid):
    processes={}
    for directory in Path('/proc').glob('[0-9]*'):
        try:
            stat=(directory/'stat').read_text().rsplit(')',1)[1].split()
            fields={line.split(':',1)[0]:line.split(':',1)[1].strip()
                    for line in (directory/'status').read_text().splitlines() if ':' in line}
            processes[int(directory.name)]=(int(stat[1]),
                int(fields.get('VmRSS','0 kB').split()[0])*1024,
                int(fields.get('VmHWM','0 kB').split()[0])*1024)
        except (OSError,ValueError,IndexError):
            continue
    included={root_pid}
    while True:
        expanded=included|{pid for pid,(parent,_,_) in processes.items() if parent in included}
        if expanded==included:break
        included=expanded
    members=[processes[pid] for pid in included if pid in processes]
    available=next(int(line.split()[1])*1024 for line in Path('/proc/meminfo').read_text().splitlines()
                   if line.startswith('MemAvailable:'))
    return dict(tree_rss_bytes=sum(x[1] for x in members),
                process_peak_rss_bytes=max((x[2] for x in members),default=0),
                available_bytes=available)


def terminate_group(child):
    try:os.killpg(child.pid,signal.SIGINT)
    except ProcessLookupError:return
    try:child.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        child.wait()


def execute_job(source, root, job, rss_gib, stop):
    stage,instance,limit=job
    name=f'step{stage}_setA-{instance:02d}'
    directory=root/name;directory.mkdir(parents=True,exist_ok=True)
    metadata=directory/'supervisor.json'
    if metadata.exists() and json.loads(metadata.read_text()).get('completed'):
        return json.loads(metadata.read_text())
    if stop.is_set():return dict(job=name,completed=False,reason='queue_stopped')
    private=root/'workers'/name
    if not private.exists():
        shutil.copytree(source,private,ignore=shutil.ignore_patterns('results','output','.git','__pycache__'))
    output=directory/'experiment';command=job_command(private,output,stage,instance,limit)
    env=os.environ.copy()
    env.update({key:'1' for key in ['JULIA_NUM_THREADS','OPENBLAS_NUM_THREADS','OMP_NUM_THREADS',
                                   'MKL_NUM_THREADS','VECLIB_MAXIMUM_THREADS']})
    started=time.monotonic();peak=0;hwm=0;reason=None
    with (directory/'console.log').open('a') as log,(directory/'memory.jsonl').open('a') as samples:
        child=subprocess.Popen(command,cwd=private,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        while child.poll() is None:
            measurement=linux_memory(child.pid);elapsed=time.monotonic()-started
            peak=max(peak,measurement['tree_rss_bytes']);hwm=max(hwm,measurement['process_peak_rss_bytes'])
            samples.write(json.dumps(dict(elapsed_seconds=elapsed,**measurement))+'\n');samples.flush()
            if stop.is_set():reason='another_job_failed'
            elif measurement['tree_rss_bytes']>rss_gib*1024**3:reason='RSS_GUARD'
            elif measurement['available_bytes']<3*1024**3:reason='LOW_SYSTEM_MEMORY'
            elif elapsed>limit*1.25+300:reason='EXTERNAL_WALL_LIMIT'
            if reason:
                terminate_group(child);break
            time.sleep(2)
        code=child.wait()
    row_file=output/f'setA-{instance:02d}_run-01.json'
    row=json.loads(row_file.read_text()) if row_file.exists() else {}
    completed=code==0 and reason is None and row.get('validated') is True and not row.get('error')
    completed=completed and row.get('termination') not in ['ERROR','MODEL_SIZE_LIMIT']
    summary=dict(job=name,stage=stage,instance=instance,limit_seconds=limit,completed=completed,
                 returncode=code,reason=reason,termination=row.get('termination'),
                 wall_seconds=time.monotonic()-started,sampled_tree_peak_rss_bytes=peak,
                 observed_process_hwm_bytes=hwm,command=command,result_file=str(row_file))
    write_json(metadata,summary)
    print(json.dumps(summary),flush=True)
    if not completed:stop.set()
    return summary


def collect_results(root):
    for stage in (6,9):
        rows=[]
        for path in sorted(root.glob(f'step{stage}_setA-*/experiment/setA-*_run-01.json')):
            rows.append(json.loads(path.read_text()))
        if rows:
            fields=list(dict.fromkeys(key for row in rows for key in row))
            with (root/f'step{stage}_runs.csv').open('w',newline='') as stream:
                writer=csv.DictWriter(stream,fieldnames=fields);writer.writeheader();writer.writerows(rows)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output',type=Path,default=Path('/opt/orange/results/one_pass'))
    parser.add_argument('--mode',choices=['pilot','batch'],default='pilot')
    parser.add_argument('--workers',type=int,choices=[1,2],default=1)
    parser.add_argument('--rss-gib',type=float,default=48)
    parser.add_argument('--run',action='store_true')
    args=parser.parse_args();jobs=tasks(args.mode)
    if args.workers*args.rss_gib>50:parser.error('Aggregate job RSS allowance must not exceed 50 GiB')
    plan=dict(mode=args.mode,jobs=len(jobs),workers=args.workers,rss_gib=args.rss_gib,
              optimize_allowance_hours=sum(job[2] for job in jobs)/3600,execute=args.run)
    print(json.dumps(plan,indent=2),flush=True)
    if not args.run:return
    if platform.system()!='Linux':parser.error('--run is Linux-only; no solver starts on the Mac')
    source=args.source.resolve();root=args.output.resolve();root.mkdir(parents=True,exist_ok=True)
    fingerprints={str(path.relative_to(source)):hashlib.sha256(path.read_bytes()).hexdigest()
                  for name in ['Project_Orange.jl','Project.toml','Manifest.toml','scripts','cloud']
                  for path in ([source/name] if (source/name).is_file() else sorted((source/name).rglob('*')))
                  if path.is_file() and '__pycache__' not in path.parts}
    config=dict(plan=plan,source_sha256=fingerprints)
    config_file=root/'cloud-config.json'
    if config_file.exists() and json.loads(config_file.read_text())!=config:
        parser.error('Source/config changed; use a new output directory')
    write_json(config_file,config);stop=Event();observations=[]
    try:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures=[pool.submit(execute_job,source,root,job,args.rss_gib,stop) for job in jobs]
            for future in as_completed(futures):
                observations.append(future.result());collect_results(root)
                write_json(root/'queue-status.json',observations)
    finally:
        stop.set();collect_results(root)
    if any(not row['completed'] for row in observations):raise SystemExit(1)


if __name__=='__main__':main()
