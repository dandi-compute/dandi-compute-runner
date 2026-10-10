#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Images
#SBATCH --partition=mit_quicktest
#SBATCH --time=00:15:00
#SBATCH --mem=1GB
#SBATCH --cpus-per-task=1

# Once a day, an hour ahead of `create`: check that the container images of the latest AIND
# pipeline tag are cached, and when any is missing, submit pull_images.sh to pull them in a
# high-memory job. This job does not wait for that one; the pull checks its own result.
# Record this run in the global logs repository (see launcher/record.sh).
[ -n "${DANDI_COMPUTE_RECORDED:-}" ] || exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs images -- bash /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/images.sh "$@"
set -euo pipefail
source /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/environment.sh

PIPELINE_DIRECTORY=aind-ephys-pipeline
CACHE_DIRECTORY="$BASE_DIRECTORY/work/apptainer_cache"
LOG_DIRECTORY="$BASE_DIRECTORY/dandi-compute-global-logs/untracked/slurm"
LAUNCHER_DIRECTORY="$BASE_DIRECTORY/dandi-compute-runner/launcher"

# The latest local tag is what new job capsules are formed against. Its files are read with
# `git show`, since the shared checkout is on whatever tag the last capsule used.
TAG=$(python -c "from dandi_compute_code.queue import PipelineQueue; print(PipelineQueue.resolve_latest_pipeline_version(pipeline='aind+ephys'))")
if ! VERSIONS=$(git -C "$PIPELINE_DIRECTORY" show "${TAG}:pipeline/capsule_versions.env"); then
    echo "The pipeline has no pipeline/capsule_versions.env at ${TAG}."
    exit 1
fi
# `|| true` since a key the release lacks makes grep fail, which under pipefail would end the
# task silently.
capsule_version() { grep -E "^$1=" <<< "$VERSIONS" | cut -d= -f2 | tr -d "[:space:]\"'" || true; }
# Releases from 1.4.0 name the image tag outright. Earlier ones tag the images by SpikeInterface
# version.
CONTAINER_TAG=$(capsule_version CONTAINER_TAG)
if [ -z "$CONTAINER_TAG" ]; then
    SPIKEINTERFACE_VERSION=$(capsule_version SPIKEINTERFACE_VERSION)
    if [ -z "$SPIKEINTERFACE_VERSION" ]; then
        echo "Neither CONTAINER_TAG nor SPIKEINTERFACE_VERSION in pipeline/capsule_versions.env at ${TAG}."
        exit 1
    fi
    CONTAINER_TAG="si-${SPIKEINTERFACE_VERSION}"
fi
echo "Pipeline ${TAG} uses image tag ${CONTAINER_TAG}"

if "$LAUNCHER_DIRECTORY/tasks/pull_images.sh" --check "$CACHE_DIRECTORY" "$CONTAINER_TAG"; then
    echo "Every image is already cached."
    exit 0
fi

mkdir -p "$LOG_DIRECTORY"
# The pull records itself, so it is not handed this task's own marker of being recorded.
"$LAUNCHER_DIRECTORY/guarded-submit" -N DANDI-Compute-Image-Cache -- \
    sbatch --export=ALL,DANDI_COMPUTE_RECORDED= --output="$LOG_DIRECTORY/pull-images-%j.log" \
    "$LAUNCHER_DIRECTORY/tasks/pull_images.sh" "$BASE_DIRECTORY/$PIPELINE_DIRECTORY" "$TAG" "$CACHE_DIRECTORY" "$CONTAINER_TAG"
