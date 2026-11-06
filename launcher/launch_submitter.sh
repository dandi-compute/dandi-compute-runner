#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Submitter
# Every workflow step on this runner runs inside this job, beside the runner itself and the
# DataLad and duct of launcher/record.sh. Creating job capsules alone peaks above 500 MB.
#SBATCH --mem=4GB
#SBATCH --cpus-per-task 1
#SBATCH --partition=mit_preemptable
#SBATCH --time=12:00:00

source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env
flock -n /orcd/data/dandi/001/dandi-compute/flocks/submitter.lock -c "/orcd/data/dandi/001/dandi-compute/runners/submitter/actions-runner/run.sh" || echo "$(date): lock held, skipping submit"
