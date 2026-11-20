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
# Run on its own it records itself; record.sh runs it again, recorded, for the snapshot.
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh disk usage -- "$0"
fi

set -uo pipefail

PATHS=(/orcd/data/dandi/001 /orcd/data/dandi/002)
QUOTA_REPORT="$HOME/orcd/.quota"
DU_TIMEOUT_SECONDS=600

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

exit "$status"
