"""Summarize a day of squeue snapshots, one JSON line per snapshot, for the Status page's history.

    monitor_history.py --repository DIR --ref REF --output FILE

Reads every snapshot launcher/monitor.sh recorded under monitor/ in REF of the global logs
repository at DIR (a monitor/YYYY-MM-DD day branch) and writes FILE, one line per snapshot, oldest
first. A line holds:

- `t`: when the snapshot was taken, the cluster's wall-clock time (US Eastern), from its record name
- `jobs`: how many of this user's jobs are in each state (`R`, `PD`, ...)
- `pending`: how many pending jobs wait for each reason (`Priority`, `QOSMaxMemoryPerUser`, ...)
- `partitions`: per partition, the memory (GB) and CPUs its running jobs hold (`mem`, `cpu`) and its
  pending jobs ask for (`mem_pending`, `cpu_pending`)
- `qos`: the same per QOS with a per-user cap (MaxTRESPU), with the caps (`mem_cap`, `cpu_cap`). A
  job counts under its own QOS and under its partition's, as SLURM counts it.
- `fairshare`: this user's fair-share factor, from sshare
- `priority`: the lowest, median and highest priority of the pending jobs, from sprio, and the
  median of each part it adds up to

Keys a snapshot has no data for are left out: snapshots from before monitor.sh recorded priority.txt,
fairshare.txt and limits.txt have no `qos`, `fairshare` or `priority`. A pending job array counts as
one job. The squeue table is read by its header, so older formats with fewer columns read too.

Written for the Python 3 of the login node as well as the jobs' environments, so only the standard
library, and nothing newer than Python 3.6.
"""

import argparse
import json
import re
import statistics
import subprocess
import sys

RECORD_PATTERN = re.compile(r"^monitor/(\d{2})/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})-[\w.-]+/(stdout|priority\.txt|fairshare\.txt|limits\.txt)$")
NUMBER = re.compile(r"^-?\d+(\.\d+)?$")
MEMORY = re.compile(r"^(\d+(?:\.\d+)?)([KMGTP]?)$", re.IGNORECASE)
MEMORY_SCALE_GB = {"K": 1 / (1024 * 1024), "M": 1 / 1024, "G": 1, "T": 1024, "P": 1024 * 1024}


def memory_gb(value):
    """A size as squeue and sacctmgr print it ("256G", "4000M", "512") in GB; a bare number is MB."""
    match = MEMORY.match((value or "").strip())
    if not match:
        return None
    return float(match.group(1)) * MEMORY_SCALE_GB[(match.group(2) or "M").upper()]


def tres(text):
    """The memory (GB) and CPUs of a TRES list such as "cpu=512,mem=4000G,gres/gpu=8"."""
    parts = {}
    for part in (text or "").split(","):
        name, _, value = part.partition("=")
        if name == "mem" and memory_gb(value) is not None:
            parts["mem"] = memory_gb(value)
        elif name == "cpu" and value.isdigit():
            parts["cpu"] = int(value)
    return parts


def squeue_table(text):
    """squeue's fixed-width table as a list of {header: cell}, or None when it is not one.

    The columns are the runs of positions that are not blank on any line, as the Status page reads it.
    """
    lines = [line.rstrip() for line in (text or "").split("\n") if line.strip()]
    if not lines:
        return None
    width = max(len(line) for line in lines)
    used = [False] * width
    for line in lines:
        for index, character in enumerate(line):
            if character != " ":
                used[index] = True
    spans = []
    index = 0
    while index < width:
        if not used[index]:
            index += 1
            continue
        start = index
        while index < width and used[index]:
            index += 1
        spans.append((start, index))
    labels = lines[0].split()
    if len(spans) != len(labels):
        return None
    return [{label: line[start:end].strip() for label, (start, end) in zip(labels, spans)} for line in lines[1:]]


def pipe_tables(text):
    """The "|"-separated tables of a file, blank-line separated, each as a list of {HEADER: cell}."""
    tables = []
    for block in re.split(r"\n\s*\n", text or ""):
        lines = [line for line in block.split("\n") if line.strip()]
        if len(lines) < 2 or "|" not in lines[0]:
            continue
        labels = [cell.strip().upper() for cell in lines[0].split("|")]
        rows = []
        for line in lines[1:]:
            cells = [cell.strip() for cell in line.split("|")]
            rows.append({label: cells[index] if index < len(cells) else "" for index, label in enumerate(labels)})
        tables.append(rows)
    return tables


def jobs_of(table):
    jobs = []
    for row in table:
        state = row.get("ST", row.get("STATE", ""))
        nodes = int(row["NODES"]) if row.get("NODES", "").isdigit() else 1
        cpu_cell = row.get("CPUS", row.get("CP", ""))
        cpus = int(cpu_cell) if cpu_cell.isdigit() else 0
        memory_cell = row.get("MIN_MEMORY", "")
        per_cpu = memory_cell[-1:].lower() == "c"
        memory = memory_gb(memory_cell[:-1] if per_cpu else memory_cell)
        reason_cell = next((cell for label, cell in row.items() if label.startswith("NODELIST")), "")
        reason = None
        if state == "PD" and reason_cell.startswith("("):
            reason = reason_cell.strip("()").split(",")[0].strip() or None
        jobs.append(
            {
                "partition": row.get("PARTITION", ""),
                "state": state,
                "cpu": cpus,
                "mem": None if memory is None else memory * (cpus if per_cpu else nodes),
                "qos": row.get("QOS", ""),
                "reason": reason,
            }
        )
    return jobs


def add_usage(totals, job):
    key_mem, key_cpu = ("mem", "cpu") if job["state"] == "R" else ("mem_pending", "cpu_pending")
    totals[key_mem] = totals.get(key_mem, 0) + (job["mem"] or 0)
    totals[key_cpu] = totals.get(key_cpu, 0) + job["cpu"]


def rounded(values):
    return {key: round(value, 1) if isinstance(value, float) else value for key, value in values.items()}


def summarize(time, files):
    """One snapshot's line, from its record's files ({name: text}); None when its squeue does not read."""
    table = squeue_table(files.get("stdout"))
    if table is None:
        return None
    jobs = jobs_of(table)
    line = {"t": time, "jobs": {}, "pending": {}, "partitions": {}}
    for job in jobs:
        line["jobs"][job["state"]] = line["jobs"].get(job["state"], 0) + 1
        if job["state"] == "PD":
            reason = job["reason"] or "unknown"
            line["pending"][reason] = line["pending"].get(reason, 0) + 1
        if job["state"] in ("R", "PD") and job["partition"]:
            add_usage(line["partitions"].setdefault(job["partition"], {}), job)

    limits = pipe_tables(files.get("limits.txt"))
    if limits:
        partition_qos = {}
        caps = {}
        for rows in limits:
            for row in rows:
                if row.get("PARTITION"):
                    partition_qos[row["PARTITION"]] = row.get("QOS", "")
                elif row.get("NAME"):
                    cap = tres(row.get("MAXTRESPU"))
                    if cap:
                        caps[row["NAME"]] = cap
        qos = {}
        for job in jobs:
            if job["state"] not in ("R", "PD"):
                continue
            names = {job["qos"], partition_qos.get(job["partition"], "")} & set(caps)
            for name in names:
                add_usage(qos.setdefault(name, {}), job)
        for name, totals in qos.items():
            for part, value in caps[name].items():
                totals[part + "_cap"] = value
        if qos:
            line["qos"] = {name: rounded(totals) for name, totals in sorted(qos.items())}

    for rows in pipe_tables(files.get("fairshare.txt"))[:1]:
        row = next((row for row in rows if row.get("USER")), rows[0] if rows else {})
        if NUMBER.match(row.get("FAIRSHARE", "")):
            line["fairshare"] = float(row["FAIRSHARE"])

    for rows in pipe_tables(files.get("priority.txt"))[:1]:
        priorities = [float(row["PRIORITY"]) for row in rows if NUMBER.match(row.get("PRIORITY", ""))]
        if priorities:
            priority = {"min": min(priorities), "median": statistics.median(priorities), "max": max(priorities)}
            for part in ("AGE", "FAIRSHARE", "JOBSIZE", "PARTITION_FACTOR", "QOS"):
                values = [float(row[part]) for row in rows if NUMBER.match(row.get(part, ""))]
                if values:
                    priority[part.lower()] = statistics.median(values)
            line["priority"] = rounded(priority)

    line["partitions"] = {name: rounded(totals) for name, totals in sorted(line["partitions"].items())}
    return line


def git(repository, *arguments, **keywords):
    return subprocess.run(["git", "-C", repository] + list(arguments), stdout=subprocess.PIPE, check=True, **keywords)


def read_records(repository, ref):
    """{time: {file name: text}} for every snapshot under monitor/ in REF."""
    listing = git(repository, "ls-tree", "-r", "--name-only", ref, "--", "monitor/").stdout.decode()
    wanted = {}
    for path in listing.split("\n"):
        match = RECORD_PATTERN.match(path)
        if match:
            year, month, day, hour, minute, second = match.group(2, 3, 4, 5, 6, 7)
            time = "{}-{}-{}T{}:{}:{}".format(year, month, day, hour, minute, second)
            wanted[path] = (time, match.group(8))
    if not wanted:
        return {}
    paths = sorted(wanted)
    batch = git(repository, "cat-file", "--batch", input="".join("{}:{}\n".format(ref, path) for path in paths).encode()).stdout
    records = {}
    offset = 0
    for path in paths:
        header_end = batch.index(b"\n", offset)
        header = batch[offset:header_end].split()
        offset = header_end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        time, name = wanted[path]
        records.setdefault(time, {})[name] = batch[offset : offset + size].decode("utf-8", "replace")
        offset += size + 1
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    records = read_records(arguments.repository, arguments.ref)
    lines = [summarize(time, files) for time, files in sorted(records.items())]
    lines = [line for line in lines if line is not None]
    with open(arguments.output, "w") as output:
        for line in lines:
            output.write(json.dumps(line, separators=(",", ":"), sort_keys=True) + "\n")
    print("{}: {} snapshots".format(arguments.ref, len(lines)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
