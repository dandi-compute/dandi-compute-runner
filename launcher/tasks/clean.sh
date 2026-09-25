#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Clean
#SBATCH --partition=mit_preemptable
#SBATCH --time=02:00:00
#SBATCH --mem=1GB
#SBATCH --cpus-per-task=1

# Once a week: clear the cached Nextflow work directory.
# Record this run in the global logs repository (see launcher/record.sh).
[ -n "${DANDI_COMPUTE_RECORDED:-}" ] || exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs clean -- bash /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/clean.sh "$@"
set -euo pipefail
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/environment.sh

dandicompute clean --base "$BASE_DIRECTORY" --work
