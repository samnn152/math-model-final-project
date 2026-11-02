"""Release the separate Step6/Step9 reruns only after full local certification."""
import argparse
import base64
import concurrent.futures
import json
import hashlib
import subprocess
from pathlib import Path

REPO=Path(__file__).resolve().parents[1]
HOSTS=[('35.188.143.164',None),('34.60.227.193',None),('34.30.13.108',None),('104.198.40.229','35.253.172.83')]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--verified-pilot',type=Path,required=True)
    args=parser.parse_args()
    pilot=json.loads(args.verified_pilot.read_text())
    manifest=json.loads((args.verified_pilot.parent/'manifest.json').read_text())
    expected_hash=manifest['notebook_sha256']
    assert hashlib.sha256((REPO/'Project_Orange.jl').read_bytes()).hexdigest()==expected_hash, 'Notebook changed after pilot start'
    assert pilot.get('cloud_release_allowed') is True
    assert {x['stage'] for x in pilot['stages']}=={6,9}
    assert all(x['completed'] and x['full_lex_optimal'] and x['validated'] for x in pilot['stages'])
    runner=base64.b64encode((REPO/'cloud/step6_budget_v2.py').read_bytes()).decode()
    jobs=[f'step9v2_setA-{i:02d}_run-{r:02d}' for i in range(1,21) for r in range(1,11)]
    code=r'''import json,base64,subprocess,shutil,hashlib
from pathlib import Path
source=Path('/opt/orange/source-optimize-budget-v2');target=Path('/opt/orange/source-step9-optimize-budget-v2')
assert hashlib.sha256((source/'Project_Orange.jl').read_bytes()).hexdigest()==EXPECTED_HASH, 'Cloud source differs from verified notebook'
if not target.exists():shutil.copytree(source,target,ignore=shutil.ignore_patterns('results','output','.git','__pycache__'))
p=target/'cloud/run_cloud_jobs.py';text=p.read_text()
text=text.replace("name=f'step6v2_", "name=f'step9v2_")
text=text.replace("str(root) not in (", "str(root) not in ('/opt/orange/results/step9_optimize_budget_v2_20261024', ")
# Explicitly remove execution-wall cutoffs only in this new cohort.
text='\n'.join(line.replace('elif stage==9 and elapsed>', 'elif False and elapsed>') if 'EXTERNAL_WALL_LIMIT' in line else line for line in text.splitlines())+'\n'
compile(text,str(p),'exec');p.write_text(text)
Path('/opt/orange/recovery/step9-budget-v2-jobs.json').write_text(json.dumps(JOBS))
Path('/opt/orange/recovery/step9_budget_v2.py').write_bytes(base64.b64decode(RUNNER))
unit='[Unit]\nDescription=Orange Step9 verified optimize-only rerun\nAfter=network-online.target\n[Service]\nWorkingDirectory=/opt/orange/recovery\nEnvironment=ORANGE_STAGE=9\nEnvironment=ORANGE_RESULT_ROOT=/opt/orange/results/step9_optimize_budget_v2_20261024\nEnvironment=ORANGE_SOURCE=/opt/orange/source-step9-optimize-budget-v2\nEnvironment=ORANGE_JOB_LIST=/opt/orange/recovery/step9-budget-v2-jobs.json\nEnvironment=JULIA_DEPOT_PATH=/opt/orange/depot\nEnvironment=JULIA_NUM_THREADS=1\nEnvironment=OPENBLAS_NUM_THREADS=1\nEnvironment=OMP_NUM_THREADS=1\nExecStart=/usr/bin/python3 /opt/orange/recovery/step9_budget_v2.py\nMemoryMax=49G\nMemoryHigh=44G\nMemorySwapMax=0\nRestart=on-failure\nRestartSec=15\n[Install]\nWantedBy=multi-user.target\n'
Path('/etc/systemd/system/orange-step9-budget-v2.service').write_text(unit)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','orange-step9-budget-v2.service'],check=True)
# Releasing the shared admission gate resumes unfinished Step6-v2 claims and
# permits Step9-v2 starts; process creation remains capped at four per VM.
subprocess.run(['systemctl','stop','orange-pilot-admission-hold.service'],check=True)
print('Verified pilot gate released; Step6-v2 retained and Step9-v2 enabled')
'''.replace('RUNNER',repr(runner)).replace('EXPECTED_HASH',repr(expected_hash))
    def deploy(item):
        i,(ip,alias)=item
        command=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=12']
        if alias:command+=['-o','HostKeyAlias='+alias]
        command+=['-i',str(Path.home()/'.ssh/google_compute_engine'),'hider152@'+ip,'sudo python3 -']
        result=subprocess.run(command,input=code.replace('JOBS',repr(jobs[i::4])),text=True,capture_output=True,timeout=90)
        if result.returncode:raise RuntimeError(ip+': '+result.stderr)
        return dict(host=ip,output=result.stdout)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(deploy,enumerate(HOSTS)))
    path=args.verified_pilot.parent/'cloud_release.json'
    path.write_text(json.dumps(results,indent=2))

if __name__=='__main__':main()
