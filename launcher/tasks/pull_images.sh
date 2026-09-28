#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Image-Cache
#SBATCH --partition=mit_normal
#SBATCH --time=04:00:00
#SBATCH --mem=32GB
#SBATCH --cpus-per-task=8

# Pull the AIND container images of one pipeline tag into the Apptainer cache, with the
# pipeline's own pull_pipeline_images.sh. Building a multi-gigabyte image needs far more memory
# than the 1 GB Nextflow driver that would otherwise pull it, which is why this is its own job.
#
# Usage: pull_images.sh PIPELINE_DIRECTORY TAG CACHE_DIRECTORY CONTAINER_TAG
#        pull_images.sh --check CACHE_DIRECTORY CONTAINER_TAG   (exit 0 when every image is cached)
set -euo pipefail

if [ "${1:-}" != "--check" ] && [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    # Record this run in the global logs repository (see launcher/record.sh).
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs pull-images -- bash /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/tasks/pull_images.sh "$@"
fi

# The images upstream's script pulls by default (--sorter kilosort4), under the file names
# Nextflow looks for.
missing_images() {
    local cache_directory="$1" container_tag="$2" repository file_name
    for repository in aind-ephys-pipeline-base aind-ephys-pipeline-nwb aind-ephys-spikesort-kilosort4; do
        file_name="ghcr.io-allenneuraldynamics-${repository}-${container_tag}.img"
        [ -f "${cache_directory}/${file_name}" ] || echo "$file_name"
    done
}

if [ "${1:-}" = "--check" ]; then
    missing=$(missing_images "$2" "$3")
    [ -z "$missing" ] && exit 0
    printf 'Not cached yet: %s\n' $missing
    exit 1
fi

PIPELINE_DIRECTORY="$1"
TAG="$2"
CACHE_DIRECTORY="$3"
CONTAINER_TAG="$4"

SCRIPT_FILE_PATH=$(mktemp --suffix=-pull_pipeline_images.sh)
trap 'rm -f "$SCRIPT_FILE_PATH"' EXIT
git -C "$PIPELINE_DIRECTORY" show "${TAG}:pull_pipeline_images.sh" > "$SCRIPT_FILE_PATH"

set +u
source /etc/profile.d/modules.sh
module load apptainer
set -u
bash "$SCRIPT_FILE_PATH" --cache "$CACHE_DIRECTORY" --tag "$CONTAINER_TAG"

# The upstream script ignores a failed pull (`|| true`), so success is judged by the images
# actually being in place.
still_missing=$(missing_images "$CACHE_DIRECTORY" "$CONTAINER_TAG")
if [ -n "$still_missing" ]; then
    printf 'Still not cached: %s\n' $still_missing
    exit 1
fi
echo "Every image of ${CONTAINER_TAG} is cached."
