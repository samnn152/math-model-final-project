"""Cross-dispatcher admission gate and pressure guard for supplementary workers."""
import fcntl
import json
import os
import signal
import time
from pathlib import Path

EXTRA = '/opt/orange/results/memory_retry_adaptive_20261023'


def processes():
    out = []
    for p in Path('/proc').glob('[0-9]*'):
        try:
            args = (p / 'cmdline').read_bytes().decode().split('\0')
            if Path(args[0]).name != 'julia' or '--output' not in args:
                continue
            output = args[args.index('--output') + 1]
            status = (p / 'status').read_text().splitlines()
            rss = next(int(x.split()[1]) * 1024 for x in status if x.startswith('VmRSS:'))
            out.append(dict(pid=int(p.name), output=output, rss=rss))
        except (OSError, ValueError, IndexError, StopIteration):
            pass
    return out


def available():
    return next(int(x.split()[1]) * 1024 for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:'))


def guarded_popen(popen, *args, **kwargs):
    # Serialize the process creation itself, across both dispatcher generations.
    with open('/opt/orange/recovery/admission.lock', 'a') as lock:
        while True:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if len(processes()) < 4 and available() >= 16 * 2**30:
                child = popen(*args, **kwargs)
                # /proc exec visibility must settle before the next admission.
                for _ in range(100):
                    if any(x['pid'] == child.pid for x in processes()) or child.poll() is not None:
                        break
                    time.sleep(.05)
                fcntl.flock(lock, fcntl.LOCK_UN)
                return child
            fcntl.flock(lock, fcntl.LOCK_UN)
            time.sleep(2)


def main():
    paused = set()
    while True:
        current = processes()
        extras = [x for x in current if x['output'].startswith(EXTRA + '/')]
        live = {x['pid'] for x in extras}
        paused &= live
        free = available()
        action = 'healthy'
        if free < 12 * 2**30:
            for x in extras:
                if x['pid'] not in paused:
                    try:
                        os.killpg(x['pid'], signal.SIGSTOP)
                        paused.add(x['pid'])
                    except ProcessLookupError:
                        pass
            action = 'supplementary_paused'
        elif free > 18 * 2**30:
            for pid in list(paused):
                try:
                    os.killpg(pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
                paused.discard(pid)
        # Pausing does not release RSS. Sacrifice only a newly added attempt if
        # growth in protected jobs threatens their old 3-GiB supervisor guard.
        if free < 8 * 2**30 and extras:
            victim = max(extras, key=lambda x: x['rss'])
            try:
                os.killpg(victim['pid'], signal.SIGCONT)
                os.killpg(victim['pid'], signal.SIGTERM)
                paused.discard(victim['pid'])
                action = 'supplementary_evicted_for_headroom'
                print(json.dumps(dict(event=action, **victim)), flush=True)
            except ProcessLookupError:
                pass
        Path('/opt/orange/recovery/adaptive-pressure.json').write_text(json.dumps(dict(timestamp=time.time(), available_gib=free/2**30, workers=len(current), paused=sorted(paused), action=action)))
        time.sleep(.5)

if __name__ == '__main__':
    main()
