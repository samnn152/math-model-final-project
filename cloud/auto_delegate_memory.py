"""Publish owner-side memory delegation after installing launch guards."""
import importlib.util
import json
import os
import re
import shutil
import time
from pathlib import Path

GUARD = '''# ORANGE_DELEGATED_MEMORY_GUARD: scheduling only; no model changes.
let marker = "/opt/orange/recovery/delegated-jobs.txt"
    retry_pool = "--output" in ARGS && occursin("/memory_retry_", ARGS[findfirst(==("--output"), ARGS) + 1])
    if !retry_pool && isfile(marker) && "--instances" in ARGS && "--run-start" in ARGS
        instance = ARGS[findfirst(==("--instances"), ARGS) + 1]
        run = ARGS[findfirst(==("--run-start"), ARGS) + 1]
        job = "step9_setA-" * lpad(instance, 2, '0') * "_run-" * lpad(run, 2, '0')
        if job in readlines(marker)
            println(stderr, "DELEGATED_MEMORY_RETRY: ", job, " reserved for shared 24-GiB pool; no solve started")
            exit(75)
        end
    end
end
'''

def atomic_write(path, text):
    tmp = path.with_name(path.name + '.auto-delegate-tmp')
    tmp.write_text(text)
    if path.exists():
        shutil.copymode(path, tmp)
        stat = path.stat()
        os.chown(tmp, stat.st_uid, stat.st_gid)
    else:
        tmp.chmod(0o644)
    tmp.replace(path)

def install_guard(path):
    text = path.read_text()
    if text.startswith('# ORANGE_DELEGATED_MEMORY_GUARD'):
        text, count = re.subn(r'\A# ORANGE_DELEGATED_MEMORY_GUARD.*?(?=# Run explicitly;)', '', text, count=1, flags=re.S)
        if count != 1:
            raise RuntimeError('Unrecognized launch guard: ' + str(path))
    updated = GUARD + text
    if path.read_text() != updated:
        backup = Path(str(path) + '.before-auto-delegation')
        if not backup.exists():
            shutil.copy2(path, backup)
        atomic_write(path, updated)

def cycle(memory, cfg):
    state = memory.snapshot(cfg)
    marker = Path('/opt/orange/recovery/delegated-jobs.txt')
    previous = set(marker.read_text().splitlines()) if marker.exists() else set()
    eligible = set(state['memory_failed']) - set(state['completed']) - set(state['active_jobs'])
    jobs = previous | eligible
    paths = [Path(cfg['source']) / 'scripts/run_time01_experiments.jl']
    # Existing private copies may be reused by an original owner's retry.
    for root in cfg['roots']:
        paths.extend(Path(root).glob('workers/step9_setA-*/scripts/run_time01_experiments.jl'))
    for path in paths:
        if path.exists():
            install_guard(path)
    content = '\n'.join(sorted(jobs)) + ('\n' if jobs else '')
    atomic_write(marker, content)
    atomic_write(Path('/etc/orange-memory/delegated-jobs.txt'), content)
    # Publish a fresh process inventory after guards and marker become visible.
    snapshot = memory.snapshot(cfg)
    snapshot['delegated_memory_jobs'] = sorted(jobs)
    memory.put_object('snapshots/' + snapshot['vm'] + '.json', snapshot)
    if jobs != previous:
        print(json.dumps({'newly_delegated': sorted(jobs - previous), 'delegated_total': len(jobs)}), flush=True)
    return len(jobs)

def main():
    spec = importlib.util.spec_from_file_location('memory', '/opt/orange/recovery/shared_memory.py')
    memory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(memory)
    cfg = memory.read(Path('/etc/orange-memory/config.json'))
    while True:
        try:
            count = cycle(memory, cfg)
            Path('/opt/orange/recovery/auto-delegation-status.json').write_text(json.dumps({'timestamp': time.time(), 'delegated_jobs': count}))
        except Exception as error:
            print('No new delegation published:', type(error).__name__, str(error), flush=True)
        time.sleep(30)

if __name__ == '__main__':
    main()
