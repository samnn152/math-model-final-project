#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run with sudo'; exit 2; }
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-google-auth python3-requests
cat > /etc/systemd/system/orange-monitor.service <<'UNIT'
[Unit]
Description=Read-only Orange batch progress summary
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/orange/source/cloud/monitor_batch.py
TimeoutStartSec=60
UNIT
cat > /etc/systemd/system/orange-monitor.timer <<'UNIT'
[Unit]
Description=Summarize Orange batch hourly
[Timer]
OnActiveSec=1h
OnUnitActiveSec=1h
AccuracySec=1min
[Install]
WantedBy=timers.target
UNIT
mkdir -p /etc/systemd/system/orange-batch.service.d
cat > /etc/systemd/system/orange-batch.service.d/monitor.conf <<'UNIT'
[Service]
ExecStopPost=
ExecStopPost=+/usr/bin/python3 /opt/orange/source/cloud/monitor_batch.py --final
ExecStopPost=+/usr/bin/systemctl --no-block poweroff
UNIT
systemctl daemon-reload
systemctl enable --now orange-monitor.timer
systemctl start orange-monitor.service
systemctl list-timers orange-monitor.timer --no-pager
