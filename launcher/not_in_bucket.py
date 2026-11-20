"""Summarize the mirrored blobs the bucket no longer has, for the disk usage snapshot.

simple-s3-backup's checksum job (DANDI-Verify-Checksums) finds the mirrored blobs that are no
longer in the bucket and keeps each for GRACE_DAYS (183) from when it first found it missing, then
deletes it from the mirror. Every event is appended to RECORD (`time`, `event`, `key`, `path`, `job`):
`missing` when first found, `reappeared` when back in the bucket, `deleted` when deleted from the
mirror, `gone` when gone from the mirror by other means. A blob is pending while its last event is
`missing`, and its grace period runs from the first `missing` since its last other event.

    not_in_bucket.py [--record FILE] [--grace-days DAYS] [--list-to DIR] [--cache FILE]

This prints, as the blocks of the disk usage snapshot (launcher/disk.sh):

- what the record is, how long a blob is kept, when the record last changed, and the list's length;
- per partition, how many pending blobs it holds, their size, and their share of its used space,
  which is what deleting them frees;
- how many are due to be deleted within a week, a month, three months or later, with the soonest.
  One already due goes at the next checksum run of its head.

With --list-to, the pending blobs are also written there as blobs-not-in-bucket.tsv, soonest to be
deleted first: `key`, `partition`, `size` (bytes, empty when the file cannot be read), `missing_since`
and `deletion_due`. It holds no time that changes from one snapshot to the next, so git stores it
once for as long as the record stays the same.

Each pending blob's size is read from the mirror. The sizes are cached in --cache, with the record's
size and modification time, and read again only once the record has changed.

Written for the Python 3 of the login node as well as the jobs' environments, so only the standard
library, and nothing newer than Python 3.6.
"""

import argparse
import datetime
import math
import os
import re
import sys

RECORD = "/orcd/data/dandi/001/backup/not_in_bucket.tsv"
RECORD_COLUMNS = ("time", "event", "key", "path", "job")
# Where simple-s3-backup sets how long a blob is kept, in its checkout on the cluster.
GRACE_DAYS_SOURCE = "/orcd/data/dandi/001/backup/simple-s3-backup/src/simple_s3_backup/_base/_not_in_bucket.py"
DEFAULT_GRACE_DAYS = 183
MIRROR_ROOT = "/orcd/data/dandi"
PARTITIONS = ("001", "002")
LIST_NAME = "blobs-not-in-bucket.tsv"
LIST_COLUMNS = ("key", "partition", "size", "missing_since", "deletion_due")
CACHE_COLUMNS = ("key", "partition", "size", "missing_since")
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
DAY_SECONDS = 24 * 3600
# The rows of the time left table: (label, upper bound in days, or None for no bound).
DELETION_BANDS = (
    ("due", 0),
    ("under-7-days", 7),
    ("7-to-30-days", 30),
    ("30-to-90-days", 90),
    ("over-90-days", None),
)
ISO_TIME = re.compile(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


def parse_time(text):
    """A UTC time from an ISO 8601 text, with or without its offset (UTC when none); None when it is not one."""
    match = ISO_TIME.match(text or "")
    if not match:
        return None
    moment = datetime.datetime(*(int(part) for part in match.groups()[:6]))
    offset = match.group(7)
    if offset and offset != "Z":
        sign = 1 if offset[0] == "+" else -1
        digits = offset[1:].replace(":", "")
        moment -= sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return moment


def format_time(moment):
    return moment.strftime(TIME_FORMAT) if moment else ""


def human_size(size):
    """A size the way `df -h` writes it (1024-based, one decimal below 10, rounded up)."""
    value = float(size)
    unit = "B"
    for unit in "BKMGTPE":
        if value < 1024 or unit == "E":
            break
        value /= 1024
    if unit == "B":
        return "{}B".format(int(value))
    tenths = math.ceil(value * 10) / 10
    if tenths < 10:
        return "{:.1f}{}".format(tenths, unit)
    return "{}{}".format(int(math.ceil(value)), unit)


def human_duration(seconds):
    """`2d4h`, `5h12m` or `40m`, without spaces so that it stays one cell of a table."""
    minutes = max(0, int(seconds // 60))
    days, minutes = divmod(minutes, 24 * 60)
    hours, minutes = divmod(minutes, 60)
    if days:
        return "{}d{}h".format(days, hours)
    if hours:
        return "{}h{}m".format(hours, minutes)
    return "{}m".format(minutes)


def percent(part, whole):
    if not whole:
        return "-"
    text = "{:.2f}%".format(100.0 * part / whole)
    # A share too small to show is not shown as none.
    return "<0.01%" if part and text == "0.00%" else text


def grace_days(source=GRACE_DAYS_SOURCE):
    """simple-s3-backup's GRACE_DAYS as deployed, and where the number came from."""
    try:
        with open(source) as stream:
            for line in stream:
                match = re.match(r"GRACE_DAYS\s*=\s*(\d+(?:\.\d+)?)\s*(?:#.*)?$", line.strip())
                if match:
                    return float(match.group(1)), "simple-s3-backup's GRACE_DAYS"
    except OSError:
        pass
    return float(DEFAULT_GRACE_DAYS), "assumed"


def partition_of(key, path):
    """The partition a blob is mirrored on, from its path, or else from its head as the backup splits them."""
    prefix = MIRROR_ROOT.rstrip("/") + "/"
    if path.startswith(prefix):
        partition = path[len(prefix) :].split("/", 1)[0]
        if partition in PARTITIONS:
            return partition
    head = key[len("blobs/") : len("blobs/") + 1].lower() if key.startswith("blobs/") else ""
    if head and head in "0123456789":
        return "001"
    if head and head in "abcdef":
        return "002"
    return ""


def pending_blobs(record):
    """
    The pending blobs of the record, as simple-s3-backup reads it: {key: (missing since, path)}.

    The first `missing` of a blob starts its grace period, and any other event ends it.
    """
    pending = {}
    with open(record) as stream:
        for line in stream:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != len(RECORD_COLUMNS) or fields[0] == RECORD_COLUMNS[0]:
                continue
            moment, event, key, path, _ = fields
            if event == "missing":
                since = parse_time(moment)
                if since is not None and key not in pending:
                    pending[key] = (since, path)
            else:
                pending.pop(key, None)
    return pending


def record_signature(record):
    stat = os.stat(record)
    return "{} {}".format(stat.st_size, stat.st_mtime_ns)


def read_cache(cache, signature):
    """The cached rows, when they were made from the record as it is now; else None."""
    try:
        with open(cache) as stream:
            if stream.readline().rstrip("\n") != "# " + signature:
                return None
            if stream.readline().rstrip("\n").split("\t") != list(CACHE_COLUMNS):
                return None
            return [dict(zip(CACHE_COLUMNS, line.rstrip("\n").split("\t"))) for line in stream if line.strip()]
    except OSError:
        return None


def write_cache(cache, signature, rows):
    try:
        directory = os.path.dirname(cache)
        if directory:
            os.makedirs(directory, exist_ok=True)
        partial = cache + ".partial"
        with open(partial, "w") as stream:
            stream.write("# " + signature + "\n" + "\t".join(CACHE_COLUMNS) + "\n")
            for row in rows:
                stream.write("\t".join(row[column] for column in CACHE_COLUMNS) + "\n")
        os.replace(partial, cache)
    except OSError as error:
        print("Could not cache the sizes in {}: {}".format(cache, error), file=sys.stderr)


def blob_rows(record, cache=None):
    """One row per pending blob, with its partition, size (empty when unreadable) and when it went missing."""
    signature = record_signature(record)
    rows = read_cache(cache, signature) if cache else None
    if rows is not None:
        return rows
    rows = []
    for key, (since, path) in pending_blobs(record).items():
        try:
            size = str(os.stat(path).st_size)
        except OSError:
            size = ""
        partition = partition_of(key, path)
        rows.append({"key": key, "partition": partition, "size": size, "missing_since": format_time(since)})
    if cache:
        write_cache(cache, signature, rows)
    return rows


def partition_usage(partition):
    """The used and total bytes of a partition, as df counts them; (None, None) when it cannot be read."""
    try:
        stat = os.statvfs(os.path.join(MIRROR_ROOT, partition))
    except OSError:
        return None, None
    return (stat.f_blocks - stat.f_bfree) * stat.f_frsize, stat.f_blocks * stat.f_frsize


def table(rows):
    """Rows of cells as text columns, the first left-aligned and the rest right-aligned, as df prints them."""
    widths = [max(len(row[index]) for row in rows) for index in range(len(rows[0]))]
    lines = []
    for row in rows:
        cells = [row[0].ljust(widths[0])] + [cell.rjust(width) for cell, width in zip(row[1:], widths[1:])]
        lines.append(" ".join(cells).rstrip())
    return "\n".join(lines)


def summary_blocks(rows, days, source, updated, now, usage=partition_usage):
    """The blocks the disk snapshot shows: what this is, the share of each partition, the time left."""
    grace = datetime.timedelta(days=days)
    about = "\n".join(
        [
            "Not in bucket: mirrored blobs that are no longer in the bucket",
            "Deleted from the mirror: {:g} days after first found missing ({})".format(days, source),
            "Record updated: {}".format(format_time(updated)),
            "List: {} ({} blobs)".format(LIST_NAME, len(rows)),
        ]
    )

    share = [["Mirror", "Blobs", "Size", "Used", "Share%"]]
    total_blobs = total_bytes = total_used = 0
    used_known = True
    for partition in PARTITIONS:
        mine = [row for row in rows if row["partition"] == partition]
        size = sum(int(row["size"]) for row in mine if row["size"])
        used, _ = usage(partition)
        total_blobs += len(mine)
        total_bytes += size
        if used is None:
            used_known = False
        else:
            total_used += used
        share.append(
            [
                os.path.join(MIRROR_ROOT, partition),
                str(len(mine)),
                human_size(size),
                human_size(used) if used is not None else "-",
                percent(size, used) if used is not None else "-",
            ]
        )
    share.append(
        [
            "all",
            str(total_blobs),
            human_size(total_bytes),
            human_size(total_used) if used_known else "-",
            percent(total_bytes, total_used) if used_known else "-",
        ]
    )

    left = []
    for row in rows:
        since = parse_time(row["missing_since"])
        if since is not None:
            left.append(((since + grace - now).total_seconds(), row))
    remaining = [["Deletion", "Blobs", "Size", "Soonest", "SoonestDue"]]
    lower = float("-inf")
    for label, upper in DELETION_BANDS:
        upper_seconds = float("inf") if upper is None else upper * DAY_SECONDS
        band = [(seconds, row) for seconds, row in left if lower <= seconds < upper_seconds]
        soonest = min((seconds for seconds, _ in band), default=None)
        remaining.append(
            [
                label,
                str(len(band)),
                human_size(sum(int(row["size"]) for _, row in band if row["size"])),
                human_duration(soonest) if soonest is not None and soonest > 0 else "-",
                format_time(now + datetime.timedelta(seconds=soonest)) if soonest is not None else "-",
            ]
        )
        lower = upper_seconds
    return [about, table(share), table(remaining)]


def list_text(rows, days):
    grace = datetime.timedelta(days=days)
    lines = ["\t".join(LIST_COLUMNS)]
    keyed = []
    for row in rows:
        since = parse_time(row["missing_since"])
        due = format_time(since + grace) if since is not None else ""
        keyed.append(((due or "~", row["key"]), [row["key"], row["partition"], row["size"], row["missing_since"], due]))
    lines.extend("\t".join(cells) for _, cells in sorted(keyed))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--record", default=RECORD, help="simple-s3-backup's record of blobs not in the bucket")
    parser.add_argument("--grace-days", type=float, help="days a blob is kept (default: simple-s3-backup's, else 183)")
    parser.add_argument("--list-to", default="", help="a directory to write the list of pending blobs into")
    parser.add_argument("--cache", default="", help="a file to cache the pending blobs' sizes in")
    arguments = parser.parse_args(argv)

    if arguments.grace_days is not None:
        days, source = arguments.grace_days, "given"
    else:
        days, source = grace_days()
    try:
        rows = blob_rows(arguments.record, arguments.cache or None)
        modified = os.stat(arguments.record).st_mtime
    except OSError:
        print("Not in bucket: no record yet ({})".format(arguments.record))
        return 0
    updated = datetime.datetime.fromtimestamp(int(modified), datetime.timezone.utc).replace(tzinfo=None)
    print("\n\n".join(summary_blocks(rows, days, source, updated, utc_now())))
    if arguments.list_to:
        try:
            with open(os.path.join(arguments.list_to, LIST_NAME), "w") as stream:
                stream.write(list_text(rows, days))
        except OSError as error:
            print("Could not write {} to {}: {}".format(LIST_NAME, arguments.list_to, error), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
