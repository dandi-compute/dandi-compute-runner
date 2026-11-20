#!/bin/bash
#
# backup.sh - submit one of the S3 backup jobs of simple-s3-backup.
#
# Usage: backup.sh blobs|nonblobs|zarr|dashboard|checksums
#
# Run by the crontab on the login node. The jobs mirror the DANDI S3 bucket onto the project
# partitions, from which every job capsule reads its input, and update the dashboard at
# https://github.com/dandi/backup-status, and `checksums` verifies the content of the blob mirror
# against the bucket. Their scripts are those of the simple-s3-backup checkout
# at /orcd/data/dandi/001/backup/simple-s3-backup, which this repository does not manage.
#
# Each job writes its output to LOG_DIRECTORY, one file per job or array task named after the job
# and its ID, so the Check backup workflow can show why a task failed. Logs older than
# LOG_RETENTION_DAYS are deleted at the next submission. The job names given here are the ones that
# workflow looks for, whatever the scripts themselves set.
#
# Nothing is submitted while a job of the same name is still pending or running (see the end).
#
# Run on its own it records the submission in the global logs repository (see launcher/record.sh).
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs "backup-${1:-unknown}" -- "$0" "$@"
fi

set -uo pipefail

BACKUP_DIRECTORY=/orcd/data/dandi/001/backup
SCRIPT_DIRECTORY="$BACKUP_DIRECTORY/simple-s3-backup/scripts"
LOCK_DIRECTORY="$BACKUP_DIRECTORY/flocks"
LOG_DIRECTORY="$BACKUP_DIRECTORY/logs"
LOG_RETENTION_DAYS=30

# SLURM fills in %x (job name), %A_%a (array job and task) and %j (job ID) itself.
case "${1:-}" in
    blobs)
        JOB_NAME=DANDI-Backup-Blobs
        SCRIPT=backup_blobs_batch_deployment.sh
        LOCK=backup_blobs_batch.lock
        LOG_NAME='%x-%A_%a.log'
        ;;
    nonblobs)
        JOB_NAME=DANDI-Backup-Nonblobs
        SCRIPT=backup_nonblobs_deployment.sh
        LOCK=backup_nonblobs.lock
        LOG_NAME='%x-%j.log'
        ;;
    zarr)
        JOB_NAME=DANDI-Backup-Zarr
        SCRIPT=backup_zarr_batch_deployment.sh
        LOCK=backup_zarr_batch.lock
        LOG_NAME='%x-%A_%a.log'
        ;;
    dashboard)
        JOB_NAME=DANDI-Update-Backup-Dashboard
        SCRIPT=update_dashboard.sh
        LOCK=update_dashboard.lock
        LOG_NAME='%x-%j.log'
        ;;
    checksums)
        JOB_NAME=DANDI-Verify-Checksums
        SCRIPT=verify_checksums_batch_deployment.sh
        LOCK=verify_checksums_batch.lock
        LOG_NAME='%x-%A_%a.log'
        ;;
    *)
        echo "usage: $0 blobs|nonblobs|zarr|dashboard|checksums" >&2
        exit 2
        ;;
esac

if ! mkdir -p "$LOG_DIRECTORY"; then
    echo "Could not create $LOG_DIRECTORY, so $JOB_NAME was not submitted." >&2
    exit 1
fi
deleted=$(find "$LOG_DIRECTORY" -maxdepth 1 -type f -name '*.log' -mtime +"$LOG_RETENTION_DAYS" -delete -print | wc -l)
echo "Deleted $deleted backup logs older than $LOG_RETENTION_DAYS days from $LOG_DIRECTORY."

# guarded-submit -N skips the submission, and says so, while a job of the same name is still
# pending, configuring or running. The blob and checksum tasks lock their share of the mirror, and
# their 12 hours do not always end before the next day's submission: the blob array submitted at
# 22:00 on 2026-11-16 waited for a maintenance reservation until 10:57 the next day, its tasks
# still held their locks at 22:05, and every task of the array submitted at 22:00 on 2026-11-17
# failed on them. The checksum arrays, 4 tasks at a time, take two days or more and piled up.
# -n 0 turns off guarded-submit's limit on the account's pending jobs, which the job capsules
# reach on their own. The flock makes the check and the submission one step.
# --error as well as --output, since a script's own #SBATCH --error would otherwise still send
# its stderr, where its errors go, somewhere else.
flock -n "$LOCK_DIRECTORY/$LOCK" \
    "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/guarded-submit" -n 0 -N "$JOB_NAME" -- \
    sbatch --job-name="$JOB_NAME" --output="$LOG_DIRECTORY/$LOG_NAME" --error="$LOG_DIRECTORY/$LOG_NAME" \
    "$SCRIPT_DIRECTORY/$SCRIPT"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Submitting $JOB_NAME failed (exit $status)." >&2
fi
exit "$status"
