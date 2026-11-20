"""Track the blobs the cluster's mirror still holds after the DANDI bucket deleted them.

The blob backup copies with `s5cmd cp`, which never deletes, so a blob DANDI deletes from the
bucket stays in the mirror for good. The bucket is versioned: deleting a blob leaves a delete
marker, and its lifecycle rule keeps the deleted version for a number of days (30 for blobs/)
before deleting it for good. Until then DANDI can still restore the blob from the bucket; after
that the mirror holds the only copy.

    deleted_blobs.py scan [--state DIR] [--mirror-root DIR] [--workers N]
    deleted_blobs.py summary [--state DIR] [--list-to DIR]

`scan` lists every version of blobs/ in the bucket, anonymously, and every blob in both
partitions of the mirror, and writes to the state directory the blobs that are mirrored but no
longer in the bucket (deleted-blobs-{time}.tsv) and the totals of the mirror (summary.json),
which names that list. Run daily as a job (launcher/backup.sh deleted).

`summary` prints those totals as the blocks of the disk usage snapshot (launcher/disk.sh): the
time of the last scan, then per partition how much of the mirror is no longer in the bucket,
then how long the deleted blobs have left in the bucket. With --list-to it also copies the list
there as deleted-blobs.tsv, so the snapshot carries it.

The list has one row per blob, soonest to leave the bucket first:

    key           the blob's key in the bucket, blobs/{id[0:3]}/{id[3:6]}/{id}
    partition     the partition of the mirror that holds it (001 or 002)
    size          its size in the mirror, in bytes
    first_missing when a scan first found it missing from the bucket
    deleted       when the bucket deleted it (its delete marker), when known
    expires       when the bucket's lifecycle deletes its last version for good, when known
    state         `restorable` while the bucket still has a version of it, else `expired`

The bucket forgets a deletion once the version is gone, so `deleted` and `expires` are kept from
earlier scans. A blob that was already gone from the bucket when tracking began has neither.

Written for the Python 3 of the login node as well as the jobs' environments, so only the standard
library, and nothing newer than Python 3.6.
"""

import argparse
import concurrent.futures
import datetime
import json
import math
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree

BUCKET_URL = "https://dandiarchive.s3.amazonaws.com"
S3_NAMESPACE = "{http://s3.amazonaws.com/doc/2006-03-01/}"
STATE_DIRECTORY = "/orcd/data/dandi/001/backup/deleted_blobs"
MIRROR_ROOT = "/orcd/data/dandi"
PARTITIONS = ("001", "002")
HEADS = "0123456789abcdef"
# What the bucket's lifecycle rule for blobs/ said when this was written; used when it cannot be read.
DEFAULT_RETENTION_DAYS = 30
LISTING_ATTEMPTS = 5
SUMMARY_FILE = "summary.json"
LIST_FILE_PREFIX = "deleted-blobs-"
SNAPSHOT_LIST_NAME = "deleted-blobs.tsv"
LIST_COLUMNS = ("key", "partition", "size", "first_missing", "deleted", "expires", "state")
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
# The rows of the time remaining table: (label, upper bound in days).
REMAINING_BANDS = (("under-1-day", 1), ("1-to-7-days", 7), ("over-7-days", None))


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


def format_time(moment):
    return moment.strftime(TIME_FORMAT) if moment else ""


def parse_time(text):
    """A time written by this script or by S3 (with milliseconds), or None for an empty string."""
    if not text:
        return None
    for pattern in (TIME_FORMAT, "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.datetime.strptime(text, pattern).replace(microsecond=0)
        except ValueError:
            continue
    return None


def expiry(deleted, retention_days):
    """When S3 deletes a version made noncurrent at `deleted`: that many days on, at the next midnight UTC."""
    moment = deleted + datetime.timedelta(days=retention_days)
    midnight = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight if midnight == moment else midnight + datetime.timedelta(days=1)


def human_size(size):
    """A size the way `df -h` writes it (1024-based, one decimal below 10)."""
    units = "BKMGTPE"
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return "{}B".format(int(value))
    if value < 10:
        return "{:.1f}{}".format(math.ceil(value * 10) / 10, unit)
    return "{}{}".format(int(math.ceil(value)), unit)


def human_duration(seconds):
    """`2d4h`, `5h12m` or `40m`: the time left, without spaces so it stays one cell of a table."""
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
    value = 100.0 * part / whole
    text = "{:.2f}%".format(value)
    # A share too small to show is not shown as none.
    return "<0.01%" if part and text == "0.00%" else text


# --- the bucket ------------------------------------------------------------------------------


def get_xml(url):
    for attempt in range(1, LISTING_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return xml.etree.ElementTree.fromstring(response.read())
        except (urllib.error.URLError, OSError, xml.etree.ElementTree.ParseError) as error:
            if attempt == LISTING_ATTEMPTS:
                raise
            print("Reading {} failed ({}); trying again.".format(url, error), flush=True)
            time.sleep(2**attempt)


def retention_days():
    """The NoncurrentDays of the bucket's lifecycle rule for blobs/, and where that number came from."""
    try:
        root = get_xml(BUCKET_URL + "/?lifecycle")
    except (urllib.error.URLError, OSError, xml.etree.ElementTree.ParseError) as error:
        print("Could not read the bucket's lifecycle ({}); assuming {} days.".format(error, DEFAULT_RETENTION_DAYS))
        return DEFAULT_RETENTION_DAYS, "assumed"
    for rule in root.iter(S3_NAMESPACE + "Rule"):
        prefix = rule.findtext(S3_NAMESPACE + "Filter/" + S3_NAMESPACE + "Prefix")
        if prefix is None:
            prefix = rule.findtext(S3_NAMESPACE + "Prefix") or ""
        days = rule.findtext(S3_NAMESPACE + "NoncurrentVersionExpiration/" + S3_NAMESPACE + "NoncurrentDays")
        if rule.findtext(S3_NAMESPACE + "Status") == "Enabled" and "blobs/".startswith(prefix) and days:
            return int(days), "lifecycle"
    print("The bucket's lifecycle has no rule expiring deleted blobs; assuming {} days.".format(DEFAULT_RETENTION_DAYS))
    return DEFAULT_RETENTION_DAYS, "assumed"


def list_bucket_head(head):
    """
    Every key under blobs/{head} as the bucket has it now.

    Returns (live, deleted): the size of each key that is in the bucket, and for each key whose
    newest version is a delete marker, (when it was deleted, whether a version of it is left).
    """
    live = {}
    deleted = {}
    parameters = {"versions": "", "prefix": "blobs/" + head, "max-keys": "1000"}
    while True:
        root = get_xml(BUCKET_URL + "/?" + urllib.parse.urlencode(parameters))
        for element in root:
            kind = element.tag[len(S3_NAMESPACE) :]
            if kind not in ("Version", "DeleteMarker"):
                continue
            key = element.findtext(S3_NAMESPACE + "Key")
            latest = element.findtext(S3_NAMESPACE + "IsLatest") == "true"
            if kind == "DeleteMarker" and latest:
                deleted[key] = (parse_time(element.findtext(S3_NAMESPACE + "LastModified")), False)
            elif kind == "Version" and latest:
                live[key] = int(element.findtext(S3_NAMESPACE + "Size"))
            elif kind == "Version" and key in deleted:
                # Versions follow their key's delete marker, newest first.
                deleted[key] = (deleted[key][0], True)
        if root.findtext(S3_NAMESPACE + "IsTruncated") != "true":
            return live, deleted
        parameters["key-marker"] = root.findtext(S3_NAMESPACE + "NextKeyMarker")
        parameters["version-id-marker"] = root.findtext(S3_NAMESPACE + "NextVersionIdMarker")


# --- the mirror ------------------------------------------------------------------------------


def mirrored_blobs(blobs_directory, head):
    """(key, path) of every blob of `head` in one partition's blobs/ directory, without the cached checksums."""
    try:
        prefixes = sorted(name for name in os.listdir(blobs_directory) if name.startswith(head))
    except FileNotFoundError:
        return
    for prefix in prefixes:
        for directory, _, file_names in os.walk(os.path.join(blobs_directory, prefix)):
            for file_name in file_names:
                # Blob IDs never start with a dot; the checksums verify-checksums caches beside them do.
                if file_name.startswith("."):
                    continue
                path = os.path.join(directory, file_name)
                yield "blobs/" + os.path.relpath(path, blobs_directory).replace(os.sep, "/"), path


def scan_head(head, mirror_root, retention, previous, now):
    """The totals of one head per partition, and the rows of its mirrored blobs no longer in the bucket."""
    started = time.time()
    live, deleted = list_bucket_head(head)
    listed = time.time()
    totals = {partition: {"mirrored": 0, "mirrored_bytes": 0} for partition in PARTITIONS}
    rows = []
    for partition in PARTITIONS:
        blobs_directory = os.path.join(mirror_root, partition, "s3dandiarchive", "blobs")
        for key, path in mirrored_blobs(blobs_directory, head):
            size = live.get(key)
            try:
                stat = os.stat(path) if size is None else None
            except OSError:
                continue
            totals[partition]["mirrored"] += 1
            if size is not None:
                totals[partition]["mirrored_bytes"] += size
                continue
            totals[partition]["mirrored_bytes"] += stat.st_size
            # Copied since the listing began, so from an object the listing may have passed already.
            if stat.st_ctime >= started:
                continue
            rows.append(deleted_row(key, partition, stat.st_size, deleted.get(key), retention, previous.get(key), now))
    print(
        "Head {}: {} in the bucket, {} deleted there within {} days; {} mirrored, {} of them no longer in the bucket "
        "(listed in {:.0f} s, walked in {:.0f} s)".format(
            head,
            len(live),
            len(deleted),
            retention,
            sum(total["mirrored"] for total in totals.values()),
            len(rows),
            listed - started,
            time.time() - listed,
        ),
        flush=True,
    )
    return totals, rows


def deleted_row(key, partition, size, marker, retention, previous, now):
    previous = previous or {}
    if marker is not None:
        deleted_at, version_left = marker
        expires_at = expiry(deleted_at, retention) if deleted_at else None
        state = "restorable" if version_left else "expired"
    else:
        # Not in the bucket at all: its last version is gone, and what earlier scans saw is all there is.
        deleted_at = parse_time(previous.get("deleted", ""))
        expires_at = parse_time(previous.get("expires", ""))
        state = "expired"
    return {
        "key": key,
        "partition": partition,
        "size": str(size),
        "first_missing": previous.get("first_missing") or format_time(now),
        "deleted": format_time(deleted_at),
        "expires": format_time(expires_at),
        "state": state,
    }


# --- the state directory ---------------------------------------------------------------------


def read_summary(state_directory):
    try:
        with open(os.path.join(state_directory, SUMMARY_FILE)) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None


def read_list(path):
    rows = []
    try:
        with open(path) as stream:
            header = stream.readline().rstrip("\n").split("\t")
            for line in stream:
                fields = line.rstrip("\n").split("\t")
                if len(fields) == len(header):
                    rows.append(dict(zip(header, fields)))
    except OSError:
        pass
    return rows


def list_path(state_directory, summary):
    return os.path.join(state_directory, summary["list"]) if summary and summary.get("list") else None


def write_atomically(path, text):
    partial = path + ".partial"
    with open(partial, "w") as stream:
        stream.write(text)
    os.replace(partial, path)


def sort_key(row):
    # Restorable blobs first, soonest to expire first; then the rest by when they were deleted.
    return (row["state"] != "restorable", row["expires"] or "~", row["deleted"] or "~", row["key"])


def scan(arguments):
    state_directory = arguments.state
    os.makedirs(state_directory, exist_ok=True)
    now = utc_now()
    began = time.time()
    retention, retention_source = retention_days()
    previous_summary = read_summary(state_directory)
    previous_path = list_path(state_directory, previous_summary)
    previous = {row["key"]: row for row in read_list(previous_path)} if previous_path else {}
    print(
        "Scanning the mirror under {} against {}/blobs/ ({} days kept after deletion, {}); "
        "{} blobs tracked so far".format(arguments.mirror_root, BUCKET_URL, retention, retention_source, len(previous)),
        flush=True,
    )

    totals = {partition: {"mirrored": 0, "mirrored_bytes": 0} for partition in PARTITIONS}
    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        futures = [executor.submit(scan_head, head, arguments.mirror_root, retention, previous, now) for head in HEADS]
        # A head that cannot be listed or walked fails the whole scan, so the last complete one stays.
        for future in futures:
            head_totals, head_rows = future.result()
            for partition, total in head_totals.items():
                for name, value in total.items():
                    totals[partition][name] += value
            rows.extend(head_rows)

    rows.sort(key=sort_key)
    list_name = "{}{}.tsv".format(LIST_FILE_PREFIX, now.strftime("%Y%m%dT%H%M%SZ"))
    lines = ["\t".join(LIST_COLUMNS)] + ["\t".join(row[column] for column in LIST_COLUMNS) for row in rows]
    write_atomically(os.path.join(state_directory, list_name), "\n".join(lines) + "\n")
    for partition in PARTITIONS:
        mine = [row for row in rows if row["partition"] == partition]
        restorable = [row for row in mine if row["state"] == "restorable"]
        totals[partition].update(
            {
                "deleted": len(mine),
                "deleted_bytes": sum(int(row["size"]) for row in mine),
                "restorable": len(restorable),
                "restorable_bytes": sum(int(row["size"]) for row in restorable),
            }
        )
    summary = {
        "checked": format_time(now),
        "seconds": int(time.time() - began),
        "retention_days": retention,
        "retention_source": retention_source,
        "list": list_name,
        "partitions": totals,
    }
    # The summary names its list, so whoever reads the two never pairs a summary with another scan's list.
    write_atomically(os.path.join(state_directory, SUMMARY_FILE), json.dumps(summary, indent=2) + "\n")
    for name in os.listdir(state_directory):
        if name.startswith(LIST_FILE_PREFIX) and name.endswith(".tsv") and name != list_name:
            os.remove(os.path.join(state_directory, name))

    newly = sum(1 for row in rows if row["key"] not in previous)
    found = {row["key"] for row in rows}
    gone = sum(1 for key in previous if key not in found)
    print("\n" + "\n\n".join(summary_blocks(summary, rows, now)))
    print("\n{} newly missing from the bucket, {} no longer in the mirror or back in the bucket.".format(newly, gone))
    print("Wrote {} and {} in {}.".format(list_name, SUMMARY_FILE, state_directory))
    return 0


# --- the summary -----------------------------------------------------------------------------


def table(rows):
    """Rows of cells as text columns, the first left-aligned and the rest right-aligned, as df prints them."""
    widths = [max(len(row[index]) for row in rows) for index in range(len(rows[0]))]
    lines = []
    for row in rows:
        cells = [row[0].ljust(widths[0])] + [cell.rjust(width) for cell, width in zip(row[1:], widths[1:])]
        lines.append(" ".join(cells).rstrip())
    return "\n".join(lines)


def summary_blocks(summary, rows, now):
    """The blocks the disk snapshot shows: the scan, the share of the mirror, and the time left."""
    retention = summary["retention_days"]
    checked = parse_time(summary["checked"])
    age = human_duration((now - checked).total_seconds()) if checked else "?"
    source = "the bucket's lifecycle rule" if summary.get("retention_source") == "lifecycle" else "assumed"
    about = "\n".join(
        [
            "Deleted blobs: mirrored blobs that are no longer in the bucket",
            "Checked: {} ({} ago)".format(summary["checked"], age),
            "Kept in the bucket after deletion: {} days ({})".format(retention, source),
            "List: {} ({} blobs)".format(SNAPSHOT_LIST_NAME, len(rows)),
        ]
    )

    partitions = summary["partitions"]
    share = [["Mirror", "Blobs", "Deleted", "Deleted%", "Size", "DeletedSize", "DeletedSize%", "Restorable"]]
    for name in PARTITIONS + ("all",):
        totals = partitions.get(name)
        if name == "all":
            totals = {
                field: sum(partitions[partition].get(field, 0) for partition in PARTITIONS)
                for field in ("mirrored", "mirrored_bytes", "deleted", "deleted_bytes", "restorable")
            }
        if totals is None:
            continue
        share.append(
            [
                os.path.join(MIRROR_ROOT, name) if name != "all" else "all",
                str(totals["mirrored"]),
                str(totals["deleted"]),
                percent(totals["deleted"], totals["mirrored"]),
                human_size(totals["mirrored_bytes"]),
                human_size(totals["deleted_bytes"]),
                percent(totals["deleted_bytes"], totals["mirrored_bytes"]),
                str(totals["restorable"]),
            ]
        )

    remaining = [["Remaining", "Blobs", "Size", "Soonest", "SoonestExpiry"]]
    restorable = [row for row in rows if row["state"] == "restorable" and parse_time(row["expires"])]
    left = [(parse_time(row["expires"]) - now).total_seconds() for row in restorable]
    lower = float("-inf")
    for label, upper in REMAINING_BANDS:
        upper_seconds = upper * 86400 if upper else float("inf")
        band = [(seconds, row) for seconds, row in zip(left, restorable) if lower <= seconds < upper_seconds]
        soonest = min((seconds for seconds, _ in band), default=None)
        remaining.append(
            [
                label,
                str(len(band)),
                human_size(sum(int(row["size"]) for _, row in band)),
                human_duration(soonest) if soonest is not None else "-",
                format_time(now + datetime.timedelta(seconds=soonest)) if soonest is not None else "-",
            ]
        )
        lower = upper_seconds
    expired = [row for row in rows if row["state"] != "restorable" or not parse_time(row["expires"])]
    expired_size = human_size(sum(int(row["size"]) for row in expired))
    remaining.append(["expired", str(len(expired)), expired_size, "-", "-"])
    return [about, table(share), table(remaining)]


def summary(arguments):
    state = read_summary(arguments.state)
    path = list_path(arguments.state, state)
    if state is None or path is None or not os.path.exists(path):
        print("Deleted blobs: not checked yet (no scan in {})".format(arguments.state))
        return 0
    rows = read_list(path)
    print("\n\n".join(summary_blocks(state, rows, utc_now())))
    if arguments.list_to:
        try:
            shutil.copyfile(path, os.path.join(arguments.list_to, SNAPSHOT_LIST_NAME))
        except OSError as error:
            print("Could not copy {} to {}: {}".format(path, arguments.list_to, error), file=sys.stderr)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command")
    scan_parser = commands.add_parser("scan", help="compare the mirror with the bucket and write the list")
    scan_parser.add_argument("--state", default=STATE_DIRECTORY, help="where the list and its summary are kept")
    scan_parser.add_argument("--mirror-root", default=MIRROR_ROOT, help="where the partitions are mounted")
    scan_parser.add_argument("--workers", type=int, default=4, help="how many heads are scanned at once")
    summary_parser = commands.add_parser("summary", help="print the last scan's summary for the disk snapshot")
    summary_parser.add_argument("--state", default=STATE_DIRECTORY, help="where the list and its summary are kept")
    summary_parser.add_argument("--list-to", default="", help="a directory to copy the list into")
    arguments = parser.parse_args(argv)
    if arguments.command == "scan":
        return scan(arguments)
    if arguments.command == "summary":
        return summary(arguments)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
