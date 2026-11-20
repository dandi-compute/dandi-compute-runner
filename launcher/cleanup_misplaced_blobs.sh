#!/bin/bash
#SBATCH --job-name=DANDI-Cleanup-Misplaced-Blobs
#SBATCH --partition mit_preemptable
#SBATCH --requeue
#SBATCH --mem=4GB
#SBATCH --cpus-per-task 1
#SBATCH --time=12:00:00
#SBATCH --open-mode=append
#
# cleanup_misplaced_blobs.sh - delete the blob directories left on a partition that
# simple-s3-backup's partitions.json does not assign them to, such as heads a-f stranded on 001
# from before the 001/002 split.
#
# Usage: sbatch cleanup_misplaced_blobs.sh [--apply]
#
# Runs `s3backup dandi cleanup-misplaced-blobs` of simple-s3-backup, a dry run that only lists what
# it would delete unless given --apply. Even then it deletes a misplaced sub-directory only once the
# assigned partition holds a complete copy of the same size, so a run cut short, or requeued after a
# preemption, is safe to run again. It stats every file of the misplaced directories and of their
# copies, which takes hours, so it runs as a SLURM job of its own rather than on the runner, which
# also processes the queue. The Cleanup misplaced blobs workflow submits it; it is never scheduled.
#
# The run records itself in the global logs repository (see launcher/record.sh), so its output can
# be read on GitHub. Its SLURM log, wherever sbatch --output put it, has the same output.
if [ "$#" -gt 1 ]; then
    echo "usage: $0 [--apply]" >&2
    exit 2
fi
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    case "${1:-}" in
        "") RECORD_NAME=cleanup-misplaced-blobs ;;
        --apply) RECORD_NAME=cleanup-misplaced-blobs-apply ;;
        *)
            echo "usage: $0 [--apply]" >&2
            exit 2
            ;;
    esac
    # $0 is SLURM's copy of the script as submitted, so an Update codebase run during the job
    # cannot change what runs.
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs "$RECORD_NAME" -- bash "$0" "$@"
fi

APPLY=()
case "${1:-}" in
    "") ;;
    --apply) APPLY=(--apply) ;;
    *)
        echo "usage: $0 [--apply]" >&2
        exit 2
        ;;
esac

# shellcheck source=/dev/null
source /etc/profile.d/modules.sh  # Not set up for a non-interactive shell otherwise
module load miniforge
conda activate /orcd/data/dandi/001/environments/name-s3+backup_env

# Only after the setup above, which reads unset variables (as in simple-s3-backup's scripts).
set -uo pipefail

LOCK=/orcd/data/dandi/001/backup/flocks/cleanup_misplaced_blobs.lock
# Its output goes through pipes into the record, where Python would hold it back until the end;
# what a preempted run had done by then would be lost from its log.
export PYTHONUNBUFFERED=1

echo "$(date --iso-8601=seconds) cleanup-misplaced-blobs ${APPLY[*]:-(dry run)} in SLURM job ${SLURM_JOB_ID:-none} on $(hostname)"
# -n: a second cleanup, dry run or not, would only race the first over the same directories.
flock -n -E 75 "$LOCK" s3backup dandi cleanup-misplaced-blobs "${APPLY[@]}"
status=$?
if [ "$status" -eq 75 ]; then
    echo "Another cleanup holds $LOCK, so this one did not run." >&2
fi
echo "$(date --iso-8601=seconds) cleanup-misplaced-blobs exited $status"
exit "$status"
