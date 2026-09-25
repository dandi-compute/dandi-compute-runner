#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Dispatch
#SBATCH --partition=mit_quicktest
#SBATCH --time=00:15:00
#SBATCH --mem=2GB
#SBATCH --cpus-per-task=1

# Every 30 minutes: submit each pipeline's job array unless its last one is still churning, and
# rewrite jobs.tsv when the attempt was not skipped.
# Record this run in the global logs repository (see launcher/record.sh).
[ -n "${DANDI_COMPUTE_RECORDED:-}" ] || exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs dispatch -- bash /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/dispatch.sh "$@"
set -euo pipefail
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/environment.sh

dandicompute jobs dispatch --base "$BASE_DIRECTORY" --refresh --jitter 0
