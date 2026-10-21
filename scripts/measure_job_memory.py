"""Run one bounded experiment and sample its RSS plus macOS memory pressure."""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def output(command):
    return subprocess.check_output(command, universal_newlines=True).strip()


def system_memory():
    swap = output(['sysctl', '-n', 'vm.swapusage'])
    match = re.search(r'used\s*=\s*([0-9.]+)([MG])', swap)
    used = float(match.group(1)) * (1024 ** (2 if match.group(2) == 'M' else 3))
    pressure = int(output(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level']))
    vm = output(['vm_stat'])
    page_size = int(re.search(r'page size of (\d+) bytes', vm).group(1))
    values = dict((name.strip(), int(value)) for name, value in re.findall(r'^([^:\n]+):\s+(\d+)\.', vm, re.MULTILINE))
    return dict(swap_used_bytes=used,pressure_level=pressure,
        free_bytes=page_size*values.get('Pages free',0),
        inactive_bytes=page_size*values.get('Pages inactive',0),
        speculative_bytes=page_size*values.get('Pages speculative',0),
        compressor_physical_bytes=page_size*values.get('Pages occupied by compressor',0),
        pageouts=values.get('Pageouts',0),swapouts=values.get('Swapouts',0))


def process_memory(parent):
    processes = {}
    for line in output(['ps','-axo','pid=,ppid=,rss=,%cpu=']).splitlines():
        parts = line.split()
        if len(parts)==4:
            pid, ppid, rss = map(int,parts[:3])
            processes[pid]=(ppid,rss*1024,float(parts[3]))
    included = set([parent])
    changed = True
    while changed:
        changed = False
        for pid, (ppid,rss,cpu) in processes.items():
            if ppid in included and pid not in included:
                included.add(pid);changed=True
    members = [processes[pid] for pid in included if pid in processes]
    return dict(process_tree_rss_bytes=sum(row[1] for row in members),
        largest_process_rss_bytes=max([row[1] for row in members] or [0]),
        process_tree_cpu_percent=sum(row[2] for row in members),process_count=len(members))


def measure(root, directory, instance, solver, solve_seconds):
    directory.mkdir(parents=True,exist_ok=False)
    baseline=system_memory()
    command=['/usr/bin/time','-l','julia','--project=.', 'scripts/run_experiments.jl',
        '--instances',str(instance),'--runs','1','--time-limit',str(solve_seconds),
        '--solver',solver,'--threads','1','--output',str(directory/'experiment')]
    config=dict(command=command,instance=instance,solver=solver,solve_seconds=solve_seconds,
        physical_memory_bytes=int(output(['sysctl','-n','hw.memsize'])),
        baseline=baseline,sample_interval_seconds=3,
        safeguard_rss_bytes=16*1024**3,hard_process_wall_seconds=solve_seconds+120,
        note='One process tree; no concurrent pilot jobs. RSS samples include native solver allocations. No solver parameter changes beyond existing CLI settings.')
    (directory/'monitor_config.json').write_text(json.dumps(config,indent=2))
    rows=[];reason=None;red_samples=0
    started=time.monotonic()
    with (directory/'console.log').open('w') as console, (directory/'time_and_stderr.log').open('w') as stderr:
        child=subprocess.Popen(command,cwd=str(root),stdout=console,stderr=stderr,start_new_session=True)
        with (directory/'memory_samples.csv').open('w',newline='') as stream:
            writer=None
            while child.poll() is None:
                row=dict(elapsed_wall_seconds=time.monotonic()-started,**process_memory(child.pid),**system_memory())
                rows.append(row)
                if writer is None:
                    writer=csv.DictWriter(stream,fieldnames=list(row));writer.writeheader()
                writer.writerow(row);stream.flush()
                red_samples=red_samples+1 if row['pressure_level']>=4 else 0
                if row['process_tree_rss_bytes']>=config['safeguard_rss_bytes']:
                    reason='process_tree_RSS_reached_16_GiB'
                elif red_samples>=2:
                    reason='sustained_critical_system_memory_pressure'
                elif row['elapsed_wall_seconds']>=config['hard_process_wall_seconds']:
                    reason='external_wall_timeout'
                if reason:
                    os.killpg(child.pid,signal.SIGINT)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid,signal.SIGKILL);child.wait()
                    break
                time.sleep(3)
        code=child.wait()
    end=system_memory()
    stderr_text=(directory/'time_and_stderr.log').read_text()
    native_peak=re.search(r'^\s*(\d+)\s+maximum resident set size',stderr_text,re.MULTILINE)
    footprint_peak=re.search(r'^\s*(\d+)\s+peak memory footprint',stderr_text,re.MULTILINE)
    result=dict(returncode=code,stopped_by_monitor=reason,total_wall_seconds=time.monotonic()-started,
        sampled_peak_tree_rss_bytes=max(row['process_tree_rss_bytes'] for row in rows),
        sampled_peak_single_process_rss_bytes=max(row['largest_process_rss_bytes'] for row in rows),
        time_maximum_resident_set_bytes=int(native_peak.group(1)) if native_peak else None,
        time_peak_memory_footprint_bytes=int(footprint_peak.group(1)) if footprint_peak else None,
        baseline=baseline,end=end,
        max_swap_increase_bytes=max(row['swap_used_bytes'] for row in rows)-baseline['swap_used_bytes'],
        maximum_pressure_level=max(row['pressure_level'] for row in rows),samples=len(rows))
    (directory/'memory_summary.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2),flush=True)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_directory',type=Path)
    parser.add_argument('--instance',type=int,default=4)
    parser.add_argument('--solver',choices=['scip','highs'],default='scip')
    parser.add_argument('--time-limit',type=float,default=300)
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    measure(root,args.output_directory.resolve(),args.instance,args.solver,args.time_limit)
