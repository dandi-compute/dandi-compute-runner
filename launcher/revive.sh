#!/bin/bash
#SBATCH --job-name=revive
#SBATCH --output=/orcd/data/dandi/001/dandi-compute/tmp/revive-logs/%x-%j.out
#SBATCH --time=00:10:00
#SBATCH --partition=mit_preemptable
#SBATCH --mem=100MB
#SBATCH --cpus-per-task=1

set -uo pipefail

INTERVAL_MIN=60
SELF="/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/revive.sh"

OTHERS=$(squeue --noheader --name="$SLURM_JOB_NAME" --user="$USER" \
         --states=PENDING,RUNNING --format="%A" \
         | grep -v "^${SLURM_JOB_ID}$" || true)

if [ -n "$OTHERS" ]; then
    echo "$(date) duplicate ${SLURM_JOB_NAME} found ($OTHERS) — exiting."
    exit 0
fi

sbatch --begin="now+${INTERVAL_MIN}minutes" "$SELF"

echo "$(date) running on $(hostname), reinstalling crontab"

if "$(dirname "$SELF")/install_crontab.sh"; then
    echo "$(date) crontab reinstall succeeded"
fi
