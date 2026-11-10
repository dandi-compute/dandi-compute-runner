#!/bin/bash
#
# Clear Bazel's output root in the home directory, ~/.cache/bazel/_bazel_$USER, except what a Bazel
# command may still be using. Run by the crontab on the login node every 15 minutes: Bazel fills it
# with hundreds of thousands of files within hours, and the home directory has a quota on the
# number of files as well as on space (see disk.sh).
#
# The output root holds an output base for each workspace Bazel ran in (a directory named by a
# hash, with the build, the external repositories and the Bazel server's files), the install base
# of each Bazel version under install/, and the download cache under cache/. Deleting files on the
# shared filesystem from here breaks a Bazel command using them on another node, so:
#
#   - an output base is deleted once it has been idle for IDLE_MINUTES, that is, once nothing
#     directly in it or in its server/ directory has been modified for that long. A running Bazel
#     command writes its command.log and its server's java.log there at least once a minute;
#   - install/ and cache/ serve every output base, so they are deleted only while no output base
#     is kept, and only once they themselves have not changed for IDLE_MINUTES either (Bazel
#     changes install/ when it unpacks a new install base, before it makes the output base). What
#     is inside them is not looked at: Bazel dates the files of an install base years ahead;
#   - anything else directly in the output root is treated like an output base.
#
# What is idle goes even if a program started from it is still running (a binary run from
# bazel-bin after the build finished); Bazel is not told of that, and neither is this script.
#
# Bazel can leave read-only directories behind (the Go module cache of rules_go does), and nothing
# in one can be deleted until it is writable again, so those are made writable first. Only the
# directories are, not every file, which over the network filesystem would take as long as the
# deleting itself. Symbolic links (the output base links into the workspace) are deleted, never
# followed.
#
# The run says what it deleted, with how many files and directories, and what it kept and why.
# For an output base it also gives the workspace Bazel ran in, which Bazel writes to the output
# base's DO_NOT_BUILD_HERE, so the records show what keeps running Bazel. It exits non-zero when
# something could not be deleted.
#
# Run on its own it records itself in the global logs repository (see launcher/record.sh).
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs clean-bazel -- "$0"
fi

set -uo pipefail
shopt -s nullglob dotglob

OUTPUT_ROOT="$HOME/.cache/bazel/_bazel_$(id -un)"
IDLE_MINUTES=60
SHARED=(install cache)

if [ ! -d "$OUTPUT_ROOT" ]; then
    echo "$OUTPUT_ROOT: not there, skipped"
    exit 0
fi

# is_shared NAME tells whether NAME is one of SHARED.
is_shared() {
    local shared
    for shared in "${SHARED[@]}"; do
        [ "$1" = "$shared" ] && return 0
    done
    return 1
}

# is_idle DEPTH PATH... tells whether nothing within DEPTH levels of the PATHs (0 for the PATHs
# themselves) was modified in the last IDLE_MINUTES. A PATH that cannot be read counts as in use.
is_idle() {
    local depth="$1"
    shift
    local recent
    recent=$(find "$@" -maxdepth "$depth" -mmin -"$IDLE_MINUTES" -print -quit) || return 1
    [ -z "$recent" ]
}

# remove PATH deletes PATH and everything in it, and says how many files and directories that was.
remove() {
    local path="$1"
    find "$path" -type d ! -perm -u=w -exec chmod u+w {} +
    local chmod_status=$?
    local count
    count=$(find "$path" -delete -print | wc -l)
    local delete_status=$?
    if [ "$chmod_status" -eq 0 ] && [ "$delete_status" -eq 0 ]; then
        echo "$path: deleted, $count files and directories"
        return 0
    fi
    echo "$path: not all deleted, $count files and directories were"
    return 1
}

status=0
kept=0
for entry in "$OUTPUT_ROOT"/*; do
    is_shared "$(basename "$entry")" && continue
    if [ -f "$entry/DO_NOT_BUILD_HERE" ] && [ ! -L "$entry/DO_NOT_BUILD_HERE" ]; then
        echo "$entry: the output base of workspace $(head -c 1024 "$entry/DO_NOT_BUILD_HERE")"
    fi
    paths=("$entry")
    [ -d "$entry/server" ] && [ ! -L "$entry/server" ] && paths+=("$entry/server")
    if is_idle 1 "${paths[@]}"; then
        remove "$entry" || status=1
    else
        echo "$entry: kept, in use in the last $IDLE_MINUTES minutes"
        kept=1
    fi
done
for name in "${SHARED[@]}"; do
    entry="$OUTPUT_ROOT/$name"
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ "$kept" -eq 1 ]; then
        echo "$entry: kept, an output base is in use"
    elif ! is_idle 0 "$entry"; then
        echo "$entry: kept, changed in the last $IDLE_MINUTES minutes"
    else
        remove "$entry" || status=1
    fi
done
exit "$status"
