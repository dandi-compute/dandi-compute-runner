#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Create
#SBATCH --partition=mit_preemptable
#SBATCH --time=01:00:00
#SBATCH --mem=4GB
#SBATCH --cpus-per-task=1

# Once a day: create up to 5 job capsules per pipeline, then rewrite jobs.tsv so they show
# as pending without waiting for the next dispatch that is not skipped.
set -euo pipefail
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/environment.sh

LIMIT=5

pip install --quiet -U dandi
# One call per configured pipeline, so each gets its own limit and none can starve another.
PIPELINES=$(python -c "from dandi_compute_code.queue import PipelineQueue; print(*PipelineQueue.load_pipeline_config()['pipelines'])")
for pipeline in $PIPELINES; do
    dandicompute jobs create --base "$BASE_DIRECTORY" --pipeline "$pipeline" --limit "$LIMIT"
done
dandicompute jobs refresh --base "$BASE_DIRECTORY"
