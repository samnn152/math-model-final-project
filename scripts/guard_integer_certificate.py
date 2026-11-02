"""Sample a local pilot and enforce its configured emergency RSS guard."""
import json
import os
import signal
import subprocess
import time
from pathlib import Path
root=Path(os.environ.get('ORANGE_CERTIFICATE_OUTPUT',str(Path(__file__).resolve().parents[1]/'results/local_setA05_integer_certificate_20261024_attempt02')))
pid=json.loads((root/'process.json').read_text())['pid']
awake=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(pid)])
peak=0
guard_gib=float(os.environ.get('ORANGE_CERTIFICATE_GUARD_GIB','6'))
process_match=os.environ.get('ORANGE_CERTIFICATE_PROCESS_MATCH','test_seta05_integer_certificate.jl')
try:
    while True:
        command=subprocess.run(['ps','-p',str(pid),'-o','rss=,stat=,command='],capture_output=True,text=True).stdout.strip()
        if not command or process_match not in command:break
        parts=command.split(None,2)
        if parts[1].startswith('Z'):break
        rss=int(parts[0])*1024;peak=max(peak,rss)
        state=dict(timestamp=time.time(),pid=pid,rss_bytes=rss,peak_rss_bytes=peak,guard_gib=guard_gib)
        if rss>guard_gib*2**30:
            state['termination']='LOCAL_RSS_GUARD'
            os.killpg(pid,signal.SIGINT)
            (root/'guard_status.json').write_text(json.dumps(state,indent=2))
            time.sleep(5)
            if subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip():
                os.killpg(pid,signal.SIGTERM)
            break
        (root/'guard_status.json').write_text(json.dumps(state,indent=2))
        time.sleep(2)
finally:awake.terminate()
