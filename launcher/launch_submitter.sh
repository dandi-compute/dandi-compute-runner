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
# Every workflow step, and every Slurm job a step submits, inherits these. Without them each DANDI
# CLI call leaves files in the home directory that nothing removes: a log under
# ~/.local/state/dandi-cli/log/, and a cache entry under ~/.cache/fscacher/ for every file it
# hashes. The home directory's quota counts files as well as space. The logs go to the project
# directory instead, where the Clean work directory workflow prunes them, and the cache, which
# only ever sees each throwaway working tree once, is not kept at all.
export DANDI_CACHE=ignore
export XDG_STATE_HOME=/orcd/data/dandi/001/dandi-compute/state
flock -n /orcd/data/dandi/001/dandi-compute/flocks/submitter.lock -c "/orcd/data/dandi/001/dandi-compute/runners/submitter/actions-runner/run.sh" || echo "$(date): lock held, skipping submit"
