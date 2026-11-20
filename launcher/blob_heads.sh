#!/bin/bash
#
# Measure how much of each blob partition (001, 002) every blob head takes, for the disk usage
# snapshots (launcher/disk.sh) and so the Status page of dandi-compute-page. The blob mirror is
# split across the partitions by head, the first hex digit of the content ID (see
# BLOBS_HEAD_TO_PARTITION in simple-s3-backup), so these figures show what moving a head from one
# partition to the other would shift. A head can have blobs on both partitions, left over from an
# earlier split, so every head is measured on each.
#
# Run by the crontab on the login node once a day. Walking hundreds of thousands of blobs and their
# checksum files takes too long for every disk snapshot, so the result is written to $OUTPUT for
# disk.sh to show until the next measurement. Usage is the space allocated to the files (blobs
# and the checksum files beside them), so it adds up the way `df` counts it.
#
# Run on its own it records itself in the global logs repository (see launcher/record.sh).
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs blob-heads -- "$0"
fi

set -uo pipefail

PARTITIONS=(001 002)
HEADS=(0 1 2 3 4 5 6 7 8 9 a b c d e f)
OUTPUT=/orcd/data/dandi/001/dandi-compute/disk/blob_heads.txt
# Per head and partition, so one slow walk costs only its own figure.
HEAD_TIMEOUT_SECONDS=1800

mkdir -p "$(dirname "$OUTPUT")" || exit 1
temporary=$(mktemp "$OUTPUT.XXXXXX") || exit 1
trap 'rm -f "$temporary"' EXIT

status=0
{
    echo "Blob heads, measured $(date '+%Y-%m-%d %H:%M %Z')"
    printf '%-4s %-9s %16s %10s\n' Head Partition Bytes Files
    for partition in "${PARTITIONS[@]}"; do
        blobs="/orcd/data/dandi/$partition/s3dandiarchive/blobs"
        for head in "${HEADS[@]}"; do
            # The blob directories of a head, blobs/{id[0:3]}/, all start with it.
            directories=("$blobs/$head"??)
            [ -d "${directories[0]}" ] || continue
            # %b is in 512-byte blocks. A file the backup removes mid-walk makes find complain, which
            # does not spoil the figure; only a walk cut short by the timeout does.
            result=$(nice -n 19 ionice -c 3 timeout "$HEAD_TIMEOUT_SECONDS" \
                find "${directories[@]}" -type f -printf '%b\n' 2> /dev/null |
                awk '{ files++; blocks += $1 } END { printf "%.0f %d\n", blocks * 512, files }')
            if [ "$?" -ne 124 ]; then
                read -r bytes files <<< "$result"
            else
                bytes="?"
                files="?"
                status=1
            fi
            printf '%-4s %-9s %16s %10s\n' "$head" "$partition" "$bytes" "$files"
        done
    done
} > "$temporary"

cat "$temporary"
chmod a+r "$temporary"
mv "$temporary" "$OUTPUT" && trap - EXIT
exit "$status"
