#!/usr/bin/env bash
# Select concurrency from the completed pilot, then launch a detached systemd unit.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run with sudo'; exit 2; }
if [[ "${1:-}" == --skip-pilot ]]; then
  workers=2
else
workers="$(python3 - <<'PY'
import json
from pathlib import Path
p=Path('/opt/orange/results/pilot/step9_setA-20/supervisor.json')
if not p.exists():raise SystemExit('Pilot summary missing; do not start the full batch')
r=json.loads(p.read_text())
if not r['completed']:raise SystemExit('Pilot failed; inspect logs before starting the batch')
peak=max(r['sampled_tree_peak_rss_bytes'],r['observed_process_hwm_bytes'])
print(2 if peak<=20*1024**3 else 1)
PY
)"
fi
rss=48
[[ "$workers" == 2 ]] && rss=24
cat > /etc/systemd/system/orange-batch.service <<UNIT
[Unit]
Description=Orange one-pass Step 6 and Step 9
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=orange
WorkingDirectory=/opt/orange/source
Environment=JULIA_DEPOT_PATH=/opt/orange/depot
Environment=JULIA_NUM_THREADS=1
Environment=OPENBLAS_NUM_THREADS=1
Environment=OMP_NUM_THREADS=1
ExecStart=/usr/bin/python3 /opt/orange/source/cloud/run_cloud_jobs.py --mode batch --workers $workers --rss-gib $rss --output /opt/orange/results/one_pass --run
MemoryMax=56G
MemorySwapMax=0
RuntimeMaxSec=35h
TimeoutStopSec=30
KillMode=control-group
Restart=no
ExecStopPost=+/usr/bin/systemctl --no-block poweroff
UNIT
systemctl daemon-reload
systemctl start orange-batch.service
printf 'Batch started: %s workers, %s GiB RSS guard per job. VM powers off when service ends.\n' "$workers" "$rss"
