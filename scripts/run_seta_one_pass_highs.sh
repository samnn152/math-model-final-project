#!/usr/bin/env bash
# Explicit entry point: preparing this file does not start an experiment.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
stage="${1:-all}"
output_root="${2:-results/seta_one_pass_highs_20261021}"
case "$stage" in
  all|6|9) ;;
  *) echo 'Usage: bash scripts/run_seta_one_pass_highs.sh [all|6|9] [output-directory]' >&2; exit 2 ;;
esac

export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
mkdir -p "$output_root"

# Resume requires the same model, dependencies and CLI sources.
snapshot="$(mktemp "$output_root/.source-hashes.XXXXXX")"
shasum -a 256 Project_Orange.jl Project.toml Manifest.toml \
  scripts/run_experiments.jl scripts/run_time01_experiments.jl \
  scripts/run_seta_one_pass_highs.sh > "$snapshot"
if [[ -f "$output_root/source-sha256.txt" ]]; then
  if ! cmp -s "$snapshot" "$output_root/source-sha256.txt"; then
    rm -f "$snapshot"
    echo 'Sources changed. Use a new output directory to avoid mixing results.' >&2
    exit 1
  fi
  rm -f "$snapshot"
else
  mv "$snapshot" "$output_root/source-sha256.txt"
fi

if [[ "$stage" == all || "$stage" == 6 ]]; then
  mkdir -p "$output_root/step6_time0"
  julia --project=. scripts/run_experiments.jl \
    --instances 1:20 --runs 1 --time-limit 1800 \
    --solver highs --threads 1 --seed-base 1000 \
    --splitting ecmp --formulation routes --highs-profile default \
    --target-gap 0.10 --deadline-callback true \
    --max-routes 16 --pricing-rounds 40 --pricing-time 30 \
    --warm-start-seconds 3 --proof-tolerance 1e-7 --lock-tolerance 1e-7 \
    --max-binary-variables 2000000 \
    --output "$output_root/step6_time0" \
    2>&1 | tee -a "$output_root/step6_time0/console.log"
fi

if [[ "$stage" == all || "$stage" == 9 ]]; then
  mkdir -p "$output_root/step9_time01"
  julia --project=. scripts/run_time01_experiments.jl \
    --instances 1:20 --runs 1 --time-limit 3600 \
    --solver highs --threads 1 --seed-base 1000 --formulation paired \
    --pricing-slice 2 --max-columns 100000 \
    --max-variables 2200000 --max-pricing-variables 2200000 \
    --output "$output_root/step9_time01" \
    2>&1 | tee -a "$output_root/step9_time01/console.log"
fi
