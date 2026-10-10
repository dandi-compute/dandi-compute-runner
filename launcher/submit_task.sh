#!/bin/bash
#
# Submit one scheduled task from launcher/tasks/ as a short SLURM job. Called by the crontab.
#
# Usage: submit_task.sh TASK    (dispatch, create or clean)
#
# guarded-submit skips the submission while a job of the same name is pending or running, so a
# task that is slow to start never piles up copies of itself. Each task records itself in the
# global logs repository (see record.sh); the job's raw output also goes to
# untracked/slurm/{task}-{job id}.log in its checkout, in case recording itself fails.
set -euo pipefail

TASK="${1:?usage: submit_task.sh TASK}"
LAUNCHER_DIRECTORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher
TASK_SCRIPT="$LAUNCHER_DIRECTORY/tasks/$TASK.sh"
LOG_DIRECTORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/untracked/slurm
[ -f "$TASK_SCRIPT" ] || { echo "No such task: $TASK" >&2; exit 2; }

JOB_NAME=$(sed -n 's/^#SBATCH[[:space:]]\+--job-name=//p' "$TASK_SCRIPT" | head -n 1)
mkdir -p "$LOG_DIRECTORY"

exec "$LAUNCHER_DIRECTORY/guarded-submit" -N "$JOB_NAME" -- \
    sbatch --output="$LOG_DIRECTORY/$TASK-%j.log" "$TASK_SCRIPT"
