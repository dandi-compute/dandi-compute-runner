#!/bin/bash
#
# publish_checksum_mismatches.sh - keep the ledger of checksum mismatches of the S3 backup on the
# checksum-mismatches branch of the global logs repository.
#
# The DANDI-Verify-Checksums job (see launcher/backup.sh), and any `s3backup dandi verify-checksums`
# run by hand, appends to LEDGER every mirrored blob found not to match the bucket and what became
# of it. This puts a copy of the ledger, passed through launcher/redact.sed, at
# checksum-mismatches.tsv on the checksum-mismatches branch: a single branch, never deleted, unlike
# the day branches of record.sh, so the ledger always has the same address. The branch's history
# keeps every version.
#
# Run by the crontab every hour. It does nothing while there is no ledger, or while the ledger is as
# it was last published (PUBLISHED holds that copy). Otherwise it records itself under logs/, through
# record.sh like the other launchers, and publishes. A publication that fails leaves PUBLISHED as it
# was, so the next hour tries again.

set -uo pipefail

LEDGER=/orcd/data/dandi/001/backup/checksum_mismatches.tsv
LOG_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-global-logs
RUNNER_REPOSITORY=/orcd/data/dandi/001/dandi-compute/dandi-compute-runner
BRANCH=checksum-mismatches
FILE=checksum-mismatches.tsv
PUBLISHED="$LOG_REPOSITORY/untracked/$BRANCH.published"
# This script's own worktree of the shared checkout, and its own lock, so it never waits on the
# deliveries of record.sh nor they on it.
WORKTREE="$LOG_REPOSITORY/untracked/worktrees/$BRANCH"
LOCK_FILE="$LOG_REPOSITORY/.git/dandi-compute-$BRANCH.lock"
LOCK_TIMEOUT_SECONDS=600
REDACT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/redact.sed"

[ -f "$LEDGER" ] || exit 0

WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/dandi-compute-ledger-XXXXXX") || exit 1
trap 'rm -rf "$WORK_DIRECTORY"' EXIT
LEDGER_COPY="$WORK_DIRECTORY/$FILE"
if [ -f "$REDACT_SCRIPT" ]; then
    sed -E -f "$REDACT_SCRIPT" "$LEDGER" > "$LEDGER_COPY" || exit 1
else
    sed -E -e 's#(://)[^/@[:space:]]+@#\1***@#g' "$LEDGER" > "$LEDGER_COPY" || exit 1
fi
cmp -s "$LEDGER_COPY" "$PUBLISHED" && exit 0

if [ -z "${DANDI_COMPUTE_RECORDED:-}" ]; then
    exec "$RUNNER_REPOSITORY/launcher/record.sh" logs publish-checksum-mismatches -- "$0" "$@"
fi

# Commits need an identity even where git has none configured.
git config user.email > /dev/null 2>&1 || export GIT_AUTHOR_NAME="DANDI Compute" GIT_AUTHOR_EMAIL="dandi-compute@users.noreply.github.com" \
    GIT_COMMITTER_NAME="DANDI Compute" GIT_COMMITTER_EMAIL="dandi-compute@users.noreply.github.com"

exec 9> "$LOCK_FILE" || { echo "Cannot open $LOCK_FILE." >&2; exit 1; }
if ! flock -w "$LOCK_TIMEOUT_SECONDS" 9; then
    echo "Timed out waiting for $LOCK_FILE; the next run publishes the ledger." >&2
    exit 1
fi

# The worktree, made afresh when it is missing or broken; whatever it held is on GitHub.
if ! top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2> /dev/null) || [ "$top" != "$(cd "$WORKTREE" && pwd -P)" ]; then
    rm -rf "$WORKTREE"
    git -C "$LOG_REPOSITORY" worktree prune
    mkdir -p "$(dirname "$WORKTREE")" && git -C "$LOG_REPOSITORY" worktree add -q --detach "$WORKTREE" \
        || { echo "Could not make the worktree $WORKTREE." >&2; exit 1; }
fi
cd "$WORKTREE" || exit 1

runner_commit=$(git -C "$RUNNER_REPOSITORY" rev-parse --short HEAD 2> /dev/null || echo unknown)
events=$(($(wc -l < "$LEDGER_COPY") - 1))
# The ledger is the whole content of the file, so a push GitHub turns down is redone from GitHub's
# branch as it is then, rather than merged.
for attempt in 1 2 3; do
    git cherry-pick --abort > /dev/null 2>&1
    git rebase --abort > /dev/null 2>&1
    git reset -q --hard
    git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2> /dev/null
    if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" > /dev/null; then
        git checkout -q -B "$BRANCH" "origin/$BRANCH"
    else
        # The first publication starts the branch from main, as every branch of the repository is.
        git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" && git checkout -q -B "$BRANCH" origin/main
    fi || { echo "Could not check out $BRANCH in $WORKTREE." >&2; sleep $((attempt * 5)); continue; }

    cp "$LEDGER_COPY" "$FILE" && git add -- "$FILE" || exit 1
    if git diff --cached --quiet; then
        echo "$BRANCH already holds the ledger as it is."
        cp "$LEDGER_COPY" "$PUBLISHED"
        exit 0
    fi
    git commit -q -m "[DANDI Compute] checksum mismatches: $events events (runner $runner_commit)" || exit 1
    if git push -q origin "$BRANCH"; then
        cp "$LEDGER_COPY" "$PUBLISHED"
        echo "Published the ledger of $events events to $BRANCH:"
        tail -n +2 "$LEDGER_COPY" | tail -n 20
        exit 0
    fi
    sleep $((attempt * 5))
done
echo "Could not push $BRANCH to GitHub; the next run tries again." >&2
exit 1
