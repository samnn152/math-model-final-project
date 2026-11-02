"""One exclusive 48-GiB retry after an observed 24-GiB RSS-guard failure."""
import concurrent.futures
import importlib.util
import inspect
import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

HOLD = Path('/opt/orange/recovery/reserve48')
ROOT48 = Path('/opt/orange/results/memory_retry_48_20261023')
REVISION = 'stall_memory_v1'
LEGACY48_JOBS = set()

def eligible_claim(record):
    if not record or record.get('state') != 'failed':
        return False
    if record.get('rss_gib') == 24:
        return record.get('reason') == 'RSS_GUARD'
    return (record.get('rss_gib') == 48 and record.get('job') in LEGACY48_JOBS
            and record.get('reason') in ('RSS_GUARD', 'CODE_UPGRADE')
            and record.get('implementation_revision') != REVISION)

def pending(memory, rows):
    completed = {j for r in rows for j in r['completed']}
    active = {j for r in rows for j in r['active_jobs']}
    failed = {j for r in rows for j in r['memory_failed']}
    result = []
    for job in sorted(failed - completed - active):
        record, generation = memory.get_object('claims/' + job + '.json')
        if eligible_claim(record):
            result.append((job, record, generation))
    return result

def reserve(memory, job, previous, generation):
    record = dict(job=job, vm=os.uname().nodename, state='running', rss_gib=48,
                  claimed_at=time.time(), previous_attempt=previous, implementation_revision=REVISION)
    new_generation = memory.put_object('claims/' + job + '.json', record, generation)
    return (record, new_generation) if new_generation else (None, None)

def mirror_success(cfg, job, row):
    # Keep the original 24-GiB attempt files and archive its supervisor before
    # publishing the successful recovery pointer into the existing monitor root.
    directory = Path(cfg['output']) / job
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / 'supervisor.json'
    backup = directory / 'supervisor_before_48.json'
    if target.exists() and not backup.exists():
        shutil.copy2(target, backup)
    mirror = dict(row, recovered_at_rss_gib=48, recovery_results_root=str(ROOT48),
                  supervisor_mirror=True)
    temporary = directory / 'supervisor.json.recovery-tmp'
    temporary.write_text(json.dumps(mirror, indent=2))
    temporary.replace(target)

def execute(memory, cfg, job, record, generation):
    source = Path(cfg['source'])
    try:
        spec = importlib.util.spec_from_file_location('dispatch48_' + job, source / 'cloud/run_cloud_jobs.py')
        dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatch)
        directory = ROOT48 / job
        previous_supervisor = memory.read(directory / 'supervisor.json')
        if directory.exists() and not previous_supervisor.get('completed'):
            archive = ROOT48 / 'recovery-history' / (job + '_' + str(time.time_ns()))
            archive.parent.mkdir(parents=True, exist_ok=True)
            directory.rename(archive)
        instance = int(job.split('setA-')[1].split('_')[0])
        run = int(job.rsplit('-', 1)[1])
        kwargs = {'stop': threading.Event()} if 'stop' in inspect.signature(dispatch.execute_job).parameters else {'attempt': 1}
        row = dispatch.execute_job(source, ROOT48, (9, instance, 3600, run), 48, **kwargs)
    except Exception as error:
        row = dict(job=job, completed=False, reason=type(error).__name__ + ': ' + str(error))
    record.update(state='completed' if row.get('completed') else 'failed',
                  finished_at=time.time(), reason=row.get('reason'),
                  termination=row.get('termination'), result_file=row.get('result_file'))
    if row.get('completed'):
        mirror_success(cfg, job, row)
    for attempt in range(5):
        try:
            if memory.put_object('claims/' + job + '.json', record, generation):
                break
        except Exception as error:
            print('48-GiB completion upload:', type(error).__name__, str(error), flush=True)
        time.sleep(10)
    print(json.dumps(record), flush=True)
    return record

def main():
    global LEGACY48_JOBS
    legacy_path = Path('/opt/orange/recovery/legacy48_revision_retry.json')
    LEGACY48_JOBS = set(json.loads(legacy_path.read_text())) if legacy_path.exists() else set()
    spec = importlib.util.spec_from_file_location('memory', '/opt/orange/recovery/shared_memory.py')
    memory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(memory)
    cfg = memory.read(Path('/etc/orange-memory/config.json'))
    ROOT48.mkdir(parents=True, exist_ok=True)
    future = None
    job_running = None
    held_since = None
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        while True:
            try:
                if future is not None and future.done():
                    future.result()
                    future = None
                    job_running = None
                rows = memory.load_snapshots()
                if rows is None:
                    # A hold remains in place on coordination errors; never
                    # launch a high-memory job using stale global state.
                    raise RuntimeError('Global snapshots unavailable or stale')
                candidates = pending(memory, rows)
                if candidates or future is not None:
                    if not HOLD.exists():
                        HOLD.write_text('48-GiB queue pending; drain current 24-GiB jobs\n')
                    if held_since is None:
                        held_since = time.monotonic()
                else:
                    HOLD.unlink(missing_ok=True)
                    held_since = None
                normal_state = subprocess.run(['systemctl', 'is-active', cfg['normal_service']], capture_output=True, text=True).stdout.strip()
                ready = (future is None and candidates and normal_state not in ('active', 'activating', 'deactivating')
                         and not memory.processes() and held_since is not None
                         and time.monotonic() - held_since >= 10)
                if ready:
                    for job, previous, generation in candidates:
                        # Recheck the global inventory immediately before CAS.
                        fresh = memory.load_snapshots()
                        if fresh is None:
                            break
                        if any(job in r['completed'] or job in r['active_jobs'] for r in fresh):
                            continue
                        record, new_generation = reserve(memory, job, previous, generation)
                        if record:
                            future = pool.submit(execute, memory, cfg, job, record, new_generation)
                            job_running = job
                            print('exclusive 48-GiB claim:', job, flush=True)
                            break
                state = dict(timestamp=time.time(), workers=1, rss_gib_per_job=48,
                             active_job=job_running, queued_48=len(candidates),
                             hold_24=HOLD.exists(), phase='running_48' if future else 'draining_for_48' if HOLD.exists() else 'standby')
                (ROOT48 / 'pool-status.json').write_text(json.dumps(state))
            except Exception as error:
                print('48-GiB coordination unavailable:', type(error).__name__, str(error), flush=True)
            time.sleep(30)

if __name__ == '__main__':
    main()
