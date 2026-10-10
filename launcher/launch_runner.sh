#!/bin/bash
#
# Keep the self-hosted GitHub Actions runner (labels mit, engaging, submitter) up on the login
# node. Run by the crontab every 5 minutes; the lock makes every call after the first a no-op
# while the runner is up.
#
# The runner lives on the login node rather than in a SLURM job because its steps only do light
# work and submit sbatch jobs for anything heavy, so it needs no allocation of its own. Each step
# records itself in the global logs repository through launcher/record.sh.

LOG_DIRECTORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/untracked/runner
mkdir -p "$LOG_DIRECTORY"

source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env

exec flock -n /orcd/data/dandi/001/dandi-compute/flocks/runner.lock \
    /orcd/data/dandi/001/dandi-compute/runners/submitter/actions-runner/run.sh \
    >> "$LOG_DIRECTORY/runner-$(date +%F).log" 2>&1
