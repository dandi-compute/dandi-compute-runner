#!/bin/bash
#SBATCH --job-name=DANDI-Track-Deleted-Blobs
#SBATCH --partition=mit_preemptable
#SBATCH --requeue
#SBATCH --mem=2GB
#SBATCH --cpus-per-task=4
#SBATCH --time=04:00:00
#
# deleted_blobs.sh - the daily scan of the blob mirror for blobs the bucket no longer has.
#
# Submitted by the crontab through launcher/backup.sh (`backup.sh deleted`), which names the job
# and sends its output to the backup logs. It runs launcher/deleted_blobs.py scan, which lists every
# version of blobs/ in the bucket and every blob on both partitions, and keeps in STATE_DIRECTORY the
# blobs that are mirrored but no longer in the bucket. The disk usage snapshots (launcher/disk.sh)
# show the newest scan, and the Status page of dandi-compute-page shows them.
#
# Listing the bucket takes a few minutes. Walking the mirror reads only directories, never a blob.
# A scan that fails leaves the last complete one in place.

set -uo pipefail

LAUNCHER=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher
STATE_DIRECTORY=/orcd/data/dandi/001/backup/deleted_blobs
# deleted_blobs.py needs only a Python 3; these are tried before the one on PATH.
PYTHONS=(
    /orcd/data/dandi/001/environments/name-s3+backup_env/bin/python
    /orcd/data/dandi/001/environments/name-datalad_env/bin/python
)

python=$(command -v python3)
for candidate in "${PYTHONS[@]}"; do
    [ -x "$candidate" ] && { python="$candidate"; break; }
done
if [ -z "$python" ]; then
    echo "$(date --iso-8601=seconds) ERROR: no Python to run $LAUNCHER/deleted_blobs.py with." >&2
    exit 1
fi

echo "$(date --iso-8601=seconds) scanning for deleted blobs (job ${SLURM_JOB_ID:-?} on $(hostname), $("$python" --version 2>&1))"
"$python" "$LAUNCHER/deleted_blobs.py" scan --state "$STATE_DIRECTORY" --workers "${SLURM_CPUS_PER_TASK:-4}"
status=$?
if [ "$status" -ne 0 ]; then
    echo "$(date --iso-8601=seconds) ERROR: the scan exited with status $status; the last complete scan stays in $STATE_DIRECTORY." >&2
fi
exit "$status"
