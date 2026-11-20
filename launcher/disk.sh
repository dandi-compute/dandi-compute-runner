#!/bin/bash
#
# Record a snapshot of disk usage in the global logs repository, under disk/ on the day's
# disk/YYYY-MM-DD branch, the way monitor.sh records the queue under monitor/ (see
# launcher/record.sh). Run by the crontab on the login node every 30 minutes; the Status page of
# dandi-compute-page shows the newest one. Day branches are ephemeral, so the snapshots never pile
# up anywhere that matters.
#
# The snapshot is `df` for the filesystems of the DANDI project directories, on space and on the
# number of files (inodes), each with its limit, then the quota report of the home directory, the
# one shown at login. A filesystem can run out of inodes before it runs out of space, and the blob
# mirror keeps a checksum file beside each of its hundreds of thousands of blobs. The home
# directory sits on a filesystem shared with every user, so `df` says nothing about it; what
# counts is its own quota, on space and on the number of files, which ORCD writes to
# ~/orcd/.quota every 30 minutes. Should that file be
# missing, the home directory's usage is measured with `du` instead (space only, no limits).
#
# Last come the mirrored blobs that are no longer in the bucket, which simple-s3-backup's checksum
# job deletes from the mirror 183 days after it first finds them missing, from its record of them
# (launcher/not_in_bucket.py): how many each partition holds, their share of its used space, and how
# long they have left. Their list goes into the record beside the output, as blobs-not-in-bucket.tsv.
# Git stores one copy of it for as long as the record does not change.
#
# Run on its own it records itself; record.sh runs it again, recorded, for the snapshot.
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh disk usage -- "$0"
fi

set -uo pipefail

PATHS=(/orcd/data/dandi/001 /orcd/data/dandi/002)
QUOTA_REPORT="$HOME/orcd/.quota"
DU_TIMEOUT_SECONDS=600
# The sizes of the blobs not in the bucket, read again only once simple-s3-backup's record changes.
NOT_IN_BUCKET_CACHE=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/untracked/not-in-bucket-sizes.tsv
LAUNCHER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# not_in_bucket.py needs only a Python 3; these are tried before the one on PATH.
PYTHONS=(
    /orcd/data/dandi/001/environments/name-datalad_env/bin/python
    /orcd/data/dandi/001/environments/name-s3+backup_env/bin/python
)

# One line per filesystem, the mount point first. The header is made one word per column, at
# the same width so the columns stay aligned, for the Status page to read the output as a table.
df -h --output=target,size,used,avail,pcent,itotal,iused,iavail,ipcent "${PATHS[@]}" | sed '1s/^Mounted on/Mounted   /'
status=$?

echo
if [ -r "$QUOTA_REPORT" ]; then
    cat "$QUOTA_REPORT"
else
    # Low priority, and bounded, so that a large home directory never holds the login node or the
    # next snapshot.
    printf '%-10s %s\n' Used Path
    if read -r size path < <(nice -n 19 ionice -c 3 timeout "$DU_TIMEOUT_SECONDS" du -sh "$HOME" 2> /dev/null); then
        printf '%-10s %s\n' "$size" "$path"
    else
        printf '%-10s %s\n' "?" "$HOME (du failed or took over ${DU_TIMEOUT_SECONDS}s)"
    fi
fi

echo
python=$(command -v python3)
for candidate in "${PYTHONS[@]}"; do
    [ -x "$candidate" ] && { python="$candidate"; break; }
done
if [ -n "$python" ]; then
    # DANDI_COMPUTE_RECORD_DIRECTORY is the record's own directory (see launcher/record.sh).
    "$python" "$LAUNCHER/not_in_bucket.py" --cache "$NOT_IN_BUCKET_CACHE" \
        ${DANDI_COMPUTE_RECORD_DIRECTORY:+--list-to "$DANDI_COMPUTE_RECORD_DIRECTORY"}
else
    echo "Not in bucket: no Python to read the record with"
fi

exit "$status"
