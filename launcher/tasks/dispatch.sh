#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Dispatch
#SBATCH --partition=mit_quicktest
#SBATCH --time=00:15:00
#SBATCH --mem=2GB
#SBATCH --cpus-per-task=1

# Every 30 minutes: submit each pipeline's job array unless its last one is still churning,
# log the attempt as one line in the day's derivatives/logs/dispatch/ log on the Dandiset, and
# rewrite jobs.tsv when the attempt was not skipped.
set -euo pipefail
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/environment.sh

dandicompute jobs dispatch --base "$BASE_DIRECTORY" --record --refresh --jitter 0
