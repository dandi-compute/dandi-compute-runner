#!/bin/bash
#
# record.sh - run one operation and record it in the global logs repository.
#
# Usage: record.sh KIND NAME -- COMMAND [ARGS...]
#
#   KIND     `logs` for tasks and workflow steps, `monitor` for monitor snapshots
#   NAME     a short name for the operation, used in the record's directory name
#
# The record lands in KIND/{YYYYMMDDTHHMMSS}-NAME/ on the day's branch (YYYY-MM-DD) of the
# global logs repository, a DataLad dataset checked out at $LOG_REPOSITORY, and is pushed to
# GitHub. The command runs under `datalad run`, inside duct when it is available, in a throwaway
# clone, so the shared checkout is locked only while the finished record is moved onto its
# branch. The command runs in the directory record.sh was called from, and record.sh exits with
# its exit status.
#
# Recording never stops the work and never loses a record. Whatever fails along the way is
# written to record.log beside the command's output:
#   - without DataLad, or when `datalad run` fails before the command starts, the command runs
#     anyway and its output is committed with plain git;
#   - when the shared checkout is busy or broken, the record is pushed from the throwaway clone
#     straight to GitHub;
#   - when GitHub cannot be reached either, the record is parked in untracked/unpushed/ in the
#     shared checkout, and the next delivery that gets through commits it under recovered/.
#
# Commands run through record.sh see DANDI_COMPUTE_RECORDED=1, which is how the task scripts
# know not to wrap themselves a second time.

set -u

LOG_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
LOG_REPOSITORY_URL=https://github.com/dandi-compute/dandi-compute-global-logs.git
DATALAD_ENVIRONMENT=/orcd/data/dandi/001/environments/name-datalad_env
RUNNER_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner
LOCK_TIMEOUT_SECONDS=900

if [ "$#" -lt 4 ] || [ "$3" != "--" ]; then
    echo "usage: record.sh KIND NAME -- COMMAND [ARGS...]" >&2
    exit 2
fi
KIND="$1"
NAME="$2"
shift 3

ORIGINAL_DIRECTORY="$PWD"
DATE=$(date +%F)
BRANCH="$DATE"
OUTPUT_PATH="$KIND/$(date +%Y%m%dT%H%M%S)-$NAME"
export DANDI_COMPUTE_RECORDED=1

WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/dandi-compute-record-XXXXXX") || WORK_DIRECTORY=""
CLONE="$WORK_DIRECTORY/logs"
NOTES="$WORK_DIRECTORY/record.log"
cleanup() { [ -n "$WORK_DIRECTORY" ] && rm -rf "$WORK_DIRECTORY"; }
trap cleanup EXIT

note() {
    echo "[record.sh] $*" >&2
    [ -n "$WORK_DIRECTORY" ] && echo "$(date '+%F %T') $*" >> "$NOTES"
}

# ~/.dandi_env carries GH_TOKEN for pushing (and the secrets the tasks need).
set +u
# shellcheck disable=SC1091
[ -f "$HOME/.dandi_env" ] && source "$HOME/.dandi_env"
set -u

# Commits need an identity even where git has none configured.
git config user.email > /dev/null 2>&1 || export GIT_AUTHOR_NAME="DANDI Compute" GIT_AUTHOR_EMAIL="dandi-compute@users.noreply.github.com" \
    GIT_COMMITTER_NAME="DANDI Compute" GIT_COMMITTER_EMAIL="dandi-compute@users.noreply.github.com"

# Push with GH_TOKEN when there is one, without putting it on the command line.
git_push() {
    local repository="$1"
    shift
    if [ -n "${GH_TOKEN:-}" ]; then
        git -C "$repository" -c credential.helper= \
            -c credential.helper='!f() { test "$1" = get && echo username=x-access-token && echo "password=${GH_TOKEN}"; }; f' \
            push "$@"
    else
        git -C "$repository" push "$@"
    fi
}

# --- run the command ------------------------------------------------------------------------

# The throwaway clone starts from the day's branch when the shared checkout has one, from main
# otherwise. It is cloned from GitHub when the shared checkout cannot be cloned.
prepare_clone() {
    [ -n "$WORK_DIRECTORY" ] || { echo "[record.sh] no temporary directory" >&2; return 1; }
    local base=main
    git -C "$LOG_REPOSITORY" rev-parse --verify -q "refs/heads/$BRANCH" > /dev/null 2>&1 && base="$BRANCH"
    if git clone -q --shared --single-branch --branch "$base" "$LOG_REPOSITORY" "$CLONE" 2>> "$NOTES"; then
        return 0
    fi
    note "could not clone the shared checkout at $LOG_REPOSITORY; cloning from GitHub instead"
    rm -rf "$CLONE"
    git ls-remote --exit-code --heads "$LOG_REPOSITORY_URL" "$BRANCH" > /dev/null 2>&1 && base="$BRANCH" || base=main
    git clone -q --depth 1 --single-branch --branch "$base" "$LOG_REPOSITORY_URL" "$CLONE" 2>> "$NOTES" && return 0
    note "could not clone from GitHub either; starting an empty repository"
    rm -rf "$CLONE"
    git init -q -b "$BRANCH" "$CLONE"
}

# The command itself, as recorded: from the clone's root it moves to the directory record.sh
# was called from, runs, and leaves its exit status beside its output. Without duct it also
# captures its own output, which it still echoes.
inner_command() {
    local capture="$1"
    shift
    local script='output="$PWD/$0"; directory="$1"; capture="$2"; shift 2; echo started > "$output/exit_status"
cd "$directory" || { echo 111 > "$output/exit_status"; exit 111; }
if [ "$capture" = yes ]; then "$@" > >(tee "$output/stdout") 2> >(tee "$output/stderr" >&2); else "$@"; fi
status=$?; echo "$status" > "$output/exit_status"; exit "$status"'
    printf '%s\0' bash -c "$script" "$OUTPUT_PATH" "$ORIGINAL_DIRECTORY" "$capture" "$@"
}

# The day's copy of GitHub's script file for a workflow step, which GitHub deletes afterwards.
keep_step_script() {
    local argument
    for argument in "$@"; do
        if [ -n "${RUNNER_TEMP:-}" ] && [ -f "$argument" ] && [[ "$argument" == "$RUNNER_TEMP"/* ]]; then
            cp "$argument" "$CLONE/$OUTPUT_PATH/step.sh"
        fi
    done
}

commit_message() {
    local message="[DANDI Compute] $NAME on $(hostname)"
    local runner_commit
    runner_commit=$(git -C "$RUNNER_REPOSITORY" rev-parse --short HEAD 2> /dev/null) && message+=" (runner $runner_commit)"
    [ -n "${GITHUB_RUN_ID:-}" ] && message+=" for ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
    echo "$message"
}

COMMAND_STATUS=""
run_with_datalad() {
    local datalad="$DATALAD_ENVIRONMENT/bin/datalad"
    [ -x "$datalad" ] || { note "DataLad not found at $datalad"; return 1; }
    local run=()
    if [ -x "$DATALAD_ENVIRONMENT/bin/con-duct" ]; then
        # con-duct directly: `duct` itself execs con-duct from PATH, which need not be this one.
        # --fail-time 0 keeps the logs of a command that fails quickly, which duct would delete.
        run=("$DATALAD_ENVIRONMENT/bin/con-duct" run -q --fail-time 0 -p "$OUTPUT_PATH/")
        mapfile -d '' -t inner < <(inner_command no "$@")
    else
        note "duct not found in $DATALAD_ENVIRONMENT; recording without resource usage"
        mapfile -d '' -t inner < <(inner_command yes "$@")
    fi
    run+=("${inner[@]}")
    # datalad run fills {placeholders} in the command, so literal braces are doubled.
    run=("${run[@]//\{/\{\{}")
    run=("${run[@]//\}/\}\}}")

    local start
    start=$(git -C "$CLONE" rev-parse -q --verify HEAD)
    # The command's own output passes through to wherever record.sh's goes, as well as into the record.
    (cd "$CLONE" && "$datalad" -l warning -f disabled run --explicit -m "$(commit_message)" --output "$OUTPUT_PATH" -- "${run[@]}")
    local datalad_status=$?

    if [ ! -f "$CLONE/$OUTPUT_PATH/exit_status" ]; then
        note "datalad run exited $datalad_status before the command started"
        return 1
    fi
    COMMAND_STATUS=$(cat "$CLONE/$OUTPUT_PATH/exit_status")
    if [ "$COMMAND_STATUS" = started ]; then
        # Started but never finished: running it again could repeat whatever it did.
        note "the command started but did not finish (datalad run exited $datalad_status)"
        COMMAND_STATUS=1
    fi
    if [ "$(git -C "$CLONE" rev-parse -q --verify HEAD)" = "$start" ]; then
        # A failing command leaves its run record in .git/COMMIT_EDITMSG for saving by hand.
        if [ -f "$CLONE/.git/COMMIT_EDITMSG" ]; then
            (cd "$CLONE" && "$datalad" -l warning -f disabled save -F .git/COMMIT_EDITMSG -- "$OUTPUT_PATH") 2>> "$NOTES" \
                || note "could not save the run record of the failed command"
        fi
    fi
    return 0
}

run_without_datalad() {
    note "running the command without DataLad"
    mapfile -d '' -t inner < <(inner_command yes "$@")
    (cd "$CLONE" && "${inner[@]}")
    COMMAND_STATUS=$(cat "$CLONE/$OUTPUT_PATH/exit_status" 2> /dev/null || echo 1)
    [ "$COMMAND_STATUS" = started ] && COMMAND_STATUS=1
}

commit_pending() {
    local message="$1"
    [ -s "$NOTES" ] && cp "$NOTES" "$CLONE/$OUTPUT_PATH/record.log"
    git -C "$CLONE" add -A -- "$OUTPUT_PATH" 2>> "$NOTES"
    git -C "$CLONE" diff --cached --quiet || git -C "$CLONE" commit -q -m "$message" 2>> "$NOTES"
}

# --- deliver the record ---------------------------------------------------------------------

# Move the clone's commits made since the last delivery onto the day's branch in the shared
# checkout, commit anything parked earlier, and push, all under the shared checkout's lock.
DELIVERED=""
deliver_through_shared_checkout() {
    local lock_file="$LOG_REPOSITORY/.git/dandi-compute-record.lock" status
    exec 9> "$lock_file" || { note "cannot open $lock_file"; return 1; }
    if flock -w "$LOCK_TIMEOUT_SECONDS" 9; then
        move_onto_shared_branch
        status=$?
    else
        note "timed out waiting for the shared checkout"
        status=1
    fi
    exec 9>&-
    [ "$status" -eq 0 ] && DELIVERED=$(git -C "$CLONE" rev-parse HEAD)
    return "$status"
}

move_onto_shared_branch() {
    (
        set -e
        cd "$LOG_REPOSITORY"
        git cherry-pick --abort > /dev/null 2>&1 || true
        git rebase --abort > /dev/null 2>&1 || true
        git reset -q --hard
        git fetch -q origin 2>> "$NOTES" || echo "$(date '+%F %T') could not fetch from GitHub" >> "$NOTES"
        if git rev-parse --verify -q "refs/heads/$BRANCH" > /dev/null; then
            git checkout -q "$BRANCH"
        elif git rev-parse --verify -q "refs/remotes/origin/$BRANCH" > /dev/null; then
            git checkout -q -b "$BRANCH" "origin/$BRANCH"
        else
            git checkout -q -b "$BRANCH" main
        fi
        if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" > /dev/null; then
            git rebase -q "origin/$BRANCH" 2>> "$NOTES"
        fi
        git fetch -q "$CLONE" HEAD
        git cherry-pick --allow-empty --keep-redundant-commits "${DELIVERED:-$CLONE_START}..FETCH_HEAD" > /dev/null 2>> "$NOTES"
        if [ -n "$(ls -A untracked/unpushed 2> /dev/null)" ]; then
            mkdir -p recovered
            cp -r untracked/unpushed/. recovered/
            rm -rf untracked/unpushed
            git add -A recovered
            git commit -q -m "[DANDI Compute] recovered records that could not be delivered earlier"
        fi
    ) 9>&- || {
        note "could not move the record onto $BRANCH in the shared checkout"
        git -C "$LOG_REPOSITORY" cherry-pick --abort > /dev/null 2>&1
        git -C "$LOG_REPOSITORY" rebase --abort > /dev/null 2>&1
        return 1
    }

    local attempt
    for attempt in 1 2 3; do
        git_push "$LOG_REPOSITORY" -q origin "$BRANCH" 2>> "$NOTES" && return 0
        git -C "$LOG_REPOSITORY" pull -q --rebase origin "$BRANCH" 2>> "$NOTES" || true
        sleep $((attempt * 5))
    done
    note "could not push $BRANCH from the shared checkout; it stays there for the next push"
    return 0
}

# Push the clone's commits straight to the day's branch on GitHub.
deliver_directly() {
    local attempt
    for attempt in 1 2 3; do
        if git -C "$CLONE" fetch -q "$LOG_REPOSITORY_URL" "$BRANCH" 2>> "$NOTES"; then
            git -C "$CLONE" rebase -q FETCH_HEAD 2>> "$NOTES" || { git -C "$CLONE" rebase --abort; note "could not rebase onto GitHub's $BRANCH"; }
        fi
        git_push "$CLONE" -q "$LOG_REPOSITORY_URL" "HEAD:refs/heads/$BRANCH" 2>> "$NOTES" && return 0
        sleep $((attempt * 5))
    done
    note "could not push to GitHub"
    return 1
}

# Last resort: keep the record's files beside the shared checkout for the next delivery.
park() {
    local parked="$LOG_REPOSITORY/untracked/unpushed/$DATE/$(basename "$OUTPUT_PATH")"
    mkdir -p "$parked" && cp -r "$CLONE/$OUTPUT_PATH/." "$parked/" && cp "$NOTES" "$parked/record.log" \
        && note "parked the record in $parked" && return 0
    echo "[record.sh] could not park the record; it is lost: $OUTPUT_PATH" >&2
}

# --- main -----------------------------------------------------------------------------------

# Called from the file's last line, so bash has read all of record.sh before any of it runs and a
# `git pull` that rewrites it mid-run (the Update codebase workflow) cannot disturb it.
main() {
    if ! prepare_clone; then
        note "could not prepare anywhere to record; running the command unrecorded"
        "$@"
        exit $?
    fi
    CLONE_START=$(git -C "$CLONE" rev-parse -q --verify HEAD || true)
    mkdir -p "$CLONE/$OUTPUT_PATH"
    keep_step_script "$@"

    run_with_datalad "$@" || run_without_datalad "$@"
    commit_pending "[DANDI Compute] $NAME: $([ -s "$NOTES" ] && echo "record.log" || echo "output")"

    if [ -z "$CLONE_START" ]; then
        # An empty repository has nothing to cherry-pick from; only a direct push can deliver it.
        deliver_directly || park
    elif ! deliver_through_shared_checkout; then
        commit_pending "[DANDI Compute] $NAME: record.log (delivery)"
        deliver_directly || park
    elif [ -s "$NOTES" ] && ! cmp -s "$NOTES" "$CLONE/$OUTPUT_PATH/record.log"; then
        # Problems met while delivering belong in the record too.
        commit_pending "[DANDI Compute] $NAME: record.log (delivery)"
        deliver_through_shared_checkout || deliver_directly || park
    fi

    exit "${COMMAND_STATUS:-1}"
}

main "$@"; exit $?
