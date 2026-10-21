#!/usr/bin/env bash
# Run on the dedicated Debian/Ubuntu worker, after transferring the source bundle.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux x86_64 required'; exit 2; }
[[ $(id -u) == 0 ]] || { echo 'Run with sudo'; exit 2; }
bundle="${1:?Provide source archive path}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl python3 perl tar build-essential gfortran
id orange >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/orange/home orange
mkdir -p /opt/orange/source /opt/orange/depot /opt/orange/results /opt/orange/downloads
cd /opt/orange/downloads
curl --fail --location --retry 3 -o julia.tar.gz https://julialang-s3.julialang.org/bin/linux/x64/1.13/julia-1.13.1-linux-x86_64.tar.gz
curl --fail --location --retry 3 -o julia.sha256 https://julialang-s3.julialang.org/bin/checksums/julia-1.13.1.sha256
python3 - <<'PY'
import hashlib
from pathlib import Path
expected=next(line.split()[0] for line in Path('julia.sha256').read_text().splitlines()
              if line.split()[-1].lstrip('*')=='julia-1.13.1-linux-x86_64.tar.gz')
assert hashlib.sha256(Path('julia.tar.gz').read_bytes()).hexdigest()==expected,'Julia checksum mismatch'
PY
tar -xzf julia.tar.gz -C /opt/orange
ln -sfn /opt/orange/julia-1.13.1/bin/julia /usr/local/bin/julia
tar -xzf "$bundle" -C /opt/orange/source
chown -R orange:orange /opt/orange/source /opt/orange/depot /opt/orange/results
sudo -u orange env JULIA_DEPOT_PATH=/opt/orange/depot JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=2 \
  julia --project=/opt/orange/source -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
# No experiment starts during bootstrap. Install the pilot service, but do not start it.
cat > /etc/systemd/system/orange-pilot.service <<'UNIT'
[Unit]
Description=Orange bounded cloud capacity pilot
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
ExecStart=/usr/bin/python3 /opt/orange/source/cloud/run_cloud_jobs.py --mode pilot --workers 1 --rss-gib 48 --output /opt/orange/results/pilot --run
MemoryMax=56G
MemorySwapMax=0
RuntimeMaxSec=30min
TimeoutStopSec=30
KillMode=control-group
Restart=no
ExecStopPost=+/usr/bin/systemctl --no-block poweroff
UNIT
systemctl daemon-reload
printf '%s\n' 'Setup complete. Pilot service is installed but has not started.'
