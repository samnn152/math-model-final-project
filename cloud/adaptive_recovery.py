"""Bounded four-slot Step 9 scheduler; shared CAS claims and preserved old results."""
import concurrent.futures
import importlib.util
import inspect
import json
import math
import os
import pwd
import signal
import shutil
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path('/opt/orange/results/memory_retry_adaptive_20261023')
REVISION = 'stall_memory_v1'
SCHEDULER = 'parallel_v1' # retain CAS ownership semantics
RSS_BUDGET = 52
SLOTS = 4
DEFAULT_RSS = 12
STOP = threading.Event()


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.parallel-tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def global_sets(rows):
    done = {j for row in rows for j in row['completed']}
    active = {j for row in rows for j in row['active_jobs']}
    jobs = {j for row in rows for j in row['normal_assigned'] if j.startswith('step9_')}
    return done, active, jobs


def previous_required(record):
    if not record:
        return DEFAULT_RSS
    state = record.get('state')
    if state == 'completed':
        return None
    if state == 'queued':
        return record.get('next_rss_gib', DEFAULT_RSS)
    if state == 'failed':
        # New-revision terminal failures do not loop automatically.
        if record.get('scheduler') == SCHEDULER:
            return None
        if record.get('implementation_revision') == REVISION and record.get('rss_gib') == 48:
            return None
        return DEFAULT_RSS
    return None


def capacity(legacy_caps, own_caps, required=DEFAULT_RSS):
    if len(legacy_caps) + len(own_caps) >= SLOTS:
        return None
    free = RSS_BUDGET - sum(legacy_caps) - sum(own_caps)
    if required == 48:
        return 48 if not legacy_caps and not own_caps else None
    if required > DEFAULT_RSS:
        return required if free >= required else None
    return min(DEFAULT_RSS, free) if free >= 4 else None


def service_state(service):
    return subprocess.run(['systemctl', 'is-active', service], capture_output=True, text=True).stdout.strip()


def stop_idle_recovery(memory, cfg, service, prefix, status_file):
    """Freeze and recheck before stopping only an idle old dispatcher."""
    if service_state(service) not in ('active', 'activating', 'deactivating'):
        return True
    if any(p['output'].startswith(prefix + '/') for p in memory.processes()):
        return False
    value = subprocess.run(['systemctl', 'show', service, '-p', 'MainPID', '--value'], capture_output=True, text=True).stdout.strip()
    pid = int(value or 0)
    if not pid:
        return False
    try:
        os.kill(pid, signal.SIGSTOP)
        if any(p['output'].startswith(prefix + '/') for p in memory.processes()):
            os.kill(pid, signal.SIGCONT)
            return False
        state = read(Path(status_file))
        waiting = state.get('active_memory_jobs', []) or ([state['active_job']] if state.get('active_job') else [])
        for job in waiting:
            result_path = Path(prefix) / job / 'experiment' / (job.split('step9_')[1] + '.json')
            result = read(result_path)
            record, _ = memory.get_object('claims/' + job + '.json')
            if result.get('validated') and record and record.get('state') == 'running':
                # Let a finished child publish its success rather than losing it.
                os.kill(pid, signal.SIGCONT)
                return False
        os.kill(pid, signal.SIGKILL)
        subprocess.run(['systemctl', 'stop', service], check=True, timeout=35)
        return True
    except ProcessLookupError:
        return service_state(service) not in ('active', 'activating')
    except Exception:
        try:
            os.kill(pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        raise


def legacy_cap(process, cfg):
    try:
        status = Path('/proc') / str(process['pid']) / 'status'
        rss = next(int(x.split()[1]) / 1048576 for x in status.read_text().splitlines() if x.startswith('VmRSS:'))
        return max(4, math.ceil(rss * 1.5 + 2))
    except (OSError, StopIteration):
        return 12


def set_cap(service, gib):
    if service != 'orange-adaptive.service':
        return 0
    hard = max(37, gib)
    subprocess.run(['systemctl', 'set-property', '--runtime', service, 'MemoryMax=' + str(hard) + 'G', 'MemoryHigh=' + str(max(30, hard - 7)) + 'G'], check=True, capture_output=True)
    return hard


def can_adopt(record, rows, active):
    if not record or record.get('state') != 'running' or record.get('scheduler') == SCHEDULER:
        return False
    if record['job'] in active:
        return False
    owner = next((row for row in rows if row['vm'] == record.get('vm')), None)
    service = 'orange-memory48.service' if record.get('rss_gib') == 48 else 'orange-memory-retry.service'
    return bool(owner and service in owner.get('stopped_legacy_recovery', []))


def claim(memory, job, cap, previous, generation):
    value = dict(job=job, vm=os.uname().nodename, state='running', rss_gib=cap,
                 claimed_at=time.time(), implementation_revision=REVISION, scheduler=SCHEDULER)
    if previous:
        value['previous_attempt'] = previous
    new_generation = memory.put_object('claims/' + job + '.json', value, generation if previous else 0)
    return (value, new_generation) if new_generation else (None, None)


class OrangeSubprocess:
    """Use the existing supervisor, but launch Julia as its usual service user."""
    def __getattr__(self, name):
        return getattr(subprocess, name)

    def Popen(self, command, **kwargs):
        user = pwd.getpwnam('orange')
        private = Path(kwargs['cwd'])
        os.chown(private, user.pw_uid, user.pw_gid)
        if '--output' in command:
            parent = Path(command[command.index('--output') + 1]).parent
            os.chown(parent, user.pw_uid, user.pw_gid)
        return subprocess.Popen(command, user=user.pw_uid, group=user.pw_gid, **kwargs)


def mirror_success(cfg, job, row):
    directory = Path(cfg['output']) / job
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / 'supervisor.json'
    backup = directory / 'supervisor_before_parallel.json'
    if target.exists() and not backup.exists():
        shutil.copy2(target, backup)
    atomic_json(target, dict(row, supervisor_mirror=True, recovery_results_root=str(ROOT)))


def execute(memory, cfg, job, record, generation):
    source = Path(cfg['source'])
    try:
        spec = importlib.util.spec_from_file_location('dispatch_' + job, source / 'cloud/run_cloud_jobs.py')
        dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatch)
        dispatch.subprocess = OrangeSubprocess()
        directory = ROOT / job
        old = read(directory / 'supervisor.json')
        if directory.exists() and not old.get('completed'):
            archive = ROOT / 'recovery-history' / (job + '_' + str(time.time_ns()))
            archive.parent.mkdir(parents=True, exist_ok=True)
            directory.rename(archive)
        instance = int(job.split('setA-')[1].split('_')[0])
        run = int(job.rsplit('-', 1)[1])
        options = {'stop': threading.Event()} if 'stop' in inspect.signature(dispatch.execute_job).parameters else {'attempt': 1}
        row = dispatch.execute_job(source, ROOT, (9, instance, 3600, run), record['rss_gib'], **options)
    except Exception as error:
        row = dict(job=job, completed=False, reason=type(error).__name__ + ': ' + str(error))
    record.update(state='completed' if row.get('completed') else 'failed', finished_at=time.time(),
                  reason=row.get('reason'), termination=row.get('termination'), result_file=row.get('result_file'))
    if row.get('completed'):
        mirror_success(cfg, job, row)
    elif row.get('reason') in ('RSS_GUARD', 'LOW_SYSTEM_MEMORY'):
        if record['rss_gib'] < 48:
            record.update(state='queued', next_rss_gib=24 if record['rss_gib'] < 24 else 48)
    if not row.get('completed') and row.get('returncode') in (-15, -9):
        record.update(state='queued', next_rss_gib=24, reason='ADAPTIVE_HEADROOM_RETRY')
    for attempt in range(5):
        try:
            if memory.put_object('claims/' + job + '.json', record, generation):
                break
        except Exception as error:
            print('Completion upload:', type(error).__name__, str(error), flush=True)
        time.sleep(5)
    print(json.dumps(record), flush=True)
    return record


def main():
    spec = importlib.util.spec_from_file_location('memory', '/opt/orange/recovery/shared_memory.py')
    memory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(memory)
    cfg = read(Path('/etc/orange-memory/config.json'))
    cfg['roots'] = cfg['roots'] + [str(ROOT)]
    ROOT.mkdir(parents=True, exist_ok=True)
    futures = {}
    vm = os.uname().nodename
    with concurrent.futures.ThreadPoolExecutor(max_workers=SLOTS) as pool:
        while not STOP.is_set():
            try:
                for future in list(futures):
                    if future.done():
                        future.result()
                        del futures[future]
                stopped = []
                # Legacy services keep supervising their existing processes.
                stopped = [x for x in ('orange-memory-retry.service', 'orange-memory48.service') if service_state(x) not in ('active', 'activating')]
                local = memory.snapshot(cfg)
                local.update(stopped_legacy_recovery=stopped, parallel_revision=SCHEDULER,
                             parallel_claimed_jobs=[item['job'] for item in futures.values()])
                local['active_jobs'] = sorted(set(local['active_jobs']) | set(local['parallel_claimed_jobs']))
                memory.put_object('snapshots/' + vm + '.json', local)
                rows = memory.load_snapshots()
                if rows is None:
                    raise RuntimeError('Fresh global snapshots required')
                done, active, jobs = global_sets(rows)
                candidates = []
                for job in sorted(jobs - done - active):
                    previous, generation = memory.get_object('claims/' + job + '.json')
                    required = previous_required(previous)
                    if can_adopt(previous, rows, active):
                        required = DEFAULT_RSS
                    if required is not None:
                        # Normal dispatchers are disabled for delegated IDs only.
                        owners = [r for r in rows if job in r['normal_assigned']]
                        if not owners or any(r['normal_active'] and job not in r.get('delegated_memory_jobs', []) for r in owners):
                            continue
                        candidates.append((job, required, previous, generation))
                processes = memory.processes()
                legacy = [p for p in processes if not p['output'].startswith(str(ROOT) + '/')]
                caps = [legacy_cap(p, cfg) for p in legacy]
                own_caps = [item['rss_gib'] for item in futures.values()]
                # Keep a hard per-service cap under the host's 62.8-GiB RAM.
                for service, match in [(cfg['normal_service'], lambda p: '/memory_retry_' not in p['output']),
                                       ('orange-memory-retry.service', lambda p: p['output'].startswith(cfg['output'] + '/')),
                                       ('orange-memory48.service', lambda p: '/memory_retry_48_' in p['output'])]:
                    service_caps = [legacy_cap(p, cfg) for p in legacy if match(p)]
                    if service_caps:
                        hard = set_cap(service, sum(service_caps) + 1)
                        if hard > sum(service_caps) + 1:
                            # Account for retained page cache rather than killing a live job.
                            caps.append(hard - sum(service_caps) - 1)
                heavy_pending = any(required == 48 for _, required, _, _ in candidates)
                for job, required, previous, generation in candidates:
                    if heavy_pending and required != 48:
                        continue
                    cap = capacity(caps, own_caps, required)
                    if cap is None:
                        continue
                    fresh = memory.load_snapshots()
                    if fresh is None:
                        break
                    fresh_done, fresh_active, _ = global_sets(fresh)
                    if job in fresh_done or job in fresh_active:
                        continue
                    set_cap('orange-adaptive.service', sum(own_caps) + cap + 1)
                    record, new_generation = claim(memory, job, cap, previous, generation)
                    if record:
                        futures[pool.submit(execute, memory, cfg, job, record, new_generation)] = record
                        own_caps.append(cap)
                        print('Parallel claim', job, cap, 'GiB', flush=True)
                state = dict(timestamp=time.time(), target_workers=SLOTS, rss_budget_gib=RSS_BUDGET,
                             legacy_jobs=legacy, active_jobs=[{'job':r['job'],'rss_gib':r['rss_gib']} for r in futures.values()],
                             completed_global=len(done), remaining_global=400-len(done), eligible_pending=len(candidates),
                             stopped_legacy_recovery=stopped, heavy_pending=heavy_pending)
                atomic_json(ROOT / 'pool-status.json', state)
                if len(done) == 400 and not futures:
                    print('All 400 unique jobs completed.', flush=True)
                    break
            except Exception as error:
                print('No new admissions:', type(error).__name__, str(error), flush=True)
            STOP.wait(10)

if __name__ == '__main__':
    main()
