#!/bin/bash
#
# scrub_global_logs.sh - mask credentials in the records that the shared checkout of the global
# logs repository has not pushed yet, so GitHub's push protection lets them through.
#
# Records made before record.sh masked them could hold a token that duct sampled from a command
# line, and duct's info.json the host, user, OS and SLURM variables it now leaves out. Only commits
# GitHub does not have are rewritten, their files and messages alike, with launcher/redact.sed and
# under the lock record.sh delivers under. The next record pushes them.
#
# Each file version new since GitHub's copy is masked once, and only the commits holding a version
# that changed get it swapped in their index; nothing is checked out, so a day's backlog of
# hundreds of records takes seconds rather than hours.

set -euo pipefail

LOG_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
REDACT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/redact.sed"
STRIP_DUCT_INFO="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/strip_duct_info.py"
PYTHON=/orcd/data/dandi/001/environments/name-datalad_env/bin/python
[ -x "$PYTHON" ] || PYTHON=$(command -v python3)

cd "$LOG_REPOSITORY"
exec 9> .git/dandi-compute-record.lock
echo "Waiting for the shared checkout, which record.sh locks while it delivers a record..."
flock 9

git cherry-pick --abort > /dev/null 2>&1 || true
git rebase --abort > /dev/null 2>&1 || true
git reset -q --hard
git fetch -q --prune origin
current=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Writes "old new" to $WORK/map for every blob new in $1..$2 that masking changes.
map_masked_blobs() {
    : > "$WORK/map"
    local type object path name masked
    git rev-list --objects "$1..$2" \
        | git cat-file --batch-check='%(objecttype) %(objectname) %(rest)' \
        | while read -r type object path; do
            [ "$type" = blob ] || continue
            name=$(basename "$path")
            [ "$name" = info.json ] || name=file
            git cat-file blob "$object" | sed -E -f "$REDACT_SCRIPT" > "$WORK/$name"
            [ "$name" = info.json ] && "$PYTHON" "$STRIP_DUCT_INFO" "$WORK/$name"
            masked=$(git hash-object -w "$WORK/$name")
            [ "$masked" = "$object" ] || echo "$object $masked"
        done | sort -u > "$WORK/map"
}

# The day's branches of every kind (KIND/YYYY-MM-DD), and the undivided YYYY-MM-DD ones from before.
for branch in $(git for-each-ref --format='%(refname:short)' 'refs/heads/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
    'refs/heads/*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'); do
    if git rev-parse --verify -q "refs/remotes/origin/$branch" > /dev/null; then
        base="origin/$branch"
    else
        base=$(git merge-base origin/main "$branch")
    fi
    count=$(git rev-list --count "$base..$branch")
    echo "$branch: $count commit(s) not on GitHub"
    [ "$count" -gt 0 ] || continue

    map_masked_blobs "$base" "$branch"
    messages_masked=no
    git log --format=%B "$base..$branch" > "$WORK/messages"
    sed -E -f "$REDACT_SCRIPT" "$WORK/messages" | cmp -s - "$WORK/messages" || messages_masked=yes
    echo "$branch: $(wc -l < "$WORK/map") file version(s) to mask, messages to mask: $messages_masked"
    [ -s "$WORK/map" ] || [ "$messages_masked" = yes ] || continue

    # The index filter swaps each mapped blob wherever a commit holds it, through one
    # update-index per commit.
    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
        --index-filter "git ls-files -s | awk 'NR == FNR { masked[\$1] = \$2; next }
            { split(\$0, entry, \"\\t\"); split(entry[1], field, \" \")
              if (field[2] in masked) printf \"%s %s\\t%s\\n\", field[1], masked[field[2]], entry[2] }' '$WORK/map' - \
            | git update-index --index-info" \
        --msg-filter "sed -E -f '$REDACT_SCRIPT'" \
        -- "$base..$branch" > /dev/null
done
git for-each-ref --format='%(refname)' refs/original/ | xargs -r -n 1 git update-ref -d

# Records parked for a later delivery are committed from there as they are, so they are masked too.
if [ -d untracked/unpushed ]; then
    echo "Masking the records parked in untracked/unpushed/"
    find untracked/unpushed -type f -exec sed -i -E -f "$REDACT_SCRIPT" {} +
    find untracked/unpushed -type f -name info.json -exec "$PYTHON" "$STRIP_DUCT_INFO" {} +
fi
git checkout -q "$current"
git reset -q --hard
echo "Done. The next record pushes these branches."
