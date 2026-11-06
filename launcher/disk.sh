#!/bin/bash
#
# Record a snapshot of disk usage in the global logs repository, under monitor/ on the day's
# branch beside the squeue snapshots (see launcher/record.sh). Run by the crontab on the login
# node every 30 minutes; the Status page of dandi-compute-page shows the newest one. Day branches
# are ephemeral, so the snapshots never pile up anywhere that matters.
#
# The snapshot is `df` for the filesystems of the home directory and the DANDI project
# directories, then how much the home directory itself holds (`du`), which `df` cannot show:
# the home directory has a quota of its own on a filesystem shared with every user.
#
# Run on its own it records itself; record.sh runs it again, recorded, for the snapshot.
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh monitor disk -- "$0"
fi

set -uo pipefail

PATHS=("$HOME" /orcd/data/dandi/001 /orcd/data/dandi/002)
DU_TIMEOUT_SECONDS=600

# One line per filesystem, the mount point first. The header is made one word per column, at
# the same width so the columns stay aligned, for the Status page to read the output as a table.
df -h --output=target,size,used,avail,pcent "${PATHS[@]}" | sed '1s/^Mounted on/Mounted   /'
status=$?

# The home directory's own usage. Low priority, and bounded, so that a large home directory
# never holds the login node or the next snapshot.
echo
printf '%-10s %s\n' Used Path
if read -r size path < <(nice -n 19 ionice -c 3 timeout "$DU_TIMEOUT_SECONDS" du -sh "$HOME" 2> /dev/null); then
    printf '%-10s %s\n' "$size" "$path"
else
    printf '%-10s %s\n' "?" "$HOME (du failed or took over ${DU_TIMEOUT_SECONDS}s)"
fi

exit "$status"
