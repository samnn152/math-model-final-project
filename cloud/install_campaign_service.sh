#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run with sudo'; exit 2; }
shard="${1:?shard index required}"
[[ "$shard" =~ ^[012]$ ]] || { echo 'Expected shard 0, 1 or 2'; exit 2; }
source_dir=/opt/orange/source-tenrun-20261022
output_dir=/opt/orange/results/tenrun_20261022
mkdir -p "$output_dir"
chown orange:orange "$output_dir"
cat > /etc/systemd/system/orange-batch.service <<UNIT
[Unit]
Description=Orange ten-run campaign shard $shard of 3
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=orange
WorkingDirectory=$source_dir
Environment=JULIA_DEPOT_PATH=/opt/orange/depot
Environment=JULIA_NUM_THREADS=1
Environment=OPENBLAS_NUM_THREADS=1
Environment=OMP_NUM_THREADS=1
Environment=ORANGE_RESULTS_ROOT=$output_dir
ExecStart=/usr/bin/python3 $source_dir/cloud/run_cloud_jobs.py --mode batch --runs 10 --shards 3 --shard-index $shard --workers 6 --rss-gib 8 --output $output_dir --run
MemoryMax=56G
MemorySwapMax=0
RuntimeMaxSec=35h
TimeoutStopSec=30
KillMode=control-group
Restart=no
ExecStopPost=+/usr/bin/python3 $source_dir/cloud/monitor_batch.py --final
ExecStopPost=+/usr/bin/systemctl --no-block poweroff
UNIT
# Remove the old monitor hook to avoid duplicate stop actions.
rm -f /etc/systemd/system/orange-batch.service.d/monitor.conf
cat > /etc/systemd/system/orange-monitor.service <<UNIT
[Unit]
Description=Orange campaign progress and quality email
[Service]
Type=oneshot
Environment=ORANGE_RESULTS_ROOT=$output_dir
ExecStart=/usr/bin/python3 $source_dir/cloud/monitor_batch.py
TimeoutStartSec=60
UNIT
cat > /etc/systemd/system/orange-monitor.timer <<'UNIT'
[Unit]
Description=Orange progress email every three hours
[Timer]
OnActiveSec=3h
OnUnitActiveSec=3h
AccuracySec=1min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now orange-monitor.timer
systemctl start orange-batch.service
systemctl start orange-monitor.service
systemctl is-active orange-batch.service
