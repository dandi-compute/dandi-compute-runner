#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Submitter
#SBATCH --mem=1GB
#SBATCH --cpus-per-task 1
#SBATCH --partition=mit_preemptable
#SBATCH --time=12:00:00

source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env
flock -n /orcd/data/dandi/001/dandi-compute/flocks/submitter.lock -c "/orcd/data/dandi/001/dandi-compute/runners/submitter/actions-runner/run.sh" || echo "$(date): lock held, skipping submit"
