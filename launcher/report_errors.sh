#!/bin/bash
#
# report_errors.sh - record what is going wrong on the cluster, for the Report errors workflow.
#
# Usage: report_errors.sh SECTION
#
# Each section is recorded on its own in the global logs repository, under errors/ on the day's
# errors/YYYY-MM-DD branch (see launcher/record.sh), so the report can be read from GitHub
# without a shell on the cluster.
#
#   backup-checkout     the simple-s3-backup checkout the backup jobs run from, compared with
#                       GitHub, and the crontab installed on the login node
#   backup-environment  the setup of the blob backup job replayed in cron's environment, the lock
#                       files, the blob mirror's directories and access to the S3 bucket
#   backup-reproduce    one task of the blob backup submitted the way cron does, traced, with its
#                       output kept (only when REPRODUCE is true)
#   slurm-failures      every job of this user that did not complete in the last DAYS days, grouped
#                       by name and state, and the errors their Nextflow tasks ended with
#   missing-blobs       job capsules prepared on the cluster whose input blob is not in the mirror
#   home-usage          the home directory's quota, and which of its directories hold the most files
#                       and space, since every job of this user writes there
#   diagnosis           what the sections above point to
#
# The sections share what they find through files in ERRORS_STATE_DIRECTORY, which diagnosis reads,
# so they run in this order in one job. Every section exits 0 unless it could not run at all: a
# problem it finds is part of its report, not a failure of the report.
#
# Run on its own it records itself (see launcher/record.sh), from wherever this copy of the script
# is, since the workflow runs the copy of the commit it was started for.
RECORD_SCRIPT=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    if [ -x "$RECORD_SCRIPT" ]; then
        exec "$RECORD_SCRIPT" errors "${1:-unknown}" -- bash "$(readlink -f "$0")" "$@"
    fi
    echo "record.sh not found, reporting unrecorded" >&2
fi

set -uo pipefail

SECTION="${1:-}"
BACKUP_DIRECTORY=/orcd/data/dandi/001/backup
BACKUP_CHECKOUT="$BACKUP_DIRECTORY/simple-s3-backup"
BACKUP_REPOSITORY_URL=https://github.com/dandi/simple-s3-backup
BLOB_SCRIPT="$BACKUP_CHECKOUT/scripts/backup_blobs_batch_deployment.sh"
BACKUP_LOG_DIRECTORY="$BACKUP_DIRECTORY/logs"
PARTITIONS=(001 002)
BASE_DIRECTORY=/orcd/data/dandi/001/dandi-compute
RUNNER_CHECKOUT="$BASE_DIRECTORY/dandi-compute-runner"
LOGIN_HOST=login007
# The runner's temporary directory lasts for the job, so every section of one run shares it.
STATE_DIRECTORY="${ERRORS_STATE_DIRECTORY:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dandi-compute-errors}"
DAYS="${DAYS:-7}"
REPRODUCE="${REPRODUCE:-false}"
REPRODUCE_TASK="${REPRODUCE_TASK:-4}"
REPRODUCE_WAIT_SECONDS="${REPRODUCE_WAIT_SECONDS:-600}"
COMMAND_TIMEOUT=300
MAX_OUTPUT_BYTES=200000
MAX_WORK_DIRECTORIES=500
COUNT_TIMEOUT=300
USER_NAME=$(id -un)
# What a backup job submitted by cron sees: cron's own few variables and nothing of this job's.
# The records are public, so they name the runner's user and home directory only by role.
CRON_ENVIRONMENT=(env -i "HOME=$HOME" "LOGNAME=$USER_NAME" "USER=$USER_NAME" PATH=/usr/bin:/bin SHELL=/bin/sh)

mkdir -p "$STATE_DIRECTORY"
# The records are public: the home directory reads as ~ and the user name as <user>.
mask() { sed -e "s#${HOME}#~#g" -e "s#\b${USER_NAME}\b#<user>#g"; }
fact() { printf '%s\n' "$2" > "$STATE_DIRECTORY/$1"; }
read_fact() { if [ -s "$STATE_DIRECTORY/$1" ]; then cat "$STATE_DIRECTORY/$1"; else echo "${2-unknown}"; fi; }

# show TITLE COMMAND... prints the command, its output (stdout and stderr together, cut at
# MAX_OUTPUT_BYTES) and its exit status, giving up on it after COMMAND_TIMEOUT seconds.
show() {
    local title="$1" status
    shift
    echo
    echo "### $title"
    printf '$'
    printf ' %q' "$@"
    echo
    timeout "$COMMAND_TIMEOUT" "$@" 2>&1 | head -c "$MAX_OUTPUT_BYTES"
    status=${PIPESTATUS[0]}
    [ "$status" -eq 124 ] && echo "(timed out after ${COMMAND_TIMEOUT} seconds)"
    echo "[exit $status]"
}

# Error messages with what varies between occurrences (content IDs, paths, numbers) masked, so
# the same error from different jobs reads the same.
normalize() {
    sed -E \
        -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' \
        -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g' \
        -e 's#/[^[:space:]:,'"'"'"]+#<path>#g' \
        -e 's/[0-9]+/<n>/g' | cut -c1-300
}

# The line of FILE that best says why it failed: the last error-like line, or else its last line.
error_line() {
    local line
    line=$(grep -E 'Error|error|ERROR|Exception|NotFound|Not a conda|not an existing|No such file|Killed|denied|exceeded|unbound variable|not found' "$1" 2> /dev/null \
        | grep -v -E '^[[:space:]]*(File "|\^|\+)|^PATH[[:space:]]+SIZE[[:space:]]+ERRORS' | tail -n 1)
    [ -n "$line" ] || line=$(grep -v -E '^[[:space:]]*$' "$1" 2> /dev/null | tail -n 1)
    echo "${line:-(empty)}"
}

# group_errors SOURCES groups the files listed in SOURCES (job name, tab, file) by their error
# line with what varies masked, most frequent first, with the end of one example of each.
group_errors() {
    local sources="$1" lines job_name file line
    lines=$(mktemp)
    while IFS=$'\t' read -r job_name file; do
        line=$(error_line "$file")
        printf '%s\t%s\t%s\t%s\n' "$(normalize <<< "$line")" "${job_name%%_(*}" "$file" "$line"
    done < "$sources" > "$lines"
    if [ ! -s "$lines" ]; then
        echo "(none found)"
        fact error_signatures "none found"
        rm -f "$lines"
        return 0
    fi
    local signatures count signature example
    signatures=$(cut -f1 "$lines" | sort | uniq -c | sort -rn | head -n 30)
    while read -r count signature; do
        echo
        echo "$count x $signature"
        echo "  from: $(awk -F'\t' -v s="$signature" '$1 == s { print $2 }' "$lines" | sort | uniq -c | sort -rn \
            | awk '{ printf "%s%s (%s)", separator, $2, $1; separator = ", " }')"
        example=$(awk -F'\t' -v s="$signature" '$1 == s { print $3; exit }' "$lines")
        echo "  e.g. $(awk -F'\t' -v s="$signature" '$1 == s { print $4; exit }' "$lines")"
        echo "  the end of $example:"
        tail -n 15 "$example" 2> /dev/null | cut -c1-300 | sed 's/^/    | /'
    done <<< "$signatures"
    fact error_signatures "$(head -n 10 <<< "$signatures")"
    fact missing_input_failures "$(grep -c 'not an existing file or folder' "$lines" || true)"
    rm -f "$lines"
}

# --- backup-checkout ------------------------------------------------------------------------

section_backup_checkout() {
    echo "## The simple-s3-backup checkout the backup jobs run from: $BACKUP_CHECKOUT"
    if ! git -C "$BACKUP_CHECKOUT" rev-parse --git-dir > /dev/null 2>&1; then
        echo "It is not a git checkout."
        fact checkout_state "missing or not a git checkout"
        return 0
    fi
    show "Branch and state" git -C "$BACKUP_CHECKOUT" status --short --branch
    show "Recent commits" git -C "$BACKUP_CHECKOUT" log --oneline --decorate -5
    local head github changes untracked
    head=$(git -C "$BACKUP_CHECKOUT" rev-parse HEAD 2> /dev/null)
    github=$(timeout 60 git ls-remote "$BACKUP_REPOSITORY_URL" refs/heads/main 2> /dev/null | cut -f1)
    echo
    echo "### Against GitHub"
    echo "HEAD is ${head:-unknown}; main on GitHub is ${github:-unknown}."
    if [ -n "$github" ] && [ "$github" != "$head" ]; then
        if git -C "$BACKUP_CHECKOUT" merge-base --is-ancestor "$head" "$github" 2> /dev/null; then
            echo "The checkout is behind GitHub's main."
        else
            echo "The checkout's HEAD is not on GitHub's main as far as this checkout knows (it is behind, or has commits of its own)."
        fi
    fi
    changes=$(git -C "$BACKUP_CHECKOUT" status --porcelain --untracked-files=no 2> /dev/null | grep -c . || true)
    untracked=$(git -C "$BACKUP_CHECKOUT" ls-files --others --exclude-standard 2> /dev/null | grep -c . || true)
    echo "Changed files against HEAD: $changes. Untracked files: $untracked."
    fact checkout_state "HEAD ${head:-unknown}, GitHub main ${github:-unknown}, changed files: $changes, untracked files: $untracked"
    fact checkout_changes "$changes"
    show "Commits with dates" git -C "$BACKUP_CHECKOUT" log --format='%h %ad %s' --date=iso -10
    show "When the checkout moved (reflog)" git -C "$BACKUP_CHECKOUT" reflog --date=iso -20
    # Commits that may exist nowhere but here, so they are kept in full.
    local base
    if [ -n "$github" ] && git -C "$BACKUP_CHECKOUT" cat-file -e "$github^{commit}" 2> /dev/null; then
        base="$github"
    else
        base=$(git -C "$BACKUP_CHECKOUT" merge-base HEAD origin/main 2> /dev/null)
    fi
    if [ -n "$base" ] && [ "$base" != "$head" ]; then
        show "Commits of HEAD that are not on main, in full" git -C "$BACKUP_CHECKOUT" log -p --format='commit %H%nDate: %ad%n%n%B' --date=iso "$base..HEAD"
        fact checkout_commits "$(git -C "$BACKUP_CHECKOUT" log --format='%h %ad %s' --date=short "$base..HEAD" 2> /dev/null)"
    fi
    show "Changes against HEAD" git -C "$BACKUP_CHECKOUT" diff HEAD
    show "Untracked files" git -C "$BACKUP_CHECKOUT" ls-files --others --exclude-standard
    local script
    for script in "$BACKUP_CHECKOUT"/scripts/*.sh; do
        show "Deployed $(basename "$script")" cat "$script"
    done

    echo
    echo "## The crontab installed on $LOGIN_HOST"
    local installed
    installed=$(mktemp)
    show "Installed crontab" ssh -o BatchMode=yes -o ConnectTimeout=15 "$LOGIN_HOST" crontab -l
    if timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=15 "$LOGIN_HOST" crontab -l > "$installed" 2> /dev/null; then
        if cmp -s "$installed" "$RUNNER_CHECKOUT/launcher/crontab"; then
            echo "It matches $RUNNER_CHECKOUT/launcher/crontab."
            fact crontab "installed, matches the runner checkout"
        else
            show "Installed crontab against $RUNNER_CHECKOUT/launcher/crontab" diff "$installed" "$RUNNER_CHECKOUT/launcher/crontab"
            fact crontab "installed, differs from the runner checkout"
        fi
    else
        fact crontab "could not be read"
    fi
    rm -f "$installed"
}

# --- backup-environment ---------------------------------------------------------------------

section_backup_environment() {
    echo "## The blob backup job's setup, replayed in cron's environment on $(hostname)"
    if [ ! -f "$BLOB_SCRIPT" ]; then
        echo "$BLOB_SCRIPT does not exist."
        fact setup "the blob backup script does not exist"
        return 0
    fi
    show "SBATCH directives of $BLOB_SCRIPT" grep '^#SBATCH' "$BLOB_SCRIPT"

    # Every command of the script before its first line that runs s3backup, each failure reported
    # where it happens (without `set -e`, a failed setup step only shows in the last command's
    # status). The script is cut there rather than having that line dropped, which would leave an
    # `if` around it without a body.
    local probe output
    probe=$(mktemp)
    output=$(mktemp)
    {
        echo "trap 'echo \"!!! exit \$? from: \$BASH_COMMAND\" >&2' ERR"
        echo 'set -x'
        awk '/s3backup/ { exit } /^[[:space:]]*(#|$)/ { next } { print }' "$BLOB_SCRIPT"
        echo 'set +x'
        cat << 'PROBE'
echo "--- after the setup"
echo "CONDA_PREFIX=${CONDA_PREFIX:-}"
echo "PATH=$PATH"
type s3backup s5cmd python flock
echo "--- s3backup dandi blobs --help"
s3backup dandi blobs --help
echo "--- the package s3backup runs"
python -c 'import simple_s3_backup._base as base, simple_s3_backup; print(simple_s3_backup.__file__)'
echo "--- s5cmd"
s5cmd version
echo "--- listing a blob prefix with the job's credentials"
s5cmd ls 's3://dandiarchive/blobs/482/5cf/*'
echo "--- the same without signing"
s5cmd --no-sign-request ls 's3://dandiarchive/blobs/482/5cf/*'
PROBE
    } > "$probe"
    show "Commands replayed (from $BLOB_SCRIPT, up to its first line that runs s3backup)" cat "$probe"
    echo
    echo "### Replayed in cron's environment (only HOME, LOGNAME, USER, SHELL=/bin/sh and PATH=/usr/bin:/bin set), as array task $REPRODUCE_TASK"
    local status
    # As one task of the array: the script names its lock file after the task, and without a task
    # it would make a stray lock file in the shared lock directory.
    local task_environment=(SLURM_ARRAY_TASK_ID="$REPRODUCE_TASK" SLURM_ARRAY_JOB_ID=replay)
    timeout "$COMMAND_TIMEOUT" "${CRON_ENVIRONMENT[@]}" "${task_environment[@]}" /bin/bash "$probe" > "$output" 2>&1
    status=$?
    head -c "$MAX_OUTPUT_BYTES" "$output"
    echo "[exit $status]"
    local failed_steps
    failed_steps=$(grep '^!!! exit' "$output" | head -n 10)
    [ "$status" -ne 0 ] && [ -z "$failed_steps" ] && failed_steps="the replay itself exited $status: $(grep -v '^+' "$output" | tail -n 1)"
    fact setup_failures "${failed_steps:-none}"
    fact setup_output "$(head -n 200 "$output")"

    # `set -e` or `set -u` in the script ends the replay at the first problem. Without them, the
    # rest of the setup shows whether anything else would fail once that one is fixed.
    if grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*[eu]' "$probe"; then
        sed -i -E 's/^[[:space:]]*set[[:space:]]+-[a-z]*[eu][a-z]*([[:space:]]+(-o[[:space:]]+)?pipefail)?[[:space:]]*$/: removed for this replay/' "$probe"
        echo
        echo "### Replayed again without the script's own set -e and set -u"
        timeout "$COMMAND_TIMEOUT" "${CRON_ENVIRONMENT[@]}" "${task_environment[@]}" /bin/bash "$probe" > "$output" 2>&1
        status=$?
        head -c "$MAX_OUTPUT_BYTES" "$output"
        echo "[exit $status]"
        failed_steps=$(grep '^!!! exit' "$output" | head -n 10)
        [ "$status" -ne 0 ] && [ -z "$failed_steps" ] && failed_steps="the replay itself exited $status: $(grep -v '^+' "$output" | tail -n 1)"
        fact setup_failures_without_set_options "${failed_steps:-none}"
    fi
    rm -f "$probe" "$output"

    echo
    echo "## Lock files"
    show "Lock directory" bash -c "stat -c '%A %y %n' '$BACKUP_DIRECTORY/flocks' '$BACKUP_DIRECTORY'/flocks/*"
    local lock held=()
    for lock in "$BACKUP_DIRECTORY"/flocks/*.lock; do
        [ -e "$lock" ] || continue
        if ! flock -n "$lock" true 2> /dev/null; then
            held+=("$(basename "$lock")")
        fi
    done
    echo "Held right now: ${held[*]:-none}"
    fact locks_held "${held[*]:-none}"

    echo
    echo "## The blob mirror"
    show "Space on the partitions" df -h "${PARTITIONS[@]/#//orcd/data/dandi/}"
    local partition root test_file writable=()
    for partition in "${PARTITIONS[@]}"; do
        root="/orcd/data/dandi/$partition/s3dandiarchive/blobs"
        show "$root" stat -c '%A group %G, changed %y' "$root"
        if [ "$(stat -c %U "$root" 2> /dev/null)" = "$USER_NAME" ]; then
            echo "Owned by the runner's user."
        else
            echo "NOT owned by the runner's user (uid $(stat -c %u "$root" 2> /dev/null))."
        fi
        test_file="$root/.dandi-compute-write-test-$$"
        if touch "$test_file" 2> /dev/null; then
            rm -f "$test_file"
            echo "Writable by the runner's user."
            writable+=("$partition:yes")
        else
            echo "NOT writable by the runner's user."
            writable+=("$partition:no")
        fi
        echo "Top-level prefixes: $(find "$root" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)"
        # A prefix directory changes whenever a blob is added under a new second-level prefix, so the
        # newest of them say roughly when the backup last added anything here.
        show "Most recently changed prefixes of $partition" bash -c "ls -dt '$root'/*/ | head -n 5 | xargs -r stat -c '%y %n'"
    done
    fact mirror_writable "${writable[*]}"
    show "AWS configuration in the home directory (file names only)" bash -c 'ls -A ~/.aws'
}

# --- backup-reproduce -----------------------------------------------------------------------

section_backup_reproduce() {
    echo "## One task of the blob backup, submitted the way cron submits it"
    if [ "$REPRODUCE" != true ]; then
        echo "Skipped: REPRODUCE is not true (scheduled runs do not submit a backup task)."
        fact reproduce "skipped"
        return 0
    fi
    if [ ! -f "$BLOB_SCRIPT" ]; then
        echo "$BLOB_SCRIPT does not exist."
        fact reproduce "the blob backup script does not exist"
        return 0
    fi
    mkdir -p "$BACKUP_LOG_DIRECTORY"
    # The deployed script as it is, traced: `set -x` and an ERR trap go right after its #SBATCH
    # lines, which sbatch only reads before the first command.
    local traced sbatch_path job_id log_file
    traced=$(mktemp)
    awk '
        { lines[NR] = $0 }
        /^#SBATCH/ { last = NR }
        END {
            if (!last) last = 1
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last) {
                    print "trap '\''echo \"!!! exit $? from: $BASH_COMMAND\" >&2'\'' ERR"
                    print "set -x"
                }
            }
        }' "$BLOB_SCRIPT" > "$traced"
    show "Script submitted" cat "$traced"
    sbatch_path=$(command -v sbatch)
    echo
    echo "### Submission"
    # The real job keeps its lock while it runs, so tonight's task of the same number skips
    # rather than running twice.
    job_id=$("${CRON_ENVIRONMENT[@]}" "$sbatch_path" --parsable --array="$REPRODUCE_TASK" \
        --job-name=DANDI-Backup-Blobs-Diagnose \
        --output="$BACKUP_LOG_DIRECTORY/%x-%A_%a.log" --error="$BACKUP_LOG_DIRECTORY/%x-%A_%a.log" "$traced" 2>&1)
    local status=$?
    rm -f "$traced"
    echo "sbatch exited $status: $job_id"
    if [ "$status" -ne 0 ]; then
        fact reproduce "sbatch failed: $job_id"
        return 0
    fi
    job_id="${job_id%%;*}"
    log_file="$BACKUP_LOG_DIRECTORY/DANDI-Backup-Blobs-Diagnose-${job_id}_${REPRODUCE_TASK}.log"

    local waited=0 state="" running_since=""
    while [ "$waited" -lt "$REPRODUCE_WAIT_SECONDS" ]; do
        sleep 10
        waited=$((waited + 10))
        state=$(sacct -j "${job_id}_${REPRODUCE_TASK}" -X -n -P -o State 2> /dev/null | head -n 1)
        state="${state%% *}"
        case "$state" in
            PENDING | REQUEUED | "") continue ;;
            RUNNING | COMPLETING | CONFIGURING)
                [ -z "$running_since" ] && running_since="$waited"
                # Running for two minutes means its setup went through: the backup itself has started.
                [ $((waited - running_since)) -ge 120 ] && break
                ;;
            *) break ;;
        esac
    done
    echo "State after ${waited} seconds: ${state:-unknown}"
    show "sacct for the task and its steps" sacct -j "${job_id}_${REPRODUCE_TASK}" -P \
        -o JobID,JobName,Partition,State,ExitCode,DerivedExitCode,Elapsed,Start,End,NodeList,MaxRSS,Reason
    show "Its log, $log_file" tail -n 300 "$log_file"
    local exit_code
    exit_code=$(sacct -j "${job_id}_${REPRODUCE_TASK}" -X -n -P -o ExitCode 2> /dev/null | head -n 1)
    fact reproduce "job ${job_id}_${REPRODUCE_TASK}: ${state:-unknown} (exit ${exit_code:-unknown}) after ${waited} seconds of watching"
    fact reproduce_state "${state:-unknown}"
    fact reproduce_log_head "$(head -n 200 "$log_file" 2> /dev/null)"
    fact reproduce_log_tail "$(tail -n 60 "$log_file" 2> /dev/null)"
}

# --- slurm-failures -------------------------------------------------------------------------

section_slurm_failures() {
    local since records failures
    since=$(date -d "$DAYS days ago" +%F)
    echo "## Jobs of the runner's user since $since that did not complete"
    if ! records=$(sacct --user "$USER_NAME" --allocations --noheader --parsable2 --starttime "$since" \
        --format JobID,JobName,State,ExitCode,Start,End,Elapsed,WorkDir 2>&1); then
        echo "sacct failed: $records"
        fact slurm_failures "sacct failed"
        return 0
    fi
    failures=$(awk -F'|' '{ split($3, state, " ") }
        state[1] !~ /^(COMPLETED|RUNNING|PENDING|REQUEUED|COMPLETING|CONFIGURING|SUSPENDED|RESIZING)$/' <<< "$records")
    local total failed
    total=$(grep -c . <<< "$records" || true)
    failed=$(grep -c . <<< "$failures" || true)
    echo "$failed of the $total jobs and tasks since $since did not complete."
    fact slurm_failures "$failed of $total jobs and tasks since $since did not complete"

    echo
    echo "### By job name, state and exit code (most frequent first)"
    awk -F'|' '{ split($3, state, " "); key = $2 " | " state[1] " | exit " $4; count[key]++; if ($6 > last[key]) last[key] = $6 }
        END { for (key in count) printf "%6d  %s | last ended %s\n", count[key], key, last[key] }' <<< "$failures" \
        | sort -rn | head -n 60
    fact slurm_failure_groups "$(awk -F'|' '{ split($3, state, " "); count[$2 " (" state[1] ", exit " $4 ")"]++ }
        END { for (key in count) printf "%d  %s\n", count[key], key }' <<< "$failures" | sort -rn | head -n 10)"

    # Where each failed job left its output: a Nextflow task's .command.err in its work directory
    # (Nextflow runs every step of an AIND capsule as a job there), a dispatch task's log under
    # processing/derivatives/logs/, or a backup task's log.
    echo
    echo "### The errors failed jobs ended with"
    local sources job_id job_name work_directory log_file seen=0
    sources=$(mktemp)
    while IFS='|' read -r job_id job_name _ _ _ _ _ work_directory; do
        [ -n "$job_id" ] || continue
        seen=$((seen + 1))
        [ "$seen" -gt "$MAX_WORK_DIRECTORIES" ] && break
        if [ -f "$work_directory/.command.err" ]; then
            printf '%s\t%s\n' "$job_name" "$work_directory/.command.err"
            continue
        fi
        for log_file in "$BASE_DIRECTORY/processing/derivatives/logs/$job_name/"*"-${job_id}.log" \
            "$BACKUP_LOG_DIRECTORY/"*"${job_id}."*; do
            [ -f "$log_file" ] && printf '%s\t%s\n' "$job_name" "$log_file"
        done
    done < <(tac <<< "$failures") > "$sources"
    echo "Found the output of $(cut -f2 "$sources" | sort -u | grep -c . || true) of the newest $((seen > MAX_WORK_DIRECTORIES ? MAX_WORK_DIRECTORIES : seen)) failed jobs."
    group_errors "$sources"
    rm -f "$sources"

    echo
    echo "### The other failed jobs, newest first"
    awk -F'|' '$8 == "" || $8 !~ /\/work\// { printf "%s %s %s exit %s ended %s after %s in %s\n", $1, $2, $3, $4, $6, $7, $8 }' <<< "$failures" \
        | tac | head -n 60
}

# --- missing-blobs --------------------------------------------------------------------------

section_missing_blobs() {
    echo "## Job capsules on the cluster whose input blob is not in the mirror"
    local processing="$BASE_DIRECTORY/processing" listing scripts
    listing=$(mktemp)
    # Only the capsules' code/ directories are wanted, so their outputs are never walked.
    find "$processing" -mindepth 1 -maxdepth 1 -name 'prepare-job-*' -print0 2> /dev/null \
        | timeout 1200 xargs -0 -r -I{} find {} \( -path '*/job-*/derivatives' -o -path '*/job-*/intermediate' -o -path '*/job-*/logs' \) -prune \
            -o -path '*/code/submit.sh' -type f -print 2> /dev/null > "$listing"
    scripts=$(grep -c . "$listing" || true)
    echo "Submission scripts found: $scripts"

    local script blob tree done_mark state other ok=0 elsewhere=0 missing=0 none=0 rows
    rows=$(mktemp)
    while read -r script; do
        blob=$(grep -oE '/orcd/data/dandi/[0-9]{3}/s3dandiarchive/blobs/[0-9a-f]{3}/[0-9a-f]{3}/[0-9a-f-]{36}' "$script" | head -n 1)
        if [ -z "$blob" ]; then
            none=$((none + 1))
            continue
        fi
        tree=$(sed -E 's#^.*/processing/(prepare-job-[^/]+)/.*#\1#' <<< "$script")
        done_mark=no
        grep -qxF "$tree" "$processing/done.txt" 2> /dev/null && done_mark=yes
        if [ -f "$blob" ]; then
            ok=$((ok + 1))
            continue
        fi
        other=""
        for partition in "${PARTITIONS[@]}"; do
            [ -f "${blob/\/dandi\/[0-9][0-9][0-9]\//\/dandi\/$partition\/}" ] && other="$partition"
        done
        if [ -n "$other" ]; then
            state="on partition $other instead"
            elsewhere=$((elsewhere + 1))
        else
            state="not mirrored"
            missing=$((missing + 1))
        fi
        printf '%s | %s | ran to completion: %s | %s\n' "$(basename "$blob")" "$state" "$done_mark" "$(dirname "$(dirname "$script")")" >> "$rows"
    done < "$listing"
    echo "Blob present: $ok. On the other partition: $elsewhere. Not mirrored: $missing. No blob path in the script: $none."
    fact missing_blobs "$scripts capsules on the cluster: $ok with their blob, $elsewhere pointing at the wrong partition, $missing whose blob is not mirrored"
    echo
    echo "### Capsules whose blob is missing (content ID | where it is | whether its script ran to completion | capsule)"
    sort "$rows" | head -n 300
    [ "$(grep -c . "$rows" || true)" -gt 300 ] && echo "... and $(($(grep -c . "$rows") - 300)) more"
    rm -f "$listing" "$rows"
}

# count_files DIRECTORY prints the number of files and directories under DIRECTORY, a tab and its
# path, giving up after COUNT_TIMEOUT seconds with what it counted so far, marked "at least".
count_files() {
    [ -d "$1" ] || return 0
    local count status
    count=$(timeout "$COUNT_TIMEOUT" find "$1" -xdev 2> /dev/null | wc -l)
    status=${PIPESTATUS[0]}
    if [ "$status" -eq 124 ]; then
        printf '%s\t%s (at least; counting stopped after %s seconds)\n' "$count" "$1" "$COUNT_TIMEOUT"
    else
        printf '%s\t%s\n' "$count" "$1"
    fi
}

# --- home-usage -----------------------------------------------------------------------------

section_home_usage() {
    echo "## The home directory"
    # ORCD writes the quota report shown at login every 30 minutes; space and the number of files
    # each have a limit, and every write fails once either is reached.
    local report="$HOME/orcd/.quota" files_used
    show "Quota report" cat "$report"
    files_used=$(awk '$1 == "HOME" { for (i = 1; i <= NF; i++) if ($i == "|") bar++; else if (bar == 6) { print $i; exit } }' "$report" 2> /dev/null)
    local space_used
    space_used=$(awk '$1 == "HOME" { for (i = 1; i <= NF; i++) if ($i == "|") bar++; else if (bar == 3) { print $i; exit } }' "$report" 2> /dev/null)
    fact home_quota "space ${space_used:-unknown}% used, files ${files_used:-unknown}% used"
    # `du` reads every file's attributes, which over a million files on network storage takes over
    # an hour. Listing names is enough to count files, so each directory is counted with `find`,
    # one at a time and each for at most COUNT_TIMEOUT seconds, a count cut short marked as such.
    echo
    echo "### Files in the usual suspects"
    local directory
    for directory in .local/state/dandi-cli/log .apptainer/cache .singularity/cache .cache/bazel .cache/pip \
        .conda/pkgs .nextflow .local/lib .cache; do
        count_files "$HOME/$directory"
    done
    echo
    echo "### Files under each top-level entry of the home directory (most first)"
    local counts
    counts=$(mktemp)
    for directory in "$HOME"/* "$HOME"/.[!.]*; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || continue
        count_files "$directory"
    done | sort -t$'\t' -k1,1rn > "$counts"
    head -n 40 "$counts"
    fact home_file_hogs "$(head -n 5 "$counts")"
    # One level further down in the directory holding the most.
    local largest
    largest=$(head -n 1 "$counts" | cut -f2 | sed "s#^~#$HOME#")
    if [ -n "$largest" ] && [ -d "$largest" ]; then
        echo
        echo "### Inside ${largest/#$HOME/\~} (most first)"
        for directory in "$largest"/* "$largest"/.[!.]*; do
            [ -d "$directory" ] && [ ! -L "$directory" ] || continue
            count_files "$directory"
        done | sort -t$'\t' -k1,1rn | head -n 20
    fi
    rm -f "$counts"
    local dandi_logs
    dandi_logs=$(find "$HOME/.local/state/dandi-cli/log" -maxdepth 1 -type f 2> /dev/null | wc -l)
    echo
    echo "dandi-cli log files: $dandi_logs"
    fact dandi_cli_logs "$dandi_logs"
}

# --- diagnosis ------------------------------------------------------------------------------

# The first step the ERR traps reported failing in TEXT ("!!! exit N from: COMMAND"), with the
# last line the step printed before it.
first_failure() {
    awk '/^!!! exit [0-9]+ from: / {
            command = substr($0, index($0, "from: ") + 6)
            printf "`%s` exited %s", command, $3
            if (message != "") printf ": %s", message
            print ""
            exit
        }
        !/^\+/ { message = $0 }' <<< "$1"
}

# TEXT up to the first failed step, so a later error caused by it is not taken for the cause.
until_first_failure() {
    awk '{ print } /^!!! exit [0-9]+ from: / { exit }' <<< "$1"
}

# A likely cause, from a known message in TEXT.
likely_cause() {
    local text="$1"
    case "$text" in
        *"unbound variable"*)
            echo "The script runs with \`set -u\`, and a file it sources reads a variable cron does not set, so bash stops the job at once: $(grep -m 1 'unbound variable' <<< "$text")" ;;
        *"profile.d/modules.sh"*"No such file"*)
            echo "The module system's setup script is not on the node the job ran on." ;;
        *EnvironmentNameNotFound* | *EnvironmentLocationNotFound* | *"Could not find conda environment"* | *"Not a conda environment"*)
            echo "The conda environment the script activates does not exist at that path." ;;
        *"Run 'conda init'"* | *"conda: command not found"* | *"conda activate: command not found"*)
            echo "conda is not set up in the job's shell, so the environment is never activated." ;;
        *"module: command not found"* | *"Lmod has detected"* | *"unknown module"* | *"are unknown"*)
            echo "The module system, or the module the script loads, is not available to the job." ;;
        *"s3backup: command not found"* | *"failed to execute s3backup"* | *"s3backup: No such file"*)
            echo "s3backup is not on PATH: the environment is not activated, or the package is not installed in it." ;;
        *ModuleNotFoundError* | *ImportError*)
            echo "s3backup cannot import a package: $(grep -oE '(ModuleNotFoundError|ImportError): .*' <<< "$text" | tail -n 1)" ;;
        *"cannot open lock file"* | *"Permission denied"*)
            echo "A file or directory the job writes is not writable: $(grep -E 'cannot open lock file|Permission denied' <<< "$text" | tail -n 1)" ;;
        *"Disk quota exceeded"* | *"No space left on device"*)
            echo "A quota or a full disk stops the job: $(grep -E 'Disk quota exceeded|No space left on device' <<< "$text" | tail -n 1)" ;;
        *Traceback*)
            echo "s3backup raised an exception: $(grep -E '^[A-Za-z_.]+(Error|Exception)' <<< "$text" | tail -n 1)" ;;
        *)
            return 1 ;;
    esac
}

section_diagnosis() {
    local report
    report=$(mktemp)
    {
        echo "## Diagnosis"
        echo
        echo "### The blob backup"
        echo "- Checkout: $(read_fact checkout_state)"
        echo "- Crontab: $(read_fact crontab)"
        echo "- Locks held: $(read_fact locks_held)"
        echo "- Mirror writable: $(read_fact mirror_writable)"
        echo "- Setup steps that failed when replayed in cron's environment:"
        read_fact setup_failures none | sed 's/^/    /'
        echo "- Setup steps that failed when replayed again without the script's set -e and set -u:"
        read_fact setup_failures_without_set_options "(not replayed: the script sets neither)" | sed 's/^/    /'
        echo "- Reproduction: $(read_fact reproduce)"
        local log setup failure cause
        log=$(read_fact reproduce_log_head '')
        setup=$(read_fact setup_output '')
        if failure=$(first_failure "$log") && [ -n "$failure" ]; then
            echo "- First step that failed in the reproduced task: $failure"
        fi
        if failure=$(first_failure "$setup") && [ -n "$failure" ]; then
            echo "- First step that failed in the replayed setup: $failure"
        fi
        if cause=$(likely_cause "$(until_first_failure "$log")") || cause=$(likely_cause "$log$(read_fact reproduce_log_tail '')"); then
            echo "- Likely cause, from the reproduced task's log: $cause"
        elif cause=$(likely_cause "$(until_first_failure "$setup")") || cause=$(likely_cause "$setup"); then
            echo "- Likely cause, from the replayed setup: $cause"
        elif [ "$(read_fact reproduce_state '')" = RUNNING ]; then
            echo "- The reproduced task got through its setup and is backing up, so the job works when submitted now."
        else
            echo "- No known message matched. The end of the reproduced task's log:"
            read_fact reproduce_log_tail '(none)' | tail -n 20 | sed 's/^/    /'
        fi
        if [ "$(read_fact checkout_changes 0)" != 0 ]; then
            echo "- The checkout has local changes that are not on GitHub (see backup-checkout)."
        fi
        if [ -n "$(read_fact checkout_commits '')" ]; then
            echo "- The checkout runs commits that are not on GitHub's main (in full in backup-checkout):"
            read_fact checkout_commits '' | sed 's/^/    /'
        fi
        echo
        echo "### The home directory"
        echo "- Quota: $(read_fact home_quota)"
        echo "- dandi-cli log files: $(read_fact dandi_cli_logs)"
        echo "- Directories holding the most files:"
        read_fact home_file_hogs none | sed 's/^/    /'
        echo
        echo "### Job capsules"
        echo "- Inputs: $(read_fact missing_blobs)"
        echo "- Nextflow tasks that failed on a missing input: $(read_fact missing_input_failures)"
        echo "- SLURM: $(read_fact slurm_failures)"
        echo "- Most frequent failures:"
        read_fact slurm_failure_groups none | sed 's/^/    /'
        echo "- Most frequent errors of failed jobs:"
        read_fact error_signatures none | sed 's/^/    /'
    } > "$report"
    cat "$report"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            mask < "$report"
            echo
            echo "Every section in full: https://github.com/dandi-compute/dandi-compute-global-logs/tree/errors/$(date +%F)/errors"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    rm -f "$report"
}

case "$SECTION" in
    backup-checkout) section_backup_checkout 2>&1 | mask ;;
    backup-environment) section_backup_environment 2>&1 | mask ;;
    backup-reproduce) section_backup_reproduce 2>&1 | mask ;;
    slurm-failures) section_slurm_failures 2>&1 | mask ;;
    missing-blobs) section_missing_blobs 2>&1 | mask ;;
    home-usage) section_home_usage 2>&1 | mask ;;
    diagnosis) section_diagnosis 2>&1 | mask ;;
    *)
        echo "usage: $0 backup-checkout|backup-environment|backup-reproduce|slurm-failures|missing-blobs|home-usage|diagnosis" >&2
        exit 2
        ;;
esac
exit 0
