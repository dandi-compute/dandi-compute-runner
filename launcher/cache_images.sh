#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Image-Cache
#SBATCH --output=/orcd/data/dandi/001/dandi-compute/processing/derivatives/logs/dandicompute-images/job-%j_slurm.log
#SBATCH --mem=32GB
#SBATCH --cpus-per-task 8
#SBATCH --partition=mit_normal
#SBATCH --time=04:00:00

# Builds the AIND step images into the Apptainer cache Nextflow reads from (work/apptainer_cache/).
# Building a SIF file from a multi-gigabyte image takes several gigabytes of memory, and left to
# Nextflow the build happens inside a capsule's 1 GB driver job, where it is killed.
#
# Any arguments are passed on to `dandicompute images cache`, e.g. `--version v1.2.4`.
# The --output directory above has to exist before this is submitted.

source /etc/profile.d/modules.sh
module load miniforge
module load apptainer
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env
dandicompute images cache --base /orcd/data/dandi/001/dandi-compute "$@"
