#!/bin/bash
#SBATCH --job-name=DANDI-Compute-Submitter
#SBATCH --mem=1GB
#SBATCH --cpus-per-task 1
#SBATCH --partition=mit_preemptable
#SBATCH --time=12:00:00

# The crontab keeps exactly one of these jobs pending or running (guarded-submit -N), so each
# time one starts is the cluster's own daily-or-better tick. On that tick the job starts the
# self-hosted runner and, once it is listening, dispatches the process-queue workflow onto it.
# That workflow submits the job arrays (`dandicompute jobs dispatch`, which never stacks a
# second array on a live one) and records the attempt with a squeue snapshot on the Dandiset.

BASE_DIRECTORY=/orcd/data/dandi/001/dandi-compute
LOG_DIRECTORY="$BASE_DIRECTORY/submitter/logs"
RUNNER_LOG_FILE_PATH="$LOG_DIRECTORY/job-${SLURM_JOB_ID}_runner.log"
DISPATCH_LOG_FILE_PATH="$LOG_DIRECTORY/job-${SLURM_JOB_ID}_dispatch.log"
mkdir -p "$LOG_DIRECTORY"

source /etc/profile.d/modules.sh
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-dandi+compute_env

flock -n "$BASE_DIRECTORY/flocks/submitter.lock" -c "$BASE_DIRECTORY/runners/submitter/actions-runner/run.sh" \
    > "$RUNNER_LOG_FILE_PATH" 2>&1 &
RUNNER_PID=$!

# The workflow cancels itself when no runner is online, so it is only dispatched once this one
# is listening. A runner that exits first (the lock is held by another) dispatches nothing.
for _ in $(seq 120); do
    grep -q "Listening for Jobs" "$RUNNER_LOG_FILE_PATH" && break
    kill -0 "$RUNNER_PID" 2>/dev/null || break
    sleep 5
done
if grep -q "Listening for Jobs" "$RUNNER_LOG_FILE_PATH"; then
    "$BASE_DIRECTORY/dandi-compute-runner/launcher/dispatch_process_queue.sh" >> "$DISPATCH_LOG_FILE_PATH" 2>&1 \
        || echo "$(date): dispatch failed; see $DISPATCH_LOG_FILE_PATH" >> "$RUNNER_LOG_FILE_PATH"
else
    echo "$(date): runner never reported it was listening; not dispatching" >> "$RUNNER_LOG_FILE_PATH"
fi

wait "$RUNNER_PID"
