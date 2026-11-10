#!/bin/bash
#
# Keep Bazel's output root out of the home directory, and clear from it whatever no Bazel command
# may still be using. Run by the crontab on the login node every 15 minutes: Bazel fills an output
# root with hundreds of thousands of files within hours, and the home directory has a quota on the
# number of files as well as on space (see disk.sh).
#
# ~/.bazelrc is kept a symbolic link to launcher/bazelrc, which moves the output root to
# /orcd/data/dandi/001/dandi-compute/work/bazel. The link is made when there is no ~/.bazelrc; one
# that is something else is left alone, and the run fails until it is removed. Where that path is
# not reachable, in a container that binds the home directory but not /orcd/data/dandi/001, the
# link dangles and Bazel falls back to ~/.cache/bazel/_bazel_$USER, so both output roots are
# cleared, the same way.
#
# An output root holds an output base for each workspace Bazel ran in (a directory named by a
# hash, with the build, the external repositories and the Bazel server's files), the install base
# of each Bazel version under install/, and the download cache under cache/. Deleting files on the
# shared filesystem from here breaks a Bazel command using them on another node, so:
#
#   - an output base is deleted once it has been idle for IDLE_MINUTES, that is, once nothing
#     directly in it or in its server/ directory has been modified for that long. A running Bazel
#     command reports its progress to command.log there at least once a minute, even while an
#     action runs without a word;
#   - install/ and cache/ serve every output base, so they are deleted only while no output base
#     of the same root is kept, and only once they themselves have not changed for IDLE_MINUTES
#     either (Bazel changes install/ when it unpacks a new install base, before it makes the output
#     base). What is inside them is not looked at: Bazel dates the files of an install base years
#     ahead;
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
# something could not be deleted or ~/.bazelrc is not the link.
#
# Run on its own it records itself in the global logs repository (see launcher/record.sh).
if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec /orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/record.sh logs clean-bazel -- "$0"
fi

set -uo pipefail
shopt -s nullglob dotglob

BAZELRC="$HOME/.bazelrc"
BAZELRC_TARGET="/orcd/data/dandi/001/dandi-compute/dandi-compute-runner/launcher/bazelrc"
HOME_OUTPUT_ROOT="$HOME/.cache/bazel/_bazel_$(id -un)"
IDLE_MINUTES=60
SHARED=(install cache)

# link_bazelrc makes BAZELRC a link to BAZELRC_TARGET when there is no BAZELRC, and says whether
# it is that link.
link_bazelrc() {
    if [ -L "$BAZELRC" ] && [ "$(readlink "$BAZELRC")" = "$BAZELRC_TARGET" ]; then
        echo "$BAZELRC: links to $BAZELRC_TARGET"
    elif [ -e "$BAZELRC" ] || [ -L "$BAZELRC" ]; then
        echo "$BAZELRC: left alone, but it is not the link to $BAZELRC_TARGET, so Bazel may still fill the home directory"
        return 1
    elif ln -s "$BAZELRC_TARGET" "$BAZELRC"; then
        echo "$BAZELRC: linked to $BAZELRC_TARGET"
    else
        return 1
    fi
}

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

# clear_output_root ROOT deletes what is idle in the output root ROOT, as described above.
clear_output_root() {
    local root="$1"
    if [ ! -d "$root" ]; then
        echo "$root: not there, skipped"
        return 0
    fi
    local result=0 kept=0 entry name paths
    for entry in "$root"/*; do
        is_shared "$(basename "$entry")" && continue
        if [ -f "$entry/DO_NOT_BUILD_HERE" ] && [ ! -L "$entry/DO_NOT_BUILD_HERE" ]; then
            echo "$entry: the output base of workspace $(head -c 1024 "$entry/DO_NOT_BUILD_HERE")"
        fi
        paths=("$entry")
        [ -d "$entry/server" ] && [ ! -L "$entry/server" ] && paths+=("$entry/server")
        if is_idle 1 "${paths[@]}"; then
            remove "$entry" || result=1
        else
            echo "$entry: kept, in use in the last $IDLE_MINUTES minutes"
            kept=1
        fi
    done
    for name in "${SHARED[@]}"; do
        entry="$root/$name"
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        if [ "$kept" -eq 1 ]; then
            echo "$entry: kept, an output base is in use"
        elif ! is_idle 0 "$entry"; then
            echo "$entry: kept, changed in the last $IDLE_MINUTES minutes"
        else
            remove "$entry" || result=1
        fi
    done
    return "$result"
}

status=0
link_bazelrc || status=1
# The output root launcher/bazelrc names, read from it so the two cannot disagree.
cache_output_root=$(sed -n 's/^startup --output_user_root=//p' "$BAZELRC_TARGET" 2> /dev/null | tail -n 1)
clear_output_root "$HOME_OUTPUT_ROOT" || status=1
if [ -n "$cache_output_root" ]; then
    clear_output_root "$cache_output_root" || status=1
else
    echo "$BAZELRC_TARGET: names no output root, so none but the home directory's is cleared"
    status=1
fi
exit "$status"
