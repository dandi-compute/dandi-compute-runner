#!/bin/bash
#
# Clear the caches and logs that pile up in the home directory, part of the cluster-wide cleanup.
# Run by the crontab on the login node once a week. The home directory has a quota on both space
# and number of files (see disk.sh), and these fill it:
#
#   - Apptainer's blob cache, of which only the blobs older than a week are deleted
#   - dandi-cli's logs, one file per invocation, all of them deleted
#
# Bazel's output root fills it far faster, so clean_bazel.sh clears that every 15 minutes instead.
#
# A directory that is not there is skipped. Every step runs even when an earlier one fails, and the
# script exits non-zero when any of them did.
#
# Run on its own it records itself in the global logs repository (see launcher/record.sh).
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs clean-home -- "$0"
fi

set -uo pipefail

APPTAINER_BLOBS="$HOME/.apptainer/cache/blob/blobs/sha256"
APPTAINER_BLOB_AGE_DAYS=7
DANDI_CLI_LOGS="$HOME/.local/state/dandi-cli/log"

# delete_files DIRECTORY [FIND TESTS...] deletes the files directly in DIRECTORY that pass the
# tests, and says how many it deleted.
delete_files() {
    local directory="$1"
    shift
    if [ ! -d "$directory" ]; then
        echo "$directory: not there, skipped"
        return 0
    fi
    local count
    count=$(find "$directory" -maxdepth 1 -type f "$@" -delete -print | wc -l)
    local find_status=$?
    echo "$directory: files deleted: $count"
    return "$find_status"
}

status=0
delete_files "$APPTAINER_BLOBS" -mtime +"$APPTAINER_BLOB_AGE_DAYS" || status=1
delete_files "$DANDI_CLI_LOGS" || status=1
exit "$status"
