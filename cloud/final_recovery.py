"""Retry only the explicitly audited, incomplete tail of the Orange campaign."""
import concurrent.futures
import importlib.util
import json
import os
import time
from pathlib import Path


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    memory = module('memory', '/opt/orange/recovery/shared_memory.py')
    worker = module('adaptive', '/opt/orange/recovery/adaptive_recovery.py')
    cfg = json.loads(Path('/etc/orange-memory/config.json').read_text())
    cfg['roots'] = list(set(cfg['roots'] + [cfg['output'],
        '/opt/orange/results/memory_retry_parallel_20261023', str(worker.ROOT)]))
    assigned = json.loads(Path('/opt/orange/recovery/final-recovery-jobs.json').read_text())
    pending = set(assigned)
    futures = {}
    attempted = set()
    vm = os.uname().nodename
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        while True:
            try:
                for future in list(futures):
                    if future.done():
                        future.result()
                        del futures[future]
                local = memory.snapshot(cfg)
                local['active_jobs'] = sorted(set(local['active_jobs']) | {x['job'] for x in futures.values()})
                local['final_recovery_revision'] = 'wall_guard_v2'
                memory.put_object('snapshots/' + vm + '.json', local)
                rows = memory.load_snapshots()
                if rows:
                    done, active, jobs = worker.global_sets(rows)
                    pending -= done
                    for job in sorted(pending - active - attempted):
                        if len(futures) >= 3:
                            break
                        old, generation = memory.get_object('claims/' + job + '.json')
                        if old and old.get('state') == 'completed':
                            pending.discard(job)
                            continue
                        # An old running claim must be explicitly reconciled;
                        # freshness alone is never permission to steal a job.
                        if old and old.get('state') == 'running':
                            continue
                        if job in {j for row in memory.load_snapshots() or [] for j in row['completed'] + row['active_jobs']}:
                            continue
                        record, generation = worker.claim(memory, job, 12, old, generation)
                        if record:
                            record['execution_revision'] = 'wall_guard_v2'
                            attempted.add(job)
                            futures[pool.submit(worker.execute, memory, cfg, job, record, generation)] = record
                            print('FINAL_RECOVERY_START', job, flush=True)
                    state = dict(timestamp=time.time(), assigned=assigned, pending=sorted(pending-done),
                        active=[x['job'] for x in futures.values()], completed_global=len(done),
                        attempted=sorted(attempted), optimize_limit_seconds=3600, external_wall_seconds=21600)
                    worker.atomic_json(Path('/opt/orange/recovery/final-recovery-status.json'), state)
                time.sleep(10)
            except Exception as error:
                print('Admission deferred:', type(error).__name__, str(error), flush=True)
                time.sleep(10)

if __name__ == '__main__':
    main()
