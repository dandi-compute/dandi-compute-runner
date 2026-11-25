#!/bin/bash
#
# Record a snapshot of this user's SLURM jobs in the global logs repository, under monitor/ on
# the day's branch. Run by the crontab on the login node every 5 minutes; it is a script rather
# than a crontab line because cron cannot take the `%` in squeue's format. `--me` makes every job
# this user's, so the format leaves out the USER column. squeue cuts every field to its width, and
# a pending job array's ID carries its task range and throttle (28331361_[5-1000%10]), so JOBID is
# kept wide enough for one. PRIORITY is the job's priority, and QOS the quality of service whose
# limits hold it when its reason is one of the QOSMax... ones.
#
# Beside the output, in the record's own directory, go three tables the Status page of
# dandi-compute-page reads. Each is "|"-separated with a header line, and a table that could not
# be made is left out, with its command's error in {name}.stderr.
#   priority.txt  sprio for this user's pending jobs: the weighted parts their priority adds up to
#   fairshare.txt sshare for this user: shares, usage and the fair-share factor
#   limits.txt    the limits of the partitions the jobs run on and of every QOS this user's jobs
#                 can run under, from scontrol and sacctmgr. They seldom change, so they are asked
#                 for at most once an hour and kept in between.
# Only this user's own jobs and shares are recorded; the limits are the cluster's configuration.
#
# Run on its own it records itself; record.sh runs it again, recorded, for the snapshot.
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh monitor squeue -- "$0"
fi

set -uo pipefail

PARTITIONS=(mit_normal mit_normal_gpu mit_preemptable)
LIMITS_CACHE=${MONITOR_LIMITS_CACHE:-/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs/untracked/monitor-limits.txt}
LIMITS_MAX_AGE_MINUTES=60
ME="${USER:-$(id -un)}"

squeue --me --format="%.30i %15P %40j %.2t %.10M %.6D %.2C %.10m %.10Q %10q %30R"
status=$?

# DANDI_COMPUTE_RECORD_DIRECTORY is the record's own directory (see launcher/record.sh). Without
# it, as when run by hand under record.sh's DANDI_COMPUTE_RECORDED, only the queue is shown.
RECORD="${DANDI_COMPUTE_RECORD_DIRECTORY:-}"
[ -n "$RECORD" ] && [ -d "$RECORD" ] || exit "$status"

# Runs a command that prints one table and writes it to {name}.txt. A command that fails, or
# prints only its header, leaves no table, and what it wrote to stderr goes to {name}.stderr.
table() {
    local name="$1"
    shift
    local output errors
    errors=$(mktemp)
    if output=$("$@" 2> "$errors") && [ "$(printf '%s\n' "$output" | grep -c .)" -gt 1 ]; then
        printf '%s\n' "$output" > "$RECORD/$name.txt"
    fi
    [ -s "$errors" ] && cp "$errors" "$RECORD/$name.stderr"
    rm -f "$errors"
}

# sprio prints a row per partition a job may run in. Its own header is made of the format's
# widths, so it is left out for one in the same "|"-separated form as the rows.
pending_priority() {
    local rows
    rows=$(sprio -h -u "$ME" -o "%i|%r|%Y|%A|%F|%J|%P|%Q|%N") || return
    echo "JOBID|PARTITION|PRIORITY|AGE|FAIRSHARE|JOBSIZE|PARTITION_FACTOR|QOS|NICE"
    printf '%s\n' "$rows" | tr -d ' '
}
table priority pending_priority

table fairshare sshare -U -P -o Account,User,RawShares,NormShares,RawUsage,NormUsage,EffectvUsage,FairShare,LevelFS

# The partitions' own limits, and the QOS of the partitions and of this user's associations.
cluster_limits() {
    local partition line qos_names
    echo "PARTITION|QOS|MAXTIME|MAXNODES|MAXMEMPERNODE|MAXCPUSPERNODE|DEFMEMPERCPU|TRES"
    qos_names=()
    for partition in "${PARTITIONS[@]}"; do
        line=$(scontrol -o show partition "$partition" 2> /dev/null) || continue
        local -A field=()
        local pair
        for pair in $line; do
            field["${pair%%=*}"]="${pair#*=}"
        done
        echo "${partition}|${field[QoS]:-}|${field[MaxTime]:-}|${field[MaxNodes]:-}|${field[MaxMemPerNode]:-}|${field[MaxCPUsPerNode]:-}|${field[DefMemPerCPU]:-}|${field[TRES]:-}"
        [ -n "${field[QoS]:-}" ] && [ "${field[QoS]}" != "N/A" ] && qos_names+=("${field[QoS]}")
        unset field
    done
    local association
    association=$(sacctmgr -nP show association where user="$ME" format=QOS 2> /dev/null | tr ',' '\n')
    mapfile -t -O "${#qos_names[@]}" qos_names < <(printf '%s\n' "$association" | grep .)
    [ "${#qos_names[@]}" -gt 0 ] || return 0
    local names
    names=$(printf '%s\n' "${qos_names[@]}" | sort -u | paste -sd,)
    echo
    sacctmgr -P show qos where name="$names" \
        format=Name,Priority,MaxTRESPU,MaxJobsPU,MaxSubmitPU,MaxTRES,MaxWall,GrpTRES,GrpJobs
}

refresh_limits() {
    [ -s "$LIMITS_CACHE" ] && [ -z "$(find "$LIMITS_CACHE" -mmin +"$LIMITS_MAX_AGE_MINUTES" 2> /dev/null)" ] && return 0
    local fresh
    fresh=$(cluster_limits) || return 0
    [ "$(printf '%s\n' "$fresh" | grep -c .)" -gt 1 ] || return 0
    mkdir -p "$(dirname "$LIMITS_CACHE")" && printf '%s\n' "$fresh" > "$LIMITS_CACHE"
}
refresh_limits 2> /dev/null
# Git keeps one copy of the file for as long as it does not change.
[ -s "$LIMITS_CACHE" ] && cp "$LIMITS_CACHE" "$RECORD/limits.txt"

exit "$status"
