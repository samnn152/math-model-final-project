#!/usr/bin/env bash
# Copy this script and the source archive to Cloud Shell. No default action creates a VM.
set -euo pipefail
action="${1:-preflight}"
vm=orange-seta-onepass
zone=us-central1-a
region=us-central1
case "$action" in preflight|create|setup|pilot|fetch) ;; *) echo 'Use preflight|create|setup|pilot|fetch'; exit 2 ;; esac
if [[ "$action" == preflight ]]; then
  gcloud billing projects describe "$(gcloud config get-value project)" --format='value(billingEnabled)'
  gcloud services list --enabled --filter='config.name=compute.googleapis.com' --format='value(config.name)'
  gcloud compute regions describe "$region" --format='json(quotas)' --quiet
  exit
fi
if [[ "$action" == create ]]; then
  [[ -f orange-source.tar.gz ]] || { echo 'Upload orange-source.tar.gz first'; exit 2; }
  sha256sum --check orange-source.tar.gz.sha256
  gcloud services enable compute.googleapis.com
  if gcloud compute instances describe "$vm" --zone "$zone" >/dev/null 2>&1; then
    echo 'The named VM already exists; refusing to overwrite or create a duplicate.'; exit 1
  fi
  gcloud compute instances create "$vm" --zone "$zone" \
    --machine-type=e2-highmem-8 --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=50GB --boot-disk-type=pd-balanced \
    --no-service-account --no-scopes --shielded-secure-boot \
    --metadata=block-project-ssh-keys=TRUE \
    --max-run-duration=36h --instance-termination-action=STOP --no-restart-on-failure \
    --labels=purpose=orange-coursework,experiment=one-pass
fi
if [[ "$action" == setup ]]; then
  sha256sum --check orange-source.tar.gz.sha256
  gcloud compute scp --zone "$zone" orange-source.tar.gz "$vm:~/orange-source.tar.gz"
  gcloud compute ssh "$vm" --zone "$zone" --command='tar -xzf orange-source.tar.gz cloud/bootstrap.sh && sudo bash cloud/bootstrap.sh "$(pwd)/orange-source.tar.gz"'
fi
if [[ "$action" == pilot ]]; then
  gcloud compute ssh "$vm" --zone "$zone" --command='sudo systemctl start orange-pilot.service'
  echo 'Pilot runs on the VM. Its service powers off the VM on completion/failure; the boot disk retains results.'
fi
if [[ "$action" == fetch ]]; then
  gcloud compute ssh "$vm" --zone "$zone" --command='sudo tar -czf /tmp/orange-results.tar.gz -C /opt/orange/results . && sudo chmod 644 /tmp/orange-results.tar.gz'
  gcloud compute scp --zone "$zone" "$vm:/tmp/orange-results.tar.gz" ./orange-results.tar.gz
fi
